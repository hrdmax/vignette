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

    private let tracker = FocusTracker()

    init() {
        setvbuf(stdout, nil, _IONBF, 0)  // unbuffered, so logs show when piped
        isTrusted = Permissions.isAccessibilityTrusted
        print("[vignette] launched — accessibility trusted: \(isTrusted)")

        tracker.onChange = { [weak self] window in
            self?.focused = window
            if let window { print("[vignette] focus: \(window.appName) \(window.frame)") }
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
        Button("Quit Vignette") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}
