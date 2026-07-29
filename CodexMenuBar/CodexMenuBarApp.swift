import SwiftUI
import AppKit

@main
struct CodexMenuBarApp: App {
    @StateObject private var model: AppModel
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        let model = AppModel()
        _model = StateObject(wrappedValue: model)
        AppDelegate.sharedModel = model
    }

    var body: some Scene {
        MenuBarExtra {
            UsagePopover()
                .environmentObject(model)
        } label: {
            Text(model.menuBarText)
                .font(.system(.body, design: .monospaced))
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var sharedModel: AppModel?

    func applicationWillTerminate(_ notification: Notification) {
        Self.sharedModel?.shutdownSynchronously()
    }
}
