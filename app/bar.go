package main

// The input box: called up with ⌃⌥⌘I, it is a native text area (the Mac's
// input methods, ordinary editing) whose message goes to the terminal in front
// in Ghostty (ghostty.go). Enter sends, Shift+Enter starts a new line, ⌘V of a
// picture or a picture dropped on the box attaches it. Each Ghostty terminal
// keeps its own draft; a program inside a terminal (herdr's tabs, say) is not
// known here, so its draft stays whatever is in front of it.

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/egoist/mygo"
	"github.com/egoist/mygo/transfer"
	"github.com/egoist/mygo/ui"
)

const (
	barShortcut = "Ctrl+Alt+Cmd+I"
	barWidth    = 680
	barHeight   = 210
	pictureMax  = 20 << 20
)

type picture struct {
	PNG   []byte
	Thumb *ui.Bitmap
}

type draft struct {
	text string
	pics []picture
}

type bar struct {
	win *mygo.Window
	// All below is the main thread's (the view, and win.Update from goroutines).
	text     string
	prev     string // text as of the last build, to tell Enter from a line break typed
	pics     []picture
	target   target
	terr     string            // why no terminal could be read
	drafts   map[string]*draft // by Ghostty terminal ID
	status   string
	bad      bool
	busy     bool
	focus    bool
	quitting bool // the app is quitting: the window lets itself close
	// probe and deliver reach Ghostty, update runs on the main thread (the
	// window's Update); tests replace them.
	update  func(func())
	probe   func() (target, error)
	deliver func(id, text string, pictures [][]byte) error
}

func newBar() *bar {
	return &bar{drafts: map[string]*draft{}, probe: probe, deliver: deliver}
}

func (b *bar) create() {
	b.win = mygo.NewWindow(mygo.WindowOptions{
		Title: "InputBar", Width: barWidth, Height: barHeight, Hidden: true, Frameless: true,
		Transparent: true, Vibrancy: mygo.VibrancyPopover,
		DisableResize: true, DisableMinimize: true, DisableMaximize: true,
		DisableFullScreen: true, AlwaysOnTop: true, SkipTaskbar: true,
		Content: ui.View(b.view),
	})
	b.update = b.win.Update
	b.win.SetVisibleOnAllWorkspaces(true)
	// Like Spotlight: clicking elsewhere puts it away; the draft stays.
	b.win.OnBlur(func() { b.win.Hide() })
	b.win.OnClose(func(e *mygo.CloseEvent) {
		// A window refusing to close calls the app's quit off: only while running.
		if !b.quitting {
			e.PreventDefault()
			b.win.Hide()
		}
	})
}

// Toggle shows the box at the bottom of the screen the pointer is on, or
// puts it away.
func (b *bar) Toggle() {
	if b.win.IsVisible() && b.win.IsFocused() {
		b.win.Hide()
		return
	}
	area := mygo.Screen.DisplayNearestPoint(mygo.Screen.CursorScreenPoint()).WorkArea
	bounds := b.win.Bounds()
	b.win.SetPosition(area.X+(area.Width-bounds.Width)/2, area.Y+area.Height-bounds.Height-90)
	b.focus = true
	b.win.Show()
	mygo.App.Focus()
	b.win.Focus()
	go func() {
		t, err := b.probe()
		b.update(func() { b.setTarget(t, err) })
	}()
}

// setTarget switches to the draft of the terminal now in front (main thread).
func (b *bar) setTarget(t target, err error) {
	b.terr = ""
	if err != nil {
		b.terr = err.Error()
		return
	}
	if t.ID != b.target.ID {
		if b.target.ID != "" || b.text != "" || len(b.pics) > 0 {
			b.drafts[b.target.ID] = &draft{text: b.text, pics: b.pics}
		}
		d := b.drafts[t.ID]
		if d == nil && b.target.ID == "" {
			// Written before any terminal was known: it goes with the first one.
			d = &draft{text: b.text, pics: b.pics}
		}
		delete(b.drafts, t.ID)
		if d == nil {
			d = &draft{}
		}
		b.text, b.prev, b.pics = d.text, d.text, d.pics
	}
	b.target = t
	if !b.busy {
		b.status, b.bad = "", false
	}
}

