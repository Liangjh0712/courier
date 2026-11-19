package main

// The input box: called up with ⌃⌥⌘I, a native text area (the Mac's input
// methods, ordinary editing) whose message goes to the terminal in front in
// Ghostty (ghostty.go). It sits where the user dragged it last (by its top
// strip), follows the system's light or dark appearance, and grows with what
// is written, up to ten lines. Enter sends, Shift+Enter starts a new line,
// ⌥Enter only types the text in (no Enter); ⌘↑ and ⌘↓ walk through what was
// sent before; ⌘K clears the draft (撤销 brings it back for a few seconds). ⌘V of a picture or a picture dropped on the box attaches it.
// A picture sits in the text as "[图片N]" where it was pasted, and the
// message goes in that order. Each Ghostty terminal keeps its own draft; what runs inside a terminal (a
// multiplexer's tabs, say) is not known here.

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/egoist/mygo"
	"github.com/egoist/mygo/transfer"
	"github.com/egoist/mygo/ui"
)

const (
	barShortcut  = "Ctrl+Alt+Cmd+I"
	barWidth     = 680
	barMinHeight = 96
	pictureMax   = 20 << 20
	historyMax   = 50
	thumbSize    = 56
	textMaxLines = 10
	toastFor     = 1500 * time.Millisecond
	undoFor      = 6 * time.Second
)

// picture is an attachment. It sits in the text as its marker, "[图片N]"
// with N its ID, where it was pasted: the message is sent in that order.
type picture struct {
	ID    int
	PNG   []byte
	Thumb *ui.Bitmap
}

func marker(id int) string { return fmt.Sprintf("[图片%d]", id) }

var markerRE = regexp.MustCompile(`\[图片(\d+)\]`)

// pieces splits the text at the markers of its pictures, in order; pictures
// whose marker was deleted from the text go last, so none is lost. A marker
// without its picture stays text.
func pieces(text string, pics []picture) []segment {
	byID := map[int][]byte{}
	for _, p := range pics {
		byID[p.ID] = p.PNG
	}
	var out []segment
	used := map[int]bool{}
	last := 0
	for _, m := range markerRE.FindAllStringSubmatchIndex(text, -1) {
		id, _ := strconv.Atoi(text[m[2]:m[3]])
		png, ok := byID[id]
		if !ok || used[id] {
			continue
		}
		if m[0] > last {
			out = append(out, segment{Text: text[last:m[0]]})
		}
		out = append(out, segment{Picture: png})
		used[id] = true
		last = m[1]
	}
	if last < len(text) {
		out = append(out, segment{Text: text[last:]})
	}
	for _, p := range pics {
		if !used[p.ID] {
			out = append(out, segment{Picture: p.PNG})
		}
	}
	return out
}

type draft struct {
	text string
	pics []picture
}

type bar struct {
	win   *mygo.Window
	toast *mygo.Window // "已发送" for a moment where the box was
	// All below is the main thread's (the view, and update from goroutines).
	text     string
	prev     string // text as of the last build, to tell Enter from a line break typed
	pics     []picture
	target   target
	terr     string            // why no terminal could be read
	drafts   map[string]*draft // by Ghostty terminal ID
	history  []string          // what was sent, oldest first
	hist     int               // the history entry shown, len(history) for none
	stash    string            // the draft put aside while walking the history
	status   string
	bad      bool
	retry    bool // the failure was a send: offer to send again
	busy     bool
	sent     int       // pictures of the current send already typed in
	flash    time.Time // "已发送" shows in the strip until then (pinned box)
	focus    bool
	pinned   bool      // stays up after sending and when clicked away from
	preview  int       // the picture shown large, -1 for none
	height   int       // the window height last set
	sel      [2]int    // the text area's selection last frame, in runes
	caret    int       // put the caret here next frame (runes), -1 for no move
	cleared  *draft    // what ⌘K cleared, for 撤销
	undoBy   time.Time // 撤销 is offered until then
	quitting bool
	// probe and deliver reach Ghostty, update runs on the main thread (the
	// window's Update); tests replace them.
	probe   func() (target, error)
	deliver func(id string, pieces []segment, insert bool, done func(int)) error
	update  func(func())
}

