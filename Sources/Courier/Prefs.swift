import AppKit

/// Per-app keys, by bundle id: what pastes a picture (⌃V in terminals, ⌘V
/// elsewhere, unless set) and what sends (Return, unless set to ⌘Return).
enum Prefs {
    private static let d = UserDefaults.standard

    static func imageFlags(_ app: NSRunningApplication) -> CGEventFlags {
        switch d.string(forKey: "imageKey." + (app.bundleIdentifier ?? "-")) {
        case "ctrl": return .maskControl
        case "cmd": return .maskCommand
        default: return isTerminal(app) ? .maskControl : .maskCommand
        }
    }

    static func setImageFlags(_ app: NSRunningApplication, _ f: CGEventFlags) {
        d.set(f == .maskControl ? "ctrl" : "cmd", forKey: "imageKey." + (app.bundleIdentifier ?? "-"))
    }

    static func sendFlags(_ app: NSRunningApplication) -> CGEventFlags {
        d.string(forKey: "sendKey." + (app.bundleIdentifier ?? "-")) == "cmd" ? .maskCommand : []
    }

    static func setSendFlags(_ app: NSRunningApplication, _ f: CGEventFlags) {
        d.set(f == .maskCommand ? "cmd" : "return", forKey: "sendKey." + (app.bundleIdentifier ?? "-"))
    }

    static var bubble: Bool {
        get { d.object(forKey: "bubble") as? Bool ?? true }
        set { d.set(newValue, forKey: "bubble") }
    }
}
