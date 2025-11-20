//
//  USBFormatterService.swift
//  RufusX
//
//  Created by 陳德生 on 2025/11/20.
//

import Foundation

final class USBFormatterService {

    // MARK: - Error Types

    enum FormatterError: LocalizedError {
        case deviceNotFound
        case unmountFailed(String)
        case formatFailed(String)
        case mountFailed(String)
        case copyFailed(String)
        case isoMountFailed(String)
        case permissionDenied
        case cancelled
        case largeFileOnFAT32(String)
        case ddFailed(String)

        var errorDescription: String? {
            switch self {
            case .deviceNotFound:
                return "USB device not found"
            case .unmountFailed(let message):
                return "Failed to unmount device: \(message)"
            case .formatFailed(let message):
                return "Failed to format device: \(message)"
            case .mountFailed(let message):
                return "Failed to mount device: \(message)"
            case .copyFailed(let message):
                return "Failed to copy files: \(message)"
            case .isoMountFailed(let message):
                return "Failed to mount ISO: \(message)"
            case .permissionDenied:
                return "Permission denied. Please grant disk access."
            case .cancelled:
                return "Operation cancelled"
            case .largeFileOnFAT32(let filename):
                return "File '\(filename)' is too large for FAT32. Please use ExFAT or NTFS."
            case .ddFailed(let message):
                return "DD Write failed: \(message)"
            }
        }
    }

    // MARK: - Properties

    private var isCancelled = false
    private var currentProcess: Process?

    // MARK: - Public Methods

    func cancel() {
        isCancelled = true
        currentProcess?.terminate()
    }

    func formatUSBDrive(
        device: USBDevice,
        options: RufusOptions,
        progressHandler: @escaping (OperationStatus) -> Void,
        logHandler: @escaping (String, LogLevel) -> Void
    ) async throws {

        isCancelled = false

        // DD Mode Path
        if options.ddMode, let isoPath = options.isoFilePath {
            progressHandler(.preparing)
            try await writeImageDD(
                device: device,
                isoPath: isoPath,
                progressHandler: progressHandler,
                logHandler: logHandler
            )
            
            logHandler("DD Write completed successfully", .success)
            progressHandler(.completed)
            return
        }

        // Standard Mode Path
        
        // Pre-flight Check: FAT32 > 4GB
        if let isoPath = options.isoFilePath {
            logHandler("Checking ISO requirements...", .info)
            try await checkISORequirements(isoPath: isoPath, fileSystem: options.fileSystem)
        }

        // Step 1: Get disk identifier BEFORE unmounting
        logHandler("Identifying device: \(device.name)", .info)
        progressHandler(.preparing)

        let diskIdentifier = try await getDiskIdentifier(for: device)
        logHandler("Device identifier: \(diskIdentifier)", .info)

        if isCancelled { throw FormatterError.cancelled }

        // Step 2: Unmount the device
        logHandler("Unmounting device...", .info)
        try await unmountDevice(device)

        if isCancelled { throw FormatterError.cancelled }

        // Step 3: Format the device
        logHandler("Formatting device with \(options.fileSystem.rawValue) (\(options.partitionScheme.rawValue))", .info)
        progressHandler(.formatting(progress: 0.1))
        try await formatDevice(
            diskIdentifier: diskIdentifier,
            fileSystem: options.fileSystem,
            volumeLabel: options.volumeLabel,
            partitionScheme: options.partitionScheme,
            progressHandler: progressHandler
        )

        if isCancelled { throw FormatterError.cancelled }

        // Step 4: Mount ISO and copy files
        if let isoPath = options.isoFilePath {
            logHandler("Mounting ISO: \(isoPath.lastPathComponent)", .info)
            progressHandler(.copying(progress: 0, currentFile: "Mounting ISO..."))

            let isoMountPoint = try await mountISO(isoPath)

            defer {
                Task {
                    try? await unmountISO(isoMountPoint)
                }
            }

            if isCancelled { throw FormatterError.cancelled }

            // Wait for USB to remount
            try await Task.sleep(nanoseconds: 2_000_000_000)

            let usbMountPoint = try await waitForMount(diskIdentifier: diskIdentifier)

            logHandler("Copying files to USB...", .info)
            try await copyFiles(
                from: isoMountPoint,
                to: usbMountPoint,
                progressHandler: progressHandler,
                logHandler: logHandler
            )

            // Step 5: Setup boot sector
            let bootSectorService = BootSectorService()
            try await bootSectorService.setupBootSector(
                diskIdentifier: diskIdentifier,
                usbMountPoint: usbMountPoint,
                isoMountPoint: isoMountPoint,
                targetSystem: options.targetSystem,
                partitionScheme: options.partitionScheme,
                logHandler: logHandler
            )

            // Step 6: Create persistence partition for Linux if requested
            if options.persistentPartitionSizeGB > 0 {
                let persistenceService = PersistenceService()
                let distroType = persistenceService.detectLinuxDistro(isoMountPoint: isoMountPoint)

                if distroType != .other || options.persistentPartitionSizeGB > 0 {
                    try await persistenceService.createPersistencePartition(
                        diskIdentifier: diskIdentifier,
                        sizeGB: options.persistentPartitionSizeGB,
                        distroType: distroType,
                        logHandler: logHandler
                    )
                }
            }
        }

        if isCancelled { throw FormatterError.cancelled }

        logHandler("Operation completed successfully", .success)
        progressHandler(.completed)
    }

