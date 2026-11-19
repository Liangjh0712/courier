# Courier

A macOS app (Swift, SwiftPM): a floating box to write in, sending text and pictures into the frontmost app by clipboard + synthesized paste keys.

## Layout

- `Sources/CourierKit`: pure logic with tests (draft pieces and markers, saved state, history, log).
- `Sources/Courier`: the app (AppKit).
- `Tests/CourierKitTests`: `swift test`.
- `scripts/build.sh`: build the .app on a Mac, `--install` to replace ~/Applications/Courier.app.

## Things learned the hard way

- The box is a non-activating NSPanel: clicking into it leaves the other app in front, so the target stays put. Making it key from code while the app is in the back makes it look key but the keyboard stays with the front app: after a send the app activates itself (NSApp.activate) to take the keyboard.
- Before typing into the target, wait until it is really frontmost; keys posted while nothing of ours or theirs is key are lost. Stop when the front changes mid-send.
- Activating the target from our app needs `NSApp.yieldActivation(to:)` first, then `activate(from:options:)`.
- Snapshot only text-like clipboard types; reading lazily provided types of other apps can block.
- Screenshot tools and recorders bring their app to the front with an overlay window (layer > 0). The target follows the front app only when its frontmost window is at layer 0.
- `Picture` collides with a type in the macOS 27 SDK; the draft picture type is `DraftImage`.
- In an IME composition, Enter belongs to the input method: check `hasMarkedText()` before treating Enter as send.
