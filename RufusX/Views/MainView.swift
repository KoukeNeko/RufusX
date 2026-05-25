//
//  MainView.swift
//  RufusX
//
//  Created by 陳德生 on 2025/11/20.
//

import SwiftUI

struct MainView: View {
    @ObservedObject var viewModel: RufusViewModel
    @Environment(\.openWindow) var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            DrivePropertiesSection(viewModel: viewModel)
            FormatOptionsSection(viewModel: viewModel)
            StatusSection(viewModel: viewModel)
            BottomToolbar(viewModel: viewModel)
        }
        .padding()
        .fixedSize()
        .sheet(isPresented: $viewModel.showWindowsCustomization) {
            WindowsCustomizationView(
                options: $viewModel.options.windowsCustomization,
                onConfirm: {
                    viewModel.startOperation()
                }
            )
        }
        .sheet(isPresented: $viewModel.showChecksumDialog) {
            ChecksumView(
                filename: viewModel.options.isoFilePath?.lastPathComponent ?? "",
                checksum: viewModel.isoChecksum
            )
        }
        .sheet(isPresented: $viewModel.showDownloadDialog) {
            DownloadISOView(options: $viewModel.options.downloadOptions)
        }
        // LogView is now a separate window
        .sheet(isPresented: $viewModel.showAboutDialog) {
            AboutView()
        }
    }
}

// MARK: - Drive Properties Section

struct DrivePropertiesSection: View {
    @ObservedObject var viewModel: RufusViewModel

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                // Device Selection
                VStack(alignment: .leading, spacing: 4) {
                    Text("Device")
                        .font(.headline)

                    HStack {
                        Picker("", selection: $viewModel.selectedDevice) {
                            if viewModel.driveManager.availableDevices.isEmpty {
                                Text("No device found").tag(nil as USBDevice?)
                            }
                            ForEach(viewModel.driveManager.availableDevices) { device in
                                Text(device.displayName).tag(Optional(device))
                            }
                        }
                        .labelsHidden()

                        Button(action: {}) {
                            Image(systemName: "square.and.arrow.down")
                        }
                        .help("Save device settings")
                    }
                }

