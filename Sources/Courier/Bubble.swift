import AppKit
import CourierKit

/// The box put away: a small round button where the box's left end was, the
/// same card. Faint until pointed at, a dot when a draft is waiting; a click
/// opens the box from here. Dragged, it takes the box's place with it.
final class Bubble: NSObject {
    static let size: CGFloat = 44
    static let idleAlpha: CGFloat = 0.35

    var onClick: (() -> Void)?
    var onMoved: ((NSPoint) -> Void)?
    var hasDraft = false {
        didSet { dot?.isHidden = !hasDraft }
    }
    var isVisible: Bool { panel?.isVisible ?? false }
    var origin: NSPoint { panel.frame.origin }
    private var panel: NSPanel!
    private var dot: NSView!

    func build() {
        let s = Bubble.size
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: s, height: s),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false

        let view = BubbleView(frame: NSRect(x: 0, y: 0, width: s, height: s))
        view.bubble = self
        panel.contentView = view

        let icon = NSImageView(frame: NSRect(x: 11, y: 11, width: 22, height: 22))
        icon.image = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: "Courier")
        icon.symbolConfiguration = .init(pointSize: 16, weight: .semibold)
        icon.contentTintColor = .controlAccentColor
        view.addSubview(icon)

        dot = NSView(frame: NSRect(x: s - 14, y: s - 14, width: 8, height: 8))
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.layer?.cornerRadius = 4
        dot.isHidden = !hasDraft
        view.addSubview(dot)
    }

    func show(at o: NSPoint) {
        panel.setFrameOrigin(o)
        keepOnScreen()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = Bubble.idleAlpha
        }
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

    fileprivate func dropped() {
        keepOnScreen()
        onMoved?(panel.frame.origin)
    }

    fileprivate func click() {
        trace("bubble clicked")
        onClick?()
    }

    private func keepOnScreen() {
        let f = panel.frame
        guard let v = (NSScreen.screens.first { $0.frame.intersects(f) } ?? NSScreen.main)?.visibleFrame else { return }
        let s = Bubble.size
        panel.setFrameOrigin(NSPoint(x: min(max(f.minX, v.minX + 6), v.maxX - s - 6),
                                     y: min(max(f.minY, v.minY + 6), v.maxY - s - 6)))
    }

    fileprivate func menu() -> NSMenu {
        let m = NSMenu()
        let open = NSMenuItem(title: "展开输入框", action: #selector(openBox), keyEquivalent: "")
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

private final class BubbleView: CardView {
    weak var bubble: Bubble?
    private var start: NSPoint?
    private var moved = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        radius = frame.height / 2
        onHover = { [weak self] inside in self?.bubble?.hover(inside) }
    }

    required init?(coder: NSCoder) { fatalError("not coded") }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

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
        if moved { bubble?.dropped() } else { bubble?.click() }
        start = nil
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let m = bubble?.menu() else { return }
        NSMenu.popUpContextMenu(m, with: event, for: self)
    }
}
