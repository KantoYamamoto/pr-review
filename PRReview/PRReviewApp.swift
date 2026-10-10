import SwiftUI
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: ReviewModel?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        Task {
            // Finish Git transactions; cancel and reap builds before exiting.
            let ready = await model.shutdown()
            sender.reply(toApplicationShouldTerminate: ready)
        }
        return .terminateLater
    }
}

@main
struct PRReviewApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = ReviewModel()
    var body: some Scene {
        Window("PR Review", id: "reviews") {
            ContentView(model: model).onAppear { delegate.model = model }
        }
        .defaultSize(width: 1080, height: 760)
    }
}
