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

    @State private var autoScroll: Bool = true

    var body: some View {
        VStack(spacing: 16) {
            GroupBox(label: Text("Log").font(.headline)) {
                ScrollViewReader { proxy in
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
                                        .textSelection(.enabled)
                                }
                                .id(entry.id)
                            }
                        }
                        .padding(4)
                    }
                    .onChange(of: logEntries.count) { _ in
                        if autoScroll, let lastId = logEntries.last?.id {
                            withAnimation {
                                proxy.scrollTo(lastId, anchor: .bottom)
                            }
                        }
                    }
                }
                .background(Color(NSColor.textBackgroundColor))
                .cornerRadius(4)
            }
            
            // Bottom Controls
            HStack {
                Toggle("Auto-scroll", isOn: $autoScroll)
                
                Spacer()
                
                Button("Clear") {
                    logEntries.removeAll()
                }
                
                Button("Save") {
                    saveLog()
                }
                
                Button("Close") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding()
        .frame(minWidth: 600, minHeight: 400)
        .onAppear {
            // Attempt to position window next to main window
            if let window = NSApplication.shared.windows.first(where: { $0.identifier?.rawValue == "log-window" }),
               let mainWindow = NSApplication.shared.windows.first(where: { $0.identifier?.rawValue != "log-window" && $0.isVisible }) {
                
                let mainFrame = mainWindow.frame
                // Calculate new origin to place it to the right of the main window
                // Align tops: y is bottom-left corner. Top is y + height.
                // We want new window top = main window top.
                // newY + newHeight = mainY + mainHeight
                // newY = mainY + mainHeight - newHeight
                // Since newHeight = mainHeight, newY = mainY (which is mainFrame.origin.y)
                
                let newOrigin = CGPoint(x: mainFrame.maxX + 10, y: mainFrame.origin.y)
                let newFrame = NSRect(origin: newOrigin, size: mainFrame.size)
                
                window.setFrame(newFrame, display: true)
            }
        }
    }

    private func colorForLevel(_ level: LogLevel) -> Color {
        switch level {
        case .info: return .primary
        case .warning: return .orange
        case .error: return .red
        case .success: return .green
        case .debug: return .gray
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
    case debug
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
