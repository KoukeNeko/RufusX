//
//  RufusJobPlanner.swift
//  RufusX
//
//  Created by Codex on 2026/05/25.
//

import Foundation

enum RufusJobPlanner {
    static func makePlan(
        options: RufusOptions,
        imageKind: ImageKind,
        tools: [RufusToolStatus]
    ) -> RufusJobPlan {
        let statuses = [
            RufusSupportMatrix.status(for: options.bootSelection),
            RufusSupportMatrix.status(for: options.partitionScheme),
            RufusSupportMatrix.status(for: options.targetSystem),
            RufusSupportMatrix.status(for: options.fileSystem)
        ]

        var warnings = statuses
            .filter { !$0.blocksExecution }
            .compactMap { status -> String? in
                switch status {
                case .available:
                    return nil
                case .experimental, .requiresBundledTool:
                    return "\(status.label): \(status.detail)"
                case .platformLimited:
                    return nil
                }
            }

        if options.persistentPartitionSizeGB > 0 {
            warnings.append(RufusSupportMatrix.capability(for: .linuxPersistence).status.detail)
        }

        var blocker = statuses.first(where: \.blocksExecution).map { "\($0.label): \($0.detail)" }

        if blocker == nil {
            blocker = sourceImageBlocker(options: options, imageKind: imageKind)
        }

        if blocker == nil {
            blocker = toolBlocker(options: options, imageKind: imageKind, tools: tools)
        }

        let destructiveSteps = blocker == nil ? destructiveSteps(for: options, imageKind: imageKind) : []

        return RufusJobPlan(
            imageKind: imageKind,
            capabilityStatuses: statuses,
            warnings: warnings,
            destructiveSteps: destructiveSteps,
            blocker: blocker
        )
    }

    private static func sourceImageBlocker(options: RufusOptions, imageKind: ImageKind) -> String? {
        if options.bootSelection.needsSourceImage && options.isoFilePath == nil {
            return "Select a source image for \(options.bootSelection.rawValue)."
        }

        if options.bootSelection.needsSourceImage && !imageKind.isRunnableSource {
            return "The selected source image could not be identified as a supported bootable image."
        }

        switch options.bootSelection {
        case .diskOrIso:
            switch imageKind {
            case .windowsInstaller, .linuxISO, .uefiShellISO:
                return nil
            case .none:
                return "Select an ISO image."
            default:
                return "Use Raw disk image, VHD, VHDX, FFU, or Compressed image mode for \(imageKind.displayName)."
            }
        case .rawDiskImage:
            return imageKind == .rawDiskImage ? nil : "Raw disk image mode requires an .img, .dd, or .raw source."
        case .compressedImage:
            return imageKind == .compressedImage ? nil : "Compressed image mode requires a supported compressed source."
        case .vhd:
            return imageKind == .vhd ? nil : "VHD/DD image mode requires a .vhd source."
        case .vhdx:
            return imageKind == .vhdx ? nil : "VHDX image mode requires a .vhdx source."
        case .ffu:
            return imageKind == .ffu ? nil : "FFU image mode requires a .ffu source."
        case .uefiShell:
            return imageKind == .uefiShellISO ? nil : "UEFI Shell mode requires a UEFI Shell ISO source."
        case .nonBootable, .freeDOS, .msDOS:
            return nil
        }
    }

    private static func toolBlocker(options: RufusOptions, imageKind: ImageKind, tools: [RufusToolStatus]) -> String? {
        func hasTool(_ tool: RufusTool) -> Bool {
            tools.first(where: { $0.tool == tool })?.isAvailable == true
        }

        switch options.bootSelection {
        case .freeDOS:
            return hasTool(.dosfstools) ? nil : "FreeDOS media requires bundled DOS boot assets before execution."
        case .uefiShell:
            return nil
        case .compressedImage:
            return hasTool(.qemuImg) ? nil : "Compressed image writing requires a bundled extraction backend."
        case .vhd:
            return hasTool(.qemuImg) ? nil : "VHD/DD image writing requires qemu-img or an equivalent bundled backend."
        case .vhdx, .ffu, .msDOS:
            return RufusSupportMatrix.status(for: options.bootSelection).detail
        case .nonBootable, .diskOrIso, .rawDiskImage:
            break
        }

        switch options.fileSystem {
        case .ntfs:
            return hasTool(.ntfsWriter) ? nil : "NTFS formatting requires a bundled NTFS writer backend."
        case .ext2, .ext3, .ext4:
            return hasTool(.e2fsprogs) ? nil : "ext filesystem formatting requires bundled e2fsprogs-compatible tools."
        case .refs:
            return RufusSupportMatrix.status(for: .refs).detail
        case .fat, .fat32, .exfat, .udf, .apfs:
            break
        }

        if imageKind == .windowsInstaller && options.fileSystem == .ntfs && !hasTool(.uefiNTFS) {
            return "Windows UEFI:NTFS media requires bundled UEFI:NTFS assets."
        }

        return nil
    }

    private static func destructiveSteps(for options: RufusOptions, imageKind: ImageKind) -> [String] {
        var steps = ["Unmount selected drive", "Erase selected drive as \(options.fileSystem.rawValue) using \(options.partitionScheme.rawValue)"]

        switch options.bootSelection {
        case .nonBootable:
            break
        case .rawDiskImage, .compressedImage, .vhd, .vhdx, .ffu:
            steps.append("Write \(imageKind.displayName) to selected drive")
        case .diskOrIso:
            steps.append("Copy \(imageKind.displayName) files to selected drive")
            steps.append("Install boot files for \(options.targetSystem.rawValue)")
        case .freeDOS, .msDOS:
            steps.append("Install DOS boot files")
        case .uefiShell:
            steps.append("Install UEFI Shell boot files")
        }

        if options.persistentPartitionSizeGB > 0 {
            steps.append("Create \(options.persistentPartitionSizeGB) GB persistence partition")
        }

        if options.advancedFormatOptions.checkDeviceForBadBlocks {
            steps.insert("Run bad block scan", at: 0)
        }

        return steps
    }
}
