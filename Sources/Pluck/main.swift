import AppKit
import AVFoundation
import OSLog
import Carbon.HIToolbox
import PluckCore
import ServiceManagement
import UserNotifications

// Dev aid: `Pluck --snapshot-shortcut-window out.png [light|dark] [recording]` renders the window
// offscreen, so its look can be checked without a Screen Recording grant.
if CommandLine.arguments.dropFirst().first == "--snapshot-shortcut-window" {
    let args = CommandLine.arguments
    _ = NSApplication.shared
    let controller = ShortcutWindowController()
    let window = controller.window!
    window.appearance = NSAppearance(named: args.contains("dark") ? .darkAqua : .aqua)
    if args.contains("recording") { controller.showRecording() }
    window.layoutIfNeeded()
    let view = window.contentView!.superview! // Theme frame: includes the traffic lights.
    let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
    view.cacheDisplay(in: view.bounds, to: rep)
    try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
    exit(0)
}

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
    /// A name from /System/Library/Sounds, or "None".
    static var sound: String {
        get { defaults.string(forKey: "sound") ?? "Pop" }
        set { defaults.set(newValue, forKey: "sound") }
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

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private lazy var hotKey = HotKey { [weak self] in self?.capture() }
    private let speech = AVSpeechSynthesizer()
    private var capturing = false
    // Serial: Vision fails (e5rt error) when two requests load its models concurrently.
    private let visionQueue = DispatchQueue(label: "com.chuyeow.pluck.vision", qos: .userInitiated)
    private var shortcutWindow: ShortcutWindowController?
    private static let sounds = ["None", "Pop", "Tink", "Glass", "Purr", "Bottle", "Morse", "Submarine"]
    private let captureItem = NSMenuItem(title: "Capture Text", action: #selector(captureFromMenu), keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem.button?.image = NSImage(systemSymbolName: "text.viewfinder", accessibilityDescription: "Pluck")
        buildMenu()
        if !applyShortcut(Settings.shortcut) {
            notify("Shortcut unavailable", "\(Settings.shortcut.display) is used by another app. Pick another in Change Shortcut…")
        }
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
        let soundMenu = NSMenu()
        for name in Self.sounds {
            let item = NSMenuItem(title: name, action: #selector(selectSound), keyEquivalent: "")
            item.target = self
            item.state = name == Settings.sound ? .on : .off
            soundMenu.addItem(item)
            if name == "None" { soundMenu.addItem(.separator()) }
        }
        let sound = NSMenuItem(title: "Sound", action: nil, keyEquivalent: "")
        sound.submenu = soundMenu
        menu.addItem(sound)
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

    /// Selecting a sound also plays it, so the menu doubles as a preview.
    @objc private func selectSound(_ item: NSMenuItem) {
        Settings.sound = item.title
        item.menu?.items.forEach { $0.state = $0.title == item.title ? .on : .off }
        NSSound(named: item.title)?.play()
    }

    @objc private func toggleLogin(_ item: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }
        } catch {
            notify("Launch at Login failed", error.localizedDescription)
        }
        item.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @discardableResult
    private func applyShortcut(_ shortcut: Shortcut) -> Bool {
        let ok = hotKey.register(shortcut)
        captureItem.title = ok ? "Capture Text (\(shortcut.display))" : "Capture Text"
        return ok
    }

    @objc private func showShortcutWindow() {
        if shortcutWindow == nil {
            let controller = ShortcutWindowController()
            controller.register = { [weak self] in self?.applyShortcut($0) ?? false }
            controller.unregister = { [weak self] in self?.hotKey.unregister() }
            shortcutWindow = controller
        }
        NSApp.activate()
        shortcutWindow?.showWindow(nil)
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
            NSSound(named: Settings.sound)?.play()
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
