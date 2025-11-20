//
//  DownloadISOView.swift
//  RufusX
//
//  Created by 陳德生 on 2025/11/20.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct DownloadISOView: View {
    @Binding var options: ISODownloadOptions
    @Environment(\.dismiss) private var dismiss
    @StateObject private var downloadService = ISODownloadService()
    @State private var isDownloading = false
    @State private var downloadStatus = ""
    @State private var errorMessage = ""

    private let versions = [
        "Windows 11",
        "Windows 10",
        "Windows 8.1",
        "UEFI Shell"
    ]
    private let windowsReleases: [String: [String]] = [
        "Windows 11": [
            "24H2 (Build 26100 - 2024.10)",
            "23H2 v2 (Build 22631.2861 - 2024.01)",
            "22H2 v1 (Build 22621.525 - 2022.10)"
        ],
        "Windows 10": [
            "22H2 v1 (Build 19045.2965 - 2023.05)"
        ],
        "Windows 8.1": [
            "Update 3 (Build 9600)"
        ],
        "UEFI Shell": [
            "2.2 (24H2)"
        ]
    ]
    private let editions = [
        "Windows 11 Home/Pro/Edu",
        "Windows 11 Pro",
        "Windows 11 Enterprise"
    ]
    private let languages = [
        "English International",
        "English",
        "Chinese (Traditional)",
        "Chinese (Simplified)",
        "Japanese",
        "Korean",
        "French",
        "German",
        "Spanish"
    ]
    private let architectures = ["x64", "ARM64"]

    private var currentReleases: [String] {
        windowsReleases[options.version] ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.title)

                Text("Download ISO Image")
                    .font(.headline)

                Spacer()

                Button(action: { dismiss() }) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 12) {
                DownloadPickerRow(label: "Version", selection: $options.version, items: versions)
                    .onChange(of: options.version) { _, newValue in
                        if let firstRelease = windowsReleases[newValue]?.first {
                            options.release = firstRelease
                        }
                    }

                if options.version != "UEFI Shell" {
                    DownloadPickerRow(label: "Release", selection: $options.release, items: currentReleases)
                    DownloadPickerRow(label: "Edition", selection: $options.edition, items: editions)
                    DownloadPickerRow(label: "Language", selection: $options.language, items: languages)
                    DownloadPickerRow(label: "Architecture", selection: $options.architecture, items: architectures)
                }
            }

            Toggle("Download using a browser", isOn: $options.useExternalBrowser)
                .padding(.top, 8)

            if isDownloading {
                VStack(spacing: 8) {
                    ProgressView()
                        .progressViewStyle(.linear)
                    Text(downloadStatus)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundColor(.red)
            }

            Spacer()

            HStack {
                Spacer()

                Button("Download") {
                    startDownload()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(isDownloading)

                Button("Back") {
                    if isDownloading {
                        downloadService.cancel()
                    }
                    dismiss()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
        .frame(width: 420, height: 480)
        .onAppear {
            if options.version.isEmpty {
                options.version = versions[0]
                options.release = windowsReleases["Windows 11"]?.first ?? ""
                options.edition = editions[0]
                options.language = languages[0]
                options.architecture = architectures[0]
            }
        }
    }

    private func startDownload() {
        errorMessage = ""

        if options.useExternalBrowser {
            openInBrowser()
        } else {
            downloadDirectly()
        }
    }

    private func openInBrowser() {
        Task {
            do {
                isDownloading = true
                downloadStatus = "Getting download URL..."

                let url: URL
                if options.version == "UEFI Shell" {
                    url = downloadService.getUEFIShellDownloadURL()
                } else {
                    url = try await downloadService.getDownloadURL(
                        version: options.version,
                        release: options.release,
                        language: options.language,
                        architecture: options.architecture
                    )
                }

                NSWorkspace.shared.open(url)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            isDownloading = false
        }
    }

    private func downloadDirectly() {
        Task {
            do {
                isDownloading = true

                // Get download URL
                downloadStatus = "Getting download URL..."

                let url: URL
                if options.version == "UEFI Shell" {
                    url = downloadService.getUEFIShellDownloadURL()
                } else {
                    url = try await downloadService.getDownloadURL(
                        version: options.version,
                        release: options.release,
                        language: options.language,
                        architecture: options.architecture
                    )
                }

                // Show save panel
                let panel = NSSavePanel()
                panel.allowedContentTypes = [.init(filenameExtension: "iso")!]
                panel.nameFieldStringValue = generateFileName()

                guard panel.runModal() == .OK, let saveURL = panel.url else {
                    isDownloading = false
                    return
                }

                // Download
                downloadStatus = "Downloading ISO..."
                try await downloadService.downloadISO(
                    url: url,
                    to: saveURL,
                    progressHandler: { progress in
                        downloadStatus = "Downloading: \(Int(progress * 100))%"
                    }
                )

                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            isDownloading = false
        }
    }

    private func generateFileName() -> String {
        if options.version == "UEFI Shell" {
            return "UEFI-Shell.iso"
        }

        let version = options.version.replacingOccurrences(of: " ", with: "")
        let arch = options.architecture
        let lang = options.language.components(separatedBy: " ").first ?? "en"

        return "\(version)_\(arch)_\(lang).iso"
    }
}

struct DownloadPickerRow: View {
    let label: String
    @Binding var selection: String
    let items: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.subheadline)

            Picker("", selection: $selection) {
                ForEach(items, id: \.self) { item in
                    Text(item).tag(item)
                }
            }
            .labelsHidden()
        }
    }
}

#Preview {
    DownloadISOView(options: .constant(ISODownloadOptions()))
}
