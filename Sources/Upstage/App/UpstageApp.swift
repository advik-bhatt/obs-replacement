import AppKit
import SwiftUI
import UpstageCore

@main
struct UpstageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = AppState()

    var body: some SwiftUI.Scene {
        WindowGroup("Upstage") {
            MainView()
                .environmentObject(state)
                .frame(minWidth: 1100, minHeight: 700)
                .onAppear { appDelegate.state = state }
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Scene Collection") {
                Button("New…") { prompt("New scene collection", "Name") { state.newCollection(named: $0) } }
                Button("Duplicate") { state.duplicateCollection() }
                Button("Rename…") { prompt("Rename scene collection", state.collection.name) { state.renameCollection(to: $0) } }
                Divider()
                ForEach(state.collectionNames, id: \.self) { name in
                    Button(action: { state.switchCollection(named: name) }) {
                        if name == state.collection.name { Text("✓ \(name)") } else { Text(name) }
                    }
                }
            }
            CommandMenu("Profile") {
                Button("New…") { prompt("New profile (landscape 4K)", "Name") { state.newProfile(named: $0, portrait: false) } }
                Button("New Portrait 4K Profile…") { prompt("New profile (portrait 4K)", "Name") { state.newProfile(named: $0, portrait: true) } }
                Button("Duplicate") { state.duplicateProfile() }
                Button("Rename…") { prompt("Rename profile", state.profile.name) { state.renameProfile(to: $0) } }
                Divider()
                ForEach(state.profileNames, id: \.self) { name in
                    Button(action: { state.switchProfile(named: name) }) {
                        if name == state.profile.name { Text("✓ \(name)") } else { Text(name) }
                    }
                }
            }
            CommandMenu("Controls") {
                Button(state.isStreaming ? "Stop Streaming" : "Start Streaming") { state.toggleStreaming() }
                Button(state.isRecording ? "Stop Recording" : "Start Recording") { state.toggleRecording() }
                Button(state.recordingPaused ? "Resume Recording" : "Pause Recording") { state.pauseResumeRecording() }.disabled(!state.isRecording)
                Button(state.replayActive ? "Stop Replay Buffer" : "Start Replay Buffer") { state.toggleReplayBuffer() }
                Button("Save Replay") { state.saveReplay() }.disabled(!state.replayActive)
                Divider()
                Button(state.studioMode ? "Disable Studio Mode" : "Enable Studio Mode") { state.toggleStudioMode() }
                Button("Transition") { state.transition() }.disabled(!state.studioMode)
            }
            CommandGroup(replacing: .help) {
                Button("Upstage on GitHub") { NSWorkspace.shared.open(URL(string: "https://github.com/advik-bhatt/obs-replacement")!) }
                Button("Open Recordings Folder") {
                    let dir = (state.profile.recording.directory as NSString).expandingTildeInPath
                    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(URL(fileURLWithPath: dir))
                }
                Button("Open Settings Folder") { NSWorkspace.shared.open(state.store.root) }
            }
        }
        Settings {
            SettingsView().environmentObject(state)
        }
    }

    private func prompt(_ title: String, _ defaultValue: String, _ done: @escaping (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = defaultValue == "Name" ? "" : defaultValue
        field.placeholderString = "Name"
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            done(field.stringValue.trimmingCharacters(in: .whitespaces))
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var state: AppState?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if let s = state, s.isRecording || s.isStreaming {
            let alert = NSAlert()
            alert.messageText = s.isStreaming ? "You are live." : "Recording in progress."
            alert.informativeText = "Quit anyway? The current output will be stopped."
            alert.addButton(withTitle: "Quit")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() != .alertFirstButtonReturn { return .terminateCancel }
        }
        guard let state else { return .terminateNow }
        // Recording finalisation and the stream's goodbye are asynchronous; let
        // them finish, then resume termination.
        state.shutdown { NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}
