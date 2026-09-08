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
        didSet { overlay.setEnabled(isDimmingEnabled) }
    }

    var dimming: CGFloat {
        get { overlay.dimming }
        set { overlay.dimming = newValue }
    }

    private let tracker = FocusTracker()
    private let overlay = OverlayController()
    private var lastLoggedPID: pid_t?

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
        tracker.start()

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

    var focusSummary: String {
        guard isTrusted else { return "Accessibility not granted" }
        guard let focused else { return "No focused window" }
        let f = focused.frame
        return "\(focused.appName) — \(Int(f.width))×\(Int(f.height)) @ \(Int(f.minX)),\(Int(f.minY))"
    }
}

struct MenuContent: View {
    let model: AppModel

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
        Toggle("Dim Unfocused Windows", isOn: Bindable(model).isDimmingEnabled)
            .disabled(!model.isTrusted)

        Menu("Dim Amount") {
            ForEach([0.25, 0.4, 0.55, 0.7, 0.85], id: \.self) { level in
                Button("\(Int(level * 100))%") { model.dimming = level }
            }
        }

        Divider()
        Button("Quit Vignette") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}
