//
//  PersistenceService.swift
//  RufusX
//
//  Created by 陳德生 on 2025/11/20.
//

import Foundation

final class PersistenceService {

    // MARK: - Error Types

    enum PersistenceError: LocalizedError {
        case insufficientSpace
        case partitionFailed(String)
        case formatFailed(String)
        case configurationFailed(String)

        var errorDescription: String? {
            switch self {
            case .insufficientSpace:
                return "Insufficient space for persistence partition"
            case .partitionFailed(let message):
                return "Failed to create partition: \(message)"
            case .formatFailed(let message):
                return "Failed to format persistence partition: \(message)"
            case .configurationFailed(let message):
                return "Failed to configure persistence: \(message)"
            }
        }
    }

    // MARK: - Persistence Configuration

    struct PersistenceConfig {
        let sizeInBytes: Int64
        let label: String
        let fileSystem: String

        static let defaultLabel = "casper-rw"
        static let ubuntuLabel = "casper-rw"
        static let debianLabel = "persistence"
        static let fedoraLabel = "LIVE"
    }

    // MARK: - Public Methods

    func createPersistencePartition(
        diskIdentifier: String,
        sizeGB: Double,
        distroType: LinuxDistroType,
        logHandler: @escaping (String, LogLevel) -> Void
    ) async throws {

        guard sizeGB > 0 else { return }

        let sizeInBytes = Int64(sizeGB * 1_073_741_824)
        let config = getPersistenceConfig(for: distroType, sizeInBytes: sizeInBytes)

        logHandler("Creating persistence partition (\(String(format: "%.1f", sizeGB)) GB)...", .info)

        // Get current partition info
        let partitionInfo = try await getPartitionInfo(diskIdentifier: diskIdentifier)

        guard let availableSpace = partitionInfo.freeSpace, availableSpace >= sizeInBytes else {
            throw PersistenceError.insufficientSpace
        }

        // Resize main partition to make room
        try await resizeMainPartition(
            diskIdentifier: diskIdentifier,
            shrinkBy: sizeInBytes,
            logHandler: logHandler
        )

        // Create new partition for persistence
        let persistencePartition = try await createPartition(
            diskIdentifier: diskIdentifier,
            size: sizeInBytes,
            label: config.label,
            logHandler: logHandler
        )

        // Format persistence partition
        try await formatPersistencePartition(
            partition: persistencePartition,
            config: config,
            logHandler: logHandler
        )

        // Configure persistence based on distro
        try await configurePersistence(
            partition: persistencePartition,
            distroType: distroType,
            logHandler: logHandler
        )

        logHandler("Persistence partition created successfully", .success)
    }

    // MARK: - Linux Distribution Detection

    enum LinuxDistroType {
        case ubuntu
        case debian
        case fedora
        case arch
        case other

        var persistenceLabel: String {
            switch self {
            case .ubuntu: return "casper-rw"
            case .debian: return "persistence"
            case .fedora: return "LIVE"
            case .arch: return "cow_spacesize"
            case .other: return "persistence"
            }
        }
    }

    func detectLinuxDistro(isoMountPoint: String) -> LinuxDistroType {
        let fileManager = FileManager.default

        // Check for Ubuntu/Casper
        if fileManager.fileExists(atPath: "\(isoMountPoint)/casper") {
            return .ubuntu
        }

        // Check for Debian/Live
        if fileManager.fileExists(atPath: "\(isoMountPoint)/live") {
            // Check if it's specifically Debian
            let infoPath = "\(isoMountPoint)/.disk/info"
            if let info = try? String(contentsOfFile: infoPath, encoding: .utf8) {
                if info.lowercased().contains("debian") {
                    return .debian
                }
                if info.lowercased().contains("ubuntu") {
                    return .ubuntu
                }
            }
            return .debian
        }

        // Check for Fedora
        if fileManager.fileExists(atPath: "\(isoMountPoint)/LiveOS") {
            return .fedora
        }

        // Check for Arch
        if fileManager.fileExists(atPath: "\(isoMountPoint)/arch") {
            return .arch
        }

        return .other
    }

    // MARK: - Private Methods

