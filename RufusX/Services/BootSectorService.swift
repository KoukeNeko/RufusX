//
//  BootSectorService.swift
//  RufusX
//
//  Created by 陳德生 on 2025/11/20.
//

import Foundation

final class BootSectorService {

    // MARK: - Error Types

    enum BootSectorError: LocalizedError {
        case unsupportedBootType
        case mbrWriteFailed(String)
        case efiSetupFailed(String)
        case syslinuxNotFound
        case grubNotFound

        var errorDescription: String? {
            switch self {
            case .unsupportedBootType:
                return "Unsupported boot type for this configuration"
            case .mbrWriteFailed(let message):
                return "Failed to write MBR: \(message)"
            case .efiSetupFailed(let message):
                return "Failed to setup EFI boot: \(message)"
            case .syslinuxNotFound:
                return "Syslinux not found. Please install via Homebrew: brew install syslinux"
            case .grubNotFound:
                return "GRUB not found for EFI boot setup"
            }
        }
    }

    // MARK: - Boot Type Detection

    struct BootConfiguration {
        let isWindowsISO: Bool
        let isLinuxISO: Bool
        let hasEFI: Bool
        let hasBIOS: Bool
    }

    func detectBootConfiguration(isoMountPoint: String) -> BootConfiguration {
        let fileManager = FileManager.default

        // Check for Windows markers
        let windowsMarkers = [
            "\(isoMountPoint)/sources/install.wim",
            "\(isoMountPoint)/sources/install.esd",
            "\(isoMountPoint)/bootmgr",
            "\(isoMountPoint)/bootmgr.efi"
        ]
        let isWindows = windowsMarkers.contains { fileManager.fileExists(atPath: $0) }

        // Check for Linux markers
        let linuxMarkers = [
            "\(isoMountPoint)/casper",
            "\(isoMountPoint)/live",
            "\(isoMountPoint)/isolinux",
            "\(isoMountPoint)/syslinux"
        ]
        let isLinux = linuxMarkers.contains { fileManager.fileExists(atPath: $0) }

        // Check for EFI support
        let efiPaths = [
            "\(isoMountPoint)/EFI",
            "\(isoMountPoint)/efi"
        ]
        let hasEFI = efiPaths.contains { fileManager.fileExists(atPath: $0) }

        // Check for BIOS/legacy boot support
        let biosPaths = [
            "\(isoMountPoint)/isolinux",
            "\(isoMountPoint)/syslinux",
            "\(isoMountPoint)/boot/grub",
            "\(isoMountPoint)/bootmgr"
        ]
        let hasBIOS = biosPaths.contains { fileManager.fileExists(atPath: $0) }

        return BootConfiguration(
            isWindowsISO: isWindows,
            isLinuxISO: isLinux,
            hasEFI: hasEFI,
            hasBIOS: hasBIOS
        )
    }

    // MARK: - Setup Boot Sector

    func setupBootSector(
        diskIdentifier: String,
        usbMountPoint: String,
        isoMountPoint: String,
        targetSystem: TargetSystem,
        partitionScheme: PartitionScheme,
        logHandler: @escaping (String, LogLevel) -> Void
    ) async throws {

        let config = detectBootConfiguration(isoMountPoint: isoMountPoint)

        logHandler("Detected: Windows=\(config.isWindowsISO), Linux=\(config.isLinuxISO), EFI=\(config.hasEFI), BIOS=\(config.hasBIOS)", .info)

        // Setup based on target system
        switch targetSystem {
        case .uefi:
            try await setupUEFIBoot(
                usbMountPoint: usbMountPoint,
                isoMountPoint: isoMountPoint,
                config: config,
                logHandler: logHandler
            )

        case .bios:
            try await setupBIOSBoot(
                diskIdentifier: diskIdentifier,
                usbMountPoint: usbMountPoint,
                isoMountPoint: isoMountPoint,
                config: config,
                logHandler: logHandler
            )

        case .biosOrUefi:
            // Setup both if possible
            if config.hasEFI {
                try await setupUEFIBoot(
                    usbMountPoint: usbMountPoint,
                    isoMountPoint: isoMountPoint,
                    config: config,
                    logHandler: logHandler
                )
            }
            if config.hasBIOS {
                try await setupBIOSBoot(
                    diskIdentifier: diskIdentifier,
                    usbMountPoint: usbMountPoint,
                    isoMountPoint: isoMountPoint,
                    config: config,
                    logHandler: logHandler
                )
            }
        }
    }