    // MARK: - Private Methods

    private func unmountDevice(_ device: USBDevice) async throws {
        let result = try await runCommand(
            "/usr/sbin/diskutil",
            arguments: ["unmountDisk", device.mountPoint]
        )

        if result.exitCode != 0 {
            throw FormatterError.unmountFailed(result.error)
        }
    }

    private func getDiskIdentifier(for device: USBDevice) async throws -> String {
        let result = try await runCommand(
            "/usr/sbin/diskutil",
            arguments: ["info", device.mountPoint]
        )

        guard result.exitCode == 0 else {
            throw FormatterError.deviceNotFound
        }

        // First get the partition identifier (e.g., disk23s3)
        var partitionIdentifier: String?
        for line in result.output.components(separatedBy: "\n") {
            if line.contains("Device Identifier:") {
                let components = line.components(separatedBy: ":")
                if components.count >= 2 {
                    partitionIdentifier = components[1].trimmingCharacters(in: .whitespaces)
                    break
                }
            }
        }

        guard let partition = partitionIdentifier else {
            throw FormatterError.deviceNotFound
        }

        // Extract whole disk identifier (e.g., disk23s3 -> disk23)
        // Remove the partition suffix (s1, s2, etc.)
        let wholeDisk = partition.replacingOccurrences(
            of: "s\\d+$",
            with: "",
            options: .regularExpression
        )

        return wholeDisk
    }

    private func formatDevice(
        diskIdentifier: String,
        fileSystem: FileSystemType,
        volumeLabel: String,
        partitionScheme: PartitionScheme,
        progressHandler: @escaping (OperationStatus) -> Void
    ) async throws {

        let fsType = mapFileSystemType(fileSystem)

        // FAT32/FAT volume labels are limited to 11 characters
        // exFAT allows up to 11 characters, APFS allows longer names
        let maxLabelLength: Int
        switch fileSystem {
        case .fat, .fat32:
            maxLabelLength = 11
        case .exfat:
            maxLabelLength = 11
        default:
            maxLabelLength = 255
        }

        var label = volumeLabel.isEmpty ? "UNTITLED" : volumeLabel
        if label.count > maxLabelLength {
            label = String(label.prefix(maxLabelLength))
        }
        // Remove invalid characters for FAT/exFAT
        label = label.replacingOccurrences(of: "[^A-Za-z0-9_\\-]", with: "_", options: .regularExpression)

        progressHandler(.formatting(progress: 0.3))

        // Map partition scheme to diskutil format
        let scheme: String
        switch partitionScheme {
        case .mbr:
            scheme = "MBR"
        case .gpt:
            scheme = "GPT"
        }

        let result = try await runCommand(
            "/usr/sbin/diskutil",
            arguments: ["eraseDisk", fsType, label, scheme, diskIdentifier]
        )

        progressHandler(.formatting(progress: 0.9))

        if result.exitCode != 0 {
            throw FormatterError.formatFailed(result.error)
        }

        progressHandler(.formatting(progress: 1.0))
    }

