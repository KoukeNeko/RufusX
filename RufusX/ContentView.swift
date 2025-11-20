//
//  ContentView.swift
//  RufusX
//
//  Created by 陳德生 on 2025/11/20.
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var viewModel: RufusViewModel

    var body: some View {
        MainView(viewModel: viewModel)
    }
}

#Preview {
    ContentView()
}
