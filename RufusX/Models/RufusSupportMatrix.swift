//
//  RufusSupportMatrix.swift
//  RufusX
//
//  Created by Codex on 2026/05/25.
//

import Foundation

enum RufusFeature: String, CaseIterable, Identifiable {
    case formatUsb
    case fileSystems
    case freeDOS
    case msDOS
    case biosBoot
    case uefiBoot
    case uefiNTFS
    case bootableISO
    case bootableDiskImage
    case compressedImage
    case windows11Bypass
    case windowsToGo
    case driveImageCreate
    case linuxPersistence
    case checksums
    case uefiRuntimeValidation
    case windowsOOBE
    case badBlocks
    case windowsISODownload
    case uefiShellDownload
    case localization
    case portable
    case refs
    case extFileSystems

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .formatUsb: return "Format removable drives"
        case .fileSystems: return "FAT/FAT32/NTFS/UDF/exFAT/ReFS/ext2/ext3"
        case .freeDOS: return "FreeDOS boot media"
        case .msDOS: return "MS-DOS boot media"
        case .biosBoot: return "BIOS boot media"
        case .uefiBoot: return "UEFI boot media"
        case .uefiNTFS: return "UEFI:NTFS boot media"
        case .bootableISO: return "Bootable ISO images"
        case .bootableDiskImage: return "Bootable disk images"
        case .compressedImage: return "Compressed disk images"
        case .windows11Bypass: return "Windows 11 requirement bypass"
        case .windowsToGo: return "Windows To Go"
        case .driveImageCreate: return "Create VHD/DD/VHDX/FFU images"
        case .linuxPersistence: return "Persistent Linux partitions"
        case .checksums: return "MD5/SHA1/SHA256/SHA512"
        case .uefiRuntimeValidation: return "UEFI runtime validation"
        case .windowsOOBE: return "Windows OOBE customization"
        case .badBlocks: return "Bad block and fake-drive checks"
        case .windowsISODownload: return "Official Windows ISO download"
        case .uefiShellDownload: return "UEFI Shell ISO download"
        case .localization: return "Localized UI foundation"
        case .portable: return "No-install portable app behavior"
        case .refs: return "ReFS formatting"
        case .extFileSystems: return "ext2/ext3 filesystem support"
        }
    }
}

enum CapabilityStatus: Equatable {
    case available(String)
    case requiresBundledTool(String)
    case experimental(String)
    case platformLimited(String)

    var blocksExecution: Bool {
        switch self {
        case .platformLimited:
            return true
        case .available, .requiresBundledTool, .experimental:
            return false
        }
    }

    var label: String {
        switch self {
        case .available: return "Available"
        case .requiresBundledTool: return "Requires bundled tool"
        case .experimental: return "Experimental"
        case .platformLimited: return "Platform limited"
        }
    }

    var detail: String {
        switch self {
        case .available(let detail),
             .requiresBundledTool(let detail),
             .experimental(let detail),
             .platformLimited(let detail):
            return detail
        }
    }
}

struct RufusCapability: Identifiable, Equatable {
    let feature: RufusFeature
    let status: CapabilityStatus

    var id: String { feature.id }
}

enum ImageKind: Equatable {
    case none
    case windowsInstaller
    case linuxISO
    case uefiShellISO
    case rawDiskImage
    case compressedImage
    case vhd
    case vhdx
    case ffu
    case unknown(String)

    var displayName: String {
        switch self {
        case .none: return "No image"
        case .windowsInstaller: return "Windows installer ISO"
        case .linuxISO: return "Linux ISO"
        case .uefiShellISO: return "UEFI Shell ISO"
        case .rawDiskImage: return "Raw disk image"
        case .compressedImage: return "Compressed image"
        case .vhd: return "VHD/DD image"
        case .vhdx: return "VHDX image"
        case .ffu: return "FFU image"
        case .unknown(let ext): return ext.isEmpty ? "Unknown image" : "Unknown .\(ext) image"
        }
    }

    var isRunnableSource: Bool {
        switch self {
        case .unknown, .none:
            return false
        case .windowsInstaller, .linuxISO, .uefiShellISO, .rawDiskImage, .compressedImage, .vhd, .vhdx, .ffu:
            return true
        }
    }
}

struct RufusJobPlan: Equatable {
    let imageKind: ImageKind
    let capabilityStatuses: [CapabilityStatus]
    let warnings: [String]
    let destructiveSteps: [String]
    let blocker: String?

    var isRunnable: Bool { blocker == nil }

    var summary: String {
        if let blocker {
            return blocker
        }

        if warnings.isEmpty {
            return "Ready to create \(imageKind.displayName) media."
        }

        return warnings.joined(separator: " ")
    }
}

enum ISOProbeState: Equatable {
    case idle
    case probing
    case analyzed(ImageKind)
    case unsupported(String)
    case failed(String)

    var imageKind: ImageKind {
        switch self {
        case .analyzed(let kind):
            return kind
        case .idle, .probing, .unsupported, .failed:
            return .none
        }
    }

    var message: String {
        switch self {
        case .idle:
            return "Select a source image or choose a no-image boot mode."
        case .probing:
            return "Analyzing selected source image..."
        case .analyzed(let kind):
            return "Detected: \(kind.displayName)."
        case .unsupported(let message), .failed(let message):
            return message
        }
    }

    var isBlocking: Bool {
        switch self {
        case .unsupported, .failed:
            return true
        case .idle, .probing, .analyzed:
            return false
        }
    }
}

enum RufusSupportMatrix {
    static let statusSuffixSeparator = " - "