    // MARK: - UEFI Boot Setup

    private func setupUEFIBoot(
        usbMountPoint: String,
        isoMountPoint: String,
        config: BootConfiguration,
        logHandler: @escaping (String, LogLevel) -> Void
    ) async throws {

        logHandler("Setting up UEFI boot...", .info)

        let fileManager = FileManager.default
        let efiDestPath = "\(usbMountPoint)/EFI"

        // Create EFI directory structure
        try fileManager.createDirectory(
            atPath: "\(efiDestPath)/BOOT",
            withIntermediateDirectories: true
        )

        if config.isWindowsISO {
            // Copy Windows EFI bootloader
            try await copyWindowsEFIFiles(
                from: isoMountPoint,
                to: usbMountPoint,
                logHandler: logHandler
            )
        } else if config.isLinuxISO {
            // Copy Linux EFI bootloader
            try await copyLinuxEFIFiles(
                from: isoMountPoint,
                to: usbMountPoint,
                logHandler: logHandler
            )
        }

        logHandler("UEFI boot setup complete", .success)
    }

    private func copyWindowsEFIFiles(
        from isoMountPoint: String,
        to usbMountPoint: String,
        logHandler: @escaping (String, LogLevel) -> Void
    ) async throws {

        let fileManager = FileManager.default

        // Copy bootmgfw.efi as bootx64.efi
        let bootmgfwPaths = [
            "\(isoMountPoint)/efi/boot/bootx64.efi",
            "\(isoMountPoint)/EFI/Boot/bootx64.efi",
            "\(isoMountPoint)/efi/microsoft/boot/bootmgfw.efi"
        ]

        var copied = false
        for sourcePath in bootmgfwPaths {
            if fileManager.fileExists(atPath: sourcePath) {
                let destPath = "\(usbMountPoint)/EFI/BOOT/bootx64.efi"
                try? fileManager.removeItem(atPath: destPath)
                try fileManager.copyItem(atPath: sourcePath, toPath: destPath)
                logHandler("Copied EFI bootloader: \(sourcePath)", .info)
                copied = true
                break
            }
        }

        if !copied {
            logHandler("Warning: Could not find Windows EFI bootloader", .warning)
        }

        // Copy BCD store if exists
        let bcdPath = "\(isoMountPoint)/boot/bcd"
        if fileManager.fileExists(atPath: bcdPath) {
            let destBCD = "\(usbMountPoint)/boot"
            try fileManager.createDirectory(atPath: destBCD, withIntermediateDirectories: true)
            try? fileManager.copyItem(atPath: bcdPath, toPath: "\(destBCD)/bcd")
        }
    }

