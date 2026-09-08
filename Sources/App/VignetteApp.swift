import SwiftUI

@main
@MainActor
struct VignetteApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            Image(systemName: "circle.dashed.inset.filled")
        }
        .menuBarExtraStyle(.menu)
    }
}

@MainActor
@Observable
final class AppModel {
    private(set) var isTrusted = false
    private(set) var focused: FocusedWindow?

    /// Off at launch on purpose: a full-screen scrim should never appear until
    /// the user asks for it.
    var isDimmingEnabled = false {
        didSet {
            overlay.setEnabled(isDimmingEnabled)
            // Only pay for mouse polling while the overlay is actually up.
            tracker.setDragWatchingEnabled(isDimmingEnabled)
        }
    }

    var dimming: CGFloat {
        get { overlay.dimming }
        set { overlay.dimming = newValue }
    }

    private(set) var hotkey: Hotkey?

    private let tracker = FocusTracker()
    private let overlay = OverlayController()
    private var lastLoggedPID: pid_t?
    private var recorderPanel: ShortcutRecorderPanel?

    init() {
        setvbuf(stdout, nil, _IONBF, 0)  // unbuffered, so logs show when piped
        isTrusted = Permissions.isAccessibilityTrusted
        print("[vignette] launched — accessibility trusted: \(isTrusted)")

        tracker.onChange = { [weak self] window in
            guard let self else { return }
            self.focused = window
            self.overlay.update(focused: window)

            // Only on app switches: move/resize now fires per frame during a drag.
            if window?.pid != self.lastLoggedPID {
                self.lastLoggedPID = window?.pid
                print("[vignette] focus: \(window?.appName ?? "none")")
            }
        }
        tracker.onMotionChange = { [weak self] isMoving in
            self?.overlay.setSuspended(isMoving)
        }
        tracker.start()

        hotkey = Preferences.hotkey
        HotkeyManager.shared.onTrigger = { [weak self] in
            guard let self else { return }
            self.isDimmingEnabled.toggle()
        }
        HotkeyManager.shared.update(to: hotkey)

        // The grant happens in System Settings, outside our process, so poll for it.
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            MainActor.assumeIsolated { [weak self] in
                guard let self else { return }
                let trusted = Permissions.isAccessibilityTrusted
                if trusted != self.isTrusted {
                    print("[vignette] accessibility trust changed: \(trusted)")
                }
                self.isTrusted = trusted
            }
        }
    }

    func recordShortcut() {
        // The current shortcut must not fire while it's being replaced.
        HotkeyManager.shared.unregister()

        let panel = ShortcutRecorderPanel(current: hotkey)
        recorderPanel = panel
        panel.present(
            onSave: { [weak self] captured in
                guard let self else { return }
                self.hotkey = captured
                Preferences.hotkey = captured
            },
            onClose: { [weak self] in
                guard let self else { return }
                self.recorderPanel = nil
                // Re-register whether saved or cancelled: on cancel this restores
                // the previous shortcut, which unregister() just tore down.
                HotkeyManager.shared.update(to: self.hotkey)
            }
        )
    }

    func clearShortcut() {
        hotkey = nil
        Preferences.hotkey = nil
        HotkeyManager.shared.unregister()
    }

    var focusSummary: String {
        guard isTrusted else { return "Accessibility not granted" }
        guard let focused else { return "No focused window" }
        let f = focused.frame
        return "\(focused.appName) — \(Int(f.width))×\(Int(f.height)) @ \(Int(f.minX)),\(Int(f.minY))"
    }
}

struct MenuContent: View {
    let model: AppModel

    /// SwiftUI's `.keyboardShortcut` only fires while the app is frontmost, which
    /// a menu bar app never is. The global shortcut goes through Carbon instead,
    /// so it's shown here as plain text.
    private var blurLabel: String {
        guard let hotkey = model.hotkey else { return "Blur Unfocused Windows" }
        return "Blur Unfocused Windows  (\(hotkey.display))"
    }

    var body: some View {
        Text(model.focusSummary)

        if !model.isTrusted {
            Divider()
            Button("Grant Accessibility Access…") {
                Permissions.requestAccessibility()
                Permissions.openAccessibilitySettings()
            }
        }

        Divider()
        Toggle(blurLabel, isOn: Bindable(model).isDimmingEnabled)
            .disabled(!model.isTrusted)

        Menu("Darken") {
            Button("Blur only") { model.dimming = 0 }
            ForEach([0.15, 0.25, 0.4, 0.6], id: \.self) { level in
                Button("\(Int(level * 100))%") { model.dimming = level }
            }
        }

        Divider()
        Button("Set Shortcut…") { model.recordShortcut() }
        Button("Clear Shortcut") { model.clearShortcut() }
            .disabled(model.hotkey == nil)

        Divider()
        Button("Quit Vignette") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}