    private func mapFileSystemType(_ fileSystem: FileSystemType) -> String {
        switch fileSystem {
        case .fat:
            return "FAT12"
        case .fat32:
            return "FAT32"
        case .exfat:
            return "ExFAT"
        case .apfs:
            return "APFS"
        case .ntfs:
            // macOS needs third-party tools for NTFS write
            return "ExFAT"
        case .ext2, .ext3, .ext4:
            // Would need additional tools
            return "FAT32"
        case .udf:
            return "UDF"
        case .refs:
            return "ExFAT"
        }
    }

    private func mountISO(_ isoPath: URL) async throws -> String {
        let result = try await runCommand(
            "/usr/bin/hdiutil",
            arguments: ["attach", isoPath.path, "-nobrowse", "-readonly"]
        )

        guard result.exitCode == 0 else {
            throw FormatterError.isoMountFailed(result.error)
        }

        // Parse mount point from output
        let lines = result.output.components(separatedBy: "\n")
        for line in lines.reversed() {
            let components = line.components(separatedBy: "\t")
            if let mountPoint = components.last?.trimmingCharacters(in: .whitespaces),
               !mountPoint.isEmpty,
               FileManager.default.fileExists(atPath: mountPoint) {
                return mountPoint
            }
        }

        throw FormatterError.isoMountFailed("Could not determine mount point")
    }

    private func unmountISO(_ mountPoint: String) async throws {
        _ = try await runCommand(
            "/usr/bin/hdiutil",
            arguments: ["detach", mountPoint]
        )
    }

    private func waitForMount(diskIdentifier: String) async throws -> String {
        let maxAttempts = 15
        let delayNanoseconds: UInt64 = 1_000_000_000

        // Try different partition numbers (s1, s2) as GPT may have EFI partition
        let partitionCandidates = ["\(diskIdentifier)s1", "\(diskIdentifier)s2"]

        for attempt in 0..<maxAttempts {
            for partitionIdentifier in partitionCandidates {
                let result = try await runCommand(
                    "/usr/sbin/diskutil",
                    arguments: ["info", partitionIdentifier]
                )

                if result.exitCode == 0 {
                    for line in result.output.components(separatedBy: "\n") {
                        if line.contains("Mount Point:") {
                            let components = line.components(separatedBy: ":")
                            if components.count >= 2 {
                                let mountPoint = components[1].trimmingCharacters(in: .whitespaces)
                                if !mountPoint.isEmpty && mountPoint != "(not mounted)" {
                                    return mountPoint
                                }
                            }
                        }
                    }

                    // Try to mount if not mounted
                    if attempt > 2 {
                        _ = try await runCommand(
                            "/usr/sbin/diskutil",
                            arguments: ["mount", partitionIdentifier]
                        )
                    }
                }
            }

            try await Task.sleep(nanoseconds: delayNanoseconds)
        }

        throw FormatterError.mountFailed("Device did not mount after formatting")
    }

