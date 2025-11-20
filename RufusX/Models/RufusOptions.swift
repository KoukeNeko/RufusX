//
//  RufusOptions.swift
//  RufusX
//
//  Created by 陳德生 on 2025/11/20.
//

import Foundation

// MARK: - Partition Scheme

enum PartitionScheme: String, CaseIterable, Identifiable {
    case mbr = "MBR"
    case gpt = "GPT"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .mbr: return "MBR (Master Boot Record)"
        case .gpt: return "GPT (GUID Partition Table)"
        }
    }
}

// MARK: - Target System

enum TargetSystem: String, CaseIterable, Identifiable {
    case biosOrUefi = "BIOS or UEFI"
    case uefi = "UEFI (non CSM)"
    case bios = "BIOS (or UEFI-CSM)"

    var id: String { rawValue }
}

// MARK: - File System

enum FileSystemType: String, CaseIterable, Identifiable {
    case fat = "FAT"
    case fat32 = "FAT32"
    case ntfs = "NTFS"
    case exfat = "exFAT"
    case udf = "UDF"
    case refs = "ReFS"
    case ext2 = "ext2"
    case ext3 = "ext3"
    case ext4 = "ext4"
    case apfs = "APFS"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fat: return "FAT"
        case .fat32: return "FAT32 (Default)"
        case .ntfs: return "NTFS"
        case .exfat: return "exFAT"
        case .udf: return "UDF"
        case .refs: return "ReFS"
        case .ext2: return "ext2"
        case .ext3: return "ext3"
        case .ext4: return "ext4"
        case .apfs: return "APFS (macOS)"
        }
    }
}

// MARK: - Cluster Size

enum ClusterSize: Int, CaseIterable, Identifiable {
    case auto = 0
    case bytes512 = 512
    case bytes1024 = 1024
    case bytes2048 = 2048
    case bytes4096 = 4096
    case bytes8192 = 8192
    case bytes16384 = 16384
    case bytes32768 = 32768
    case bytes65536 = 65536

    var id: Int { rawValue }

    var displayName: String {
        if self == .auto {
            return "4096 bytes (Default)"
        }
        return "\(rawValue) bytes"
    }
}

// MARK: - Image Option

enum ImageOption: String, CaseIterable, Identifiable {
    case standardInstallation = "Standard Windows installation"
    case windowsToGo = "Windows To Go"

    var id: String { rawValue }
}

// MARK: - Windows Customization Options

struct WindowsCustomizationOptions {
    var removeTPMRequirement: Bool = true
    var removeSecureBootRequirement: Bool = true
    var removeRAMRequirement: Bool = true
    var removeOnlineAccountRequirement: Bool = true
    var disableDataCollection: Bool = true
    var setLocalAccountName: Bool = false
    var localAccountName: String = ""
    var useRegionalSettings: Bool = false
}

// MARK: - ISO Checksum

struct ISOChecksum {
    var md5: String = ""
    var sha1: String = ""
    var sha256: String = ""
    var sha512: String = ""
}

// MARK: - Download Options

struct ISODownloadOptions {
    var version: String = ""
    var release: String = ""
    var edition: String = ""
    var language: String = ""
    var architecture: String = "x64"
    var useExternalBrowser: Bool = false
}

// MARK: - Boot Selection

enum BootSelection: String, CaseIterable, Identifiable {
    case nonBootable = "Non bootable"
    case diskOrIso = "Disk or ISO image"
    // Future: case freeDOS = "FreeDOS"
    // Future: case syslinux = "Syslinux"

    var id: String { rawValue }
}

// MARK: - Advanced Drive Properties

struct AdvancedDriveProperties {
    var listUSBHardDrives: Bool = true
    var addFixesForOldBIOS: Bool = false
    var useRufusMBRWithBIOSID: Bool = false
    var biosID: String = "0x80 (Default)"
}

// MARK: - Advanced Format Options

struct AdvancedFormatOptions {
    var quickFormat: Bool = true
    var createExtendedLabel: Bool = true
    var checkDeviceForBadBlocks: Bool = false
    var badBlockPasses: Int = 1
}

// MARK: - Main Rufus Options

