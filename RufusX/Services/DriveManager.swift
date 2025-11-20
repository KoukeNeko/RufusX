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
        guard !isScanning else { return }

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
        var devices: [USBDevice] = []

        let fileManager = FileManager.default
        let volumesPath = "/Volumes"

        guard let volumeURLs = try? fileManager.contentsOfDirectory(
            at: URL(fileURLWithPath: volumesPath),
            includingPropertiesForKeys: [.volumeIsRemovableKey, .volumeTotalCapacityKey, .volumeNameKey],
            options: [.skipsHiddenFiles]
        ) else {
            return devices
        }

        for volumeURL in volumeURLs {
            guard let resourceValues = try? volumeURL.resourceValues(
                forKeys: [.volumeIsRemovableKey, .volumeTotalCapacityKey, .volumeNameKey]
            ) else {
                continue
            }

            let isRemovable = resourceValues.volumeIsRemovable ?? false

            guard isRemovable else { continue }

            let volumeName = resourceValues.volumeName ?? volumeURL.lastPathComponent
            let capacity = Int64(resourceValues.volumeTotalCapacity ?? 0)

            let diskName = extractDiskIdentifier(from: volumeURL.path)

            let device = USBDevice(
                id: volumeURL.path,
                name: diskName,
                volumeName: volumeName,
                capacityBytes: capacity,
                mountPoint: volumeURL.path,
                isRemovable: isRemovable
            )

            devices.append(device)
        }

        return devices.sorted { $0.name < $1.name }
    }

    private func extractDiskIdentifier(from mountPoint: String) -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        task.arguments = ["info", mountPoint]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""

            for line in output.components(separatedBy: "\n") {
                if line.contains("Device Identifier:") {
                    let components = line.components(separatedBy: ":")
                    if components.count >= 2 {
                        return components[1].trimmingCharacters(in: .whitespaces)
                    }
                }
            }
        } catch {
            // Fall back to mount point name
        }

        return URL(fileURLWithPath: mountPoint).lastPathComponent
    }
}