    private func copyLinuxEFIFiles(
        from isoMountPoint: String,
        to usbMountPoint: String,
        logHandler: @escaping (String, LogLevel) -> Void
    ) async throws {

        let fileManager = FileManager.default

        // Copy GRUB EFI files
        let grubPaths = [
            "\(isoMountPoint)/EFI/BOOT/grubx64.efi",
            "\(isoMountPoint)/EFI/boot/grubx64.efi",
            "\(isoMountPoint)/boot/grub/x86_64-efi"
        ]

        for sourcePath in grubPaths {
            if fileManager.fileExists(atPath: sourcePath) {
                let fileName = (sourcePath as NSString).lastPathComponent
                let destPath = "\(usbMountPoint)/EFI/BOOT/\(fileName)"
                try? fileManager.removeItem(atPath: destPath)
                try fileManager.copyItem(atPath: sourcePath, toPath: destPath)
                logHandler("Copied: \(fileName)", .info)
            }
        }

        // Copy bootx64.efi (shimx64 or grub)
        let bootloaderPaths = [
            "\(isoMountPoint)/EFI/BOOT/bootx64.efi",
            "\(isoMountPoint)/EFI/boot/bootx64.efi"
        ]

        for sourcePath in bootloaderPaths {
            if fileManager.fileExists(atPath: sourcePath) {
                let destPath = "\(usbMountPoint)/EFI/BOOT/bootx64.efi"
                try? fileManager.removeItem(atPath: destPath)
                try fileManager.copyItem(atPath: sourcePath, toPath: destPath)
                logHandler("Copied EFI bootloader", .info)
                break
            }
        }
    }

    // MARK: - BIOS Boot Setup

    private func setupBIOSBoot(
        diskIdentifier: String,
        usbMountPoint: String,
        isoMountPoint: String,
        config: BootConfiguration,
        logHandler: @escaping (String, LogLevel) -> Void
    ) async throws {

        logHandler("Setting up BIOS boot...", .info)

        if config.isWindowsISO {
            try await setupWindowsBIOSBoot(
                diskIdentifier: diskIdentifier,
                usbMountPoint: usbMountPoint,
                isoMountPoint: isoMountPoint,
                logHandler: logHandler
            )
        } else if config.isLinuxISO {
            try await setupLinuxBIOSBoot(
                diskIdentifier: diskIdentifier,
                usbMountPoint: usbMountPoint,
                isoMountPoint: isoMountPoint,
                logHandler: logHandler
            )
        }

        logHandler("BIOS boot setup complete", .success)
    }

    private func setupWindowsBIOSBoot(
        diskIdentifier: String,
        usbMountPoint: String,
        isoMountPoint: String,
        logHandler: @escaping (String, LogLevel) -> Void
    ) async throws {

        let fileManager = FileManager.default

        // Copy bootmgr
        let bootmgrPath = "\(isoMountPoint)/bootmgr"
        if fileManager.fileExists(atPath: bootmgrPath) {
            let destPath = "\(usbMountPoint)/bootmgr"
            try? fileManager.removeItem(atPath: destPath)
            try fileManager.copyItem(atPath: bootmgrPath, toPath: destPath)
            logHandler("Copied bootmgr", .info)
        }

        // Make partition active/bootable using fdisk
        // Note: This requires admin privileges
        logHandler("Setting partition as active...", .info)

        let result = try await runCommand(
            "/usr/sbin/fdisk",
            arguments: ["-e", "/dev/\(diskIdentifier)"],
            input: "f 1\nw\nq\n"
        )

        if result.exitCode != 0 {
            logHandler("Warning: Could not set partition active: \(result.error)", .warning)
        }
    }

