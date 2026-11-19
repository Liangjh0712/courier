import AppKit
import CourierKit

/// Where a send goes: the app in front, the last other than Courier, unless
/// locked. An app counts only once its frontmost window is an ordinary one, so
/// a screenshot tool, a recorder's toolbar or a notification that brings its
/// app forward with an overlay does not take the target.
final class TargetTracker {
    private(set) var app: NSRunningApplication?
    var onChange: (() -> Void)?
    var locked = false {
        didSet {
            trace("lock=\(locked) target=\(app?.localizedName ?? "-")")
            // Kept across restarts.
            UserDefaults.standard.set(locked ? app?.bundleIdentifier : nil, forKey: "lockedApp")
            onChange?()
        }
    }
    private var skipped: pid_t = 0

    /// Picked by hand: goes there until unlocked.
    func pin(_ a: NSRunningApplication) {
        app = a
        trace("pinned \(a.localizedName ?? "?")")
        locked = true
    }

    func start() {
        if let id = UserDefaults.standard.string(forKey: "lockedApp"),
           let a = NSRunningApplication.runningApplications(withBundleIdentifier: id).first {
            app = a
            trace("restored lock on \(a.localizedName ?? id)")
            locked = true
        }
        let timer = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in self?.follow() }
        RunLoop.main.add(timer, forMode: .common)
        follow()
    }

    func follow() {
        if let a = app, a.isTerminated {
            trace("target \(a.localizedName ?? "?") quit")
            app = nil
            locked = false
            onChange?()
        }
        guard !locked, let f = NSWorkspace.shared.frontmostApplication, f.processIdentifier != getpid(),
              f.processIdentifier != app?.processIdentifier else { return }
        let layer = topWindowLayer(f.processIdentifier)
        guard layer == 0 else {
            if skipped != f.processIdentifier {
                trace("skip \(f.localizedName ?? "?") layer=\(layer.map(String.init) ?? "none")")
                skipped = f.processIdentifier
            }
            return
        }
        skipped = 0
        trace("target -> \(f.localizedName ?? "?")")
        app = f
        onChange?()
    }
}

/// The layer of an app's frontmost on-screen window (0 = ordinary), nil when
/// it shows none. Layer and owner need no screen recording permission.
func topWindowLayer(_ pid: pid_t) -> Int? {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
    for w in list where (w[kCGWindowOwnerPID as String] as? Int32) == pid {
        if let a = w[kCGWindowAlpha as String] as? Double, a == 0 { continue }
        if let b = w[kCGWindowBounds as String] as? [String: Double], (b["Width"] ?? 0) < 50 || (b["Height"] ?? 0) < 50 { continue }
        return w[kCGWindowLayer as String] as? Int
    }
    return nil
}
