//
//  HurayFoodApp.swift
//  HurayFood
//
//  Created by Jae Ho Lee on 2/4/25.
//

import SwiftUI
import SwiftData

@main
struct HurayFoodApp: App {
    @StateObject private var viewModel = ImageProcessingViewModel()  // ✅ ViewModel을 앱 전역에서 유지

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Item.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)  // ✅ ViewModel을 환경 객체로 전달
        }
        .modelContainer(sharedModelContainer)
    }
}