                // Boot Selection
                VStack(alignment: .leading, spacing: 4) {
                    Text("Boot selection")
                        .font(.headline)

                    HStack {
                        // Boot Selection Picker
                        Picker("", selection: $viewModel.options.bootSelection) {
                            ForEach(BootSelection.allCases) { selection in
                                let isSupported = RufusSupportMatrix.isSupported(selection)
                                Text(RufusSupportMatrix.optionTitle(selection.rawValue, isSupported: isSupported))
                                    .tag(selection)
                                    .disabled(!isSupported)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 180)

                        if viewModel.options.bootSelection == .diskOrIso {
                            // ISO Selection Button
                            Button(action: {
                                viewModel.selectISO()
                            }) {
                                HStack {
                                    Text(viewModel.options.isoFilePath?.lastPathComponent ?? "SELECT")
                                        .truncationMode(.middle)
                                    if viewModel.options.isoFilePath == nil {
                                        Image(systemName: "chevron.down")
                                    }
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            
                            if viewModel.options.isoFilePath != nil {
                                Button(action: {
                                    viewModel.showChecksumDialog = true
                                }) {
                                    Image(systemName: "checkmark.circle")
                                }
                                .help("Compute checksum")
                            }
                        } else {
                            Spacer()
                        }
                    }
                }

                // Persistent Partition Size (for Linux)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Persistent partition size")
                        .font(.subheadline)

                    HStack {
                        Slider(value: .constant(0), in: 0...32)
                            .disabled(true)

                        TextField("", value: .constant(0), format: .number)
                            .frame(width: 50)
                            .textFieldStyle(.roundedBorder)
                            .disabled(true)

                        Text("GB")

                        Text(RufusSupportMatrix.notSupportedYetLabel)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                // Partition Scheme & Target System
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Partition scheme")
                            .font(.subheadline)

                        Picker("", selection: $viewModel.options.partitionScheme) {
                            ForEach(PartitionScheme.allCases) { scheme in
                                let isSupported = RufusSupportMatrix.isSupported(scheme)
                                Text(RufusSupportMatrix.optionTitle(scheme.rawValue, isSupported: isSupported))
                                    .tag(scheme)
                                    .disabled(!isSupported)
                            }
                        }
                        .labelsHidden()
                    }

                    Spacer()

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Target system")
                            .font(.subheadline)

                        Picker("", selection: $viewModel.options.targetSystem) {
                            ForEach(TargetSystem.allCases) { system in
                                let isSupported = RufusSupportMatrix.isSupported(system)
                                Text(RufusSupportMatrix.optionTitle(system.rawValue, isSupported: isSupported))
                                    .tag(system)
                                    .disabled(!isSupported)
                            }
                        }
                        .labelsHidden()
                    }
                }

                // Advanced Drive Properties
                DisclosureGroup(
                    isExpanded: $viewModel.showAdvancedDriveProperties
                ) {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(
                            "List USB Hard Drives",
                            isOn: $viewModel.options.advancedDriveProperties.listUSBHardDrives
                        )
                        .disabled(true)

                        Toggle(
                            "Add fixes for old BIOSes (extra partition, align, etc.)",
                            isOn: $viewModel.options.advancedDriveProperties.addFixesForOldBIOS
                        )
                        .disabled(true)

                        HStack {
                            Toggle(
                                "Use Rufus MBR with BIOS ID",
                                isOn: $viewModel.options.advancedDriveProperties.useRufusMBRWithBIOSID
                            )
                            .disabled(true)

                            Picker("", selection: $viewModel.options.advancedDriveProperties.biosID) {
                                Text("0x80 (Default)").tag("0x80 (Default)")
                                Text("0x81").tag("0x81")
                                Text("0x82").tag("0x82")
                            }
                            .labelsHidden()
                            .frame(width: 120)
                            .disabled(true)
                        }

                        Text(RufusSupportMatrix.notSupportedYetLabel)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 8)
                } label: {
                    Text(viewModel.showAdvancedDriveProperties ? "Hide advanced drive properties" : "Show advanced drive properties")
                        .font(.subheadline)
                }
            }
            .padding(8)
        } label: {
            Text("Drive Properties")
                .font(.title2)
                .fontWeight(.bold)
        }
    }
}

// MARK: - Format Options Section

struct FormatOptionsSection: View {
    @ObservedObject var viewModel: RufusViewModel

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                // Volume Label
                VStack(alignment: .leading, spacing: 4) {
                    Text("Volume label")
                        .font(.subheadline)

                    TextField("", text: $viewModel.options.volumeLabel)
                        .textFieldStyle(.roundedBorder)
                }

                // File System & Cluster Size
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("File system")
                            .font(.subheadline)

                        Picker("", selection: $viewModel.options.fileSystem) {
                            ForEach(FileSystemType.allCases) { fs in
                                let isSupported = RufusSupportMatrix.isSupported(fs)
                                Text(RufusSupportMatrix.optionTitle(fs.displayName, isSupported: isSupported))
                                    .tag(fs)
                                    .disabled(!isSupported)
                            }
                        }
                        .labelsHidden()
                    }

                    Spacer()

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Cluster size")
                            .font(.subheadline)

                        Picker("", selection: $viewModel.options.clusterSize) {
                            ForEach(ClusterSize.allCases) { size in
                                Text(size.displayName).tag(size)
                            }
                        }
                        .labelsHidden()
                        .disabled(true)
                        .help(RufusSupportMatrix.notSupportedYetLabel)
                    }
                }

                // Advanced Format Options
                DisclosureGroup(
                    isExpanded: $viewModel.showAdvancedFormatOptions
                ) {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(
                            "Quick format",
                            isOn: $viewModel.options.advancedFormatOptions.quickFormat
                        )
                        .disabled(true)

                        Toggle(
                            "Create extended label and icon files",
                            isOn: $viewModel.options.advancedFormatOptions.createExtendedLabel
                        )
                        .disabled(true)

                        HStack {
                            Toggle(
                                "Check device for bad blocks",
                                isOn: $viewModel.options.advancedFormatOptions.checkDeviceForBadBlocks
                            )
                            .disabled(true)

                            Picker("", selection: $viewModel.options.advancedFormatOptions.badBlockPasses) {
                                Text("1 pass").tag(1)
                                Text("2 passes").tag(2)
                                Text("3 passes").tag(3)
                                Text("4 passes").tag(4)
                            }
                            .labelsHidden()
                            .frame(width: 80)
                            .disabled(true)
                        }

                        Text(RufusSupportMatrix.notSupportedYetLabel)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 8)
                } label: {
                    Text(viewModel.showAdvancedFormatOptions ? "Hide advanced format options" : "Show advanced format options")
                        .font(.subheadline)
                }
            }
            .padding(8)
        } label: {
            Text("Format Options")
                .font(.title2)
                .fontWeight(.bold)
        }
    }
}

