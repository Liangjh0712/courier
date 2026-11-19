import AppKit

// Courier: write in a floating box, send into whatever app is in front.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
