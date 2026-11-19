import AppKit
import CourierKit

/// The box's window: floats over every app and every space, and clicking into
/// it does not take the front from the app being written to.
final class Panel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// The box's background; tells when the mouse comes over it and leaves.
final class HoverView: NSVisualEffectView {
    var onHover: ((Bool) -> Void)?
    private var area: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(a)
        area = a
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}

/// The text field: plain text, Enter sends, ⇧Enter is a new line, ⌥Enter fills
/// in without Return; ⌘V and ⌃V take a picture from the clipboard.
final class Editor: NSTextView {
    var onSubmit: ((_ insertOnly: Bool) -> Void)?
    var onImage: ((Data) -> Void)?
    var onRecall: ((_ step: Int) -> Void)?

    override func paste(_ sender: Any?) {
        if let png = clipboardImage() {
            trace("paste: picture \(png.count / 1024)KB")
            onImage?(png)
            return
        }
        pasteAsPlainText(sender)
    }

    // The app is mostly not active (the panel does not activate it), so the
    // menu's key equivalents are not to be counted on: the editing ones are here.
    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        guard e.type == .keyDown, window?.firstResponder === self else { return super.performKeyEquivalent(with: e) }
        let mods = e.modifierFlags.intersection([.command, .shift, .option, .control])
        switch (mods, e.charactersIgnoringModifiers ?? "") {
        case (.command, "v"): paste(nil)
        case (.command, "c"): copy(nil)
        case (.command, "x"): cut(nil)
        case (.command, "a"): selectAll(nil)
        case (.command, "z"): undoManager?.undo()
        case ([.command, .shift], "z"), ([.command, .shift], "Z"): undoManager?.redo()
        case (.command, "w"): window?.performClose(nil)
        case (.command, "q"): NSApp.terminate(nil)
        default:
            if mods.contains(.command) && (e.keyCode == 126 || e.keyCode == 125) {
                onRecall?(e.keyCode == 126 ? -1 : +1)
                return true
            }
            return super.performKeyEquivalent(with: e)
        }
        return true
    }

    // While an input method is composing, Enter is the input method's.
    override func keyDown(with e: NSEvent) {
        let mods = e.modifierFlags.intersection([.command, .shift, .option, .control])
        if mods == .control && e.charactersIgnoringModifiers == "v" {
            paste(nil)
            return
        }
        if (e.keyCode == 36 || e.keyCode == 76) && !hasMarkedText() {
            if mods.contains(.shift) { insertNewlineIgnoringFieldEditor(nil); return }
            onSubmit?(mods.contains(.option))
            return
        }
        super.keyDown(with: e)
    }
}