// MARK: - Status Section

struct StatusSection: View {
    @ObservedObject var viewModel: RufusViewModel

    var body: some View {
        GroupBox {
            VStack(spacing: 8) {
                ProgressView(value: viewModel.status.progress)
                    .progressViewStyle(.linear)

                Text(viewModel.status.displayText)
                    .frame(maxWidth: .infinity)
                    .padding(8)
                    .background(statusBackgroundColor)
                    .foregroundColor(statusForegroundColor)
                    .cornerRadius(4)

                Text(viewModel.supportStatusMessage)
                    .font(.caption)
                    .foregroundColor(viewModel.supportStatusIsBlocking ? .orange : .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
            }
            .padding(8)
        } label: {
            Text("Status")
                .font(.title2)
                .fontWeight(.bold)
        }
    }

    private var statusBackgroundColor: Color {
        switch viewModel.status {
        case .completed:
            return .green
        case .failed:
            return .red
        default:
            return Color(NSColor.controlBackgroundColor)
        }
    }

    private var statusForegroundColor: Color {
        switch viewModel.status {
        case .completed, .failed:
            return .white
        default:
            return .primary
        }
    }
}

// MARK: - Bottom Toolbar

struct BottomToolbar: View {
    @ObservedObject var viewModel: RufusViewModel
    @Environment(\.openWindow) var openWindow

    var body: some View {
        HStack {
            // Left side icons
            HStack(spacing: 12) {
                Button(action: {}) {
                    Image(systemName: "globe")
                }
                .buttonStyle(.plain)
                .help("Language")

                Button(action: {
                    viewModel.showAboutDialog = true
                }) {
                    Image(systemName: "info.circle")
                }
                .buttonStyle(.plain)
                .help("About")

                Button(action: {}) {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.plain)
                .help("Settings")

                Button(action: {
                    // Open Log Window
                    openWindow(id: "log-window")
                }) {
                    Image(systemName: "keyboard")
                }
                .buttonStyle(.plain)
                .help("Show log")
            }

            Spacer()

            // Right side buttons
            HStack(spacing: 12) {
                if viewModel.status.isInProgress {
                    Button("CANCEL") {
                        viewModel.cancelOperation()
                    }
                    .keyboardShortcut(.cancelAction)
                } else {
                    Button("START") {
                        viewModel.startOperation()
                    }
                    .disabled(!viewModel.canStart)
                    .help(viewModel.startBlockerMessage ?? RufusSupportMatrix.supportedPathDescription)
                    .keyboardShortcut(.defaultAction)

                    Button("CLOSE") {
                        NSApplication.shared.terminate(nil)
                    }
                }
            }

            // Elapsed time
            Text(viewModel.formattedElapsedTime)
                .font(.system(.body, design: .monospaced))
                .frame(width: 70, alignment: .trailing)
        }

        // Device count
        HStack {
            Text("\(viewModel.deviceCount) device found")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
        }
    }
}

#Preview {
    MainView(viewModel: RufusViewModel())
}