// Send types the message into the terminal in front, if it is still the one
// the box was opened for (main thread). The box goes away once it is sent.
func (b *bar) Send() {
	text := strings.TrimRight(b.text, "\n")
	if b.busy || (strings.TrimSpace(text) == "" && len(b.pics) == 0) {
		return
	}
	if b.target.ID == "" {
		b.status, b.bad = "还不知道发给哪个终端："+b.terr, true
		return
	}
	pics := make([][]byte, len(b.pics))
	for i, p := range b.pics {
		pics[i] = p.PNG
	}
	b.busy, b.bad, b.status = true, false, "发送中…"
	if len(pics) > 0 {
		b.status = fmt.Sprintf("发送中…（%d 张图片，每张约 1.5 秒）", len(pics))
	}
	id, sentText, sentPics := b.target.ID, b.text, len(b.pics)
	go func() {
		err := b.deliver(id, strings.ReplaceAll(text, "\r\n", "\n"), pics)
		b.update(func() {
			b.busy = false
			if err != nil {
				b.status, b.bad = "没发出去："+err.Error(), true
				return
			}
			b.status, b.bad = "", false
			if b.target.ID == id && b.text == sentText {
				b.text, b.prev = "", ""
			}
			if b.target.ID == id && len(b.pics) >= sentPics {
				b.pics = b.pics[sentPics:]
			}
			if b.win != nil {
				b.win.Hide()
			}
		})
	}()
}

func (b *bar) attach(data []byte) {
	if len(data) > pictureMax {
		b.status, b.bad = fmt.Sprintf("图片超过 %d MB，没附上", pictureMax>>20), true
		return
	}
	p, err := asPNG(data)
	if err != nil {
		b.status, b.bad = "没附上："+err.Error(), true
		return
	}
	thumb, _ := ui.DecodeBitmap(p)
	b.pics = append(b.pics, picture{PNG: p, Thumb: thumb})
	b.status, b.bad = "", false
	b.focus = true
}

// Pasted runs for the Edit menu's Paste (⌘V): while the box has the
// keyboard, a picture on the clipboard with no text is attached and it reports
// true; otherwise the caller pastes as usual. Main thread.
func (b *bar) Pasted() bool {
	if b.win == nil || !b.win.IsVisible() || !b.win.IsFocused() {
		return false
	}
	formats := mygo.Clipboard.Formats()
	has := func(f transfer.Format) bool {
		for _, x := range formats {
			if x == f {
				return true
			}
		}
		return false
	}
	if has(transfer.Text) || !has(transfer.PNG) {
		return false
	}
	defer b.win.Invalidate()
	data, err := mygo.Clipboard.ReadFormat(transfer.PNG)
	if err != nil || len(data) == 0 {
		b.status, b.bad = "剪贴板里的图片读不出来", true
		return true
	}
	b.attach(data)
	return true
}

func (b *bar) dropped(paths []string) {
	for _, path := range paths {
		info, err := os.Stat(path)
		if err != nil || info.IsDir() {
			b.status, b.bad = "只能附图片："+filepath.Base(path), true
			continue
		}
		if info.Size() > pictureMax {
			b.status, b.bad = fmt.Sprintf("%s 超过 %d MB", filepath.Base(path), pictureMax>>20), true
			continue
		}
		data, err := os.ReadFile(path)
		if err == nil {
			b.attach(data)
		}
	}
}

// enterTyped reports whether after is before with one line break typed into
// it, and gives before back: the text area takes Enter for a new line, so a
// plain Enter is told apart this way (and Shift by shiftHeld).
func enterTyped(before, after string) (string, bool) {
	if len(after) != len(before)+1 {
		return "", false
	}
	i := 0
	for i < len(before) && before[i] == after[i] {
		i++
	}
	if after[i] != '\n' || after[i+1:] != before[i:] {
		return "", false
	}
	return before, true
}

