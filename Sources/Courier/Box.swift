import AppKit
import ApplicationServices
import CourierKit

/// The box: the floating window with the draft, and what it does.
final class Box: NSObject, NSTextViewDelegate, NSWindowDelegate {
    private(set) var panel: Panel!
    private var editor: Editor!
    private let icon = NSImageView()
    private let targetLabel = NSTextField(labelWithString: "点一下要发往的窗口")
    private let lockButton = NSButton()
    private let status = NSTextField(labelWithString: "")
    let tracker = TargetTracker()
    private let sender = Sender()
    private var pics: [DraftImage] = []
    private var nextID = 1
    private var history: [String] = []
    private var hist = 0
    private var busy = false
    private var saveTimer: Timer?
    private var lastSaved: SavedState?
    private var trustTimer: Timer?
    private var hovering = false

    /// How much of the box shows while it is not being written in (the
    /// keyboard is elsewhere and the mouse is not over it).
    static let idleAlpha: CGFloat = 0.35

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

    // MARK: state

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
        pics = (st.pictures ?? []).map { DraftImage(id: $0.id, png: $0.png) }
        nextID = (pics.map(\.id).max() ?? 0) + 1
        editor.string = st.text
        editor.setSelectedRange(NSRange(location: (st.text as NSString).length, length: 0))
        lastSaved = st
        trace("loaded: \(history.count) sent, draft \(st.text.count) chars, \(pics.count) pictures")
    }

    private func currentState() -> SavedState {
        let text = editor.string
        return SavedState(history: history, text: text,
                          pictures: referenced(text, pics).map { .init(id: $0.id, png: $0.png) })
    }

    func save() {
        saveTimer?.invalidate()
        saveTimer = nil
        let st = currentState()
        guard st != lastSaved else { return }
        do {
            try st.save(to: Paths.state)
            lastSaved = st
        } catch {
            trace("save failed: \(error)")
        }
    }

    private func saveSoon() {
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { [weak self] _ in self?.save() }
    }

    func textDidChange(_ notification: Notification) { saveSoon() }

    // MARK: actions

    func showBox() {
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(editor)
    }

    func windowDidBecomeKey(_ notification: Notification) { fade() }
    func windowDidResignKey(_ notification: Notification) { fade() }

    /// Out of the way while not in use: faint until written in or pointed at.
    private func fade() {
        let want: CGFloat = panel.isKeyWindow || hovering ? 1 : Box.idleAlpha
        guard panel.alphaValue != want else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = want == 1 ? 0.12 : 0.35
            panel.animator().alphaValue = want
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        panel.orderOut(nil)
        save()
        trace("box put away")
        return false
    }

    @objc func toggleLock() {
        guard tracker.app != nil else { return }
        tracker.locked.toggle()
    }

    private func attach(_ png: Data) {
        let id = nextID
        nextID += 1
        pics.append(DraftImage(id: id, png: png))
        editor.insertText(marker(id), replacementRange: editor.selectedRange())
        trace("attach picture \(id) (\(png.count / 1024)KB)")
    }

    /// ⌘↑ ⌘↓: walk through what was sent. A draft being written is never replaced.
    private func recall(_ step: Int) {
        let text = editor.string
        let showing = hist < history.count && text == history[hist]
        guard text.isEmpty || showing else {
            show("先发送或清空草稿，再翻历史")
            return
        }
        let n = hist + step
        guard n >= 0, n <= history.count else {
            NSSound.beep()
            return
        }
        hist = n
        editor.string = n == history.count ? "" : history[n]
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        saveSoon()
    }

    private func submit(insertOnly: Bool) {
        guard !busy else { return }
        let text = trimmedEnd(editor.string)
        let parts = pieces(text, pics)
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
        switch outcome {
        case .sent:
            remember(trimmedEnd(withoutMarkers(text)), in: &history)
            hist = history.count
            editor.string = ""
            pics = []
            nextID = 1
            editor.undoManager?.removeAllActions()
            save()
            show(insertOnly ? "已填入" : "已发送")
        case .aborted(let why):
            failed = true
            show(why + "，没有发完，草稿还在", bad: true, keep: true)
        }
        if takeKeyboardAfterSend || failed {
            // A panel made key by code while the app is in the back looks key
            // but the keyboard stays with the app in front: take the front
            // (the target is remembered, so the next send still goes there).
            NSApp.activate(ignoringOtherApps: true)
            showBox()
        } else {
            panel.orderFrontRegardless()
        }
    }

    // MARK: view

    private func show(_ s: String, bad: Bool = false, keep: Bool = false) {
        status.stringValue = s
        status.textColor = bad ? .systemRed : .secondaryLabelColor
        guard !keep else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            if self?.status.stringValue == s { self?.status.stringValue = "" }
        }
    }

    private func renderTarget() {
        guard let app = tracker.app else {
            icon.image = nil
            targetLabel.stringValue = "点一下要发往的窗口"
            lockButton.isHidden = true
            return
        }
        let img = (app.icon?.copy() as? NSImage) ?? NSImage()
        img.size = NSSize(width: 16, height: 16)
        icon.image = img
        let name = app.localizedName ?? "?"
        targetLabel.stringValue = "发往 \(name)"
        targetLabel.toolTip = "图片用 " + (isTerminal(app) ? "⌃V" : "⌘V") + " 贴进 \(name)"
        lockButton.isHidden = false
        lockButton.image = NSImage(systemSymbolName: tracker.locked ? "lock.fill" : "lock.open", accessibilityDescription: nil)
        lockButton.contentTintColor = tracker.locked ? .controlAccentColor : .tertiaryLabelColor
        lockButton.toolTip = tracker.locked ? "已锁定发往 \(name)，点击解锁" : "点击锁定：一直发往 \(name)"
    }

    private func build() {
        panel = Panel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 170),
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
        panel.minSize = NSSize(width: 360, height: 120)
        panel.delegate = self
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        let bg = HoverView()
        bg.onHover = { [weak self] inside in
            self?.hovering = inside
            self?.fade()
        }
        bg.material = .popover
        bg.blendingMode = .behindWindow
        bg.state = .active
        panel.contentView = bg

        icon.translatesAutoresizingMaskIntoConstraints = false
        targetLabel.font = .systemFont(ofSize: 12, weight: .medium)
        targetLabel.textColor = .secondaryLabelColor
        lockButton.isBordered = false
        lockButton.imagePosition = .imageOnly
        lockButton.target = self
        lockButton.action = #selector(toggleLock)
        lockButton.isHidden = true
        status.font = .systemFont(ofSize: 12)
        status.alignment = .right
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [icon, targetLabel, lockButton, spacer, status])
        header.spacing = 6
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 16), icon.heightAnchor.constraint(equalToConstant: 16),
        ])

        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        editor = Editor(frame: .zero)
        editor.isRichText = false
        editor.allowsUndo = true
        editor.font = .systemFont(ofSize: 14)
        editor.drawsBackground = false
        editor.textContainerInset = NSSize(width: 2, height: 6)
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isVerticallyResizable = true
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.delegate = self
        editor.onSubmit = { [weak self] only in self?.submit(insertOnly: only) }
        editor.onImage = { [weak self] png in self?.attach(png) }
        editor.onRecall = { [weak self] step in self?.recall(step) }
        scroll.documentView = editor

        let hint = NSTextField(labelWithString: "Enter 发送 · ⇧Enter 换行 · ⌥Enter 只填不发 · ⌘V 贴截图 · ⌘↑↓ 历史")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor

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
