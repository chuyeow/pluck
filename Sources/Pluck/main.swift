import AppKit
import AVFoundation
import OSLog
import Carbon.HIToolbox
import PluckCore
import ServiceManagement
import UserNotifications

// CLI mode: `Pluck <image>` prints the recognized text. Handy for scripts and for testing the pipeline.
if CommandLine.arguments.count > 1 {
    let url = URL(fileURLWithPath: CommandLine.arguments[1])
    guard let image = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        FileHandle.standardError.write("pluck: cannot read image \(url.path)\n".data(using: .utf8)!)
        exit(1)
    }
    print(try Recognizer.recognize(image).text(keepLineBreaks: Settings.keepLineBreaks))
    exit(0)
}

let log = Logger(subsystem: "com.chuyeow.pluck", category: "capture")

enum Settings {
    static let defaults = UserDefaults.standard

    static var shortcut: Shortcut {
        get { defaults.data(forKey: "shortcut").flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) } ?? .default }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "shortcut") }
    }
    static var keepLineBreaks: Bool {
        get { defaults.object(forKey: "keepLineBreaks") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "keepLineBreaks") }
    }
    static var appendToClipboard: Bool {
        get { defaults.bool(forKey: "appendToClipboard") }
        set { defaults.set(newValue, forKey: "appendToClipboard") }
    }
    static var speak: Bool {
        get { defaults.bool(forKey: "speak") }
        set { defaults.set(newValue, forKey: "speak") }
    }
}

/// Carbon global hotkey: needs no Accessibility permission, unlike an NSEvent global monitor.
final class HotKey {
    private var ref: EventHotKeyRef?
    private static var action: (() -> Void)?

    init(action: @escaping () -> Void) {
        HotKey.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { HotKey.action?() }
            return noErr
        }, 1, &spec, nil, nil)
    }

    @discardableResult
    func register(_ shortcut: Shortcut) -> Bool {
        unregister()
        let id = EventHotKeyID(signature: OSType(0x504C434B), id: 1) // 'PLCK'
        return RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
    }
}

/// Button that records the next key combo pressed while it is active.
final class ShortcutRecorder: NSButton {
    var onChange: ((Shortcut) -> Void)?
    var onRecordingChange: ((Bool) -> Void)?
    private var monitor: Any?
    var shortcut: Shortcut { didSet { title = shortcut.display } }

