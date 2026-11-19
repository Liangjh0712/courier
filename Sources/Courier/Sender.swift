import AppKit
import ApplicationServices
import CourierKit

// Sending works the way an input method lands text in any app, without
// knowing the app: put the text on the clipboard, press ⌘V for it, the same
// for each picture (⌃V in terminals), then Return; then give the clipboard
// back. It needs the Accessibility permission (to post key events).

/// The clipboard as it was, text-like types only: reading what other apps
/// provide lazily can block.
struct ClipboardSnapshot {
    static let safe: [NSPasteboard.PasteboardType] = [.string, .rtf, .html, .png, .tiff, .fileURL, .URL]
    let items: [[NSPasteboard.PasteboardType: Data]]

    static func capture() -> ClipboardSnapshot {
        let items = (NSPasteboard.general.pasteboardItems ?? []).map { item in
            var d: [NSPasteboard.PasteboardType: Data] = [:]
            for t in safe where item.types.contains(t) {
                if let v = item.data(forType: t) { d[t] = v }
            }
            return d
        }.filter { !$0.isEmpty }
        return ClipboardSnapshot(items: items)
    }

    func restore() {
        let pb = NSPasteboard.general
        pb.clearContents()
        let objs = items.map { d -> NSPasteboardItem in
            let it = NSPasteboardItem()
            for (t, v) in d { it.setData(v, forType: t) }
            return it
        }
        if !objs.isEmpty { pb.writeObjects(objs) }
    }
}

/// Marks what we put on the clipboard as passing through (nspasteboard.org),
/// so clipboard history apps leave it out.
private let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

private func put(string s: String) -> Int {
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(s, forType: .string)
    pb.setData(Data(), forType: transient)
    return pb.changeCount
}

private func put(png: Data) -> Int {
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setData(png, forType: .png)
    if let rep = NSBitmapImageRep(data: png), let tiff = rep.tiffRepresentation { pb.setData(tiff, forType: .tiff) }
    pb.setData(Data(), forType: transient)
    return pb.changeCount
}

private let keyV: CGKeyCode = 0x09
private let keyReturn: CGKeyCode = 0x24

private func postKey(_ code: CGKeyCode, _ flags: CGEventFlags = []) {
    let src = CGEventSource(stateID: .hidSystemState)
    let down = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true)
    let up = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false)
    down?.flags = flags
    up?.flags = flags
    down?.post(tap: .cghidEventTap)
    usleep(10_000)
    up?.post(tap: .cghidEventTap)
}

/// Terminals take a picture with ⌃V (the convention of Claude Code and other
/// terminal programs); every other app with ⌘V.
let terminals: Set<String> = [
    "com.mitchellh.ghostty", "com.googlecode.iterm2", "com.apple.Terminal", "net.kovidgoyal.kitty",
    "dev.warp.Warp-Stable", "com.github.wez.wezterm", "co.zeit.hyper", "org.alacritty", "io.alacritty",
]

func isTerminal(_ app: NSRunningApplication) -> Bool { terminals.contains(app.bundleIdentifier ?? "") }

/// A picture on the clipboard: an image file copied in Finder, or image data.
/// Text wins over image data (a copy from a web page carries both).
func clipboardImage() -> Data? {
    let pb = NSPasteboard.general
    if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
       let url = urls.first {
        return pngOfImageFile(url)
    }
    if pb.string(forType: .string) != nil { return nil }
    if let png = pb.data(forType: .png) { return png }
    if let tiff = pb.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff) {
        return rep.representation(using: .png, properties: [:])
    }
    return nil
}

func pngOfImageFile(_ url: URL) -> Data? {
    guard let img = NSImage(contentsOf: url), let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff) else { return nil }
    return rep.representation(using: .png, properties: [:])
}

/// What has the keyboard focus in an app, as accessibility sees it: its role
/// and the length of its text (the text growing tells that a paste landed).
func axFocus(_ pid: pid_t) -> String {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 0.5)
    var v: CFTypeRef?
    let err = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &v)
    guard err == .success, let el = v, CFGetTypeID(el) == AXUIElementGetTypeID() else { return "focus=none(\(err.rawValue))" }
    let e = el as! AXUIElement
    var role: CFTypeRef?
    AXUIElementCopyAttributeValue(e, kAXRoleAttribute as CFString, &role)
    var val: CFTypeRef?
    AXUIElementCopyAttributeValue(e, kAXValueAttribute as CFString, &val)
    let len = (val as? String).map { String($0.count) } ?? "-"
    return "focus=\(role as? String ?? "?") len=\(len)"
}

