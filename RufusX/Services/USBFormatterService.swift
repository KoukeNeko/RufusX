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

        // Step 4: Mount ISO and copy files (Only for DiskOrIso mode)
        if options.bootSelection == .diskOrIso, let isoPath = options.isoFilePath {
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
                        sizeGB: Double(options.persistentPartitionSizeGB),
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
        // Check if mounted first to avoid errors
        let infoResult = try await runCommand("/usr/sbin/diskutil", arguments: ["info", device.mountPoint])
        if infoResult.exitCode == 0 && infoResult.output.contains("Mounted:                   No") {
            return // Already unmounted
        }

        let result = try await runCommand(
            "/usr/sbin/diskutil",
            arguments: ["unmountDisk", device.mountPoint]
        )

        if result.exitCode != 0 {
            // If it failed, check if it's because it was already unmounted (race condition)
            if result.error.contains("not currently mounted") || result.output.contains("not currently mounted") {
                return
            }
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
        var lastProgressUpdate = Date()

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
                // Use 256KB chunks to match industry standards (Rufus uses 64-128KB) and ensure responsiveness
                let bufferSize = 256 * 1024 // 256KB
                var offset: UInt64 = 0
                
                while offset < UInt64(file.size) {
                    // Check for cancellation
                    try Task.checkCancellation()
                    
                    // Use autoreleasepool to keep memory usage low
                    let bytesRead = try autoreleasepool { () -> Int in
                        sourceHandle.seek(toFileOffset: offset)
                        let data = try sourceHandle.read(upToCount: bufferSize) ?? Data()
                        
                        if data.isEmpty { return 0 }
                        
                        destHandle.seek(toFileOffset: offset)
                        try destHandle.write(contentsOf: data)
                        
                        return data.count
                    }
                    
                    if bytesRead == 0 { break }
                    
                    offset += UInt64(bytesRead)
                    copiedSize += Int64(bytesRead)
                    
                    // Update progress periodically (throttled to 0.5s)
                    let now = Date()
                    if now.timeIntervalSince(lastProgressUpdate) >= 0.5 {
                        let progress = Double(copiedSize) / Double(max(totalSize, 1))
                        let sizeString = self.formatBytes(file.size)
                        let statusText = "\(fileName) (\(sizeString))"
                        
                        // Use Task.detached to avoid inheriting actor context for the update
                        Task.detached { @MainActor in
                            progressHandler(.copying(progress: progress, currentFile: statusText))
                        }
                        lastProgressUpdate = now
                    }
                    
                    // Yield every chunk (1MB) to ensure UI responsiveness
                    // Even on slow drives, 1MB should write relatively quickly
                    await Task.yield()
                }
                
            } catch {
                throw FormatterError.copyFailed("Failed to copy \(fileName): \(error.localizedDescription)")
            }

            // Report progress with current filename
            let progress = Double(index + 1) / Double(filesToCopy.count)
            let sizeString = formatBytes(file.size)
            let statusText = "\(fileName) (\(sizeString))"
            
            await MainActor.run {
                progressHandler(.copying(progress: progress, currentFile: statusText))
                logHandler("Copied: \(fileName) (\(sizeString))", .info)
            }
        }

        await MainActor.run {
            progressHandler(.copying(progress: 1.0, currentFile: "Complete"))
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: bytes)
    }

    private func runCommand(_ command: String, arguments: [String]) async throws -> (output: String, error: String, exitCode: Int32) {
        return try await ShellService.shared.runCommand(command, arguments: arguments)
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
        
        do {
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
            
            // Explicitly unmount on success
            try await unmountISO(mountPoint)
            
        } catch {
            // Ensure unmount happens even if an error occurs (e.g. large file found)
            try? await unmountISO(mountPoint)
            throw error
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
        let diskID = try await getDiskIdentifier(for: device)
        let rawDiskPath = "/dev/r\(diskID)"
        
        logHandler("Writing image to \(rawDiskPath) (DD Mode)...", .info)
        logHandler("Warning: This will overwrite the entire drive!", .warning)
        
        // 3. Use dd with admin privileges
        // Note: We can't easily get progress from dd without signals (SIGINFO),
        // which is hard to capture via Process.
        // So we'll use a spinner or indeterminate progress for now,
        // or we could try to use 'pv' if installed, but let's stick to standard tools.
        
        progressHandler(.copying(progress: 0.5, currentFile: "Writing Image (DD)..."))
        
        let result = try await ShellService.shared.runCommandWithAdminPrivileges(
            "/bin/dd",
            arguments: [
                "if=\(isoPath.path)",
                "of=\(rawDiskPath)",
                "bs=4m",
                "status=progress" // GNU dd supports this, BSD dd (macOS) supports SIGINFO
            ]
        )
        
        if result.exitCode != 0 {
            // Fallback to /dev/diskN if rdiskN fails
            logHandler("Retrying with buffered I/O (/dev/\(diskID))...", .warning)
             let retryResult = try await ShellService.shared.runCommandWithAdminPrivileges(
                "/bin/dd",
                arguments: [
                    "if=\(isoPath.path)",
                    "of=/dev/\(diskID)",
                    "bs=4m"
                ]
            )
            
            if retryResult.exitCode != 0 {
                throw FormatterError.ddFailed(retryResult.error)
            }
        }
        
        progressHandler(.copying(progress: 1.0, currentFile: "DD Write Complete"))
    }
    

}
