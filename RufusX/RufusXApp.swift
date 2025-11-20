//
//  RufusXApp.swift
//  RufusX
//
//  Created by 陳德生 on 2025/11/20.
//

import SwiftUI

@main
struct RufusXApp: App {
    @StateObject private var viewModel = RufusViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
        }
        .windowResizability(.contentSize)
        
        Window("Log", id: "log-window") {
            LogView(logEntries: $viewModel.logEntries)
                .environmentObject(viewModel)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.trailing) // Try to position it, though this is limited
    }
}
