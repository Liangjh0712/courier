import AppKit
import CourierKit

/// When the box is put away, a small round button stays on the desktop: faint
/// until pointed at, a dot when a draft is waiting; a click brings the box
/// back. It can be dragged anywhere and settles against the nearer side edge.
final class Bubble: NSObject {
    static let size: CGFloat = 44
    static let idleAlpha: CGFloat = 0.3

    var onClick: (() -> Void)?
    var hasDraft = false {
        didSet { dot?.isHidden = !hasDraft }
    }
    private var panel: NSPanel!
    private var dot: NSView!

    func build() {
        let s = Bubble.size
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: s, height: s),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.alphaValue = Bubble.idleAlpha

        let view = BubbleView(frame: NSRect(x: 0, y: 0, width: s, height: s))
        view.bubble = self
        panel.contentView = view

        let icon = NSImageView(frame: NSRect(x: 11, y: 11, width: 22, height: 22))
        icon.image = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: "Courier")
        icon.symbolConfiguration = .init(pointSize: 17, weight: .medium)
        icon.contentTintColor = .labelColor
        view.addSubview(icon)

        dot = NSView(frame: NSRect(x: s - 15, y: s - 15, width: 9, height: 9))
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.layer?.cornerRadius = 4.5
        dot.isHidden = !hasDraft
        view.addSubview(dot)

        if let o = UserDefaults.standard.string(forKey: "bubbleOrigin") {
            panel.setFrameOrigin(NSPointFromString(o))
        } else if let v = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: v.maxX - s - 8, y: v.midY))
        }
        settle(animate: false)
    }

    func show() {
        settle(animate: false)
        panel.alphaValue = Bubble.idleAlpha
        panel.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }

    fileprivate func hover(_ inside: Bool) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = inside ? 0.12 : 0.3
            panel.animator().alphaValue = inside ? 1 : Bubble.idleAlpha
        }
    }

    fileprivate func move(by d: NSPoint) {
        var o = panel.frame.origin
        o.x += d.x
        o.y += d.y
        panel.setFrameOrigin(o)
    }

    fileprivate func click() {
        trace("bubble clicked")
        onClick?()
    }

    /// Against the nearer left or right edge of its screen, inside it vertically.
    fileprivate func settle(animate: Bool) {
        guard let screen = panel.screen ?? NSScreen.main else { return }
        let v = screen.visibleFrame
        let s = Bubble.size
        var f = panel.frame
        f.origin.x = f.midX < v.midX ? v.minX + 6 : v.maxX - s - 6
        f.origin.y = min(max(f.origin.y, v.minY + 6), v.maxY - s - 6)
        panel.setFrame(f, display: true, animate: animate)
        UserDefaults.standard.set(NSStringFromPoint(f.origin), forKey: "bubbleOrigin")
    }

    fileprivate func menu() -> NSMenu {
        let m = NSMenu()
        let open = NSMenuItem(title: "显示输入框", action: #selector(openBox), keyEquivalent: "")
        open.target = self
        m.addItem(open)
        let off = NSMenuItem(title: "不再显示悬浮球", action: #selector(turnOff), keyEquivalent: "")
        off.target = self
        m.addItem(off)
        m.addItem(.separator())
        m.addItem(NSMenuItem(title: "退出 Courier", action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""))
        return m
    }

    @objc private func openBox() { onClick?() }

    @objc private func turnOff() {
        Prefs.bubble = false
        hide()
        trace("bubble turned off")
    }
}

private final class BubbleView: NSVisualEffectView {
    weak var bubble: Bubble?
    private var start: NSPoint?
    private var moved = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        maskImage = NSImage(size: frame.size, flipped: false) { r in
            NSColor.black.setFill()
            NSBezierPath(ovalIn: r).fill()
            return true
        }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError("not coded") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { bubble?.hover(true) }
    override func mouseExited(with event: NSEvent) { bubble?.hover(false) }

    override func mouseDown(with event: NSEvent) {
        start = NSEvent.mouseLocation
        moved = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let s = start else { return }
        let p = NSEvent.mouseLocation
        if !moved && hypot(p.x - s.x, p.y - s.y) < 3 { return }
        moved = true
        bubble?.move(by: NSPoint(x: p.x - s.x, y: p.y - s.y))
        start = p
    }

    override func mouseUp(with event: NSEvent) {
        if moved { bubble?.settle(animate: true) } else { bubble?.click() }
        start = nil
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let m = bubble?.menu() else { return }
        NSMenu.popUpContextMenu(m, with: event, for: self)
    }
}
