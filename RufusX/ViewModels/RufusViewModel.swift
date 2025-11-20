//
//  RufusViewModel.swift
//  RufusX
//
//  Created by 陳德生 on 2025/11/20.
//

import Foundation
import SwiftUI
import Combine
import UniformTypeIdentifiers
import CryptoKit

@MainActor
final class RufusViewModel: ObservableObject {
    // MARK: - Published Properties

    @Published var options = RufusOptions()
    @Published var selectedDevice: USBDevice?
    @Published var status: OperationStatus = .ready
    @Published var elapsedTime: TimeInterval = 0
    @Published var showAdvancedDriveProperties: Bool = false
    @Published var showAdvancedFormatOptions: Bool = false
    @Published var showWindowsCustomization: Bool = false
    @Published var showChecksumDialog: Bool = false
    @Published var showDownloadDialog: Bool = false
    @Published var showLogDialog: Bool = false
    @Published var showAboutDialog: Bool = false
    @Published var isoChecksum = ISOChecksum()
    @Published var logEntries: [LogEntry] = []

    // MARK: - Dependencies

    let driveManager = DriveManager()
    private let formatterService = USBFormatterService()

    // MARK: - Private Properties

    private var cancellables = Set<AnyCancellable>()
    private var timer: Timer?

    // MARK: - Computed Properties

    var canStart: Bool {
        selectedDevice != nil && options.isoFilePath != nil && !status.isInProgress
    }

    var deviceCount: Int {
        driveManager.availableDevices.count
    }

    var formattedElapsedTime: String {
        let minutes = Int(elapsedTime) / 60
        let seconds = Int(elapsedTime) % 60
        return String(format: "%02d:%02d:%02d", 0, minutes, seconds)
    }

    // MARK: - Initialization

    init() {
        setupBindings()
    }

    // MARK: - Public Methods

    func selectISO() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "iso")!]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Select an ISO image file"
        panel.prompt = "Select"

        if panel.runModal() == .OK, let url = panel.url {
            options.isoFilePath = url
            updateVolumeLabelFromISO(url)
            calculateChecksums(for: url)
        }
    }

    func startOperation() {
        guard canStart, let device = selectedDevice else { return }

        status = .preparing
        startTimer()
        addLog("Starting operation on \(device.displayName)", level: .info)

        Task {
            do {
                try await formatterService.formatUSBDrive(
                    device: device,
                    options: options,
                    progressHandler: { [weak self] newStatus in
                        Task { @MainActor in
                            self?.status = newStatus
                        }
                    },
                    logHandler: { [weak self] message, level in
                        Task { @MainActor in
                            self?.addLog(message, level: level)
                        }
                    }
                )
                stopTimer()
            } catch {
                await MainActor.run {
                    self.status = .failed(message: error.localizedDescription)
                    self.addLog("Error: \(error.localizedDescription)", level: .error)
                    self.stopTimer()
                }
            }
        }
    }

    func cancelOperation() {
        formatterService.cancel()
        status = .ready
        stopTimer()
        elapsedTime = 0
        addLog("Operation cancelled", level: .warning)
    }

    func addLog(_ message: String, level: LogLevel = .info) {
        logEntries.append(LogEntry(message: message, level: level))
    }

    func refreshDevices() {
        driveManager.refreshDevices()
    }

    // MARK: - Private Methods

    private func setupBindings() {
        driveManager.$availableDevices
            .receive(on: DispatchQueue.main)
            .sink { [weak self] devices in
                guard let self = self else { return }

                if self.selectedDevice == nil, let firstDevice = devices.first {
                    self.selectedDevice = firstDevice
                    self.options.selectedDeviceID = firstDevice.id
                }

                if let selected = self.selectedDevice,
                   !devices.contains(where: { $0.id == selected.id }) {
                    self.selectedDevice = devices.first
                    self.options.selectedDeviceID = devices.first?.id ?? ""
                }
            }
            .store(in: &cancellables)
    }

    private func updateVolumeLabelFromISO(_ url: URL) {
        let filename = url.deletingPathExtension().lastPathComponent
        options.volumeLabel = String(filename.prefix(32))
    }

    private func calculateChecksums(for url: URL) {
        Task.detached {
            guard let data = try? Data(contentsOf: url) else { return }

            let md5 = Insecure.MD5.hash(data: data)
                .map { String(format: "%02x", $0) }
                .joined()

            let sha1 = Insecure.SHA1.hash(data: data)
                .map { String(format: "%02x", $0) }
                .joined()

            let sha256 = SHA256.hash(data: data)
                .map { String(format: "%02x", $0) }
                .joined()

            await MainActor.run { [weak self] in
                self?.isoChecksum = ISOChecksum(
                    md5: md5,
                    sha1: sha1,
                    sha256: sha256,
                    sha512: "Use <Alt>-<H> (in the main application window) to enable."
                )
            }
        }
    }

    private func startTimer() {
        elapsedTime = 0
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.elapsedTime += 1
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}
