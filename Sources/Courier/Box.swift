import AppKit
import ApplicationServices
import CourierKit

/// The box: the floating window with the draft, and what it does.
final class Box: NSObject, NSTextViewDelegate, NSWindowDelegate {
    private(set) var panel: Panel!
    private var card: CardView!
    private var editor: Editor!
    private var scroll: NSScrollView!
    private var scrollHeight: NSLayoutConstraint!
    private let chip = NSButton()
    private let lockBadge = NSImageView()
    private var clearButton: NSButton!
    private let sendButton = SendButton()
    private let status = NSTextField(labelWithString: "")
    private var placing = false
    let tracker = TargetTracker()
    let bubble = Bubble()
    private let sender = Sender()
    private var nextID = 1
    private var history: [String] = []
    private var hist = 0
    private var busy = false
    private var saveTimer: Timer?
    private var lastSaved: SavedState?
    private var trustTimer: Timer?
    private var hovering = false
    private var popover: NSPopover?

    /// How much of the box shows while it is not in use (the keyboard is
    /// elsewhere and the mouse is not over it).
    static let idleAlpha: CGFloat = 0.35
    /// The text area grows with the text between these heights; one line
    /// makes the box as high as the bubble, so the bubble is its left end.
    static let minBody: CGFloat = 28
    static let maxBody: CGFloat = 320
    static let pad: CGFloat = 8

    /// One place for both: the box's bottom-left corner, which is where the
    /// bubble sits when the box is put away.
    private var origin: NSPoint? {
        get { UserDefaults.standard.string(forKey: "boxOrigin").map(NSPointFromString) }
        set { UserDefaults.standard.set(newValue.map(NSStringFromPoint), forKey: "boxOrigin") }
    }
    private var width: CGFloat {
        get { UserDefaults.standard.object(forKey: "boxWidth") as? CGFloat ?? 600 }
        set { UserDefaults.standard.set(newValue, forKey: "boxWidth") }
    }

    static let takeKeyboardKey = "takeKeyboardAfterSend"
    var takeKeyboardAfterSend: Bool {
        get { UserDefaults.standard.object(forKey: Box.takeKeyboardKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Box.takeKeyboardKey) }
    }

    func start() {
        build()
        load()
        tracker.onChange = { [weak self] in self?.renderTarget() }
        tracker.start()
        bubble.onClick = { [weak self] in self?.showBox() }
        bubble.onMoved = { [weak self] o in self?.origin = o }
        bubble.build()
        renderTarget()
        checkTrust()
        showBox()
    }

    // MARK: permission

