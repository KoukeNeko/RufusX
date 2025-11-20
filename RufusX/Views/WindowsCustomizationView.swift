//
//  WindowsCustomizationView.swift
//  RufusX
//
//  Created by 陳德生 on 2025/11/20.
//

import SwiftUI

struct WindowsCustomizationView: View {
    @Binding var options: WindowsCustomizationOptions
    var onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                Image(systemName: "questionmark.circle.fill")
                    .font(.largeTitle)
                    .foregroundColor(.blue)

                Text("Windows User Experience")
                    .font(.headline)

                Spacer()
            }

            Text("Customize Windows installation?")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Divider()

            // Options
            VStack(alignment: .leading, spacing: 12) {
                Toggle(
                    "Remove requirement for 4GB+ RAM, Secure Boot and TPM 2.0",
                    isOn: Binding(
                        get: {
                            options.removeRAMRequirement &&
                            options.removeSecureBootRequirement &&
                            options.removeTPMRequirement
                        },
                        set: { newValue in
                            options.removeRAMRequirement = newValue
                            options.removeSecureBootRequirement = newValue
                            options.removeTPMRequirement = newValue
                        }
                    )
                )

                Toggle(
                    "Remove requirement for an online Microsoft account",
                    isOn: $options.removeOnlineAccountRequirement
                )

                Toggle(
                    "Disable data collection (Skip privacy questions)",
                    isOn: $options.disableDataCollection
                )

                Toggle(
                    "Set a local account using the same name as this user's",
                    isOn: $options.setLocalAccountName
                )

                Toggle(
                    "Set regional options using the same values as this user's",
                    isOn: $options.useRegionalSettings
                )
            }

            Spacer()

            // Buttons
            HStack {
                Spacer()

                Button("OK") {
                    onConfirm()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)

                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding()
        .frame(width: 480, height: 320)
    }
}

#Preview {
    WindowsCustomizationView(
        options: .constant(WindowsCustomizationOptions()),
        onConfirm: {}
    )
}
