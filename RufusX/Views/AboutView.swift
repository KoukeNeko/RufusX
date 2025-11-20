//
//  AboutView.swift
//  RufusX
//
//  Created by 陳德生 on 2025/11/20.
//

import SwiftUI

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    private let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    private let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"

    var body: some View {
        VStack(spacing: 20) {
            // App Icon
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)

            // App Name and Version
            VStack(spacing: 4) {
                Text("RufusX")
                    .font(.title)
                    .fontWeight(.bold)

                Text("Version \(appVersion) (Build \(buildNumber))")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            Divider()

            // Description
            Text("A macOS utility for formatting and creating bootable USB flash drives.")
                .multilineTextAlignment(.center)
                .font(.body)
                .padding(.horizontal)

            // Credits
            VStack(spacing: 8) {
                Text("Inspired by Rufus for Windows")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Link("Original Rufus by Pete Batard", destination: URL(string: "https://rufus.ie")!)
                    .font(.caption)
            }

            Spacer()

            // License
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Text("License")
                        .font(.headline)

                    Text("This software is provided under the GPL v3 license.")
                        .font(.caption)

                    HStack {
                        Link("View License", destination: URL(string: "https://www.gnu.org/licenses/gpl-3.0.html")!)
                            .font(.caption)

                        Spacer()

                        Link("Source Code", destination: URL(string: "https://github.com")!)
                            .font(.caption)
                    }
                }
                .padding(8)
            }

            // Close Button
            Button("OK") {
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding()
        .frame(width: 350, height: 420)
    }
}

#Preview {
    AboutView()
}
