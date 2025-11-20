//
//  ChecksumView.swift
//  RufusX
//
//  Created by 陳德生 on 2025/11/20.
//

import SwiftUI

struct ChecksumView: View {
    let filename: String
    let checksum: ISOChecksum
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(filename)
                .font(.headline)

            VStack(alignment: .leading, spacing: 12) {
                ChecksumRow(label: "MD5:", value: checksum.md5)
                ChecksumRow(label: "SHA1:", value: checksum.sha1)
                ChecksumRow(label: "SHA256:", value: checksum.sha256)
                ChecksumRow(label: "SHA512:", value: checksum.sha512)
            }

            Spacer()

            HStack {
                Spacer()
                Button("OK") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 500, height: 280)
    }
}

struct ChecksumRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top) {
            Text(label)
                .frame(width: 60, alignment: .trailing)
                .fontWeight(.medium)

            Text(value)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
                .background(Color(NSColor.textBackgroundColor))
                .cornerRadius(4)
        }
    }
}

#Preview {
    ChecksumView(
        filename: "ubuntu-22.04-desktop-amd64.iso",
        checksum: ISOChecksum(
            md5: "d78b390d70e4a858b41d6bdfdd4b27a0",
            sha1: "a11a1965243f3af7aed0eec8645114cbe8248186",
            sha256: "d490a35d36030592839f24e468a5b818c919943967012037d6ab3d65d030ef7f",
            sha512: "Use <Alt>-<H> to enable."
        )
    )
}