func configDir() string {
	dir, err := os.UserConfigDir()
	if err != nil {
		dir = os.TempDir()
	}
	return filepath.Join(dir, "InputBar")
}

func newBar() *bar {
	return &bar{drafts: map[string]*draft{}, probe: probe, deliver: deliver, preview: -1, caret: -1}
}

func (b *bar) create() {
	b.win = mygo.NewWindow(mygo.WindowOptions{
		Title: "InputBar", Width: barWidth, Height: barMinHeight, Hidden: true, Frameless: true,
		Transparent: true, Vibrancy: mygo.VibrancyPopover, StateKey: "bar",
		MinWidth: 420, MaxWidth: 1600,
		DisableMinimize: true, DisableMaximize: true, DisableFullScreen: true,
		AlwaysOnTop: true, SkipTaskbar: true,
		Content: ui.View(b.view),
	})
	b.update = b.win.Update
	b.win.SetVisibleOnAllWorkspaces(true)
	b.win.OnBlur(func() {
		if !b.pinned {
			b.win.Hide()
		}
	})
	b.win.OnClose(func(e *mygo.CloseEvent) {
		// A window refusing to close calls the app's quit off: only while running.
		if !b.quitting {
			e.PreventDefault()
			b.win.Hide()
		}
	})
	b.toast = mygo.NewWindow(mygo.WindowOptions{
		Title: "InputBar 已发送", Width: 150, Height: 40, Hidden: true, Frameless: true,
		Transparent: true, DisableResize: true, DisableMove: true, DisableMinimize: true,
		DisableMaximize: true, DisableFullScreen: true, DisableShadow: true, AlwaysOnTop: true,
		SkipTaskbar: true, Content: ui.View(b.toastView),
	})
	b.toast.SetVisibleOnAllWorkspaces(true)
	b.toast.SetIgnoreMouseEvents(true)
	b.toast.OnClose(func(e *mygo.CloseEvent) {
		if !b.quitting {
			e.PreventDefault()
		}
	})
}

// Toggle shows the box where it was last (the bottom of the screen the
// first time), or puts it away.
func (b *bar) Toggle() {
	if b.win.IsVisible() && b.win.IsFocused() {
		b.win.Hide()
		return
	}
	if b.height == 0 {
		bounds := b.win.Bounds()
		b.height = bounds.Height
		// The very first time: the bottom middle of the screen the pointer is
		// on. After that the window state (StateKey) has where it was dragged.
		marker := filepath.Join(configDir(), "placed")
		if _, err := os.Stat(marker); err != nil {
			area := mygo.Screen.DisplayNearestPoint(mygo.Screen.CursorScreenPoint()).WorkArea
			b.win.SetPosition(area.X+(area.Width-bounds.Width)/2, area.Y+area.Height-bounds.Height-90)
			if os.MkdirAll(filepath.Dir(marker), 0o700) == nil {
				_ = os.WriteFile(marker, nil, 0o600)
			}
		}
	}
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
		b.text, b.prev, b.pics, b.preview = d.text, d.text, d.pics, -1
		b.hist = len(b.history)
	}
	b.target = t
	if !b.busy && !b.retry {
		b.status, b.bad = "", false
	}
}

