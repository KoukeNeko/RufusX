//
//  ShellService.swift
//  RufusX
//
//  Created by Antigravity on 2025/11/20.
//

import Foundation

final class ShellService {
    
    static let shared = ShellService()
    
    private init() {}
    
    // MARK: - Public Methods
    
    /// Runs a shell command with standard privileges
    func runCommand(
        _ command: String,
        arguments: [String],
        input: String? = nil
    ) async throws -> (output: String, error: String, exitCode: Int32) {
        
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: command)
                process.arguments = arguments
                
                let outputPipe = Pipe()
                let errorPipe = Pipe()
                let inputPipe = Pipe()
                
                process.standardOutput = outputPipe
                process.standardError = errorPipe
                process.standardInput = inputPipe
                
                do {
                    try process.run()
                    
                    if let input = input, let inputData = input.data(using: .utf8) {
                        do {
                            if #available(macOS 10.15.4, *) {
                                try inputPipe.fileHandleForWriting.write(contentsOf: inputData)
                            } else {
                                inputPipe.fileHandleForWriting.write(inputData)
                            }
                            try inputPipe.fileHandleForWriting.close()
                        } catch {
                            // Ignore broken pipe errors if process exited early
                        }
                    } else {
                        try? inputPipe.fileHandleForWriting.close()
                    }
                    
                    process.waitUntilExit()
                    
                    let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    
                    let output = String(data: outputData, encoding: .utf8) ?? ""
                    let error = String(data: errorData, encoding: .utf8) ?? ""
                    
                    continuation.resume(returning: (output, error, process.terminationStatus))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    /// Runs a shell command with administrator privileges using osascript
    func runCommandWithAdminPrivileges(
        _ command: String,
        arguments: [String],
        input: String? = nil
    ) async throws -> (output: String, error: String, exitCode: Int32) {
        
        var shellCommand = command
        if !arguments.isEmpty {
            shellCommand += " " + arguments.joined(separator: " ")
        }
        
        if let input = input {
            // Escape single quotes for the shell
            let escapedInput = input.replacingOccurrences(of: "'", with: "'\\''")
            // Use printf to pipe input
            shellCommand = "printf '\(escapedInput)' | \(shellCommand)"
        }
        
        // Escape for AppleScript string: backslash -> \\, double quote -> \"
        let escapedForAppleScript = shellCommand
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            
        let osascriptArgs = [
            "-e",
            "do shell script \"\(escapedForAppleScript)\" with administrator privileges"
        ]
        
        return try await runCommand("/usr/bin/osascript", arguments: osascriptArgs)
    }
}