enum SendOutcome {
    /// returnTo: the app you switched to while it was sending, to go back to.
    case sent(returnTo: NSRunningApplication?)
    case aborted(String)
}

final class Sender {
    private var count = 0

    /// Brings the target to the front and types the parts into it (main thread).
    /// The completion runs on the main thread.
    func send(_ parts: [Piece], to target: NSRunningApplication, insertOnly: Bool, completion: @escaping (SendOutcome) -> Void) {
        count += 1
        let no = count
        let pid = target.processIdentifier
        let name = target.localizedName ?? "?"
        let imageFlags = Prefs.imageFlags(target)
        let sendFlags = Prefs.sendFlags(target)
        let snap = ClipboardSnapshot.capture()
        NSApp.yieldActivation(to: target)
        let ok1 = target.activate(from: NSRunningApplication.current, options: [])
        let ok2 = target.activate(options: [.activateIgnoringOtherApps])
        trace("#\(no) start target=\(name)(\(target.bundleIdentifier ?? "-")) insertOnly=\(insertOnly) parts=\(describe(parts)) activate=\(ok1)/\(ok2) wasActive=\(NSApp.isActive)")

        DispatchQueue.global(qos: .userInitiated).async {
            func frontPid() -> pid_t { DispatchQueue.main.sync { NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0 } }
            func frontName() -> String { DispatchQueue.main.sync { NSWorkspace.shared.frontmostApplication?.localizedName ?? "-" } }
            var last = -1
            // Switched away mid-send: the send still goes to the target (the
            // target is taken back to the front), and afterwards you are put
            // back where you went.
            var wentTo: NSRunningApplication?
            func regain() -> Bool {
                if frontPid() == pid { return true }
                let other = DispatchQueue.main.sync { NSWorkspace.shared.frontmostApplication }
                if wentTo == nil, let o = other, o.processIdentifier != getpid() { wentTo = o }
                trace("#\(no) front moved to \(other?.localizedName ?? "-") mid-send: taking \(name) back")
                DispatchQueue.main.sync {
                    NSApp.yieldActivation(to: target)
                    _ = target.activate(options: [.activateIgnoringOtherApps])
                }
                for _ in 0..<30 {
                    usleep(50_000)
                    if frontPid() == pid {
                        usleep(150_000)
                        return true
                    }
                }
                return false
            }
            func finish(_ outcome: SendOutcome) {
                DispatchQueue.main.async {
                    let cc = NSPasteboard.general.changeCount
                    if last < 0 {
                        trace("#\(no) clipboard untouched")
                    } else if cc == last {
                        snap.restore()
                        trace("#\(no) clipboard restored")
                    } else {
                        trace("#\(no) clipboard left alone (changed by someone else: \(cc) != \(last))")
                    }
                    if case .aborted(let why) = outcome { trace("#\(no) abort: \(why)") }
                    completion(outcome)
                }
            }

            // Keys only once the target is really in front; else they land nowhere.
            let t0 = Date()
            var front = false
            for _ in 0..<30 {
                usleep(50_000)
                if frontPid() == pid { front = true; break }
            }
            trace("#\(no) front=\(front) after \(Int(Date().timeIntervalSince(t0) * 1000))ms (\(frontName()))")
            guard front else { finish(.aborted("\(name) 没能切到前面")); return }
            usleep(150_000)
            trace("#\(no) before: \(axFocus(pid))")
            for (i, p) in parts.enumerated() {
                guard regain() else { finish(.aborted("发送中途切走后，\(name) 没能切回前面")); return }
                switch p {
                case .text(let s):
                    last = DispatchQueue.main.sync { put(string: s) }
                    postKey(keyV, .maskCommand)
                    usleep(300_000)
                    trace("#\(no) part \(i) text \(s.count) \"\(preview(s))\" ⌘V -> \(axFocus(pid))")
                case .image(let png):
                    last = DispatchQueue.main.sync { put(png: png) }
                    postKey(keyV, imageFlags)
                    // Time to take the picture in (a terminal may send it on over the network).
                    usleep(useconds_t(1_500_000 + Double(png.count) / 1_048_576 * 300_000))
                    trace("#\(no) part \(i) image \(png.count / 1024)KB \(imageFlags == .maskControl ? "⌃V" : "⌘V") -> \(axFocus(pid))")
                }
            }
            if !insertOnly {
                guard regain() else { finish(.aborted("回车前 \(name) 没能切回前面")); return }
                usleep(100_000)
                postKey(keyReturn, sendFlags)
                trace("#\(no) \(sendFlags == .maskCommand ? "⌘Return" : "Return")")
            }
            usleep(300_000)
            finish(.sent(returnTo: wentTo))
        }
    }
}