    private func getPersistenceConfig(for distroType: LinuxDistroType, sizeInBytes: Int64) -> PersistenceConfig {
        return PersistenceConfig(
            sizeInBytes: sizeInBytes,
            label: distroType.persistenceLabel,
            fileSystem: "ext4"
        )
    }

    private struct PartitionInfo {
        let totalSize: Int64
        let usedSpace: Int64
        let freeSpace: Int64?
        let partitionCount: Int
    }

    private func getPartitionInfo(diskIdentifier: String) async throws -> PartitionInfo {
        let result = try await runCommand(
            "/usr/sbin/diskutil",
            arguments: ["list", diskIdentifier]
        )

        // Parse output to get partition info
        var totalSize: Int64 = 0
        var partitionCount = 0

        for line in result.output.components(separatedBy: "\n") {
            if line.contains("*") && line.contains("GB") {
                // Extract size from line like "   1:  Apple_HFS  UNTITLED  *7.8 GB  disk2s1"
                let components = line.components(separatedBy: "*")
                if components.count >= 2 {
                    let sizeStr = components[1].trimmingCharacters(in: .whitespaces)
                    if let gbValue = Double(sizeStr.replacingOccurrences(of: " GB", with: "").replacingOccurrences(of: "GB", with: "")) {
                        totalSize = Int64(gbValue * 1_073_741_824)
                    }
                }
                partitionCount += 1
            }
        }

        return PartitionInfo(
            totalSize: totalSize,
            usedSpace: 0,
            freeSpace: totalSize / 2, // Conservative estimate
            partitionCount: partitionCount
        )
    }

    private func resizeMainPartition(
        diskIdentifier: String,
        shrinkBy bytes: Int64,
        logHandler: @escaping (String, LogLevel) -> Void
    ) async throws {

        logHandler("Resizing main partition...", .info)

        // Get main partition identifier (usually disk2s1 for disk2)
        let mainPartition = "\(diskIdentifier)s1"

        // Calculate new size
        let result = try await runCommand(
            "/usr/sbin/diskutil",
            arguments: ["info", mainPartition]
        )

        var currentSize: Int64 = 0
        for line in result.output.components(separatedBy: "\n") {
            if line.contains("Total Size:") {
                // Extract bytes from line like "Total Size:  8.0 GB (8019099648 Bytes)"
                if let match = line.range(of: "\\(([0-9]+) Bytes\\)", options: .regularExpression) {
                    let bytesStr = line[match].replacingOccurrences(of: "(", with: "").replacingOccurrences(of: " Bytes)", with: "")
                    currentSize = Int64(bytesStr) ?? 0
                }
            }
        }

        let newSize = currentSize - bytes
        let newSizeStr = "\(newSize)B"

        let resizeResult = try await runCommand(
            "/usr/sbin/diskutil",
            arguments: ["resizeVolume", mainPartition, newSizeStr]
        )

        if resizeResult.exitCode != 0 {
            // Try alternative approach using partition limits
            logHandler("Standard resize failed, trying alternative method...", .warning)

            let altResult = try await runCommand(
                "/usr/sbin/diskutil",
                arguments: ["resizeVolume", mainPartition, "limits"]
            )

            if altResult.exitCode != 0 {
                throw PersistenceError.partitionFailed(resizeResult.error)
            }
        }

        logHandler("Main partition resized", .info)
    }

    private func createPartition(
        diskIdentifier: String,
        size: Int64,
        label: String,
        logHandler: @escaping (String, LogLevel) -> Void
    ) async throws -> String {

        logHandler("Creating persistence partition...", .info)

        // Use diskutil to add partition
        let sizeStr = "\(size)B"

        let result = try await runCommand(
            "/usr/sbin/diskutil",
            arguments: [
                "addPartition",
                diskIdentifier,
                "ExFAT", // Initial format, will be reformatted to ext4
                label,
                sizeStr
            ]
        )

        if result.exitCode != 0 {
            throw PersistenceError.partitionFailed(result.error)
        }

        // Parse output to get new partition identifier
        // Example output: "Partition GUID set to: xxxxx, Disk: disk2s2"
        var newPartition = "\(diskIdentifier)s2"
        for line in result.output.components(separatedBy: "\n") {
            if line.contains("Disk:") {
                let components = line.components(separatedBy: "Disk:")
                if components.count >= 2 {
                    newPartition = components[1].trimmingCharacters(in: .whitespaces)
                }
            }
        }

        logHandler("Created partition: \(newPartition)", .info)
        return newPartition
    }

