import SwiftUI
import AppKit

@main
struct PRReviewApp: App {
    @StateObject private var model = ReviewModel()
    var body: some Scene {
        WindowGroup("PR Review") { ContentView(model: model) }
            .defaultSize(width: 940, height: 660)
    }
}
