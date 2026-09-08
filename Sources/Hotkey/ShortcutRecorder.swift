import AppKit

/// Captures one key combination. AppKit rather than SwiftUI: this needs raw
/// `keyDown` before the responder chain interprets it, which SwiftUI won't give.
@MainActor
final class ShortcutRecorderView: NSView {
    var onCapture: ((Hotkey) -> Void)?
    var onCancel: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {  // Escape
            onCancel?()
            return
        }
        if let hotkey = Hotkey.from(event: event) {
            onCapture?(hotkey)
        }
        // Swallowed either way: no beep, and no stray character typed elsewhere.
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Combinations like ⌘Q would otherwise be eaten by the menu before we
        // ever see them, making them impossible to assign.
        keyDown(with: event)
        return true
    }
}

@MainActor
final class ShortcutRecorderPanel: NSPanel {
    private let promptLabel = NSTextField(labelWithString: "Press a key combination")
    private let captureLabel = NSTextField(labelWithString: "…")
    private let saveButton = NSButton()
    private let recorder = ShortcutRecorderView()

    private var pending: Hotkey?
    private var onSave: ((Hotkey) -> Void)?
    private var onClose: (() -> Void)?

    init(current: Hotkey?) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 160),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )

        title = "Set Shortcut"
        isFloatingPanel = true
        hidesOnDeactivate = false

        promptLabel.alignment = .center
        promptLabel.font = .systemFont(ofSize: 12)
        promptLabel.textColor = .secondaryLabelColor

        captureLabel.stringValue = current?.display ?? "…"
        captureLabel.alignment = .center
        captureLabel.font = .monospacedSystemFont(ofSize: 26, weight: .medium)

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"

        saveButton.title = "Save"
        saveButton.bezelStyle = .rounded
        saveButton.target = self
        saveButton.action = #selector(save)
        saveButton.isEnabled = false

        let buttons = NSStackView(views: [cancelButton, saveButton])
        buttons.spacing = 12

        let stack = NSStackView(views: [promptLabel, captureLabel, buttons])
        stack.orientation = .vertical
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false

        recorder.onCapture = { [weak self] hotkey in
            guard let self else { return }
            self.pending = hotkey
            self.captureLabel.stringValue = hotkey.display
            self.saveButton.isEnabled = true
        }
        recorder.onCancel = { [weak self] in self?.cancel() }

        recorder.addSubview(stack)
        contentView = recorder

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: recorder.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: recorder.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: recorder.centerYAnchor),
        ])
    }

    override var canBecomeKey: Bool { true }

    func present(onSave: @escaping (Hotkey) -> Void, onClose: @escaping () -> Void) {
        self.onSave = onSave
        self.onClose = onClose

        // A menu bar app is .accessory, and an accessory app cannot take key focus
        // for a window. Switch to .regular for as long as the panel is up.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        center()
        makeKeyAndOrderFront(nil)
        makeFirstResponder(recorder)
    }

    @objc private func save() {
        if let pending { onSave?(pending) }
        dismiss()
    }

    @objc private func cancel() {
        dismiss()
    }

    override func close() {
        dismiss()
    }

    private func dismiss() {
        NSApp.setActivationPolicy(.accessory)
        orderOut(nil)
        onClose?()
    }
}
