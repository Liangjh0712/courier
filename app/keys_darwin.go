//go:build darwin

package main

import (
	"sync"

	"github.com/ebitengine/purego"
	"github.com/ebitengine/purego/objc"
)

var shiftState struct {
	once  sync.Once
	flags func(state int32) uint64
}

// shiftHeld reports whether Shift is down now, from CoreGraphics through
// purego (the app is built without cgo): the text area types a line break for
// Enter and Shift+Enter alike, and only Enter sends.
func shiftHeld() bool {
	shiftState.once.Do(func() {
		cg, err := purego.Dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", purego.RTLD_NOW|purego.RTLD_GLOBAL)
		if err == nil {
			purego.RegisterLibFunc(&shiftState.flags, cg, "CGEventSourceFlagsState")
		}
	})
	if shiftState.flags == nil {
		return false
	}
	const combinedSessionState, maskShift = 0, 0x00020000
	return shiftState.flags(combinedSessionState)&maskShift != 0
}

// nativePaste sends paste: down the responder chain, as the Edit menu's Paste
// role would, so the focused text field pastes the clipboard's text.
func nativePaste() {
	app := objc.ID(objc.GetClass("NSApplication")).Send(objc.RegisterName("sharedApplication"))
	app.Send(objc.RegisterName("sendAction:to:from:"), objc.RegisterName("paste:"), objc.ID(0), objc.ID(0))
}
