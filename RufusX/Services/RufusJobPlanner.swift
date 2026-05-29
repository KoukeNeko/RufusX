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
        var statuses = [
            RufusSupportMatrix.status(for: options.bootSelection),
            RufusSupportMatrix.status(for: options.partitionScheme),
            RufusSupportMatrix.status(for: options.targetSystem),
            RufusSupportMatrix.status(for: options.fileSystem)
        ]

        if imageKind == .windowsInstaller {
            statuses.append(RufusSupportMatrix.status(for: options.imageOption))

            if options.windowsCustomization.hasEnabledOptions {
                statuses.append(RufusSupportMatrix.capability(for: .windowsOOBE).status)
            }
        }

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

        if options.advancedFormatOptions.checkDeviceForBadBlocks {
            warnings.append(RufusSupportMatrix.capability(for: .badBlocks).status.detail)
        }

        if imageKind == .windowsInstaller
            && options.partitionScheme == .mbr
            && options.targetSystem == .uefi {
            warnings.append("UEFI Windows media is most compatible on GPT. MBR boots via the EFI fallback path, but GPT is recommended.")
        }

        var blocker = statuses.first(where: \.blocksExecution).map { "\($0.label): \($0.detail)" }

        if blocker == nil {
            blocker = sourceImageBlocker(options: options, imageKind: imageKind)
        }

        if blocker == nil {
            blocker = executionBlocker(options: options, imageKind: imageKind)
        }

        if blocker == nil {
            blocker = toolBlocker(options: options, imageKind: imageKind, tools: tools)
        }

        if blocker == nil {
            blocker = windowsMediaBlocker(options: options, imageKind: imageKind)
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

    private static func executionBlocker(options: RufusOptions, imageKind: ImageKind) -> String? {
        if options.ddMode && options.bootSelection != .rawDiskImage {
            return "DD mode is only wired for Raw disk image boot selection."
        }

        switch options.bootSelection {
        case .freeDOS:
            return "FreeDOS is visible in the UI, but DOS boot asset deployment is not wired into the executor yet."
        case .compressedImage:
            return "Compressed image extraction/write is visible in the UI, but the executor backend is not wired yet."
        case .vhd:
            return "VHD/DD image handling is visible in the UI, but the qemu-img conversion/write executor is not wired yet."
        case .msDOS, .vhdx, .ffu:
            return RufusSupportMatrix.status(for: options.bootSelection).detail
        case .nonBootable, .diskOrIso, .uefiShell, .rawDiskImage:
            break
        }

        switch options.fileSystem {
        case .ntfs:
            return "NTFS is visible in the UI, but the formatter still needs a real NTFS backend before it can erase a USB as NTFS."
        case .ext2, .ext3, .ext4:
            return "ext filesystems are visible in the UI, but the formatter still needs an e2fsprogs-backed erase path before destructive use."
        case .refs:
            return RufusSupportMatrix.status(for: .refs).detail
        case .fat, .fat32, .exfat, .udf, .apfs:
            break
        }

        if options.imageOption == .windowsToGo {
            return "Windows To Go is visible in the UI, but deployment is not wired into the executor yet."
        }

        if imageKind == .windowsInstaller && options.windowsCustomization.hasEnabledOptions {
            return "Windows customization is visible in the UI, but unattended/OOBE injection is not wired into media creation yet."
        }

        if options.persistentPartitionSizeGB > 0 && imageKind != .linuxISO {
            return "Persistent partitions require a Linux ISO source."
        }

        if options.clusterSize != .auto {
            return "Custom cluster sizes are visible in the UI, but the diskutil formatter still uses the platform default."
        }

        if !options.advancedFormatOptions.quickFormat {
            return "Full format is visible in the UI, but only quick format is wired safely right now."
        }

        if options.advancedDriveProperties.addFixesForOldBIOS {
            return "Old BIOS compatibility fixes are visible in the UI, but the executor does not apply them yet."
        }

        if options.advancedDriveProperties.useRufusMBRWithBIOSID {
            return "Rufus MBR BIOS ID selection is visible in the UI, but MBR patching is not wired yet."
        }

        return nil
    }

    private static func toolBlocker(options: RufusOptions, imageKind _: ImageKind, tools: [RufusToolStatus]) -> String? {
        func hasTool(_ tool: RufusTool) -> Bool {
            tools.first(where: { $0.tool == tool })?.isAvailable == true
        }

        if options.persistentPartitionSizeGB > 0 && !hasTool(.e2fsprogs) {
            return "Linux persistence requires bundled e2fsprogs-compatible tools before it can create a real persistence partition."
        }

        return nil
    }

    private static func windowsMediaBlocker(options: RufusOptions, imageKind: ImageKind) -> String? {
        guard imageKind == .windowsInstaller else { return nil }

        // FAT32 is the only filesystem RufusX can produce that UEFI-boots Windows
        // (NTFS needs an unimplemented shim; exFAT/APFS/UDF are not UEFI-bootable).
        // install.wim larger than 4 GB is split automatically via wimlib.
        if options.fileSystem != .fat32 {
            return "Windows install media requires FAT32. exFAT/APFS/UDF are not UEFI-bootable and NTFS is not yet supported; large install.wim files are split automatically."
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