func (b *bar) view(c *ui.Context) {
	t := c.Theme()
	if c.Shortcut(0, ui.KeyEscape) && b.win != nil {
		b.win.Hide()
	}
	if c.Vibrancy() {
		c.Root().Background(t.Background.Alpha(0.9))
	}
	root := ui.Column(c).Fill().Padding(12).Gap(8)
	if files := root.DroppedFiles(); len(files) > 0 {
		b.dropped(files)
	}
	root.Children(func() {
		b.header(c)
		box := ui.Column(c).Grow(1).Radius(9).Padding(8, 10).Background(t.Text.Alpha(0.06))
		if root.FileDragOver() {
			box.Background(t.Accent.Alpha(0.12)).Border(1.5, t.Accent)
		}
		box.Children(func() {
			area := ui.TextAreaBase(c, &b.text).Placeholder("写要发给终端的内容…").Label("输入框").FontSize(14).Grow(1)
			if b.focus {
				b.focus = false
				area.Focus()
			}
			if area.Changed() {
				if before, ok := enterTyped(b.prev, b.text); ok && !shiftHeld() {
					b.text = before
					b.Send()
				}
			}
			if area.Shortcut(ui.Cmd, ui.KeyEnter) {
				b.Send()
			}
		})
		if len(b.pics) > 0 {
			b.pictures(c)
		}
		ui.Row(c).Gap(8).AlignItems(ui.Center).Children(func() {
			color := t.TextMuted
			hint := "回车发送 · Shift+回车换行 · ⌘V 贴图 · 拖入图片 · Esc 收起"
			if b.status != "" {
				hint = b.status
				if b.bad {
					color = t.Danger
				}
			}
			ui.Text(c, hint).FontSize(11).TextColor(color).Grow(1).Shrink(1).SingleLine().Ellipsis("…").Tooltip(hint)
			ok := !b.busy && b.target.ID != "" && (strings.TrimSpace(b.text) != "" || len(b.pics) > 0)
			if ghost(c, "发送", nil, t.Accent).Disabled(!ok).Tooltip("回车或 ⌘回车").Clicked() {
				b.Send()
			}
		})
	})
	b.prev = b.text
}

// header: which terminal the message goes to, by its Ghostty window title.
func (b *bar) header(c *ui.Context) {
	t := c.Theme()
	dot, label := t.TextMuted, "读取 Ghostty 当前终端…"
	switch {
	case b.terr != "":
		dot, label = t.Danger, b.terr
	case b.target.ID != "":
		dot, label = t.Success, "发到 Ghostty · "+b.target.Title
		if strings.TrimSpace(b.target.Title) == "" {
			label = "发到 Ghostty 当前终端"
		}
	}
	ui.Row(c).Gap(7).AlignItems(ui.Center).PaddingX(2).Children(func() {
		ui.Box(c).Size(7, 7).Radius(4).Background(dot).Shrink(0)
		ui.Text(c, label).FontSize(12).FontWeight(500).Grow(1).Shrink(1).SingleLine().Ellipsis("…").Tooltip(label)
		ui.Text(c, "⌃⌥⌘I").FontSize(10.5).TextColor(t.TextMuted).Shrink(0)
	})
}

func (b *bar) pictures(c *ui.Context) {
	t := c.Theme()
	ui.Row(c).Gap(6).AlignItems(ui.Center).Children(func() {
		for i, p := range b.pics {
			c := c.Key(i)
			ui.Row(c).Gap(5).AlignItems(ui.Center).Height(30).PaddingX(4).Radius(7).Background(t.Text.Alpha(0.07)).Children(func() {
				if p.Thumb != nil {
					ui.Image(c, p.Thumb).Size(22, 22).Radius(4)
				}
				ui.Text(c, fmt.Sprintf("图片 %d", i+1)).FontSize(11).SingleLine()
				if ghost(c, "", closeIcon, t.TextMuted).Height(20).PaddingX(3).Tooltip("去掉").Clicked() {
					b.pics = append(b.pics[:i:i], b.pics[i+1:]...)
				}
			})
		}
	})
}

var closeIcon = ui.MustParseSVG([]byte(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round"><path d="M4.5 4.5l7 7M11.5 4.5l-7 7"/></svg>`))

// ghost is a quiet button: text (and icon) with a fill only under the pointer.
func ghost(c *ui.Context, label string, glyph *ui.SVG, color ui.Color) ui.Element {
	t := c.Theme()
	b := ui.ButtonBase(c).Height(26).PaddingX(8).Radius(6).Label(label)
	if label == "" {
		b.Label("去掉")
	}
	if b.Hovered() {
		b.Background(t.Text.Alpha(0.08))
	}
	b.Children(func() {
		ui.Row(c).Gap(5).AlignItems(ui.Center).Children(func() {
			if glyph != nil {
				ui.Icon(c, glyph).Size(13, 13).TextColor(color)
			}
			if label != "" {
				ui.Text(c, label).FontSize(12).TextColor(color)
			}
		})
	})
	return b
}
