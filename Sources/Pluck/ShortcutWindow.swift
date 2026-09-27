import AppKit
import Carbon.HIToolbox
import PluckCore

/// Shows the capture shortcut as keycaps and records a new one.
final class ShortcutWindowController: NSWindowController, NSWindowDelegate {
    /// Registers the hotkey; false when another app already holds it.
    var register: (Shortcut) -> Bool = { _ in true }
    /// Releases the hotkey so pressing the current combo while recording is captured, not triggered.
    var unregister: () -> Void = {}

    private let keycaps = NSStackView()
    private let hint = NSTextField(labelWithString: "")
    private let recordButton = NSButton(title: "Record New Shortcut", target: nil, action: nil)
    private let resetButton = NSButton(title: "Reset to Default", target: nil, action: nil)
    private var monitor: Any?

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 0),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Pluck Shortcut"
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        build()
        showShortcut(Settings.shortcut)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        let icon = NSImageView(image: NSImage(systemSymbolName: "keyboard", accessibilityDescription: nil)!)
        icon.symbolConfiguration = .init(pointSize: 30, weight: .regular)
        icon.contentTintColor = .controlAccentColor

        let title = NSTextField(labelWithString: "Capture Shortcut")
        title.font = .systemFont(ofSize: 18, weight: .semibold)

        let subtitle = NSTextField(wrappingLabelWithString: "Press it anywhere, then drag over text to copy it.")
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor
        subtitle.alignment = .center
        subtitle.preferredMaxLayoutWidth = 360

        keycaps.orientation = .horizontal
        keycaps.spacing = 8
        let keycapArea = NSView()
        keycapArea.translatesAutoresizingMaskIntoConstraints = false
        keycapArea.addSubview(keycaps)
        keycaps.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            keycapArea.heightAnchor.constraint(equalToConstant: 56), // Fixed so the window doesn't jump while recording.
            keycapArea.widthAnchor.constraint(equalToConstant: 360),
            keycaps.centerXAnchor.constraint(equalTo: keycapArea.centerXAnchor),
            keycaps.centerYAnchor.constraint(equalTo: keycapArea.centerYAnchor),
        ])

        hint.font = .systemFont(ofSize: 12)
        hint.alignment = .center

        resetButton.target = self
        resetButton.action = #selector(reset)
        recordButton.target = self
        recordButton.action = #selector(toggleRecording)
        recordButton.keyEquivalent = "\r"
        for button in [resetButton, recordButton] {
            button.bezelStyle = .push
            button.controlSize = .large
        }
        let buttons = NSStackView(views: [resetButton, recordButton])
        buttons.spacing = 12

        let stack = NSStackView(views: [icon, title, subtitle, keycapArea, hint, buttons])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.setCustomSpacing(14, after: icon)
        stack.setCustomSpacing(28, after: subtitle)
        stack.setCustomSpacing(10, after: keycapArea)
        stack.setCustomSpacing(30, after: hint)
        stack.edgeInsets = NSEdgeInsets(top: 44, left: 40, bottom: 32, right: 40)
        window?.contentView = stack
    }

    // MARK: States

    private func showShortcut(_ shortcut: Shortcut, error: String? = nil) {
        keycaps.setViews(shortcut.keys.map { Self.keycap($0) }, in: .center)
        setHint(error ?? "Must include ⌘, ⌥ or ⌃.", isError: error != nil)
        recordButton.title = "Record New Shortcut"
        resetButton.isEnabled = shortcut != .default
    }

    func showRecording() {
        keycaps.setViews([Self.keycap("Press new shortcut…", recording: true)], in: .center)
        setHint("Esc to cancel", isError: false)
        recordButton.title = "Cancel"
        resetButton.isEnabled = false
    }

    private func setHint(_ text: String, isError: Bool) {
        hint.stringValue = text
        hint.textColor = isError ? .systemRed : .tertiaryLabelColor
    }

    /// Raised in both appearances: lighter than the window background, never darker.
    private static let keycapFill = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.1) : .white
    }

    private static func keycap(_ text: String, recording: Bool = false) -> NSView {
        let label = NSTextField(labelWithString: text)
        let base = NSFont.systemFont(ofSize: recording ? 15 : 22, weight: .medium)
        label.font = NSFont(descriptor: base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor, size: base.pointSize)
        label.textColor = recording ? .controlAccentColor : .labelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        let box = NSBox()
        box.boxType = .custom
        box.titlePosition = .noTitle
        box.cornerRadius = 10
        box.borderWidth = recording ? 1.5 : 1
        box.borderColor = recording ? .controlAccentColor : .separatorColor
        box.fillColor = recording ? NSColor.controlAccentColor.withAlphaComponent(0.08) : keycapFill
        box.contentViewMargins = .zero
        box.translatesAutoresizingMaskIntoConstraints = false
        box.contentView!.addSubview(label)
        if !recording {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
            shadow.shadowOffset = NSSize(width: 0, height: -1)
            shadow.shadowBlurRadius = 1.5
            box.shadow = shadow
        }
        NSLayoutConstraint.activate([
            box.heightAnchor.constraint(equalToConstant: 52),
            box.widthAnchor.constraint(greaterThanOrEqualToConstant: 52),
            label.centerYAnchor.constraint(equalTo: box.contentView!.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: box.contentView!.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: box.contentView!.trailingAnchor, constant: -14),
        ])
        return box
    }

    // MARK: Actions

    @objc private func toggleRecording() { monitor == nil ? startRecording() : stopRecording() }

    private func startRecording() {
        unregister()
        showRecording()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == UInt16(kVK_Escape) { self.stopRecording(); return nil }
            let flags = event.modifierFlags
            let candidate = Shortcut(
                keyCode: UInt32(event.keyCode), key: Self.label(for: event),
                command: flags.contains(.command), shift: flags.contains(.shift),
                option: flags.contains(.option), control: flags.contains(.control))
            guard candidate.isValid else {
                NSSound.beep()
                self.setHint("Include ⌘, ⌥ or ⌃ · Esc to cancel", isError: true)
                return nil
            }
            self.endMonitor()
            if self.register(candidate) {
                Settings.shortcut = candidate
                self.showShortcut(candidate)
            } else {
                _ = self.register(Settings.shortcut)
                self.showShortcut(Settings.shortcut, error: "\(candidate.display) is used by another app. Try another.")
            }
            return nil
        }
    }

    private func stopRecording() {
        endMonitor()
        _ = register(Settings.shortcut)
        showShortcut(Settings.shortcut)
    }

    private func endMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    @objc private func reset() {
        if register(.default) {
            Settings.shortcut = .default
            showShortcut(.default)
        } else {
            showShortcut(Settings.shortcut, error: "⇧⌘2 is used by another app.")
        }
    }

    func windowWillClose(_ notification: Notification) {
        if monitor != nil { stopRecording() }
    }

    private static let specialKeys: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    private static func label(for event: NSEvent) -> String {
        specialKeys[Int(event.keyCode)] ?? (event.charactersIgnoringModifiers ?? "?").uppercased()
    }
}
