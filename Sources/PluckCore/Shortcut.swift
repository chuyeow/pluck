/// A global hotkey. `keyCode` is the hardware virtual key code; `key` is its label for display.
public struct Shortcut: Codable, Equatable, Sendable {
    public var keyCode: UInt32
    public var key: String
    public var command: Bool
    public var shift: Bool
    public var option: Bool
    public var control: Bool

    public init(keyCode: UInt32, key: String, command: Bool, shift: Bool, option: Bool, control: Bool) {
        self.keyCode = keyCode
        self.key = key
        self.command = command
        self.shift = shift
        self.option = option
        self.control = control
    }

    /// ⇧⌘2, same as TextSniper. kVK_ANSI_2 = 19.
    public static let `default` = Shortcut(keyCode: 19, key: "2", command: true, shift: true, option: false, control: false)

    /// Shift alone would swallow ordinary typing.
    public var isValid: Bool { command || option || control }

    /// Apple's canonical order: ⌃⌥⇧⌘.
    public var display: String {
        (control ? "⌃" : "") + (option ? "⌥" : "") + (shift ? "⇧" : "") + (command ? "⌘" : "") + key
    }

    /// Carbon's cmdKey, shiftKey, optionKey, controlKey.
    public var carbonModifiers: UInt32 {
        (command ? 256 : 0) | (shift ? 512 : 0) | (option ? 2048 : 0) | (control ? 4096 : 0)
    }
}
