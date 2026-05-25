//
//  ImageAnalyzerService.swift
//  RufusX
//
//  Created by Codex on 2026/05/25.
//

import Foundation

final class ImageAnalyzerService {
    enum AnalyzerError: LocalizedError {
        case mountFailed(String)
        case mountPointNotFound
        case detachFailed(String)

        var errorDescription: String? {
            switch self {
            case .mountFailed(let message):
                return "Could not mount image for analysis: \(message)"
            case .mountPointNotFound:
                return "Could not determine the mounted image location."
            case .detachFailed(let message):
                return "Could not detach image after analysis: \(message)"
            }
        }
    }

    func analyze(_ sourceURL: URL) async throws -> ImageKind {
        let pathExtension = sourceURL.pathExtension.lowercased()

        switch pathExtension {
        case "iso":
            return try await analyzeISO(sourceURL)
        case "img", "dd", "raw":
            return .rawDiskImage
        case "gz", "xz", "zip", "7z", "bz2":
            return .compressedImage
        case "vhd":
            return .vhd
        case "vhdx":
            return .vhdx
        case "ffu":
            return .ffu
        default:
            return .unknown(pathExtension)
        }
    }

    private func analyzeISO(_ sourceURL: URL) async throws -> ImageKind {
        let mountPoint = try await mountImage(sourceURL)
        defer {
            Task {
                try? await detachImage(mountPoint)
            }
        }

        let bootConfiguration = BootSectorService().detectBootConfiguration(isoMountPoint: mountPoint)
        let fileManager = FileManager.default

        if bootConfiguration.isWindowsISO {
            return .windowsInstaller
        }

        if bootConfiguration.isLinuxISO {
            return .linuxISO
        }

        let uefiShellMarkers = [
            "\(mountPoint)/EFI/BOOT/BOOTX64.EFI",
            "\(mountPoint)/EFI/BOOT/bootx64.efi",
            "\(mountPoint)/Shell.efi",
            "\(mountPoint)/shellx64.efi"
        ]

        if uefiShellMarkers.contains(where: { fileManager.fileExists(atPath: $0) }) {
            return .uefiShellISO
        }

        return .unknown("iso")
    }

    private func mountImage(_ sourceURL: URL) async throws -> String {
        let result = try await ShellService.shared.runCommand(
            "/usr/bin/hdiutil",
            arguments: ["attach", sourceURL.path, "-nobrowse", "-readonly", "-noverify", "-noautoopen"]
        )

        guard result.exitCode == 0 else {
            throw AnalyzerError.mountFailed(result.error.isEmpty ? result.output : result.error)
        }

        for line in result.output.components(separatedBy: "\n").reversed() {
            let components = line.components(separatedBy: "\t")
            guard let mountPoint = components.last?.trimmingCharacters(in: .whitespaces),
                  !mountPoint.isEmpty,
                  FileManager.default.fileExists(atPath: mountPoint) else {
                continue
            }

            return mountPoint
        }

        throw AnalyzerError.mountPointNotFound
    }

    private func detachImage(_ mountPoint: String) async throws {
        let result = try await ShellService.shared.runCommand(
            "/usr/bin/hdiutil",
            arguments: ["detach", mountPoint]
        )

        guard result.exitCode == 0 else {
            throw AnalyzerError.detachFailed(result.error.isEmpty ? result.output : result.error)
        }
    }
}
