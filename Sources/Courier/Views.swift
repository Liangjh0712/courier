import AppKit
import CourierKit

/// The box's window: floats over every app and every space, and clicking into
/// it does not take the front from the app being written to.
final class Panel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// A plain card: the text background color (white, or dark in dark mode),
/// a hairline edge, round corners; tells when the mouse comes over it. Its
/// empty parts drag the window.
class CardView: NSView {
    var onHover: ((Bool) -> Void)?
    var radius: CGFloat = 22 {
        didSet { layer?.cornerRadius = radius }
    }
    private var area: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = radius
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 0.5
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("not coded") }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
    }

    override var mouseDownCanMoveWindow: Bool { true }

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

/// A small round icon button, tinted, for the box's row.
func iconButton(_ symbol: String, _ tip: String, _ target: AnyObject, _ action: Selector) -> NSButton {
    let b = NSButton()
    b.isBordered = false
    b.imagePosition = .imageOnly
    b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
    b.symbolConfiguration = .init(pointSize: 14, weight: .regular)
    b.contentTintColor = .secondaryLabelColor
    b.toolTip = tip
    b.target = target
    b.action = action
    b.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([b.widthAnchor.constraint(equalToConstant: 26), b.heightAnchor.constraint(equalToConstant: 28)])
    return b
}

/// The send button: an accent-colored circle with an arrow.
final class SendButton: NSButton {
    var onMenu: (() -> NSMenu)?
    private let spinner = NSProgressIndicator()
    private var arrow: NSImage?

    var spinning = false {
        didSet {
            guard spinning != oldValue else { return }
            image = spinning ? nil : arrow
            spinner.isHidden = !spinning
            if spinning { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        imagePosition = .imageOnly
        image = NSImage(systemSymbolName: "arrow.up", accessibilityDescription: "发送")
        symbolConfiguration = .init(pointSize: 13, weight: .bold)
        contentTintColor = .white
        wantsLayer = true
        layer?.cornerRadius = 14
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: 28), heightAnchor.constraint(equalToConstant: 28)])
        arrow = image
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.appearance = NSAppearance(named: .darkAqua)
        spinner.isHidden = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor), spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not coded") }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(isEnabled ? 1 : 0.35).cgColor
    }

    override var isEnabled: Bool {
        didSet { needsDisplay = true }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let m = onMenu?() else { return }
        NSMenu.popUpContextMenu(m, with: event, for: self)
    }
}

/// The text field: plain text, Enter sends, ⇧Enter is a new line, ⌥Enter fills
/// in without Return; ⌘V and ⌃V take a picture from the clipboard.
final class Editor: NSTextView {
    var onSubmit: ((_ insertOnly: Bool) -> Void)?
    var onImage: ((Data) -> Void)?
    var onRecall: ((_ step: Int) -> Void)?
    var onClear: (() -> Void)?
    var onEscape: (() -> Void)?
    /// Shown while empty.
    var placeholder = "" {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard textStorage?.length == 0, !placeholder.isEmpty, !hasMarkedText() else { return }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.placeholderTextColor]
        let x = textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 0)
        (placeholder as NSString).draw(at: NSPoint(x: x, y: textContainerOrigin.y), withAttributes: attrs)
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }

    // Esc puts the box away (an input method composing takes Esc first).
    override func cancelOperation(_ sender: Any?) { onEscape?() }

    /// Pictures dropped in go where they are dropped; text is taken as plain text.
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        let at = characterIndexForInsertion(at: convert(sender.draggingLocation, from: nil))
        var images: [Data] = []
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            images = urls.compactMap(pngOfImageFile)
        }
        if images.isEmpty, let png = pb.data(forType: .png) { images = [png] }
        if images.isEmpty, let tiff = pb.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) { images = [png] }
        if !images.isEmpty {
            setSelectedRange(NSRange(location: at, length: 0))
            for png in images { onImage?(png) }
            trace("drop: \(images.count) picture(s)")
            return true
        }
        if let s = pb.string(forType: .string) {
            setSelectedRange(NSRange(location: at, length: 0))
            insertText(s, replacementRange: selectedRange())
            return true
        }
        return false
    }

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
        case (.command, "w"): onEscape?()
        case (.command, "k"): onClear?()
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
