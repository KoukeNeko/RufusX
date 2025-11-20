//
//  DownloadISOView.swift
//  RufusX
//
//  Created by 陳德生 on 2025/11/20.
//

import SwiftUI

struct DownloadISOView: View {
    @Binding var options: ISODownloadOptions
    @Environment(\.dismiss) private var dismiss

    private let versions = ["Windows 11", "Windows 10", "Ubuntu", "Debian", "Fedora"]
    private let windowsReleases = [
        "24H2 (Build 26100 - 2024.10)",
        "23H2 v2 (Build 22631.2861 - 2024.01)",
        "22H2 v1 (Build 22621.525 - 2022.10)"
    ]
    private let editions = ["Windows 11 Home/Pro/Edu", "Windows 11 Pro", "Windows 11 Enterprise"]
    private let languages = [
        "English International",
        "English",
        "Chinese (Traditional)",
        "Chinese (Simplified)",
        "Japanese",
        "Korean"
    ]
    private let architectures = ["x64", "ARM64"]

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
                DownloadPickerRow(label: "Release", selection: $options.release, items: windowsReleases)
                DownloadPickerRow(label: "Edition", selection: $options.edition, items: editions)
                DownloadPickerRow(label: "Language", selection: $options.language, items: languages)
                DownloadPickerRow(label: "Architecture", selection: $options.architecture, items: architectures)
            }

            Toggle("Download using a browser", isOn: $options.useExternalBrowser)
                .padding(.top, 8)

            Spacer()

            HStack {
                Spacer()

                Button("Download") {
                    // Implement download logic
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)

                Button("Back") {
                    dismiss()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
        .frame(width: 420, height: 420)
        .onAppear {
            if options.version.isEmpty {
                options.version = versions[0]
                options.release = windowsReleases[0]
                options.edition = editions[0]
                options.language = languages[0]
                options.architecture = architectures[0]
            }
        }
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