    private func copyFiles(
        from source: String,
        to destination: String,
        progressHandler: @escaping (OperationStatus) -> Void,
        logHandler: @escaping (String, LogLevel) -> Void
    ) async throws {

        let fileManager = FileManager.default
        let sourceURL = URL(fileURLWithPath: source)
        let destinationURL = URL(fileURLWithPath: destination)

        // Get all files to copy
        guard let enumerator = fileManager.enumerator(
            at: sourceURL,
            includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw FormatterError.copyFailed("Cannot enumerate source files")
        }

        var filesToCopy: [(source: URL, destination: URL, size: Int64)] = []
        var totalSize: Int64 = 0

        while let fileURL = enumerator.nextObject() as? URL {
            let resourceValues = try fileURL.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
            let isDirectory = resourceValues.isDirectory ?? false

            if !isDirectory {
                let relativePath = fileURL.path.replacingOccurrences(of: source, with: "")
                let destURL = destinationURL.appendingPathComponent(relativePath)
                let size = Int64(resourceValues.fileSize ?? 0)

                filesToCopy.append((fileURL, destURL, size))
                totalSize += size
            }
        }

        var copiedSize: Int64 = 0
        let fat32MaxSize: Int64 = 4_294_967_295 // 4GB - 1
        let bufferSize = 4 * 1024 * 1024 // 4MB buffer

        for (index, file) in filesToCopy.enumerated() {
            if isCancelled { throw FormatterError.cancelled }

            let fileName = file.source.lastPathComponent
            
            // Create directory if needed
            let destDir = file.destination.deletingLastPathComponent()
            try fileManager.createDirectory(at: destDir, withIntermediateDirectories: true)

            // Check FAT32 limit
            if file.size > fat32MaxSize {
                await MainActor.run {
                    logHandler("Warning: \(fileName) exceeds 4GB FAT32 limit", .warning)
                }
            }

            // Remove existing file
            if fileManager.fileExists(atPath: file.destination.path) {
                try fileManager.removeItem(at: file.destination)
            }

            // Chunked copy
            do {
                let sourceHandle = try FileHandle(forReadingFrom: file.source)
                
                // Create empty file first
                fileManager.createFile(atPath: file.destination.path, contents: nil)
                let destHandle = try FileHandle(forWritingTo: file.destination)
                
                defer {
                    try? sourceHandle.close()
                    try? destHandle.close()
                }
                
                var fileCopied: Int64 = 0
                
                while fileCopied < file.size {
                    if isCancelled { throw FormatterError.cancelled }
                    
                    // Read chunk
                    let data = try sourceHandle.read(upToCount: bufferSize) ?? Data()
                    if data.isEmpty { break }
                    
                    // Write chunk
                    try destHandle.write(contentsOf: data)
                    
                    fileCopied += Int64(data.count)
                    copiedSize += Int64(data.count)
                    
                    // Update progress periodically (every 4MB or so)
                    let progress = Double(copiedSize) / Double(max(totalSize, 1))
                    await MainActor.run {
                        progressHandler(.copying(progress: progress, currentFile: fileName))
                    }
                    
                    // Yield to main thread to keep UI responsive
                    await Task.yield()
                }
                
            } catch {
                throw FormatterError.copyFailed("Failed to copy \(fileName): \(error.localizedDescription)")
            }

            if index % 10 == 0 { // Log less frequently
                await MainActor.run {
                    logHandler("Copied: \(fileName)", .info)
                }
            }
        }

        await MainActor.run {
            progressHandler(.copying(progress: 1.0, currentFile: "Complete"))
        }
    }

    private func runCommand(_ command: String, arguments: [String]) async throws -> (output: String, error: String, exitCode: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        self.currentProcess = process

        return try await withCheckedThrowingContinuation { continuation in
            var hasResumed = false

            process.terminationHandler = { [weak self] terminatedProcess in
                self?.currentProcess = nil

                guard !hasResumed else { return }
                hasResumed = true

                // Check if cancelled
                if self?.isCancelled == true {
                    continuation.resume(returning: ("", "Operation cancelled", -1))
                    return
                }

                let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

                let output = String(data: outputData, encoding: .utf8) ?? ""
                let error = String(data: errorData, encoding: .utf8) ?? ""

                continuation.resume(returning: (output, error, terminatedProcess.terminationStatus))
            }

            do {
                try process.run()
            } catch {
                guard !hasResumed else { return }
                hasResumed = true
                self.currentProcess = nil
                continuation.resume(throwing: error)
            }
        }
    }
}

// MARK: - Bad Blocks Check

extension USBFormatterService {

    func checkBadBlocks(
        device: USBDevice,
        passes: Int,
        progressHandler: @escaping (Double) -> Void,
        logHandler: @escaping (String, LogLevel) -> Void
    ) async throws -> Int {

        logHandler("Starting bad blocks check (\(passes) pass\(passes > 1 ? "es" : ""))", .info)

        var badBlockCount = 0

        for pass in 1...passes {
            if isCancelled { throw FormatterError.cancelled }

            logHandler("Pass \(pass) of \(passes)", .info)

            // Use diskutil verifyDisk for basic check
            let diskIdentifier = try await getDiskIdentifier(for: device)
            let result = try await runCommand(
                "/usr/sbin/diskutil",
                arguments: ["verifyDisk", diskIdentifier]
            )

            let baseProgress = Double(pass - 1) / Double(passes)
            let passProgress = 1.0 / Double(passes)
            progressHandler(baseProgress + passProgress)

            if result.exitCode != 0 {
                logHandler("Verification found issues in pass \(pass)", .warning)
                badBlockCount += 1
            }
        }

        if badBlockCount > 0 {
            logHandler("Found \(badBlockCount) issue(s) during verification", .warning)
        } else {
            logHandler("No issues found", .success)
        }

        return badBlockCount
    }

