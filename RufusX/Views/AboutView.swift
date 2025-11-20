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
        VStack(spacing: 24) {
            // App Icon
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .shadow(radius: 4)

            // App Name and Version
            VStack(spacing: 4) {
                Text("RufusX")
                    .font(.system(size: 24, weight: .bold))

                Text("Version \(appVersion) (Build \(buildNumber))")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            // Description
            Text("A macOS utility for formatting and creating bootable USB flash drives.")
                .multilineTextAlignment(.center)
                .font(.body)
                .padding(.horizontal)
                .foregroundColor(.secondary)

            Divider()
                .padding(.horizontal, 40)

            // Credits
            VStack(spacing: 8) {
                Text("Inspired by Rufus for Windows")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Link("Original Rufus by Pete Batard", destination: URL(string: "https://rufus.ie")!)
                    .font(.caption)
                    .foregroundColor(.accentColor)
            }

            Spacer()

            // License & Source
            HStack(spacing: 16) {
                Link("License (GPL v3)", destination: URL(string: "https://www.gnu.org/licenses/gpl-3.0.html")!)
                    .font(.caption)
                
                Text("•")
                    .foregroundColor(.secondary)

                Link("Source Code", destination: URL(string: "https://github.com")!)
                    .font(.caption)
            }
            .padding(.bottom, 8)

            // Close Button
            Button("OK") {
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .keyboardShortcut(.cancelAction)
            .controlSize(.large)
        }
        .padding(30)
        .frame(width: 400, height: 480)
    }
}

#Preview {
    AboutView()
}
