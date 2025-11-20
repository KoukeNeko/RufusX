//
//  DriveManager.swift
//  RufusX
//
//  Created by 陳德生 on 2025/11/20.
//

import Foundation
import DiskArbitration
import Combine

final class DriveManager: ObservableObject {
    @Published private(set) var availableDevices: [USBDevice] = []
    @Published private(set) var isScanning: Bool = false
    @Published var isPaused: Bool = false

    private var session: DASession?
    private var scanTimer: Timer?

    private let diskArbitrationQueue = DispatchQueue(label: "com.rufusx.diskarbitration")

    init() {
        setupDiskArbitration()
        startPeriodicScan()
    }

    deinit {
        stopPeriodicScan()
        if let session = session {
            DASessionSetDispatchQueue(session, nil)
        }
    }

    // MARK: - Public Methods

    func refreshDevices() {
        scanForUSBDevices()
    }

    func getDevice(byID deviceID: String) -> USBDevice? {
        return availableDevices.first { $0.id == deviceID }
    }

    // MARK: - Private Methods

    private func setupDiskArbitration() {
        session = DASessionCreate(kCFAllocatorDefault)
        if let session = session {
            DASessionSetDispatchQueue(session, diskArbitrationQueue)
        }
    }

    private func startPeriodicScan() {
        scanForUSBDevices()

        let scanIntervalSeconds: TimeInterval = 3.0
        scanTimer = Timer.scheduledTimer(withTimeInterval: scanIntervalSeconds, repeats: true) { [weak self] _ in
            self?.scanForUSBDevices()
        }
    }

    private func stopPeriodicScan() {
        scanTimer?.invalidate()
        scanTimer = nil
    }

    private func scanForUSBDevices() {
        guard !isScanning, !isPaused else { return }

        DispatchQueue.main.async {
            self.isScanning = true
        }

        diskArbitrationQueue.async { [weak self] in
            let devices = self?.fetchRemovableDevices() ?? []

            DispatchQueue.main.async {
                self?.availableDevices = devices
                self?.isScanning = false
            }
        }
    }

    private func fetchRemovableDevices() -> [USBDevice] {
        // Use diskutil to get external physical disks (filters out virtual drives/ISOs)
        guard let listOutput = try? runDiskUtil(arguments: ["list", "-plist", "external", "physical"]),
              let listData = listOutput.data(using: .utf8),
              let listPlist = try? PropertyListSerialization.propertyList(from: listData, options: [], format: nil) as? [String: Any],
              let wholeDisks = listPlist["WholeDisks"] as? [String] else {
            return []
        }

        var devices: [USBDevice] = []

        for diskID in wholeDisks {
            // Get detailed info for each disk
            guard let infoOutput = try? runDiskUtil(arguments: ["info", "-plist", diskID]),
                  let infoData = infoOutput.data(using: .utf8),
                  let infoPlist = try? PropertyListSerialization.propertyList(from: infoData, options: [], format: nil) as? [String: Any] else {
                continue
            }

            let deviceIdentifier = infoPlist["DeviceIdentifier"] as? String ?? diskID
            let mediaName = infoPlist["MediaName"] as? String ?? "Unknown Device"
            let totalSize = infoPlist["TotalSize"] as? Int64 ?? 0
            let isRemovable = infoPlist["Removable"] as? Bool ?? true // Assume removable if in external list
            
            // Try to find a volume name from partitions if available
            var volumeName = ""
            if let partitions = listPlist["AllDisksAndPartitions"] as? [[String: Any]] {
                if let diskNode = partitions.first(where: { ($0["DeviceIdentifier"] as? String) == diskID }),
                   let subPartitions = diskNode["Partitions"] as? [[String: Any]] {
                    // Find first partition with a volume name
                    for part in subPartitions {
                        if let vName = part["VolumeName"] as? String, !vName.isEmpty {
                            volumeName = vName
                            break
                        }
                    }
                }
            }
            
            // If no volume name found, use media name or generic
            if volumeName.isEmpty {
                volumeName = mediaName
            }

            let device = USBDevice(
                id: deviceIdentifier,
                name: mediaName,
                volumeName: volumeName,
                capacityBytes: totalSize,
                mountPoint: "/dev/\(deviceIdentifier)", // Use raw device path
                isRemovable: isRemovable
            )

            devices.append(device)
        }

        return devices.sorted { $0.name < $1.name }
    }

    private func runDiskUtil(arguments: [String]) throws -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        task.arguments = arguments

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        try task.run()
        task.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
