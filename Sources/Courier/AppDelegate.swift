import AppKit
import CourierKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) { refreshMenu() }

    let box = Box()
    private var loginItem: NSMenuItem!
    private var keyboardItem: NSMenuItem!
    private var bubbleItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let version = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "-"
        trace("launch Courier \(version)")
        NSApp.mainMenu = buildMenu()
        box.start()
        // Starts at login unless turned off in the menu; asked once.
        if !UserDefaults.standard.bool(forKey: "loginItemSet") {
            UserDefaults.standard.set(true, forKey: "loginItemSet")
            setLogin(true)
        }
        refreshMenu()
    }

    /// A click on the Dock icon brings the box back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        box.showBox()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        box.save()
        trace("quit")
    }

    private func setLogin(_ on: Bool) {
        let s = SMAppService.mainApp
        do {
            if on { try s.register() } else { try s.unregister() }
        } catch {
            trace("login item \(on ? "register" : "unregister"): \(error.localizedDescription)")
        }
        trace("login item status \(s.status.rawValue)")
    }

    private func refreshMenu() {
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        keyboardItem.state = box.takeKeyboardAfterSend ? .on : .off
        bubbleItem.state = Prefs.bubble ? .on : .off
    }

    @objc private func toggleLogin(_ item: NSMenuItem) {
        setLogin(SMAppService.mainApp.status != .enabled)
        refreshMenu()
    }

    @objc private func toggleKeyboard(_ item: NSMenuItem) {
        box.takeKeyboardAfterSend.toggle()
        refreshMenu()
    }

    @objc private func toggleBubble(_ item: NSMenuItem) {
        Prefs.bubble.toggle()
        if !Prefs.bubble { box.bubble.hide() } else if !box.panel.isVisible { box.bubble.show(at: box.panel.frame.origin) }
        refreshMenu()
    }

    @objc private func clear(_ item: NSMenuItem) { box.clear() }

    @objc private func collapse(_ item: NSMenuItem) { box.collapse() }

    @objc private func openLog(_ item: NSMenuItem) {
        NSWorkspace.shared.open(Paths.log)
    }

    @objc private func showBox(_ item: NSMenuItem) { box.showBox() }

    @objc private func toggleLock(_ item: NSMenuItem) { box.toggleLock() }

    private func item(_ title: String, _ action: Selector?, _ key: String = "", target: AnyObject? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = target
        return i
    }

    private func buildMenu() -> NSMenu {
        let main = NSMenu()

        let app = NSMenu(title: "Courier")
        app.addItem(item("关于 Courier", #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        app.addItem(.separator())
        loginItem = item("登录时打开", #selector(toggleLogin(_:)), target: self)
        app.addItem(loginItem)
        keyboardItem = item("发送后输入框接管键盘", #selector(toggleKeyboard(_:)), target: self)
        app.addItem(keyboardItem)
        bubbleItem = item("收起时显示悬浮球", #selector(toggleBubble(_:)), target: self)
        app.addItem(bubbleItem)
        app.addItem(item("打开日志", #selector(openLog(_:)), target: self))
        app.addItem(.separator())
        app.addItem(item("隐藏 Courier", #selector(NSApplication.hide(_:)), "h"))
        app.addItem(item("退出 Courier", #selector(NSApplication.terminate(_:)), "q"))
        app.delegate = self
        let appItem = NSMenuItem()
        appItem.submenu = app
        main.addItem(appItem)

        let edit = NSMenu(title: "编辑")
        edit.addItem(item("撤销", Selector(("undo:")), "z"))
        edit.addItem(item("重做", Selector(("redo:")), "Z"))
        edit.addItem(.separator())
        edit.addItem(item("剪切", #selector(NSText.cut(_:)), "x"))
        edit.addItem(item("复制", #selector(NSText.copy(_:)), "c"))
        edit.addItem(item("粘贴", #selector(NSText.paste(_:)), "v"))
        edit.addItem(item("全选", #selector(NSText.selectAll(_:)), "a"))
        edit.addItem(.separator())
        edit.addItem(item("清空草稿", #selector(clear(_:)), "k", target: self))
        let editItem = NSMenuItem()
        editItem.submenu = edit
        main.addItem(editItem)

        let win = NSMenu(title: "窗口")
        win.addItem(item("显示输入框", #selector(showBox(_:)), "0", target: self))
        win.addItem(item("锁定/解锁发送目标", #selector(toggleLock(_:)), "l", target: self))
        win.addItem(item("收起成悬浮球", #selector(collapse(_:)), "w", target: self))
        let winItem = NSMenuItem()
        winItem.submenu = win
        main.addItem(winItem)
        NSApp.windowsMenu = win
        return main
    }
}
