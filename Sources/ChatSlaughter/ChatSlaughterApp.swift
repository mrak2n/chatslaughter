import SwiftUI
import AppKit
import ChatSlaughterCore

@MainActor
final class AppState {
    static let shared = AppState()
    let client = TelegramClient()
    lazy var executor = SweepExecutor(gateway: client)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            let state = AppState.shared
            state.executor.stop()
            while state.executor.running { try? await Task.sleep(nanoseconds: 100_000_000) }
            await state.client.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct ChatSlaughterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        WindowGroup {
            ContentView(client: AppState.shared.client, executor: AppState.shared.executor)
                .frame(minWidth: 820, minHeight: 520)
        }
        .defaultSize(width: 1040, height: 680)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .help) {
                Link("Telegram API", destination: URL(string: "https://core.telegram.org/tdlib")!)
            }
        }
    }
}
