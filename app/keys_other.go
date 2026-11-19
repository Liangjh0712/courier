//go:build !darwin

package main

// The preview and tests run on Linux, where no key is held and there is no
// responder chain.
func shiftHeld() bool { return false }

func nativePaste() {}
