//
//  RufusToolManager.swift
//  RufusX
//
//  Created by Codex on 2026/05/25.
//

import Foundation

enum RufusTool: String, CaseIterable, Identifiable {
    case wimlibImagex = "wimlib-imagex"
    case uefiNTFS = "uefi-ntfs"
    case syslinux = "syslinux"
    case grub = "grub"
    case dosfstools = "dosfstools"
    case e2fsprogs = "e2fsprogs"
    case ntfsWriter = "ntfs-writer"
    case qemuImg = "qemu-img"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .wimlibImagex: return "wimlib-imagex"
        case .uefiNTFS: return "UEFI:NTFS"
        case .syslinux: return "Syslinux"
        case .grub: return "GRUB"
        case .dosfstools: return "dosfstools"
        case .e2fsprogs: return "e2fsprogs"
        case .ntfsWriter: return "NTFS writer"
        case .qemuImg: return "qemu-img"
        }
    }

    var candidateExecutableNames: [String] {
        switch self {
        case .wimlibImagex:
            return ["wimlib-imagex"]
        case .uefiNTFS:
            return ["uefi-ntfs.img", "uefi-ntfs"]
        case .syslinux:
            return ["syslinux", "mbr.bin"]
        case .grub:
            return ["grub-install", "grub-mkstandalone"]
        case .dosfstools:
            return ["mkfs.fat", "fsck.fat"]
        case .e2fsprogs:
            return ["mkfs.ext4", "e2fsck"]
        case .ntfsWriter:
            return ["mkntfs", "ntfs-3g"]
        case .qemuImg:
            return ["qemu-img"]
        }
    }
}

struct RufusToolStatus: Identifiable, Equatable {
    let tool: RufusTool
    let bundledPath: String?
    let systemPath: String?

    var id: String { tool.id }
    var isAvailable: Bool { bundledPath != nil || systemPath != nil }

    var displayStatus: String {
        if let bundledPath {
            return "Bundled: \(bundledPath)"
        }

        if let systemPath {
            return "System: \(systemPath)"
        }

        return "Missing"
    }
}

final class RufusToolManager {
    private let fileManager = FileManager.default

    func inventory() -> [RufusToolStatus] {
        RufusTool.allCases.map { status(for: $0) }
    }

    func status(for tool: RufusTool) -> RufusToolStatus {
        RufusToolStatus(
            tool: tool,
            bundledPath: bundledPath(for: tool),
            systemPath: systemPath(for: tool)
        )
    }

    func isAvailable(_ tool: RufusTool) -> Bool {
        status(for: tool).isAvailable
    }

    private func bundledPath(for tool: RufusTool) -> String? {
        for name in tool.candidateExecutableNames {
            let url = Bundle.main.url(forResource: name, withExtension: nil)
            if let path = url?.path, fileManager.fileExists(atPath: path) {
                return path
            }
        }

        return nil
    }

    private func systemPath(for tool: RufusTool) -> String? {
        let searchDirectories = [
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/local/sbin",
            "/usr/bin",
            "/usr/sbin"
        ]

        for directory in searchDirectories {
            for name in tool.candidateExecutableNames {
                let path = "\(directory)/\(name)"
                if fileManager.fileExists(atPath: path) {
                    return path
                }
            }
        }

        return nil
    }
}
