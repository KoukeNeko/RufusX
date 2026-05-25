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
        case unsupportedConfiguration(String)

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
            case .unsupportedConfiguration(let message):
                return message
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

        if let unsupportedReason = RufusSupportMatrix.validate(options: options) {
            throw FormatterError.unsupportedConfiguration(unsupportedReason)
        }

        guard let isoPath = options.isoFilePath else {
            throw FormatterError.unsupportedConfiguration("Select a Windows installer ISO before starting.")
        }

        logHandler("Validating supported Windows ISO before touching the USB drive...", .info)
        progressHandler(.verifying(progress: 0.05))
        do {
            try await ISOProbeService().validateWindowsISO(isoPath)
        } catch {
            throw FormatterError.unsupportedConfiguration(error.localizedDescription)
        }

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
            try await checkISORequirements(isoPath: isoPath, fileSystem: options.fileSystem, logHandler: logHandler)
        }

        // Step 1: Get disk identifier BEFORE unmounting
        logHandler("Identifying device: \(device.name)", .info)
        progressHandler(.preparing)

        let diskIdentifier = try await getDiskIdentifier(for: device)
        logHandler("Device identifier: \(diskIdentifier)", .info)

        if isCancelled { throw FormatterError.cancelled }

        // Step 2: Unmount the device
        logHandler("Unmounting device...", .info)
        try await unmountDevice(device, logHandler: logHandler)

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
                fileSystem: options.fileSystem,
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

    private func unmountDevice(_ device: USBDevice, logHandler: (String, LogLevel) -> Void) async throws {
        // Check if mounted first to avoid errors
        let infoResult = try await runCommand("/usr/sbin/diskutil", arguments: ["info", device.mountPoint])
        if infoResult.exitCode == 0 && infoResult.output.contains("Mounted:                   No") {
            return // Already unmounted
        }

        var result = try await runCommand(
            "/usr/sbin/diskutil",
            arguments: ["unmountDisk", device.mountPoint]
        )

        if result.exitCode != 0 {
            // If it failed, check if it's because it was already unmounted (race condition)
            if result.error.contains("not currently mounted") || result.output.contains("not currently mounted") {
                return
            }
            
            // Retry with force
            logHandler("Standard unmount failed, retrying with force...", .warning)
            result = try await runCommand(
                "/usr/sbin/diskutil",
                arguments: ["unmountDisk", "force", device.mountPoint]
            )
            
            if result.exitCode != 0 {
                if result.error.contains("not currently mounted") || result.output.contains("not currently mounted") {
                    return
                }
                throw FormatterError.unmountFailed(result.error)
            }
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
            arguments: ["attach", isoPath.path, "-nobrowse", "-readonly", "-noverify", "-noautoopen"]
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
        fileSystem: FileSystemType,
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

        for (index, file) in filesToCopy.enumerated() {
            if isCancelled { throw FormatterError.cancelled }

            let fileName = file.source.lastPathComponent
            
            // Create directory if needed
            let destDir = file.destination.deletingLastPathComponent()
            try fileManager.createDirectory(at: destDir, withIntermediateDirectories: true)

            // Check FAT32 limit
            if (fileSystem == .fat32 || fileSystem == .fat) && file.size > fat32MaxSize {
                // Check for WIM splitting
                if fileName.lowercased() == "install.wim" || fileName.lowercased() == "install.esd" {
                    if let wimlibPath = findWimlib() {
                        try await splitWIM(
                            source: file.source,
                            destination: file.destination,
                            wimlibPath: wimlibPath,
                            logHandler: logHandler,
                            progressHandler: progressHandler
                        )
                        
                        // Update progress manually for the split file
                        copiedSize += file.size
                        let overallProgress = Double(copiedSize) / Double(max(totalSize, 1))
                        await MainActor.run {
                            progressHandler(.copying(progress: overallProgress, currentFile: "Splitting completed for \(fileName)"))
                        }
                        continue
                    }
                }
                
                // Fallback to ExFAT auto-switch
                throw FormatterError.largeFileOnFAT32(fileName)
            }

            // Remove existing file
            if fileManager.fileExists(atPath: file.destination.path) {
                try fileManager.removeItem(at: file.destination)
            }

            // Chunked copy
            // Use GCD to run on a dedicated background thread, avoiding Swift Concurrency pool contention
            // This is the most robust way to ensure the Main Thread is never blocked by I/O
            let initialCopiedSize = copiedSize
            let bytesCopiedInFile: Int64 = try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async { [weak self] in
                    guard let self = self else {
                        continuation.resume(throwing: FormatterError.cancelled)
                        return
                    }
                    
                    do {
                        let sourceHandle = try FileHandle(forReadingFrom: file.source)
                        
                        // Create empty file first
                        let innerFileManager = FileManager.default
                        innerFileManager.createFile(atPath: file.destination.path, contents: nil)
                        let destHandle = try FileHandle(forWritingTo: file.destination)
                        
                        defer {
                            try? sourceHandle.close()
                            try? destHandle.close()
                        }
                        
                        // Use 4MB chunks
                        let bufferSize = 4 * 1024 * 1024
                        var offset: UInt64 = 0
                        var fileCopiedSize: Int64 = 0
                        var lastUpdate = Date()
                        
                        while offset < UInt64(file.size) {
                            if self.isCancelled { throw FormatterError.cancelled }
                            
                            let bytesRead = try autoreleasepool { () -> Int in
                                // FileHandle automatically advances the file pointer, so explicit seek is not needed
                                // and can actually hurt performance by forcing buffer flushes.
                                let data = try sourceHandle.read(upToCount: bufferSize) ?? Data()
                                
                                if data.isEmpty { return 0 }
                                
                                try destHandle.write(contentsOf: data)
                                
                                return data.count
                            }
                            
                            if bytesRead == 0 { break }
                            
                            offset += UInt64(bytesRead)
                            fileCopiedSize += Int64(bytesRead)
                            
                            // Update progress periodically (throttled to 0.5s)
                            let now = Date()
                            if now.timeIntervalSince(lastUpdate) >= 0.5 {
                                let currentTotalCopied = initialCopiedSize + fileCopiedSize
                                let progress = Double(currentTotalCopied) / Double(max(totalSize, 1))
                                let sizeString = self.formatBytes(file.size)
                                let statusText = "\(fileName) (\(sizeString))"
                                
                                Task.detached { @MainActor in
                                    progressHandler(.copying(progress: progress, currentFile: statusText))
                                }
                                lastUpdate = now
                            }
                        }
                        
                        continuation.resume(returning: fileCopiedSize)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
            
            copiedSize += bytesCopiedInFile

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

    private func checkISORequirements(isoPath: URL, fileSystem: FileSystemType, logHandler: (String, LogLevel) -> Void) async throws {
        guard fileSystem == .fat32 || fileSystem == .fat else { return }

        let wimSplitCapable = findWimlib() != nil
        var announcedWimSplit = false

        // Mount ISO read-only to check file sizes
        logHandler("Mounting ISO to check file sizes...", .debug)
        let mountPoint = try await mountISO(isoPath)
        logHandler("ISO mounted at: \(mountPoint)", .debug)
        
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
                    let fileName = fileURL.lastPathComponent
                    let lowercasedName = fileName.lowercased()
                    let isSplittableWIM = lowercasedName == "install.wim" || lowercasedName == "install.esd"

                    if isSplittableWIM && wimSplitCapable {
                        if !announcedWimSplit {
                            logHandler("Large WIM file detected (\(fileName)). Wimlib is available, so automatic splitting will be used during copy.", .info)
                            announcedWimSplit = true
                        }
                        continue
                    }

                    if isSplittableWIM && !wimSplitCapable {
                        logHandler("Found \(fileName) larger than FAT32 limits, but wimlib-imagex was not found. Install wimlib or switch to a non-FAT filesystem.", .error)
                    }

                    throw FormatterError.largeFileOnFAT32(fileName)
                }
            }
            
            logHandler("ISO file size check passed. Unmounting...", .debug)
            
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
        try await unmountDevice(device, logHandler: logHandler)
        
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
    
    // MARK: - WIM Splitting
    
    private func findWimlib() -> String? {
        // 1. Check Bundle
        if let bundledURL = Bundle.main.url(forResource: "wimlib-imagex", withExtension: nil) {
            print("DEBUG: Found bundled wimlib at \(bundledURL.path)")
            if FileManager.default.fileExists(atPath: bundledURL.path) {
                return bundledURL.path
            }
        } else {
            print("DEBUG: Bundled wimlib not found in resources")
        }
        
        // 2. Check Homebrew (Apple Silicon)
        let brewPathARM = "/opt/homebrew/bin/wimlib-imagex"
        if FileManager.default.fileExists(atPath: brewPathARM) {
            print("DEBUG: Found Homebrew (ARM) wimlib at \(brewPathARM)")
            return brewPathARM
        } else {
            print("DEBUG: Homebrew (ARM) wimlib not found at \(brewPathARM)")
        }
        
        // 3. Check Homebrew (Intel)
        let brewPathIntel = "/usr/local/bin/wimlib-imagex"
        if FileManager.default.fileExists(atPath: brewPathIntel) {
            print("DEBUG: Found Homebrew (Intel) wimlib at \(brewPathIntel)")
            return brewPathIntel
        }
        
        // 4. Check System
        if FileManager.default.fileExists(atPath: "/usr/bin/wimlib-imagex") {
            return "/usr/bin/wimlib-imagex"
        }
        
        // 5. Check Development Path (Source Directory)
        // This allows running from Xcode even if bundling fails
        let devPath = URL(fileURLWithPath: #file).deletingLastPathComponent().appendingPathComponent("wimlib-imagex").path
        if FileManager.default.fileExists(atPath: devPath) {
            print("DEBUG: Found dev wimlib at \(devPath)")
            return devPath
        }
        
        print("DEBUG: wimlib-imagex not found anywhere")
        return nil
    }
    
    private func splitWIM(
        source: URL,
        destination: URL,
        wimlibPath: String,
        logHandler: @escaping (String, LogLevel) -> Void,
        progressHandler: @escaping (OperationStatus) -> Void
    ) async throws {
        logHandler("Splitting WIM file: \(source.lastPathComponent)...", .info)
        logHandler("This may take several minutes depending on USB speed.", .info)
        await MainActor.run {
            progressHandler(.copying(progress: 0.0, currentFile: "Splitting \(source.lastPathComponent)..."))
        }
        
        // Change extension to .swm for the first part
        let destSWM = destination.deletingPathExtension().appendingPathExtension("swm")
        try cleanupExistingSplitParts(baseSWM: destSWM, logHandler: logHandler)
        
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else {
                    continuation.resume(throwing: FormatterError.cancelled)
                    return
                }
                
                let process = Process()
                process.executableURL = URL(fileURLWithPath: wimlibPath)
                process.arguments = [
                    "split",
                    source.path,
                    destSWM.path,
                    "3800"
                ]
                
                let outputPipe = Pipe()
                process.standardOutput = outputPipe
                process.standardError = outputPipe
                self.currentProcess = process
                
                let bufferQueue = DispatchQueue(label: "com.rufusx.wimlib-output")
                var aggregatedOutput = ""
                var partialLine = ""
                var finished = false
                let fileName = source.lastPathComponent
                
                func reportProgress(percent: Int) {
                    let clamped = max(0, min(percent, 100))
                    Task { @MainActor in
                        let progressValue = Double(clamped) / 100.0
                        progressHandler(.copying(progress: progressValue, currentFile: "Splitting \(fileName) (\(clamped)%)"))
                    }
                }
                
                func emitLine(_ line: String) {
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    aggregatedOutput.append(trimmed + "\n")
                    if let match = trimmed.range(of: "(\\d{1,3})%", options: .regularExpression) {
                        let percentString = trimmed[match].replacingOccurrences(of: "%", with: "")
                        if let percent = Int(percentString) {
                            reportProgress(percent: percent)
                        }
                    }
                    let level: LogLevel = trimmed.contains("%") ? .info : .debug
                    logHandler("wimlib: \(trimmed)", level)
                }
                
                func enqueueChunk(_ chunk: String) {
                    let normalized = chunk.replacingOccurrences(of: "\r", with: "\n")
                    partialLine += normalized
                    while let range = partialLine.range(of: "\n") {
                        let line = String(partialLine[..<range.lowerBound])
                        partialLine = String(partialLine[range.upperBound...])
                        emitLine(line)
                    }
                }
                
                let readHandle = outputPipe.fileHandleForReading
                readHandle.readabilityHandler = { handle in
                    let data = handle.availableData
                    guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
                    bufferQueue.async {
                        enqueueChunk(chunk)
                    }
                }
                
                func finish(_ result: Result<Void, Error>) {
                    guard !finished else { return }
                    finished = true
                    readHandle.readabilityHandler = nil
                    bufferQueue.sync {
                        let remainingData = readHandle.readDataToEndOfFile()
                        if let chunk = String(data: remainingData, encoding: .utf8) {
                            enqueueChunk(chunk)
                        }
                        if !partialLine.isEmpty {
                            emitLine(partialLine)
                            partialLine = ""
                        }
                    }
                    try? readHandle.close()
                    self.currentProcess = nil
                    continuation.resume(with: result)
                }
                
                process.terminationHandler = { proc in
                    if self.isCancelled {
                        finish(.failure(FormatterError.cancelled))
                        return
                    }
                    if proc.terminationStatus == 0 {
                        reportProgress(percent: 100)
                        logHandler("WIM split completed successfully", .success)
                        finish(.success(()))
                    } else {
                        let errorOutput = aggregatedOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                        finish(.failure(FormatterError.copyFailed("WIM split failed: \(errorOutput.isEmpty ? "Unknown error" : errorOutput)")))
                    }
                }
                
                do {
                    try process.run()
                } catch {
                    finish(.failure(error))
                }
            }
        }
    }

    private func cleanupExistingSplitParts(baseSWM: URL, logHandler: @escaping (String, LogLevel) -> Void) throws {
        let fileManager = FileManager.default
        let directoryURL = baseSWM.deletingLastPathComponent()
        let baseName = baseSWM.deletingPathExtension().lastPathComponent
        guard fileManager.fileExists(atPath: directoryURL.path) else { return }
        let contents = try fileManager.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil)
        for url in contents {
            guard url.pathExtension.lowercased() == "swm" else { continue }
            let name = url.deletingPathExtension().lastPathComponent
            guard name.hasPrefix(baseName) else { continue }
            let suffix = name.dropFirst(baseName.count)
            let shouldRemove = suffix.isEmpty || Int(suffix) != nil
            guard shouldRemove else { continue }
            do {
                try fileManager.removeItem(at: url)
                logHandler("Removed leftover split part: \(url.lastPathComponent)", .debug)
            } catch {
                logHandler("Failed to remove leftover split part (\(url.lastPathComponent)): \(error.localizedDescription)", .warning)
            }
        }
    }

}
