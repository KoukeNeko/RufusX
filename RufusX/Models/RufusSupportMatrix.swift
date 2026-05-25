//
//  RufusSupportMatrix.swift
//  RufusX
//
//  Created by Codex on 2026/05/25.
//

import Foundation

enum RufusSupportMatrix {
    static let supportedBootSelection: BootSelection = .diskOrIso
    static let supportedPartitionScheme: PartitionScheme = .mbr
    static let supportedTargetSystem: TargetSystem = .uefi
    static let supportedFileSystem: FileSystemType = .exfat

    static let supportedPathDescription = "Supported path: Windows ISO, MBR, UEFI (non CSM), exFAT."
    static let notSupportedYetLabel = "Not supported yet"

    static func validate(options: RufusOptions) -> String? {
        if options.ddMode {
            return "DD image writing is not supported yet."
        }

        if options.bootSelection != supportedBootSelection {
            return "Only Disk or ISO image boot selection is supported right now."
        }

        if options.partitionScheme != supportedPartitionScheme {
            return "Only MBR partition scheme is supported right now."
        }

        if options.targetSystem != supportedTargetSystem {
            return "Only UEFI (non CSM) target system is supported right now."
        }

        if options.fileSystem != supportedFileSystem {
            return "Only exFAT file system is supported right now."
        }

        if options.persistentPartitionSizeGB != 0 {
            return "Linux persistence is not supported yet."
        }

        return nil
    }

    static func isSupported(_ value: BootSelection) -> Bool {
        value == supportedBootSelection
    }

    static func isSupported(_ value: PartitionScheme) -> Bool {
        value == supportedPartitionScheme
    }

    static func isSupported(_ value: TargetSystem) -> Bool {
        value == supportedTargetSystem
    }

    static func isSupported(_ value: FileSystemType) -> Bool {
        value == supportedFileSystem
    }

    static func optionTitle(_ title: String, isSupported: Bool) -> String {
        isSupported ? title : "\(title) - \(notSupportedYetLabel)"
    }
}

enum ISOProbeState: Equatable {
    case idle
    case probing
    case supportedWindows
    case unsupported(String)
    case failed(String)

    var canStart: Bool {
        self == .supportedWindows
    }

    var message: String {
        switch self {
        case .idle:
            return "Select a Windows installer ISO to continue."
        case .probing:
            return "Checking whether this is a Windows installer ISO..."
        case .supportedWindows:
            return "Windows ISO validated. \(RufusSupportMatrix.supportedPathDescription)"
        case .unsupported(let message), .failed(let message):
            return message
        }
    }

    var isBlocking: Bool {
        switch self {
        case .unsupported, .failed:
            return true
        case .idle, .probing, .supportedWindows:
            return false
        }
    }
}
