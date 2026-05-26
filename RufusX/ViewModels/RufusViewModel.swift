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
    @Published var isoProbeState: ISOProbeState = .idle
    @Published var toolStatuses: [RufusToolStatus] = []
    @Published var logEntries: [LogEntry] = []

    // MARK: - Dependencies

    let driveManager = DriveManager()
    private let formatterService = USBFormatterService()
    private let imageAnalyzer = ImageAnalyzerService()
    private let toolManager = RufusToolManager()

    // MARK: - Private Properties

    private var cancellables = Set<AnyCancellable>()
    private var timer: Timer?
    
    // Log buffering
    private var logBufferHelper: LogBuffer?

    // MARK: - Computed Properties

    var canStart: Bool {
        !status.isInProgress && startBlockerMessage == nil
    }

    var startBlockerMessage: String? {
        if selectedDevice == nil {
            return "Select a USB drive."
        }

        if case .probing = isoProbeState {
            return isoProbeState.message
        }

        if options.bootSelection.needsSourceImage && options.isoFilePath == nil {
            return "Select a source image."
        }

        if let blocker = currentJobPlan.blocker {
            return blocker
        }

        return nil
    }

    var supportStatusMessage: String {
        if case .probing = isoProbeState {
            return isoProbeState.message
        }

        var blockers: [String] = []

        if selectedDevice == nil {
            blockers.append("Select a USB drive.")
        }

        if isoProbeState.isBlocking {
            blockers.append(isoProbeState.message)
        }

        if let blocker = currentJobPlan.blocker {
            blockers.append(blocker)
        }

        if !blockers.isEmpty {
            return blockers.joined(separator: " ")
        }

        return currentJobPlan.summary
    }

    var supportStatusIsBlocking: Bool {
        selectedDevice == nil || currentJobPlan.blocker != nil || isoProbeState.isBlocking
    }

    var shouldShowCurrentJobPlan: Bool {
        startBlockerMessage == nil && !currentJobPlan.destructiveSteps.isEmpty
    }

    var currentImageKind: ImageKind {
        isoProbeState.imageKind
    }

    var currentJobPlan: RufusJobPlan {
        RufusJobPlanner.makePlan(
            options: options,
            imageKind: currentImageKind,
            tools: toolStatuses
        )
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
        toolStatuses = toolManager.inventory()
        setupBindings()
        // Initialize log buffer
        logBufferHelper = LogBuffer { [weak self] entries in
            Task { @MainActor [weak self] in
                self?.logEntries.append(contentsOf: entries)
            }
        }
    }

    // MARK: - Public Methods

    func selectISO() {
        let panel = NSOpenPanel()
        let extensions = ["iso", "img", "dd", "raw", "gz", "xz", "zip", "7z", "bz2", "vhd", "vhdx", "ffu"]
        panel.allowedContentTypes = extensions.compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Select a bootable ISO, disk image, VHD, VHDX, FFU, or compressed image"
        panel.prompt = "Select"

        if panel.runModal() == .OK, let url = panel.url {
            options.isoFilePath = url
            options.bootSelection = recommendedBootSelection(for: url)
            options.ddMode = options.bootSelection == .rawDiskImage
            isoProbeState = .probing
            if !status.isInProgress {
                status = .ready
            }
            updateVolumeLabelFromISO(url)
            calculateChecksums(for: url)
            analyzeSelectedSourceImage(url)
        }
    }

    func startOperation() {
        guard canStart, let device = selectedDevice else {
            if let message = startBlockerMessage {
                status = .failed(message: message)
                addLog(message, level: .error)
            }
            return
        }

        status = .preparing
        startTimer()
        driveManager.isPaused = true
        toolStatuses = toolManager.inventory()
        addLog("Starting operation on \(device.displayName)", level: .info)
        for warning in currentJobPlan.warnings {
            addLog(warning, level: .warning)
        }
        addLog("Planned steps: \(currentJobPlan.destructiveSteps.joined(separator: " -> "))", level: .info)

        // Capture the buffer instance to use directly from background threads
        // This avoids hopping to the MainActor for every log message
        let logBuffer = self.logBufferHelper
        
        Task.detached(priority: .utility) { [options, formatterService, logBuffer] in
            do {
                try await formatterService.formatUSBDrive(
                    device: device,
                    options: options,
                    progressHandler: { newStatus in
                        Task { @MainActor in
                            self.status = newStatus
                        }
                    },
                    logHandler: { message, level in
                        // Write directly to buffer (thread-safe) without MainActor overhead
                        logBuffer?.add(LogEntry(message: message, level: level))
                    }
                )
                await MainActor.run {
                    self.stopTimer()
                    self.driveManager.isPaused = false
                    self.driveManager.refreshDevices()
                }
            } catch {
                await MainActor.run {
                    self.status = .failed(message: error.localizedDescription)
                    self.addLog("Error: \(error.localizedDescription)", level: .error)
                    self.stopTimer()
                    self.driveManager.isPaused = false
                    self.driveManager.refreshDevices()
                }
            }
        }
    }

    func cancelOperation() {
        formatterService.cancel()
        status = .ready
        stopTimer()
        elapsedTime = 0
        driveManager.isPaused = false
        driveManager.refreshDevices()
        addLog("Operation cancelled", level: .warning)
    }

    func addLog(_ message: String, level: LogLevel = .info) {
        logBufferHelper?.add(LogEntry(message: message, level: level))
    }

    func refreshDevices() {
        driveManager.refreshDevices()
        toolStatuses = toolManager.inventory()
    }

    // MARK: - Private Methods

    private func setupBindings() {
        driveManager.$availableDevices
            .receive(on: DispatchQueue.main)
            .sink { [weak self] devices in
                guard let self = self else { return }

                if self.selectedDevice == nil, let firstDevice = devices.first {
                    self.selectedDevice = firstDevice

                }

                if let selected = self.selectedDevice,
                   !devices.contains(where: { $0.id == selected.id }) {
                    self.selectedDevice = devices.first

                }
            }
            .store(in: &cancellables)
    }

    private func updateVolumeLabelFromISO(_ url: URL) {
        let filename = url.deletingPathExtension().lastPathComponent
        options.volumeLabel = String(filename.prefix(32))
    }

    private func analyzeSelectedSourceImage(_ url: URL) {
        Task {
            do {
                let imageKind = try await imageAnalyzer.analyze(url)

                guard options.isoFilePath == url else { return }
                isoProbeState = .analyzed(imageKind)
                addLog("Detected \(imageKind.displayName): \(url.lastPathComponent)", level: imageKind.isRunnableSource ? .success : .warning)
            } catch {
                guard options.isoFilePath == url else { return }

                isoProbeState = .failed("Image analysis failed: \(error.localizedDescription)")
                addLog(isoProbeState.message, level: .error)
            }
        }
    }

    private func recommendedBootSelection(for url: URL) -> BootSelection {
        switch url.pathExtension.lowercased() {
        case "img", "dd", "raw":
            return .rawDiskImage
        case "gz", "xz", "zip", "7z", "bz2":
            return .compressedImage
        case "vhd":
            return .vhd
        case "vhdx":
            return .vhdx
        case "ffu":
            return .ffu
        default:
            return .diskOrIso
        }
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
            Task { @MainActor [weak self] in
                self?.elapsedTime += 1
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
    
    // MARK: - Log Buffering Helper
}

// Helper class for log buffering
private class LogBuffer {
    private var buffer: [LogEntry] = []
    private let queue = DispatchQueue(label: "com.rufusx.logbuffer", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private let onFlush: ([LogEntry]) -> Void
    
    init(onFlush: @escaping ([LogEntry]) -> Void) {
        self.onFlush = onFlush
        startTimer()
    }
    
    deinit {
        timer?.cancel()
    }
    
    func add(_ entry: LogEntry) {
        queue.async { [weak self] in
            self?.buffer.append(entry)
        }
    }
    
    private func startTimer() {
        timer = DispatchSource.makeTimerSource(queue: queue)
        timer?.schedule(deadline: .now() + 0.25, repeating: 0.25)
        timer?.setEventHandler { [weak self] in
            self?.flush()
        }
        timer?.resume()
    }
    
    private func flush() {
        guard !buffer.isEmpty else { return }
        let entries = buffer
        buffer.removeAll()
        onFlush(entries)
    }
}
