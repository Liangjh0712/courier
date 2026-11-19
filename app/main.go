// InputBar: a box for writing to the terminal, called up anywhere with
// ⌃⌥⌘I. The message is written in a native text field, with the Mac's input
// methods and editing, and typed into the terminal in front in Ghostty through
// Ghostty's AppleScript dictionary; pictures go by the clipboard and Ctrl+V.
// It has no menu bar icon and no window besides the box; it starts at login.
// ⌘Q while the box is open quits it.
package main

import (
	"log"

	"github.com/egoist/mygo"
)

func main() {
	b := newBar()
	mygo.App.SetName("InputBar")
	mygo.App.SetActivationPolicy(mygo.ActivationPolicyAccessory)
	mygo.App.OnBeforeQuit(func(*mygo.QuitEvent) { b.quitting = true })
	mygo.App.WhenReady(func() {
		b.create()
		mygo.App.SetMenu(appMenu(b))
		if err := mygo.GlobalShortcut.Register(barShortcut, b.Toggle); err != nil {
			log.Print("shortcut ⌃⌥⌘I: ", err)
		}
		if !mygo.App.OpenAtLogin() {
			if err := mygo.App.SetOpenAtLogin(true); err != nil {
				log.Print("login item: ", err)
			}
		}
	})
	if err := mygo.App.Run(); err != nil {
		log.Fatal(err)
	}
}

// appMenu is mygo's default menu (its Edit commands are what ⌘C, ⌘V, … do in
// the text field), except Paste: mygo hands a role item to AppKit, which sends
// paste: to the field without Go seeing it, so Paste is an item of ours that
// first takes a clipboard picture as an attachment.
func appMenu(b *bar) *mygo.Menu {
	return mygo.NewMenu([]*mygo.MenuItem{
		{Role: mygo.RoleAppMenu},
		{Role: mygo.RoleEditMenu, Submenu: []*mygo.MenuItem{
			{Role: mygo.RoleUndo},
			{Role: mygo.RoleRedo},
			mygo.Separator(),
			{Role: mygo.RoleCut},
			{Role: mygo.RoleCopy},
			{Label: "Paste", Accelerator: "CmdOrCtrl+V", Click: func(*mygo.MenuItem, *mygo.Window) {
				if !b.Pasted() {
					nativePaste()
				}
			}},
			{Role: mygo.RoleSelectAll},
			mygo.Separator(),
			// ⌘↑ ⌘↓ walk through what was sent; the text area takes the bare arrows.
			{Label: "上一条", Accelerator: "CmdOrCtrl+Up", Click: func(*mygo.MenuItem, *mygo.Window) { b.recallKey(-1) }},
			{Label: "下一条", Accelerator: "CmdOrCtrl+Down", Click: func(*mygo.MenuItem, *mygo.Window) { b.recallKey(+1) }},
		}},
	})
}