// Send types the message into the terminal in front, if it is still the one
// the box was opened for (main thread); insert leaves out the Enter. Unless
// pinned, the box goes away once it is sent and "已发送" shows a moment.
func (b *bar) Send(insert bool) {
	text := strings.TrimRight(b.text, "\n")
	if b.busy || (strings.TrimSpace(text) == "" && len(b.pics) == 0) {
		return
	}
	if b.target.ID == "" {
		b.status, b.bad, b.retry = "还不知道发给哪个终端："+b.terr, true, false
		return
	}
	parts := pieces(strings.ReplaceAll(text, "\r\n", "\n"), b.pics)
	b.busy, b.bad, b.retry, b.sent, b.preview = true, false, false, 0, -1
	b.status = "发送中…"
	id, sentText, sentPics := b.target.ID, b.text, len(b.pics)
	go func() {
		err := b.deliver(id, parts, insert, func(n int) {
			b.update(func() { b.sent = n })
		})
		b.update(func() {
			b.busy = false
			if err != nil {
				b.status, b.bad, b.retry = "没发出去："+err.Error(), true, true
				return
			}
			b.status, b.bad = "", false
			if plain := strings.TrimSpace(markerRE.ReplaceAllString(text, "")); plain != "" {
				b.remember(plain)
			}
			if b.target.ID == id && b.text == sentText {
				b.text, b.prev = "", ""
			}
			if b.target.ID == id && len(b.pics) >= sentPics {
				b.pics = b.pics[sentPics:]
			}
			b.hist = len(b.history)
			b.sentFeedback(insert)
		})
	}()
}

// Clear empties the draft (⌘K or the bin in the strip); 撤销 brings it
// back for a few seconds, as long as nothing new was written.
func (b *bar) Clear() {
	if b.busy || (b.text == "" && len(b.pics) == 0) {
		return
	}
	b.cleared = &draft{text: b.text, pics: b.pics}
	b.text, b.prev, b.pics, b.preview = "", "", nil, -1
	b.hist = len(b.history)
	b.undoBy = time.Now().Add(undoFor)
	b.status, b.bad, b.retry = "", false, false
	b.focus = true
	if b.update != nil {
		time.AfterFunc(undoFor, func() { b.update(func() {}) })
	}
}

// canUndo: a clear is recent and the box is still empty.
func (b *bar) canUndo() bool {
	return b.cleared != nil && time.Now().Before(b.undoBy) && b.text == "" && len(b.pics) == 0
}

func (b *bar) Undo() {
	if !b.canUndo() {
		return
	}
	b.text, b.prev, b.pics = b.cleared.text, b.cleared.text, b.cleared.pics
	b.cleared = nil
	b.focus = true
}

// remember keeps what was sent for ⌘↑, the latest last, without repeats.
func (b *bar) remember(text string) {
	for i, h := range b.history {
		if h == text {
			b.history = append(b.history[:i], b.history[i+1:]...)
			break
		}
	}
	b.history = append(b.history, text)
	if len(b.history) > historyMax {
		b.history = b.history[len(b.history)-historyMax:]
	}
}

// Recall walks the history: -1 for older, +1 for newer (⌘↑, ⌘↓). It works
// while the box is empty or shows a history entry, so a draft is never lost;
// coming back past the newest entry brings the draft back.
func (b *bar) Recall(step int) {
	if b.busy || len(b.history) == 0 {
		return
	}
	browsing := b.hist < len(b.history) && b.text == b.history[b.hist]
	if !browsing {
		if strings.TrimSpace(b.text) != "" && step < 0 {
			return
		}
		b.stash, b.hist = b.text, len(b.history)
	}
	n := b.hist + step
	switch {
	case n < 0:
		return
	case n >= len(b.history):
		b.hist, b.text = len(b.history), b.stash
	default:
		b.hist, b.text = n, b.history[n]
	}
	b.prev = b.text
	b.focus = true
}

// recallKey is ⌘↑ / ⌘↓ from the menu, for the box when it has the keyboard.
func (b *bar) recallKey(step int) {
	if b.win == nil || !b.win.IsVisible() || !b.win.IsFocused() {
		return
	}
	b.Recall(step)
	b.win.Invalidate()
}

func (b *bar) sentFeedback(insert bool) {
	if b.win == nil {
		return
	}
	if b.pinned {
		b.flash = time.Now().Add(toastFor)
		time.AfterFunc(toastFor, func() { b.update(func() {}) })
		return
	}
	box := b.win.Bounds()
	b.win.Hide()
	label := "已发送"
	if insert {
		label = "已插入"
	}
	b.status = label
	t := b.toast.Bounds()
	b.toast.SetPosition(box.X+(box.Width-t.Width)/2, box.Y+box.Height-t.Height)
	b.toast.Invalidate()
	b.toast.ShowInactive()
	time.AfterFunc(toastFor, func() {
		b.update(func() {
			b.toast.Hide()
			if b.status == label {
				b.status = ""
			}
		})
	})
}

