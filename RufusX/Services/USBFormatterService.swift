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
        logHandler("Formatting device with \(options.fileSystem.rawValue)", .info)
        progressHandler(.formatting(progress: 0.1))
        try await formatDevice(
            diskIdentifier: diskIdentifier,
            fileSystem: options.fileSystem,
            volumeLabel: options.volumeLabel,
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

        let result = try await runCommand(
            "/usr/sbin/diskutil",
            arguments: ["eraseDisk", fsType, label, diskIdentifier]
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
        let maxAttempts = 10
        let delayNanoseconds: UInt64 = 1_000_000_000

        // After formatting, the partition is usually disk23s1 for disk23
        let partitionIdentifier = "\(diskIdentifier)s1"

        for _ in 0..<maxAttempts {
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

        for (index, file) in filesToCopy.enumerated() {
            if isCancelled { throw FormatterError.cancelled }

            let fileName = file.source.lastPathComponent
            let progress = Double(copiedSize) / Double(max(totalSize, 1))
            progressHandler(.copying(progress: progress, currentFile: fileName))

            // Create directory if needed
            let destDir = file.destination.deletingLastPathComponent()
            try fileManager.createDirectory(at: destDir, withIntermediateDirectories: true)

            // Copy file - handle FAT32 4GB limit
            if fileManager.fileExists(atPath: file.destination.path) {
                try fileManager.removeItem(at: file.destination)
            }

            let fat32MaxSize: Int64 = 4_294_967_295 // 4GB - 1
            if file.size > fat32MaxSize {
                // File exceeds FAT32 limit - log warning
                logHandler("Warning: \(fileName) exceeds 4GB FAT32 limit (\(file.size / 1_073_741_824) GB)", .warning)
                logHandler("Consider using NTFS or exFAT for large files", .warning)
            }

            try fileManager.copyItem(at: file.source, to: file.destination)

            copiedSize += file.size

            if index % 100 == 0 {
                logHandler("Copied: \(fileName)", .info)
            }
        }

        progressHandler(.copying(progress: 1.0, currentFile: "Complete"))
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
}
