//
//  ISOProbeService.swift
//  RufusX
//
//  Created by Codex on 2026/05/25.
//

import Foundation

final class ISOProbeService {
    enum ProbeError: LocalizedError, Equatable {
        case mountFailed(String)
        case mountPointNotFound
        case detachFailed(String)
        case notWindowsISO

        var errorDescription: String? {
            switch self {
            case .mountFailed(let message):
                return "Could not mount ISO for validation: \(message)"
            case .mountPointNotFound:
                return "Could not determine the mounted ISO location."
            case .detachFailed(let message):
                return "Could not detach ISO after validation: \(message)"
            case .notWindowsISO:
                return "Only Windows installer ISOs are supported right now."
            }
        }
    }

    func validateWindowsISO(_ isoURL: URL) async throws {
        let mountPoint = try await mountISO(isoURL)
        let configuration = BootSectorService().detectBootConfiguration(isoMountPoint: mountPoint)
        try await detachISO(mountPoint)

        guard configuration.isWindowsISO else {
            throw ProbeError.notWindowsISO
        }
    }

    private func mountISO(_ isoURL: URL) async throws -> String {
        let result = try await ShellService.shared.runCommand(
            "/usr/bin/hdiutil",
            arguments: ["attach", isoURL.path, "-nobrowse", "-readonly", "-noverify", "-noautoopen"]
        )

        guard result.exitCode == 0 else {
            throw ProbeError.mountFailed(result.error.isEmpty ? result.output : result.error)
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

        throw ProbeError.mountPointNotFound
    }

    private func detachISO(_ mountPoint: String) async throws {
        let result = try await ShellService.shared.runCommand(
            "/usr/bin/hdiutil",
            arguments: ["detach", mountPoint]
        )

        guard result.exitCode == 0 else {
            throw ProbeError.detachFailed(result.error.isEmpty ? result.output : result.error)
        }
    }
}