    private func setupLinuxBIOSBoot(
        diskIdentifier: String,
        usbMountPoint: String,
        isoMountPoint: String,
        logHandler: @escaping (String, LogLevel) -> Void
    ) async throws {

        let fileManager = FileManager.default

        // Check for syslinux/isolinux
        let syslinuxPaths = [
            "\(isoMountPoint)/isolinux",
            "\(isoMountPoint)/syslinux"
        ]

        for syslinuxPath in syslinuxPaths {
            if fileManager.fileExists(atPath: syslinuxPath) {
                // Copy syslinux files
                let destPath = "\(usbMountPoint)/syslinux"
                try fileManager.createDirectory(atPath: destPath, withIntermediateDirectories: true)

                let enumerator = fileManager.enumerator(atPath: syslinuxPath)
                while let file = enumerator?.nextObject() as? String {
                    let sourcePath = "\(syslinuxPath)/\(file)"
                    let destFilePath = "\(destPath)/\(file)"

                    var isDir: ObjCBool = false
                    if fileManager.fileExists(atPath: sourcePath, isDirectory: &isDir) {
                        if isDir.boolValue {
                            try fileManager.createDirectory(atPath: destFilePath, withIntermediateDirectories: true)
                        } else {
                            try? fileManager.removeItem(atPath: destFilePath)
                            try fileManager.copyItem(atPath: sourcePath, toPath: destFilePath)
                        }
                    }
                }

                // Rename isolinux.cfg to syslinux.cfg if needed
                let isolinuxCfg = "\(destPath)/isolinux.cfg"
                let syslinuxCfg = "\(destPath)/syslinux.cfg"
                if fileManager.fileExists(atPath: isolinuxCfg) && !fileManager.fileExists(atPath: syslinuxCfg) {
                    try fileManager.moveItem(atPath: isolinuxCfg, toPath: syslinuxCfg)
                }

                logHandler("Copied syslinux files", .info)
                break
            }
        }

        // Try to install syslinux MBR if available
        try await installSyslinuxMBR(diskIdentifier: diskIdentifier, logHandler: logHandler)
    }

    private func installSyslinuxMBR(
        diskIdentifier: String,
        logHandler: @escaping (String, LogLevel) -> Void
    ) async throws {

        // Check if syslinux is installed via Homebrew
        let syslinuxMBRPaths = [
            "/usr/local/share/syslinux/mbr.bin",
            "/opt/homebrew/share/syslinux/mbr.bin",
            "/usr/share/syslinux/mbr.bin"
        ]

        var mbrPath: String?
        for path in syslinuxMBRPaths {
            if FileManager.default.fileExists(atPath: path) {
                mbrPath = path
                break
            }
        }

        guard let mbrBinPath = mbrPath else {
            logHandler("⚠️ Syslinux MBR not found!", .warning)
            logHandler("Legacy BIOS boot will NOT work without it.", .warning)
            logHandler("Please run: 'brew install syslinux' in Terminal", .warning)
            return
        }

        // Write MBR to disk
        logHandler("Installing syslinux MBR...", .info)

        let result = try await runCommand(
            "/bin/dd",
            arguments: [
                "conv=notrunc",
                "bs=440",
                "count=1",
                "if=\(mbrBinPath)",
                "of=/dev/\(diskIdentifier)"
            ]
        )

        if result.exitCode == 0 {
            logHandler("Syslinux MBR installed successfully", .success)
        } else {
            logHandler("Warning: Could not install MBR: \(result.error)", .warning)
        }
    }

    // MARK: - Helper Methods

    private func runCommand(
        _ command: String,
        arguments: [String],
        input: String? = nil
    ) async throws -> (output: String, error: String, exitCode: Int32) {

        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: command)
            process.arguments = arguments

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            let inputPipe = Pipe()

            process.standardOutput = outputPipe
            process.standardError = errorPipe
            process.standardInput = inputPipe

            do {
                try process.run()

                if let input = input, let inputData = input.data(using: .utf8) {
                    // Handle input writing safely
                    do {
                        if #available(macOS 10.15.4, *) {
                            try inputPipe.fileHandleForWriting.write(contentsOf: inputData)
                        } else {
                            // Fallback for older macOS, but riskier. 
                            // Ideally we should use the new API.
                            inputPipe.fileHandleForWriting.write(inputData)
                        }
                        try inputPipe.fileHandleForWriting.close()
                    } catch {
                        // Ignore broken pipe errors if process exited early
                        // But log it if needed (continuation handles the result)
                    }
                } else {
                    // Close input pipe if no input to signal EOF
                    try? inputPipe.fileHandleForWriting.close()
                }

                process.waitUntilExit()

                let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

                let output = String(data: outputData, encoding: .utf8) ?? ""
                let error = String(data: errorData, encoding: .utf8) ?? ""

                continuation.resume(returning: (output, error, process.terminationStatus))
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