func (b *bar) attach(data []byte) {
	if len(data) > pictureMax {
		b.status, b.bad, b.retry = fmt.Sprintf("图片超过 %d MB，没附上", pictureMax>>20), true, false
		return
	}
	p, err := asPNG(data)
	if err != nil {
		b.status, b.bad, b.retry = "没附上："+err.Error(), true, false
		return
	}
	thumb, _ := ui.DecodeBitmap(p)
	id := 1
	for _, q := range b.pics {
		id = max(id, q.ID+1)
	}
	b.pics = append(b.pics, picture{ID: id, PNG: p, Thumb: thumb})
	// The marker goes where the caret is (over a selection), so text written
	// before and after the picture keeps its place around it.
	runes := []rune(b.text)
	start, end := min(b.sel[0], b.sel[1], len(runes)), min(max(b.sel[0], b.sel[1]), len(runes))
	m := marker(id)
	b.text = string(runes[:start]) + m + string(runes[end:])
	b.prev = b.text
	b.caret = start + len([]rune(m))
	b.sel = [2]int{b.caret, b.caret}
	if !b.retry {
		b.status, b.bad = "", false
	}
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
		b.status, b.bad, b.retry = "剪贴板里的图片读不出来", true, false
		return true
	}
	b.attach(data)
	return true
}