    private func checkTrust() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard !AXIsProcessTrustedWithOptions(opts) else { return }
        trace("no accessibility permission")
        show("要先在 系统设置 › 隐私与安全性 › 辅助功能 里打开 Courier", bad: true, keep: true)
        trustTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
            guard AXIsProcessTrusted() else { return }
            t.invalidate()
            trace("accessibility permission granted")
            self?.show("辅助功能权限已打开")
        }
    }

    // MARK: draft and state

    private var draft: (text: String, pics: [DraftImage]) { fromEditor(editor.attributedString()) }

    /// Puts content in the editor as one undoable change (⌘Z brings back what was there).
    private func replaceAll(_ text: String, _ pics: [DraftImage] = [], undoable: Bool = true) {
        let content = toEditor(text, pics)
        let storage = editor.textStorage!
        if undoable {
            let all = NSRange(location: 0, length: storage.length)
            guard editor.shouldChangeText(in: all, replacementString: content.string) else { return }
            storage.replaceCharacters(in: all, with: content)
            editor.didChangeText()
        } else {
            storage.setAttributedString(content)
            editor.undoManager?.removeAllActions()
            textChanged()
        }
        editor.setSelectedRange(NSRange(location: content.length, length: 0))
        editor.typingAttributes = baseAttributes
    }

    private func load() {
        var st = SavedState.load(from: Paths.state)
        if st == nil {
            // The first start after InputBar: take over its history and draft.
            let old = Paths.support.deletingLastPathComponent().appendingPathComponent("InputBar/state.json")
            if let o = SavedState.load(from: old) {
                st = o
                trace("took over InputBar's state: \(o.history.count) sent, draft \(o.text.count) chars")
            }
        }
        guard let st else { return }
        history = st.history
        hist = history.count
        let pics = (st.pictures ?? []).map { DraftImage(id: $0.id, png: $0.png) }
        nextID = (pics.map { $0.id }.max() ?? 0) + 1
        replaceAll(st.text, pics, undoable: false)
        lastSaved = st
        trace("loaded: \(history.count) sent, draft \(st.text.count) chars, \(pics.count) pictures")
    }

    func save() {
        saveTimer?.invalidate()
        saveTimer = nil
        let d = draft
        let st = SavedState(history: history, text: d.text, pictures: d.pics.map { .init(id: $0.id, png: $0.png) })
        guard st != lastSaved else { return }
        do {
            try st.save(to: Paths.state)
            lastSaved = st
        } catch {
            trace("save failed: \(error)")
        }
    }

    private func textChanged() {
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { [weak self] _ in self?.save() }
        let empty = editor.textStorage!.length == 0
        clearButton.isHidden = empty
        sendButton.isEnabled = !empty
        bubble.hasDraft = !empty
        fitHeight()
    }

    func textDidChange(_ notification: Notification) { textChanged() }

    /// A click on a picture shows it large.
    func textView(_ textView: NSTextView, clickedOn cell: NSTextAttachmentCellProtocol, in cellFrame: NSRect, at charIndex: Int) {
        guard let a = cell.attachment as? ShotAttachment, let img = NSImage(data: a.png) else { return }
        var size = img.size
        let scale = min(1, 640 / size.width, 420 / size.height)
        size = NSSize(width: size.width * scale, height: size.height * scale)
        let view = NSImageView(frame: NSRect(origin: .zero, size: size))
        view.image = img
        view.imageScaling = .scaleProportionallyUpOrDown
        let vc = NSViewController()
        vc.view = view
        let p = NSPopover()
        p.contentViewController = vc
        p.behavior = .transient
        p.show(relativeTo: cellFrame, of: textView, preferredEdge: .maxY)
        popover = p
    }

    // MARK: actions

    func showBox() {
        if bubble.isVisible {
            origin = bubble.origin
            bubble.hide()
        }
        place()
        let wasHidden = !panel.isVisible
        if wasHidden { panel.alphaValue = 0 }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(editor)
        fitHeight()
        if wasHidden { fade() }
    }

    /// Puts the box away: it shrinks into the bubble, which takes its place.
    @objc func collapse() {
        guard panel.isVisible else { return }
        save()
        let at = panel.frame.origin
        origin = at
        trace("box put away")
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.panel.orderOut(nil)
            if Prefs.bubble { self?.bubble.show(at: at) }
        })
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        collapse()
        return false
    }

    func windowDidMove(_ notification: Notification) {
        if !placing { origin = panel.frame.origin }
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        width = panel.frame.width
        origin = panel.frame.origin
    }

    /// The box at its saved place and width, kept on screen.
    private func place() {
        var f = panel.frame
        f.size.width = width
        if let o = origin { f.origin = o } else if let v = NSScreen.main?.visibleFrame {
            f.origin = NSPoint(x: v.midX - f.width / 2, y: v.minY + 120)
        }
        setFrame(f)
    }

    private func setFrame(_ frame: NSRect) {
        var f = frame
        let screen = NSScreen.screens.first { $0.visibleFrame.intersects(f) } ?? NSScreen.main
        if let v = screen?.visibleFrame {
            f.size.width = min(f.width, v.width - 12)
            f.origin.x = min(max(f.minX, v.minX + 6), v.maxX - f.width - 6)
            f.origin.y = min(max(f.minY, v.minY + 6), v.maxY - f.height - 6)
        }
        placing = true
        panel.setFrame(f, display: true)
        placing = false
    }

    func windowDidBecomeKey(_ notification: Notification) { fade() }
    func windowDidResignKey(_ notification: Notification) { fade() }
    func windowDidResize(_ notification: Notification) { fitHeight() }

    /// Out of the way while not in use: faint until written in or pointed at.
    private func fade() {
        let want: CGFloat = panel.isKeyWindow || hovering ? 1 : Box.idleAlpha
        guard panel.alphaValue != want else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = want == 1 ? 0.12 : 0.35
            panel.animator().alphaValue = want
        }
    }

    /// The box as high as the text needs, between minBody and maxBody; the
    /// bottom edge stays (it grows upward, like a chat's input). Only the width
    /// can be dragged.
    private func fitHeight() {
        guard panel != nil, let lm = editor.layoutManager, let tc = editor.textContainer else { return }
        lm.ensureLayout(for: tc)
        let textH = ceil(lm.usedRect(for: tc).height + editor.textContainerInset.height * 2)
        let body = min(max(textH, Box.minBody), Box.maxBody)
        scrollHeight.constant = body
        let want = body + Box.pad * 2
        panel.minSize = NSSize(width: 320, height: want)
        panel.maxSize = NSSize(width: 1600, height: want)
        card.radius = want <= 46 ? want / 2 : 18
        if abs(panel.frame.height - want) > 0.5 {
            var f = panel.frame
            f.size.height = want
            setFrame(f)
        }
        panel.invalidateShadow()
    }

    @objc func toggleLock() {
        guard tracker.app != nil else { return }
        tracker.locked.toggle()
    }

    @objc func clear() {
        guard editor.textStorage!.length > 0 else { return }
        replaceAll("")
        editor.undoManager?.setActionName("清空")
        show("已清空，⌘Z 撤销")
        trace("cleared")
    }

    private func attach(_ png: Data) {
        let id = nextID
        nextID += 1
        let a = NSMutableAttributedString(attachment: ShotAttachment(id: id, png: png))
        a.addAttributes(baseAttributes, range: NSRange(location: 0, length: a.length))
        let r = editor.selectedRange()
        guard editor.shouldChangeText(in: r, replacementString: a.string) else { return }
        editor.textStorage!.replaceCharacters(in: r, with: a)
        editor.didChangeText()
        editor.setSelectedRange(NSRange(location: r.location + a.length, length: 0))
        editor.typingAttributes = baseAttributes
        trace("attach picture \(id) (\(png.count / 1024)KB)")
    }

    /// ⌘↑ ⌘↓: walk through what was sent. A draft being written is never replaced.
    private func recall(_ step: Int) {
        let text = draft.text
        let showing = hist < history.count && text == history[hist]
        guard text.isEmpty || showing else {
            show("先发送或清空草稿（⌘K），再翻历史")
            return
        }
        let n = hist + step
        guard n >= 0, n <= history.count else {
            NSSound.beep()
            return
        }
        hist = n
        replaceAll(n == history.count ? "" : history[n])
    }

    @objc private func showHistory(_ sender: NSButton) {
        let menu = NSMenu()
        if history.isEmpty {
            menu.addItem(withTitle: "还没有发过", action: nil, keyEquivalent: "").isEnabled = false
        }
        for (i, s) in history.enumerated().reversed().prefix(20) {
            let item = NSMenuItem(title: preview(s), action: #selector(useHistory(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
            item.toolTip = s
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func useHistory(_ item: NSMenuItem) {
        guard history.indices.contains(item.tag) else { return }
        let hadDraft = editor.textStorage!.length > 0
        hist = item.tag
        replaceAll(history[item.tag])
        if hadDraft { show("已换成历史内容，⌘Z 换回草稿") }
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func sendClicked() {
        submit(insertOnly: NSApp.currentEvent?.modifierFlags.contains(.option) ?? false)
    }

    @objc private func fillOnly() { submit(insertOnly: true) }
    @objc private func sendNow() { submit(insertOnly: false) }

    private func sendMenu() -> NSMenu {
        let m = NSMenu()
        for (title, sel) in [("发送（Enter）", #selector(sendNow)), ("只填入，不发送（⌥Enter）", #selector(fillOnly))] {
            let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            i.target = self
            m.addItem(i)
        }
        return m
    }

    /// The picture button: the picture on the clipboard, else pick image files.
    @objc private func addPicture() {
        if let png = clipboardImage() {
            attach(png)
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        let open = NSOpenPanel()
        open.allowedContentTypes = [.image]
        open.allowsMultipleSelection = true
        open.message = "剪贴板里没有图片，选几张图片文件"
        open.beginSheetModal(for: panel) { [weak self] r in
            guard r == .OK else { return }
            for url in open.urls { if let png = pngOfImageFile(url) { self?.attach(png) } }
            self?.panel.makeFirstResponder(self?.editor)
        }
    }

    private func submit(insertOnly: Bool) {
        guard !busy else { return }
        let d = draft
        let text = trimmedEnd(d.text)
        let parts = pieces(text, d.pics)
        guard !parts.isEmpty else { return }
        guard AXIsProcessTrusted() else {
            trace("send refused: no accessibility permission")
            show("没有辅助功能权限，发不出去", bad: true, keep: true)
            return
        }
        guard let target = tracker.app, !target.isTerminated else {
            show("先点一下要发往的窗口", bad: true)
            return
        }
        busy = true
        // Out of the way, so the app in front gets the keys again, at its own caret.
        panel.orderOut(nil)
        sender.send(parts, to: target, insertOnly: insertOnly) { [weak self] outcome in
            self?.sent(outcome, text: text, insertOnly: insertOnly)
        }
    }

    private func sent(_ outcome: SendOutcome, text: String, insertOnly: Bool) {
        busy = false
        var failed = false
        var back: NSRunningApplication?
        switch outcome {
        case .sent(let returnTo):
            back = returnTo
            remember(trimmedEnd(withoutMarkers(text)), in: &history)
            hist = history.count
            nextID = 1
            replaceAll("", undoable: false)
            save()
            show(insertOnly ? "已填入" : "已发送")
        case .aborted(let why):
            failed = true
            show(why + "，没有发完，草稿还在", bad: true, keep: true)
        }
        if let back, !back.isTerminated {
            // You went elsewhere while it was sending: back there.
            back.activate(options: [.activateIgnoringOtherApps])
            panel.orderFrontRegardless()
            trace("back to \(back.localizedName ?? "?")")
        } else if takeKeyboardAfterSend || failed {
            // A panel made key by code while the app is in the back looks key
            // but the keyboard stays with the app in front: take the front
            // (the target is remembered, so the next send still goes there).
            NSApp.activate(ignoringOtherApps: true)
            showBox()
        } else {
            panel.orderFrontRegardless()
        }
    }

    // MARK: target menu

    @objc private func showTargets(_ sender: NSButton) {
        let menu = NSMenu()
        if let t = tracker.app {
            let lock = NSMenuItem(title: "锁定发往 \(t.localizedName ?? "?")（⌘L）", action: #selector(toggleLock), keyEquivalent: "")
            lock.target = self
            lock.state = tracker.locked ? .on : .off
            menu.addItem(lock)
        }
        let follow = NSMenuItem(title: "跟随前台 App", action: #selector(followFront), keyEquivalent: "")
        follow.target = self
        follow.state = tracker.locked ? .off : .on
        menu.addItem(follow)
        menu.addItem(.separator())
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != getpid() }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
        for a in apps {
            let item = NSMenuItem(title: a.localizedName ?? "?", action: #selector(pick(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = a
            let img = (a.icon?.copy() as? NSImage) ?? NSImage()
            img.size = NSSize(width: 16, height: 16)
            item.image = img
            item.state = a.processIdentifier == tracker.app?.processIdentifier ? .on : .off
            menu.addItem(item)
        }
        if let t = tracker.app {
            let name = t.localizedName ?? "?"
            menu.addItem(.separator())
            let img = NSMenu()
            for (title, f) in [("⌘V", CGEventFlags.maskCommand), ("⌃V（终端）", .maskControl)] {
                let i = NSMenuItem(title: title, action: #selector(setImageKey(_:)), keyEquivalent: "")
                i.target = self
                i.representedObject = f.rawValue
                i.state = Prefs.imageFlags(t) == f ? .on : .off
                img.addItem(i)
            }
            let imgItem = NSMenuItem(title: "在 \(name) 里贴图片用", action: nil, keyEquivalent: "")
            imgItem.submenu = img
            menu.addItem(imgItem)
            let snd = NSMenu()
            for (title, f) in [("回车", CGEventFlags()), ("⌘回车", .maskCommand)] {
                let i = NSMenuItem(title: title, action: #selector(setSendKey(_:)), keyEquivalent: "")
                i.target = self
                i.representedObject = f.rawValue
                i.state = Prefs.sendFlags(t) == f ? .on : .off
                snd.addItem(i)
            }
            let sndItem = NSMenuItem(title: "在 \(name) 里发送用", action: nil, keyEquivalent: "")
            sndItem.submenu = snd
            menu.addItem(sndItem)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func followFront() {
        tracker.locked = false
        tracker.follow()
    }

    @objc private func pick(_ item: NSMenuItem) {
        guard let a = item.representedObject as? NSRunningApplication else { return }
        tracker.pin(a)
    }

    @objc private func setImageKey(_ item: NSMenuItem) {
        guard let t = tracker.app, let raw = item.representedObject as? UInt64 else { return }
        Prefs.setImageFlags(t, CGEventFlags(rawValue: raw))
        trace("image key for \(t.localizedName ?? "?") = \(item.title)")
        renderTarget()
    }

    @objc private func setSendKey(_ item: NSMenuItem) {
        guard let t = tracker.app, let raw = item.representedObject as? UInt64 else { return }
        Prefs.setSendFlags(t, CGEventFlags(rawValue: raw))
        trace("send key for \(t.localizedName ?? "?") = \(item.title)")
        renderTarget()
    }

    // MARK: view

    private func show(_ s: String, bad: Bool = false, keep: Bool = false) {
        status.stringValue = s
        status.isHidden = s.isEmpty
        status.textColor = bad ? .systemRed : .secondaryLabelColor
        guard !keep else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            if self?.status.stringValue == s {
                self?.status.stringValue = ""
                self?.status.isHidden = true
            }
        }
    }

    private func renderTarget() {
        guard let app = tracker.app else {
            chip.image = NSImage(systemSymbolName: "scope", accessibilityDescription: nil)
            chip.toolTip = "还没有发送目标：点一下要发往的窗口"
            lockBadge.isHidden = true
            editor.placeholder = "先点一下要发往的窗口，再回来写"
            return
        }
        let img = (app.icon?.copy() as? NSImage) ?? NSImage()
        img.size = NSSize(width: 22, height: 22)
        chip.image = img
        let name = app.localizedName ?? "?"
        let keys = "图片用 " + (Prefs.imageFlags(app) == .maskControl ? "⌃V" : "⌘V")
            + "，发送用 " + (Prefs.sendFlags(app) == .maskCommand ? "⌘回车" : "回车")
        chip.toolTip = "发往 \(name)\(tracker.locked ? "（已锁定）" : "")。\(keys)。点击换目标、锁定、改按键"
        lockBadge.isHidden = !tracker.locked
        editor.placeholder = "发往 \(name) · Enter 发送，⇧Enter 换行"
    }

    private func build() {
        panel = Panel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 44),
            styleMask: [.nonactivatingPanel, .resizable],
            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.delegate = self

        card = CardView()
        card.onHover = { [weak self] inside in
            self?.hovering = inside
            self?.fade()
        }
        panel.contentView = card

        // Left: where it goes. A click opens the target menu.
        chip.isBordered = false
        chip.imagePosition = .imageOnly
        chip.imageScaling = .scaleProportionallyDown
        chip.target = self
        chip.action = #selector(showTargets(_:))
        chip.translatesAutoresizingMaskIntoConstraints = false
        lockBadge.image = NSImage(systemSymbolName: "lock.circle.fill", accessibilityDescription: "已锁定")
        lockBadge.contentTintColor = .controlAccentColor
        lockBadge.translatesAutoresizingMaskIntoConstraints = false
        lockBadge.isHidden = true
        chip.addSubview(lockBadge)
        NSLayoutConstraint.activate([
            chip.widthAnchor.constraint(equalToConstant: 28), chip.heightAnchor.constraint(equalToConstant: 28),
            lockBadge.widthAnchor.constraint(equalToConstant: 12), lockBadge.heightAnchor.constraint(equalToConstant: 12),
            lockBadge.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: 1),
            lockBadge.bottomAnchor.constraint(equalTo: chip.bottomAnchor, constant: 1),
        ])

        // Middle: the text, TextKit 1 (for attachment clicks and measuring height).
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        editor = Editor(frame: .zero, textContainer: container)
        editor.isRichText = true
        editor.importsGraphics = false
        editor.usesFontPanel = false
        editor.allowsUndo = true
        editor.typingAttributes = baseAttributes
        editor.drawsBackground = false
        editor.textContainerInset = NSSize(width: 0, height: 5)
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.minSize = NSSize(width: 0, height: 0)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.delegate = self
        editor.onSubmit = { [weak self] only in self?.submit(insertOnly: only) }
        editor.onImage = { [weak self] png in self?.attach(png) }
        editor.onRecall = { [weak self] step in self?.recall(step) }
        editor.onClear = { [weak self] in self?.clear() }
        editor.onEscape = { [weak self] in self?.collapse() }
        scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.documentView = editor
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scrollHeight = scroll.heightAnchor.constraint(equalToConstant: Box.minBody)

        status.font = .systemFont(ofSize: 12)
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        status.translatesAutoresizingMaskIntoConstraints = false
        status.widthAnchor.constraint(lessThanOrEqualToConstant: 220).isActive = true
        status.isHidden = true

        // Right: the buttons, then send.
        let picture = iconButton("photo.badge.plus", "加图片：贴剪贴板里的图，没有就选文件（也可 ⌘V 或拖进来）", self, #selector(addPicture))
        let history = iconButton("clock.arrow.circlepath", "发过的内容（⌘↑ ⌘↓ 翻看）", self, #selector(showHistory(_:)))
        clearButton = iconButton("trash", "清空草稿（⌘K，⌘Z 撤销）", self, #selector(clear))
        clearButton.isHidden = true
        let fold = iconButton("arrow.down.right.and.arrow.up.left", "收起成悬浮球（Esc）", self, #selector(collapse))
        sendButton.target = self
        sendButton.action = #selector(sendClicked)
        sendButton.toolTip = "发送（Enter）。⌥ 点击或右键：只填入不发送"
        sendButton.onMenu = { [weak self] in self?.sendMenu() ?? NSMenu() }
        sendButton.isEnabled = false

        let row = NSStackView(views: [chip, scroll, status, picture, history, clearButton, fold, sendButton])
        row.orientation = .horizontal
        row.alignment = .bottom
        row.spacing = 4
        row.setCustomSpacing(8, after: chip)
        row.setCustomSpacing(6, after: fold)
        row.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Box.pad),
            row.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Box.pad),
            row.topAnchor.constraint(equalTo: card.topAnchor, constant: Box.pad),
            row.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -Box.pad),
            scrollHeight,
        ])
        scroll.setContentHuggingPriority(.defaultLow, for: .horizontal)
        place()
    }
}