    // MARK: - Pre-flight Checks

    private func checkISORequirements(isoPath: URL, fileSystem: FileSystemType) async throws {
        guard fileSystem == .fat32 || fileSystem == .fat else { return }

        // Mount ISO read-only to check file sizes
        let mountPoint = try await mountISO(isoPath)
        defer {
            Task { try? await unmountISO(mountPoint) }
        }

        let fileManager = FileManager.default
        let enumerator = fileManager.enumerator(
            at: URL(fileURLWithPath: mountPoint),
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )

        let limit: Int64 = 4_294_967_295 // 4GB - 1

        while let fileURL = enumerator?.nextObject() as? URL {
            let resources = try? fileURL.resourceValues(forKeys: [.fileSizeKey])
            if let size = resources?.fileSize, Int64(size) > limit {
                throw FormatterError.largeFileOnFAT32(fileURL.lastPathComponent)
            }
        }
    }

    // MARK: - DD Mode

    private func writeImageDD(
        device: USBDevice,
        isoPath: URL,
        progressHandler: @escaping (OperationStatus) -> Void,
        logHandler: @escaping (String, LogLevel) -> Void
    ) async throws {
        
        // 1. Unmount device
        logHandler("Unmounting device for DD write...", .info)
        try await unmountDevice(device)
        
        // 2. Get Raw Disk Identifier (e.g. /dev/rdisk2)
        // We need to be careful here. 'device.id' might be "disk2".
        // We want "/dev/rdisk2" for speed.
        let diskID = try await getDiskIdentifier(for: device)
        let rawDiskPath = "/dev/r\(diskID)"
        
        logHandler("Writing image to \(rawDiskPath) (DD Mode)...", .info)
        logHandler("Warning: This will overwrite the entire drive!", .warning)
        
        // 3. Open ISO and Device
        guard let isoHandle = try? FileHandle(forReadingFrom: isoPath) else {
            throw FormatterError.ddFailed("Could not open ISO file")
        }
        
        // We need to open the device for writing.
        // Note: Writing to /dev/rdisk requires root privileges usually.
        // If the app is not sandboxed or has privileges, this might work.
        // Otherwise we might need to use 'dd' command with 'sudo' (which we can't easily do).
        // Assuming the user has granted disk access or we are running with sufficient privs.
        // If this fails, we might need to fallback to 'dd' command.
        
        // Let's try using 'dd' command first as it's more standard for this,
        // but we can't easily get progress from 'dd' without signals.
        // Swift FileHandle write to /dev/rdisk might fail if not root.
        // However, 'diskutil' operations also require privs.
        
        // Let's try Swift FileHandle first.
        guard let deviceHandle = FileHandle(forWritingAtPath: rawDiskPath) else {
             // Fallback to /dev/diskN if rdiskN fails
             if let safeHandle = FileHandle(forWritingAtPath: "/dev/\(diskID)") {
                 logHandler("Using buffered I/O (/dev/\(diskID))", .info)
                 try await writeDDLoop(
                    source: isoHandle,
                    dest: safeHandle,
                    totalSize: (try? isoPath.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0,
                    progressHandler: progressHandler
                 )
                 return
             }
             throw FormatterError.ddFailed("Could not open target device for writing. Check permissions.")
        }
        
        try await writeDDLoop(
            source: isoHandle,
            dest: deviceHandle,
            totalSize: (try? isoPath.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0,
            progressHandler: progressHandler
        )
    }
    
    private func writeDDLoop(
        source: FileHandle,
        dest: FileHandle,
        totalSize: Int64,
        progressHandler: @escaping (OperationStatus) -> Void
    ) async throws {
        defer {
            try? source.close()
            try? dest.close()
        }
        
        let bufferSize = 4 * 1024 * 1024 // 4MB
        var written: Int64 = 0
        
        while true {
            if isCancelled { throw FormatterError.cancelled }
            
            let data = try source.read(upToCount: bufferSize) ?? Data()
            if data.isEmpty { break }
            
            try dest.write(contentsOf: data)
            written += Int64(data.count)
            
            let progress = Double(written) / Double(max(totalSize, 1))
            await MainActor.run {
                progressHandler(.copying(progress: progress, currentFile: "Writing Image (DD)..."))
            }
            
            await Task.yield()
        }
    }
}