    init(shortcut: Shortcut) {
        self.shortcut = shortcut
        super.init(frame: .zero)
        bezelStyle = .rounded
        title = shortcut.display
        target = self
        action = #selector(toggle)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func toggle() { monitor == nil ? start() : stop() }

    private func start() {
        title = "Type shortcut…"
        onRecordingChange?(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == UInt16(kVK_Escape) { self.stop(); return nil }
            let flags = event.modifierFlags
            let candidate = Shortcut(
                keyCode: UInt32(event.keyCode),
                key: Self.label(for: event),
                command: flags.contains(.command), shift: flags.contains(.shift),
                option: flags.contains(.option), control: flags.contains(.control))
            guard candidate.isValid else { NSSound.beep(); return nil }
            self.shortcut = candidate
            self.onChange?(candidate)
            self.stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        title = shortcut.display
        onRecordingChange?(false)
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

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private lazy var hotKey = HotKey { [weak self] in self?.capture() }
    private let speech = AVSpeechSynthesizer()
    private var capturing = false
    // Serial: Vision fails (e5rt error) when two requests load its models concurrently.
    private let visionQueue = DispatchQueue(label: "com.chuyeow.pluck.vision", qos: .userInitiated)
    private var shortcutWindow: NSWindow?
    private let captureItem = NSMenuItem(title: "Capture Text", action: #selector(captureFromMenu), keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem.button?.image = NSImage(systemSymbolName: "text.viewfinder", accessibilityDescription: "Pluck")
        buildMenu()
        applyShortcut(Settings.shortcut)
        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
        // First use after install compiles Vision's models (~1–2 min). Pay it now, not on the first capture.
        visionQueue.async {
            let blank = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            _ = try? Recognizer.recognize(blank.makeImage()!)
            log.info("vision warmed up")
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
    }

    private func buildMenu() {
        let menu = NSMenu()
        menu.addItem(captureItem)
        menu.addItem(.separator())
        menu.addItem(toggle("Keep Line Breaks", \.keepLineBreaks, #selector(toggleLineBreaks)))
        menu.addItem(toggle("Append to Clipboard", \.appendToClipboard, #selector(toggleAppend)))
        menu.addItem(toggle("Speak Captured Text", \.speak, #selector(toggleSpeak)))
        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Change Shortcut…", action: #selector(showShortcutWindow), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Quit Pluck", action: #selector(NSApplication.terminate), keyEquivalent: "q"))
        menu.items.forEach { if $0.action != #selector(NSApplication.terminate) { $0.target = self } }
        statusItem.menu = menu
    }

    private func toggle(_ title: String, _ key: KeyPath<Settings.Type, Bool>, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.state = Settings.self[keyPath: key] ? .on : .off
        return item
    }

    @objc private func toggleLineBreaks(_ item: NSMenuItem) { Settings.keepLineBreaks.toggle(); item.state = Settings.keepLineBreaks ? .on : .off }
    @objc private func toggleAppend(_ item: NSMenuItem) { Settings.appendToClipboard.toggle(); item.state = Settings.appendToClipboard ? .on : .off }
    @objc private func toggleSpeak(_ item: NSMenuItem) { Settings.speak.toggle(); item.state = Settings.speak ? .on : .off }

    @objc private func toggleLogin(_ item: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }
        } catch {
            notify("Launch at Login failed", error.localizedDescription)
        }
        item.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    private func applyShortcut(_ shortcut: Shortcut) {
        if hotKey.register(shortcut) {
            captureItem.title = "Capture Text (\(shortcut.display))"
        } else {
            captureItem.title = "Capture Text"
            notify("Shortcut unavailable", "\(shortcut.display) is taken by another app. Pick another in Change Shortcut…")
        }
    }

    @objc private func showShortcutWindow() {
        if shortcutWindow == nil {
            let recorder = ShortcutRecorder(shortcut: Settings.shortcut)
            // Release the hotkey while recording so pressing the current combo is captured, not triggered.
            recorder.onRecordingChange = { [weak self] recording in
                if recording { self?.hotKey.unregister() } else { self?.applyShortcut(Settings.shortcut) }
            }
            recorder.onChange = { Settings.shortcut = $0 }
            let reset = NSButton(title: "Reset to ⇧⌘2", target: nil, action: nil)
            reset.bezelStyle = .rounded
            reset.target = self
            reset.action = #selector(resetShortcut)
            let label = NSTextField(labelWithString: "Capture Text shortcut:")
            let stack = NSStackView(views: [label, recorder, reset])
            stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
            let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Pluck Shortcut"
            window.contentView = stack
            window.isReleasedWhenClosed = false
            window.center()
            shortcutWindow = window
        }
        NSApp.activate()
        shortcutWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func resetShortcut() {
        Settings.shortcut = .default
        (shortcutWindow?.contentView as? NSStackView)?.views.compactMap { $0 as? ShortcutRecorder }.first?.shortcut = .default
        applyShortcut(.default)
    }

    @objc private func captureFromMenu() {
        // Let the menu close before the selection overlay appears.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.capture() }
    }

    func capture() {
        guard !capturing else { return }
        log.info("capture started, screen access: \(CGPreflightScreenCaptureAccess())")
        capturing = true
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("pluck-\(UUID().uuidString).png")
        visionQueue.async {
            defer { try? FileManager.default.removeItem(at: file) }
            // macOS's own selection UI: crosshair, drag across any display, Space for window mode, Esc cancels.
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-i", "-x", file.path]
            let result: Result<Recognition, Error>?
            do {
                try process.run()
                process.waitUntilExit()
                if let image = NSImage(contentsOf: file)?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    result = .success(try Recognizer.recognize(image))
                } else {
                    result = nil // Cancelled.
                }
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async {
                self.capturing = false
                self.finish(result)
            }
        }
    }

    private func finish(_ result: Result<Recognition, Error>?) {
        switch result {
        case nil:
            log.info("capture cancelled")
            return
        case .failure(let error):
            log.error("capture failed: \(error.localizedDescription, privacy: .public)")
            notify("Capture failed", error.localizedDescription)
        case .success(let recognition):
            let text = recognition.text(keepLineBreaks: Settings.keepLineBreaks)
            log.info("recognized \(recognition.lines.count) lines, \(recognition.barcodes.count) codes, \(text.count) chars")
            guard !text.isEmpty else {
                NSSound.beep()
                notify("No text found", "Try a larger selection or zoom in.")
                return
            }
            let pasteboard = NSPasteboard.general
            let combined = clipboardText(new: text, existing: pasteboard.string(forType: .string), append: Settings.appendToClipboard)
            pasteboard.clearContents()
            pasteboard.setString(combined, forType: .string)
            NSSound(named: "Pop")?.play()
            notify(recognition.barcodes.isEmpty ? "Text copied" : "Code copied", text)
            if Settings.speak {
                speech.stopSpeaking(at: .immediate)
                speech.speak(AVSpeechUtterance(string: text))
            }
        }
    }

    private func notify(_ title: String, _ body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = String(body.prefix(200))
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
