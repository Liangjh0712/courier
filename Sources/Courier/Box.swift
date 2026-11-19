import AppKit
import ApplicationServices
import CourierKit

/// The box: the floating window with the draft, and what it does.
final class Box: NSObject, NSTextViewDelegate, NSWindowDelegate {
    private(set) var panel: Panel!
    private var editor: Editor!
    private var scroll: NSScrollView!
    private let targetButton = NSButton()
    private let lockButton = NSButton()
    private let historyButton = NSButton()
    private let clearButton = NSButton()
    private let status = NSTextField(labelWithString: "")
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
    /// The text area grows with the text between these heights.
    static let minBody: CGFloat = 48
    static let maxBody: CGFloat = 320

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
        bubble.hide()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(editor)
        fitHeight()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        panel.orderOut(nil)
        save()
        if Prefs.bubble { bubble.show() }
        trace("box put away")
        return false
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

    /// The window as high as the text needs, between minBody and maxBody; the
    /// top edge stays where it is. Only the width can be dragged.
    private func fitHeight() {
        guard let lm = editor.layoutManager, let tc = editor.textContainer, panel != nil else { return }
        panel.contentView?.layoutSubtreeIfNeeded()
        lm.ensureLayout(for: tc)
        let textH = ceil(lm.usedRect(for: tc).height + editor.textContainerInset.height * 2)
        let chrome = panel.frame.height - scroll.frame.height
        let want = chrome + min(max(textH, Box.minBody), Box.maxBody)
        panel.minSize = NSSize(width: 360, height: want)
        panel.maxSize = NSSize(width: 1600, height: want)
        guard abs(panel.frame.height - want) > 0.5 else { return }
        var f = panel.frame
        f.origin.y += f.height - want
        f.size.height = want
        panel.setFrame(f, display: true)
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
        status.textColor = bad ? .systemRed : .secondaryLabelColor
        guard !keep else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            if self?.status.stringValue == s { self?.status.stringValue = "" }
        }
    }

    private func renderTarget() {
        guard let app = tracker.app else {
            targetButton.image = NSImage(systemSymbolName: "scope", accessibilityDescription: nil)
            targetButton.title = "点一下要发往的窗口"
            lockButton.isHidden = true
            return
        }
        let img = (app.icon?.copy() as? NSImage) ?? NSImage()
        img.size = NSSize(width: 16, height: 16)
        targetButton.image = img
        let name = app.localizedName ?? "?"
        targetButton.title = "发往 \(name)"
        let keys = "图片用 " + (Prefs.imageFlags(app) == .maskControl ? "⌃V" : "⌘V")
            + "，发送用 " + (Prefs.sendFlags(app) == .maskCommand ? "⌘回车" : "回车")
        targetButton.toolTip = "\(keys)。点击可换目标、改按键"
        lockButton.isHidden = false
        lockButton.image = NSImage(systemSymbolName: tracker.locked ? "lock.fill" : "lock.open", accessibilityDescription: nil)
        lockButton.contentTintColor = tracker.locked ? .controlAccentColor : .tertiaryLabelColor
        lockButton.toolTip = tracker.locked ? "已锁定发往 \(name)，点击解锁（⌘L）" : "点击锁定：一直发往 \(name)（⌘L）"
    }

    private func iconButton(_ b: NSButton, _ symbol: String, _ tip: String, _ action: Selector) {
        b.isBordered = false
        b.imagePosition = .imageOnly
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        b.contentTintColor = .tertiaryLabelColor
        b.toolTip = tip
        b.target = self
        b.action = action
    }

    private func build() {
        panel = Panel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 150),
            styleMask: [.nonactivatingPanel, .titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        let bg = HoverView()
        bg.material = .popover
        bg.blendingMode = .behindWindow
        bg.state = .active
        bg.onHover = { [weak self] inside in
            self?.hovering = inside
            self?.fade()
        }
        panel.contentView = bg

        targetButton.isBordered = false
        targetButton.imagePosition = .imageLeading
        targetButton.font = .systemFont(ofSize: 12, weight: .medium)
        targetButton.contentTintColor = .secondaryLabelColor
        targetButton.target = self
        targetButton.action = #selector(showTargets(_:))
        targetButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        iconButton(lockButton, "lock.open", "锁定发送目标", #selector(toggleLock))
        lockButton.isHidden = true
        iconButton(historyButton, "clock.arrow.circlepath", "发过的内容（⌘↑ ⌘↓ 翻看）", #selector(showHistory(_:)))
        iconButton(clearButton, "trash", "清空草稿（⌘K）", #selector(clear))
        clearButton.isHidden = true
        status.font = .systemFont(ofSize: 12)
        status.alignment = .right
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [targetButton, lockButton, spacer, status, clearButton, historyButton])
        header.spacing = 6

        // TextKit 1, for attachment clicks and measuring the text's height.
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
        editor.textContainerInset = NSSize(width: 2, height: 6)
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
        scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.documentView = editor

        let hint = NSTextField(labelWithString: "Enter 发送 · ⇧Enter 换行 · ⌥Enter 只填不发 · ⌘V 贴截图 · ⌘K 清空")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        hint.lineBreakMode = .byTruncatingTail
        hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [header, scroll, hint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: bg.topAnchor, constant: 26),
            stack.bottomAnchor.constraint(equalTo: bg.bottomAnchor, constant: -10),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        panel.setFrameAutosaveName("CourierBox")
        if !panel.setFrameUsingName("CourierBox") { panel.center() }
    }
}