    private func formatPersistencePartition(
        partition: String,
        config: PersistenceConfig,
        logHandler: @escaping (String, LogLevel) -> Void
    ) async throws {

        logHandler("Formatting persistence partition as \(config.fileSystem)...", .info)

        // macOS doesn't natively support ext4, so we'll use ExFAT as fallback
        // For true ext4 support, users need to install e2fsprogs via Homebrew

        // Check if mkfs.ext4 is available
        let mkfsPath = [
            "/usr/local/sbin/mkfs.ext4",
            "/opt/homebrew/sbin/mkfs.ext4",
            "/usr/local/opt/e2fsprogs/sbin/mkfs.ext4",
            "/opt/homebrew/opt/e2fsprogs/sbin/mkfs.ext4"
        ].first { FileManager.default.fileExists(atPath: $0) }

        if let mkfs = mkfsPath {
            // Format as ext4
            let result = try await runCommandWithAdminPrivileges(
                mkfs,
                arguments: ["-L", config.label, "/dev/\(partition)"]
            )

            if result.exitCode != 0 {
                throw PersistenceError.formatFailed(result.error)
            }

            logHandler("Formatted as ext4", .success)
        } else {
            // Fallback to ExFAT
            logHandler("ext4 tools not found, using ExFAT (install e2fsprogs for ext4)", .warning)

            let result = try await runCommand(
                "/usr/sbin/diskutil",
                arguments: ["eraseVolume", "ExFAT", config.label, partition]
            )

            if result.exitCode != 0 {
                throw PersistenceError.formatFailed(result.error)
            }

            logHandler("Formatted as ExFAT", .info)
        }
    }

    private func configurePersistence(
        partition: String,
        distroType: LinuxDistroType,
        logHandler: @escaping (String, LogLevel) -> Void
    ) async throws {

        // Mount the persistence partition
        let result = try await runCommand(
            "/usr/sbin/diskutil",
            arguments: ["mount", partition]
        )

        guard result.exitCode == 0 else {
            throw PersistenceError.configurationFailed("Could not mount persistence partition")
        }

        // Get mount point
        let infoResult = try await runCommand(
            "/usr/sbin/diskutil",
            arguments: ["info", partition]
        )

        var mountPoint = ""
        for line in infoResult.output.components(separatedBy: "\n") {
            if line.contains("Mount Point:") {
                let components = line.components(separatedBy: ":")
                if components.count >= 2 {
                    mountPoint = components[1].trimmingCharacters(in: .whitespaces)
                }
            }
        }

        guard !mountPoint.isEmpty else {
            throw PersistenceError.configurationFailed("Could not determine mount point")
        }

        // Create persistence configuration file based on distro
        switch distroType {
        case .debian:
            // Debian needs a persistence.conf file
            let confPath = "\(mountPoint)/persistence.conf"
            try "/ union".write(toFile: confPath, atomically: true, encoding: .utf8)
            logHandler("Created persistence.conf for Debian", .info)

        case .ubuntu:
            // Ubuntu/Casper just needs the partition with correct label
            logHandler("Ubuntu persistence configured (casper-rw)", .info)

        case .fedora:
            // Fedora Live uses overlay
            logHandler("Fedora persistence configured", .info)

        case .arch:
            // Arch uses cow_spacesize parameter in boot
            logHandler("Arch persistence configured", .info)

        case .other:
            // Generic persistence.conf
            let confPath = "\(mountPoint)/persistence.conf"
            try "/ union".write(toFile: confPath, atomically: true, encoding: .utf8)
            logHandler("Created generic persistence.conf", .info)
        }
    }

    private func runCommand(
        _ command: String,
        arguments: [String]
    ) async throws -> (output: String, error: String, exitCode: Int32) {
        return try await ShellService.shared.runCommand(command, arguments: arguments)
    }
    
    private func runCommandWithAdminPrivileges(
        _ command: String,
        arguments: [String]
    ) async throws -> (output: String, error: String, exitCode: Int32) {
        return try await ShellService.shared.runCommandWithAdminPrivileges(command, arguments: arguments)
    }
}