struct RufusOptions {
    var device: USBDevice?
    var bootSelection: BootSelection
    var partitionScheme: PartitionScheme
    var targetSystem: TargetSystem
    var volumeLabel: String
    var fileSystem: FileSystemType
    var clusterSize: ClusterSize
    var quickFormat: Bool
    var createExtendedLabel: Bool
    var checkDeviceForBadBlocks: Bool
    var isoFilePath: URL?
    var persistentPartitionSizeGB: Int
    var ddMode: Bool
    
    // Advanced Options
    var advancedDriveProperties: AdvancedDriveProperties
    var advancedFormatOptions: AdvancedFormatOptions
    var windowsCustomization: WindowsCustomizationOptions
    var downloadOptions: ISODownloadOptions

    init(
        device: USBDevice? = nil,
        bootSelection: BootSelection = .diskOrIso,
        partitionScheme: PartitionScheme = .mbr,
        targetSystem: TargetSystem = .biosOrUefi,
        volumeLabel: String = "RufusX",
        fileSystem: FileSystemType = .fat32,
        clusterSize: ClusterSize = .auto,
        quickFormat: Bool = true,
        createExtendedLabel: Bool = true,
        checkDeviceForBadBlocks: Bool = false,
        isoFilePath: URL? = nil,
        persistentPartitionSizeGB: Int = 0,
        ddMode: Bool = false,
        advancedDriveProperties: AdvancedDriveProperties = AdvancedDriveProperties(),
        advancedFormatOptions: AdvancedFormatOptions = AdvancedFormatOptions(),
        windowsCustomization: WindowsCustomizationOptions = WindowsCustomizationOptions(),
        downloadOptions: ISODownloadOptions = ISODownloadOptions()
    ) {
        self.device = device
        self.bootSelection = bootSelection
        self.partitionScheme = partitionScheme
        self.targetSystem = targetSystem
        self.volumeLabel = volumeLabel
        self.fileSystem = fileSystem
        self.clusterSize = clusterSize
        self.quickFormat = quickFormat
        self.createExtendedLabel = createExtendedLabel
        self.checkDeviceForBadBlocks = checkDeviceForBadBlocks
        self.isoFilePath = isoFilePath
        self.persistentPartitionSizeGB = persistentPartitionSizeGB
        self.ddMode = ddMode
        self.advancedDriveProperties = advancedDriveProperties
        self.advancedFormatOptions = advancedFormatOptions
        self.windowsCustomization = windowsCustomization
        self.downloadOptions = downloadOptions
    }
}

// MARK: - USB Device

struct USBDevice: Identifiable, Hashable {
    let id: String
    let name: String
    let volumeName: String
    let capacityBytes: Int64
    let mountPoint: String
    let isRemovable: Bool

    var displayName: String {
        let capacityGB = Double(capacityBytes) / 1_073_741_824
        if volumeName.isEmpty {
            return "\(name) [\(String(format: "%.0f", capacityGB)) GB]"
        }
        return "\(volumeName) (\(name)) [\(String(format: "%.0f", capacityGB)) GB]"
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: USBDevice, rhs: USBDevice) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Operation Status

enum OperationStatus: Equatable {
    case ready
    case preparing
    case formatting(progress: Double)
    case copying(progress: Double, currentFile: String)
    case verifying(progress: Double)
    case completed
    case failed(message: String)

    var displayText: String {
        switch self {
        case .ready:
            return "READY"
        case .preparing:
            return "Preparing..."
        case .formatting(let progress):
            return "Formatting... \(Int(progress * 100))%"
        case .copying(let progress, _):
            return "Copying files... \(Int(progress * 100))%"
        case .verifying(let progress):
            return "Verifying... \(Int(progress * 100))%"
        case .completed:
            return "READY"
        case .failed(let message):
            return "Error: \(message)"
        }
    }

    var isInProgress: Bool {
        switch self {
        case .ready, .completed, .failed:
            return false
        default:
            return true
        }
    }

    var progress: Double {
        switch self {
        case .formatting(let p), .copying(let p, _), .verifying(let p):
            return p
        case .completed:
            return 1.0
        default:
            return 0
        }
    }
}