    static let capabilities: [RufusCapability] = [
        RufusCapability(feature: .formatUsb, status: .available("Uses diskutil for FAT/FAT32/UDF/exFAT/APFS formatting.")),
        RufusCapability(feature: .fileSystems, status: .requiresBundledTool("NTFS and ext support need bundled filesystem tools; ReFS is platform-limited.")),
        RufusCapability(feature: .freeDOS, status: .requiresBundledTool("Requires a bundled FreeDOS boot image.")),
        RufusCapability(feature: .msDOS, status: .platformLimited("MS-DOS boot files cannot be redistributed or generated reliably on macOS.")),
        RufusCapability(feature: .biosBoot, status: .experimental("Existing syslinux/fdisk path is present but needs full boot validation.")),
        RufusCapability(feature: .uefiBoot, status: .available("ISO file copy and EFI structure handling are available.")),
        RufusCapability(feature: .uefiNTFS, status: .requiresBundledTool("Requires bundled UEFI:NTFS helper assets.")),
        RufusCapability(feature: .bootableISO, status: .available("Windows/Linux ISO detection and copy flow are present.")),
        RufusCapability(feature: .bootableDiskImage, status: .available("Raw write uses dd after preflight.")),
        RufusCapability(feature: .compressedImage, status: .requiresBundledTool("Requires a bundled extraction backend before writing.")),
        RufusCapability(feature: .windows11Bypass, status: .experimental("UI exists; media injection must be completed and validated.")),
        RufusCapability(feature: .windowsToGo, status: .experimental("Selection exists; deployment backend still needs validation.")),
        RufusCapability(feature: .driveImageCreate, status: .platformLimited("Creating VHDX/FFU images needs a backend not available in this macOS build.")),
        RufusCapability(feature: .linuxPersistence, status: .experimental("Persistence partition code exists; distro boot parameter validation remains required.")),
        RufusCapability(feature: .checksums, status: .available("MD5/SHA1/SHA256 are implemented; SHA512 remains visible in UI.")),
        RufusCapability(feature: .uefiRuntimeValidation, status: .experimental("Requires VM/firmware validation harness.")),
        RufusCapability(feature: .windowsOOBE, status: .experimental("UI exists; unattended file injection must be wired into media creation.")),
        RufusCapability(feature: .badBlocks, status: .experimental("UI exists; scan executor needs destructive test validation.")),
        RufusCapability(feature: .windowsISODownload, status: .experimental("Microsoft retail ISO flow exists but depends on current public endpoints.")),
        RufusCapability(feature: .uefiShellDownload, status: .available("UEFI Shell download URL is available.")),
        RufusCapability(feature: .localization, status: .experimental("String extraction and locale files still need to be added.")),
        RufusCapability(feature: .portable, status: .available("The app runs without installation from its bundle.")),
        RufusCapability(feature: .refs, status: .platformLimited("ReFS formatting is Windows-specific and blocked on macOS.")),
        RufusCapability(feature: .extFileSystems, status: .requiresBundledTool("Requires bundled e2fsprogs-compatible tools."))
    ]

    static func capability(for feature: RufusFeature) -> RufusCapability {
        capabilities.first { $0.feature == feature } ?? RufusCapability(feature: feature, status: .platformLimited("Capability not registered."))
    }

    static func status(for bootSelection: BootSelection) -> CapabilityStatus {
        switch bootSelection {
        case .nonBootable:
            return .available("Formats the target drive without boot files.")
        case .diskOrIso:
            return capability(for: .bootableISO).status
        case .freeDOS:
            return capability(for: .freeDOS).status
        case .msDOS:
            return capability(for: .msDOS).status
        case .uefiShell:
            return capability(for: .uefiShellDownload).status
        case .rawDiskImage:
            return capability(for: .bootableDiskImage).status
        case .compressedImage:
            return capability(for: .compressedImage).status
        case .vhd:
            return .experimental("VHD/DD images are visible; backend validation is required before release.")
        case .vhdx:
            return .platformLimited("VHDX write support needs a backend not available in this macOS build.")
        case .ffu:
            return .platformLimited("FFU write support needs a backend not available in this macOS build.")
        }
    }

    static func status(for fileSystem: FileSystemType) -> CapabilityStatus {
        switch fileSystem {
        case .fat, .fat32, .exfat, .udf, .apfs:
            return .available("Supported by macOS diskutil for formatting.")
        case .ntfs:
            return .requiresBundledTool("Requires bundled NTFS write/format backend.")
        case .ext2, .ext3:
            return capability(for: .extFileSystems).status
        case .ext4:
            return .experimental("Persistence service can use e2fsprogs when available; general ext4 media still needs validation.")
        case .refs:
            return capability(for: .refs).status
        }
    }

    static func status(for targetSystem: TargetSystem) -> CapabilityStatus {
        switch targetSystem {
        case .biosOrUefi:
            return .experimental("Dual BIOS/UEFI setup exists for some ISOs but needs VM and hardware validation.")
        case .uefi:
            return capability(for: .uefiBoot).status
        case .bios:
            return capability(for: .biosBoot).status
        }
    }

    static func status(for partitionScheme: PartitionScheme) -> CapabilityStatus {
        switch partitionScheme {
        case .mbr:
            return .available("Supported by diskutil.")
        case .gpt:
            return .experimental("Supported by diskutil; boot compatibility varies by image and target system.")
        }
    }

    static func optionTitle(_ title: String, status: CapabilityStatus) -> String {
        switch status {
        case .available:
            return title
        case .requiresBundledTool, .experimental, .platformLimited:
            return "\(title)\(statusSuffixSeparator)\(status.label)"
        }
    }
}
