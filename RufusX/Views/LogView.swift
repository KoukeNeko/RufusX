//
//  LogView.swift
//  RufusX
//
//  Created by 陳德生 on 2025/11/20.
//

import SwiftUI
import UniformTypeIdentifiers

struct LogView: View {
    @Binding var logEntries: [LogEntry]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Log")
                .font(.headline)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(logEntries) { entry in
                        HStack(alignment: .top, spacing: 8) {
                            Text(entry.timestamp)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.secondary)

                            Text(entry.message)
                                .font(.system(.body, design: .monospaced))
                                .foregroundColor(colorForLevel(entry.level))
                        }
                    }
                }
                .padding(8)
            }
            .background(Color(NSColor.textBackgroundColor))
            .cornerRadius(4)

            HStack {
                Button("Clear") {
                    logEntries.removeAll()
                }

                Button("Save") {
                    saveLog()
                }

                Spacer()

                Button("Close") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding()
        .frame(width: 600, height: 400)
    }

    private func colorForLevel(_ level: LogLevel) -> Color {
        switch level {
        case .info: return .primary
        case .warning: return .orange
        case .error: return .red
        case .success: return .green
        }
    }

    private func saveLog() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "rufusx_log.txt"

        if panel.runModal() == .OK, let url = panel.url {
            let content = logEntries.map { "[\($0.timestamp)] \($0.message)" }.joined(separator: "\n")
            try? content.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - Log Models

enum LogLevel {
    case info
    case warning
    case error
    case success
}

struct LogEntry: Identifiable {
    let id = UUID()
    let timestamp: String
    let message: String
    let level: LogLevel

    init(message: String, level: LogLevel = .info) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        self.timestamp = formatter.string(from: Date())
        self.message = message
        self.level = level
    }
}

#Preview {
    LogView(logEntries: .constant([
        LogEntry(message: "Rufus version: 4.12.2296", level: .info),
        LogEntry(message: "Windows version: Windows 11 64-bit", level: .info),
        LogEntry(message: "Found 1 device", level: .success),
        LogEntry(message: "Warning: Drive may contain data", level: .warning)
    ]))
}