func (b *bar) dropped(paths []string) {
	for _, path := range paths {
		info, err := os.Stat(path)
		if err != nil || info.IsDir() {
			b.status, b.bad, b.retry = "只能附图片："+filepath.Base(path), true, false
			continue
		}
		if info.Size() > pictureMax {
			b.status, b.bad, b.retry = fmt.Sprintf("%s 超过 %d MB", filepath.Base(path), pictureMax>>20), true, false
			continue
		}
		if data, err := os.ReadFile(path); err == nil {
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
		if b.preview >= 0 {
			b.preview = -1
		} else {
			b.win.Hide()
		}
	}
	if c.Vibrancy() {
		c.Root().Background(t.Background.Alpha(0.86))
	}
	// The content keeps its natural height; the window follows it (fit).
	content := ui.Column(c).FillWidth().Padding(6, 12, 12, 12).Gap(8)
	if files := content.DroppedFiles(); len(files) > 0 {
		b.dropped(files)
	}
	content.Children(func() {
		b.strip(c)
		if b.preview >= 0 && b.preview < len(b.pics) {
			b.large(c, b.pics[b.preview])
		}
		if len(b.pics) > 0 {
			b.thumbs(c)
		}
		b.editor(c, content.FileDragOver())
		if b.bad && b.status != "" {
			b.problem(c)
		}
	})
	b.prev = b.text
	b.fit(content.Bounds().H)
}

// fit sets the window to the content's height, keeping its bottom edge where
// it is: the box grows upward, as a chat input does.
func (b *bar) fit(h float32) {
	if b.win == nil || h <= 0 {
		return
	}
	want := max(barMinHeight, int(h+0.5))
	if want == b.height {
		return
	}
	r := b.win.Bounds()
	if r.Height == want {
		b.height = want
		return
	}
	r.Y += r.Height - want
	r.Height = want
	b.height = want
	b.win.SetBounds(r)
}

// strip: the top line and the handle that moves the box. Where the message
// goes, how sending is going, and the pin.
func (b *bar) strip(c *ui.Context) {
	t := c.Theme()
	dot, label := t.TextMuted, "读取 Ghostty 当前终端…"
	switch {
	case b.terr != "":
		dot, label = t.Danger, b.terr
	case b.target.ID != "":
		dot, label = t.Success, "Ghostty · "+b.target.Title
		if strings.TrimSpace(b.target.Title) == "" {
			label = "Ghostty 当前终端"
		}
	}
	row := ui.Row(c).Height(26).Gap(7).AlignItems(ui.Center).PaddingX(2).DragWindow().Cursor(ui.CursorGrab)
	row.Children(func() {
		ui.Box(c).Size(6, 6).Radius(3).Background(dot).Shrink(0)
		ui.Text(c, label).FontSize(11.5).TextColor(t.TextMuted).Grow(1).Shrink(1).SingleLine().Ellipsis("…").Tooltip(label)
		switch {
		case b.busy && len(b.pics) > 0:
			ui.Spinner(c).Size(12, 12)
			ui.Text(c, fmt.Sprintf("发送中 %d/%d 张图片", b.sent, len(b.pics))).FontSize(11).TextColor(t.TextMuted).Shrink(0)
		case b.busy:
			ui.Spinner(c).Size(12, 12)
			ui.Text(c, "发送中").FontSize(11).TextColor(t.TextMuted).Shrink(0)
		case time.Now().Before(b.flash):
			ui.Icon(c, checkIcon).Size(12, 12).TextColor(t.Success)
			ui.Text(c, "已发送").FontSize(11).TextColor(t.Success).Shrink(0)
		case b.canUndo():
			ui.Text(c, "已清空").FontSize(11).TextColor(t.TextMuted).Shrink(0)
			if ghost(c, "撤销", t.Accent).Height(22).Clicked() {
				b.Undo()
			}
		}
		if (b.text != "" || len(b.pics) > 0) && !b.busy {
			if iconButton(c, binIcon, t.TextMuted, "清空草稿（⌘K）", false).Clicked() {
				b.Clear()
			}
		}
		color, tip := t.TextMuted, "钉住：发送后和点别处时都不收起"
		if b.pinned {
			color, tip = t.Accent, "已钉住，点一下取消"
		}
		if iconButton(c, pinIcon, color, tip, b.pinned).Clicked() {
			b.pinned = !b.pinned
			b.focus = true
		}
	})
}

// editor: the text and the two ways to send it.
func (b *bar) editor(c *ui.Context, dragging bool) {
	t := c.Theme()
	card := ui.Row(c).AlignItems(ui.End).Gap(6).Padding(6, 6, 6, 12).Radius(12).Background(t.Text.Alpha(0.055))
	if dragging {
		card.Background(t.Accent.Alpha(0.12)).Border(1.5, t.Accent)
	}
	card.Children(func() {
		area := ui.TextAreaBase(c, &b.text).Placeholder("写给终端…    回车发送 · Shift+回车换行 · ⌥回车只插入 · ⌘↑ 上一条 · ⌘K 清空").
			Label("输入框").FontSize(14).LineHeight(1.5).Lines(1, textMaxLines).Grow(1).Shrink(1).Margin(6, 0, 6, 0)
		if b.focus {
			b.focus = false
			area.Focus()
		}
		if b.caret >= 0 {
			area.SetTextSelection(b.caret, b.caret)
			b.caret = -1
		}
		if s, e := area.TextSelection(); area.Focused() {
			b.sel = [2]int{s, e}
		}
		if area.Changed() {
			if before, ok := enterTyped(b.prev, b.text); ok && !shiftHeld() {
				b.text = before
				b.Send(false)
			}
		}
		if area.Shortcut(ui.Cmd, ui.KeyEnter) {
			b.Send(false)
		}
		if area.Shortcut(ui.Alt, ui.KeyEnter) {
			b.Send(true)
		}
		if area.Shortcut(ui.Cmd, ui.KeyK) {
			b.Clear()
		}
		ready := !b.busy && b.target.ID != "" && (strings.TrimSpace(b.text) != "" || len(b.pics) > 0)
		if iconButton(c, insertIcon, t.TextMuted, "只插入，不回车（⌥回车）", false).Disabled(!ready).Clicked() {
			b.Send(true)
		}
		send := ui.ButtonBase(c).Size(32, 32).Radius(16).Label("发送").Tooltip("发送（回车）").Disabled(!ready).Shrink(0)
		fill := t.Accent
		switch {
		case !ready:
			fill = t.Text.Alpha(0.12)
		case send.Pressed():
			fill = t.Accent.Alpha(0.8)
		case send.Hovered():
			fill = t.Accent.Alpha(0.9)
		}
		send.Background(fill).Children(func() {
			ui.Row(c).Fill().Center().Children(func() {
				color := ui.Hex("#ffffff")
				if !ready {
					color = t.TextMuted
				}
				ui.Icon(c, sendIcon).Size(15, 15).TextColor(color)
			})
		})
		if send.Clicked() {
			b.Send(false)
		}
	})
}

// thumbs: the attached pictures. A click shows one large, × (under the
// pointer) takes it off; while sending, each gets a check once typed in.
func (b *bar) thumbs(c *ui.Context) {
	t := c.Theme()
	ui.Row(c).Gap(8).PaddingX(2).Children(func() {
		for i, p := range b.pics {
			c := c.Key(i)
			cell := ui.ButtonBase(c).Size(thumbSize, thumbSize).Radius(10).Padding(2).Label(marker(p.ID)).
				Tooltip("点一下放大，再点收起")
			if i == b.preview {
				cell.Background(t.Accent)
			}
			hovered := cell.Hovered()
			cell.Children(func() {
				img := ui.Image(c, p.Thumb).Size(thumbSize-4, thumbSize-4).Fit(ui.Cover).Radius(8)
				if b.busy && i >= b.sent {
					img.Opacity(0.45)
				}
				// Its number, as in the marker in the text.
				ui.Box(c).Absolute().Left(4).Bottom(4).Height(16).PaddingX(5).Radius(8).Background(ui.Hex("#000000").Alpha(0.55)).Children(func() {
					ui.Text(c, strconv.Itoa(p.ID)).FontSize(10).FontWeight(600).TextColor(ui.Hex("#ffffff"))
				})
				switch {
				case b.busy && i < b.sent:
					ui.Box(c).Absolute().Right(4).Bottom(4).Size(18, 18).Radius(9).Background(t.Success).Children(func() {
						ui.Row(c).Fill().Center().Children(func() { ui.Icon(c, checkIcon).Size(11, 11).TextColor(ui.Hex("#ffffff")) })
					})
				case b.busy && i == b.sent:
					ui.Box(c).Absolute().Right(4).Bottom(4).Size(18, 18).Children(func() { ui.Spinner(c).Size(16, 16) })
				case hovered && !b.busy:
					x := ui.ButtonBase(c).Absolute().Top(3).Right(3).Size(18, 18).Radius(9).Label("去掉").
						Background(ui.Hex("#000000").Alpha(0.6))
					x.Children(func() {
						ui.Row(c).Fill().Center().Children(func() { ui.Icon(c, closeIcon).Size(10, 10).TextColor(ui.Hex("#ffffff")) })
					})
					if x.Clicked() {
						b.removePicture(i)
						return
					}
				}
			})
			if cell.Clicked() && !b.busy {
				if b.preview == i {
					b.preview = -1
				} else {
					b.preview = i
				}
			}
		}
	})
}

// removePicture takes a picture off, and its marker out of the text.
func (b *bar) removePicture(i int) {
	b.text = strings.ReplaceAll(b.text, marker(b.pics[i].ID), "")
	b.prev = b.text
	b.pics = append(b.pics[:i:i], b.pics[i+1:]...)
	b.preview = -1
}

// large shows a picture at a readable size; Esc or a click closes it.
func (b *bar) large(c *ui.Context, p picture) {
	t := c.Theme()
	w, h := p.Thumb.Size()
	height := float32(240)
	if h > 0 && float32(h) < height {
		height = float32(h)
	}
	_ = w
	box := ui.ButtonBase(c).FillWidth().Height(height).Radius(10).Background(t.Text.Alpha(0.05)).Label("收起大图").Tooltip("点一下收起")
	box.Children(func() { ui.Image(c, p.Thumb).Fill().Fit(ui.Contain).Radius(10) })
	if box.Clicked() {
		b.preview = -1
	}
}

// problem: what went wrong, and a retry when it was the send.
func (b *bar) problem(c *ui.Context) {
	t := c.Theme()
	ui.Row(c).Gap(8).AlignItems(ui.Center).Padding(6, 10).Radius(8).Background(t.Danger.Alpha(0.1)).Children(func() {
		ui.Icon(c, alertIcon).Size(13, 13).TextColor(t.Danger).Shrink(0)
		ui.Text(c, b.status).FontSize(11.5).TextColor(t.Danger).Grow(1).Shrink(1).MaxLines(2).Ellipsis("…").Tooltip(b.status)
		if b.retry && ghost(c, "重试", t.Danger).Disabled(b.busy).Clicked() {
			b.Send(false)
		}
		if ghost(c, "知道了", t.TextMuted).Clicked() {
			b.status, b.bad, b.retry = "", false, false
		}
	})
}

func (b *bar) toastView(c *ui.Context) {
	t := c.Theme()
	label := b.status
	if label == "" {
		label = "已发送"
	}
	ui.Row(c).Fill().Padding(3).Children(func() {
		ui.Row(c).Fill().Gap(7).Center().Radius(17).Background(t.Background.Alpha(0.96)).Border(1, t.Text.Alpha(0.1)).Children(func() {
			ui.Box(c).Size(18, 18).Radius(9).Background(t.Success).Children(func() {
				ui.Row(c).Fill().Center().Children(func() { ui.Icon(c, checkIcon).Size(11, 11).TextColor(ui.Hex("#ffffff")) })
			})
			ui.Text(c, label).FontSize(12.5).FontWeight(500)
		})
	})
}

func svgIcon(shapes string) *ui.SVG {
	return ui.MustParseSVG([]byte(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">` + shapes + `</svg>`))
}

var (
	closeIcon  = svgIcon(`<path d="M4.5 4.5l7 7M11.5 4.5l-7 7"/>`)
	checkIcon  = svgIcon(`<path d="M3.5 8.5l3 3 6-7"/>`)
	sendIcon   = svgIcon(`<path d="M8 13V3.5M4 7.5l4-4 4 4"/>`)
	insertIcon = svgIcon(`<path d="M2.5 8h8M7.5 5l3 3-3 3M13.5 3.5v9"/>`)
	pinIcon    = svgIcon(`<path d="M6 2.5h4M7 2.5v4L4.5 9h7L9 6.5v-4M8 9v4.5"/>`)
	binIcon    = svgIcon(`<path d="M3 4.5h10M6.5 4.5V3h3v1.5M4.5 4.5l.6 8.5h5.8l.6-8.5M7 7v4M9 7v4"/>`)
	alertIcon  = svgIcon(`<circle cx="8" cy="8" r="6"/><path d="M8 5v3.5M8 11v.01"/>`)
)

// iconButton is a small square button with an icon, lit when on.
func iconButton(c *ui.Context, glyph *ui.SVG, color ui.Color, tip string, on bool) ui.Element {
	t := c.Theme()
	b := ui.ButtonBase(c).Size(26, 26).Radius(7).Label(tip).Tooltip(tip).Shrink(0)
	switch {
	case on:
		b.Background(t.Accent.Alpha(0.14))
	case b.Hovered():
		b.Background(t.Text.Alpha(0.08))
	}
	b.Children(func() {
		ui.Row(c).Fill().Center().Children(func() { ui.Icon(c, glyph).Size(14, 14).TextColor(color) })
	})
	return b
}

// ghost is a quiet text button with a fill only under the pointer.
func ghost(c *ui.Context, label string, color ui.Color) ui.Element {
	t := c.Theme()
	b := ui.ButtonBase(c).Height(24).PaddingX(8).Radius(6).Label(label).Shrink(0)
	if b.Hovered() {
		b.Background(t.Text.Alpha(0.08))
	}
	b.Children(func() { ui.Text(c, label).FontSize(11.5).FontWeight(500).TextColor(color) })
	return b
}
