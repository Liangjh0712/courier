package main

import (
	"bytes"
	"errors"
	"image"
	"image/color"
	"image/jpeg"
	"image/png"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/egoist/mygo/ui"
)

func TestEnterTyped(t *testing.T) {
	for _, c := range []struct {
		before, after string
		ok            bool
	}{
		{"你好", "你好\n", true},
		{"ab", "a\nb", true},
		{"", "\n", true},
		{"ab", "ab\n\n", false},
		{"ab", "abc", false},
		{"ab", "ab\nc", false},
		{"a\nb", "a\nb\n", true},
	} {
		got, ok := enterTyped(c.before, c.after)
		if ok != c.ok || (ok && got != c.before) {
			t.Errorf("enterTyped(%q, %q) = %q, %v", c.before, c.after, got, ok)
		}
	}
}

func TestScriptError(t *testing.T) {
	err := errors.New("exit status 1")
	if got := scriptError("0:120: execution error: Ghostty 没有在运行 (1001)\n", err).Error(); got != "Ghostty 没有在运行" {
		t.Fatal(got)
	}
	if got := scriptError("execution error: Not authorized to send Apple events to Ghostty. (-1743)", err).Error(); got[:len("没有控制 Ghostty 的权限")] != "没有控制 Ghostty 的权限" {
		t.Fatal(got)
	}
	if got := scriptError("", err).Error(); got != "exit status 1" {
		t.Fatal(got)
	}
}

func testBar() *bar {
	b := newBar()
	b.update = func(fn func()) { fn() }
	return b
}

func TestDraftsFollowTerminal(t *testing.T) {
	b := testBar()
	b.text = "写在知道终端之前"
	b.setTarget(target{ID: "A", Title: "a"}, nil)
	if b.text != "写在知道终端之前" {
		t.Fatalf("first terminal should keep the draft, got %q", b.text)
	}
	b.setTarget(target{ID: "B", Title: "b"}, nil)
	if b.text != "" {
		t.Fatalf("new terminal starts empty, got %q", b.text)
	}
	b.text = "给 B"
	b.setTarget(target{ID: "A"}, nil)
	if b.text != "写在知道终端之前" {
		t.Fatalf("A's draft back, got %q", b.text)
	}
	b.setTarget(target{ID: "B"}, nil)
	if b.text != "给 B" {
		t.Fatalf("B's draft back, got %q", b.text)
	}
	b.setTarget(target{}, errors.New("Ghostty 没有在运行"))
	if b.terr == "" || b.text != "给 B" || b.target.ID != "B" {
		t.Fatalf("an error keeps the draft: %+v", b)
	}
}

func TestSend(t *testing.T) {
	b := testBar()
	// The goroutine's result comes back here, as the main thread would run it.
	main := make(chan func(), 1)
	b.update = func(fn func()) { main <- fn }
	var got []string
	b.deliver = func(id string, parts []segment, insert bool, done func(int)) error {
		text := ""
		for _, p := range parts {
			text += p.Text
		}
		got = append(got, id+"|"+text)
		if text == "fail" {
			return errors.New("Ghostty 当前的终端变了，没有发送")
		}
		return nil
	}
	b.text = "没有终端"
	b.Send(false)
	if !b.bad || b.busy {
		t.Fatal("no terminal: refused")
	}
	b.setTarget(target{ID: "A"}, nil)
	b.text = "第一行\n第二行\n"
	b.Send(false)
	(<-main)()
	if b.busy || b.text != "" || got[0] != "A|第一行\n第二行" {
		t.Fatalf("%q %q", b.text, got)
	}
	b.text = "fail"
	b.Send(false)
	(<-main)()
	if b.text != "fail" || !b.bad {
		t.Fatalf("failure keeps the text: %q %v", b.text, b.status)
	}
}

func TestAsPNG(t *testing.T) {
	img := image.NewRGBA(image.Rect(0, 0, 4, 4))
	img.Set(1, 1, color.RGBA{255, 0, 0, 255})
	var j bytes.Buffer
	if err := jpeg.Encode(&j, img, nil); err != nil {
		t.Fatal(err)
	}
	p, err := asPNG(j.Bytes())
	if err != nil {
		t.Fatal(err)
	}
	if _, err := png.Decode(bytes.NewReader(p)); err != nil {
		t.Fatal(err)
	}
	if _, err := asPNG([]byte("not a picture")); err == nil {
		t.Fatal("text taken for a picture")
	}
}

func TestHistory(t *testing.T) {
	b := testBar()
	for _, s := range []string{"一", "二", "三", "二"} {
		b.remember(s)
	}
	if got := strings.Join(b.history, ","); got != "一,三,二" {
		t.Fatalf("no repeats, latest last: %s", got)
	}
	b.hist = len(b.history)
	b.Recall(-1)
	b.Recall(-1)
	if b.text != "三" {
		t.Fatalf("two back: %q", b.text)
	}
	b.Recall(+1)
	b.Recall(+1)
	if b.text != "" {
		t.Fatalf("past the newest the (empty) draft comes back: %q", b.text)
	}
	b.text = "正在写"
	b.Recall(-1)
	if b.text != "正在写" {
		t.Fatalf("a draft is never replaced: %q", b.text)
	}
}

func TestPicturesKeepTheirPlace(t *testing.T) {
	var shot bytes.Buffer
	_ = png.Encode(&shot, image.NewRGBA(image.Rect(0, 0, 4, 4)))
	b := testBar()
	b.text = "先看这里"
	b.sel = [2]int{4, 4}
	b.attach(shot.Bytes())
	if b.text != "先看这里[图片1]" || b.caret != 9 {
		t.Fatalf("marker at the caret: %q caret %d", b.text, b.caret)
	}
	b.text += "然后这张"
	b.sel = [2]int{2, 2} // a second picture in the middle of the first words
	b.attach(shot.Bytes())
	if b.text != "先看[图片2]这里[图片1]然后这张" {
		t.Fatalf("%q", b.text)
	}
	parts := pieces(b.text, b.pics)
	var order []string
	for _, p := range parts {
		if p.Picture != nil {
			order = append(order, "图")
		} else {
			order = append(order, p.Text)
		}
	}
	if got := strings.Join(order, "|"); got != "先看|图|这里|图|然后这张" {
		t.Fatalf("order: %s", got)
	}
	b.removePicture(1) // picture 2
	if b.text != "先看这里[图片1]然后这张" || len(b.pics) != 1 {
		t.Fatalf("removed with its marker: %q", b.text)
	}
	// A marker deleted by hand: the picture still goes, last; a stray marker stays text.
	parts = pieces("没有标记了 [图片9]", b.pics)
	if len(parts) != 2 || parts[0].Text != "没有标记了 [图片9]" || parts[1].Picture == nil {
		t.Fatalf("%+v", parts)
	}
}

func TestClearUndo(t *testing.T) {
	b := testBar()
	b.text = "草稿"
	b.pics = []picture{{}}
	b.Clear()
	if b.text != "" || len(b.pics) != 0 || !b.canUndo() {
		t.Fatalf("cleared: %+v", b)
	}
	b.Undo()
	if b.text != "草稿" || len(b.pics) != 1 || b.cleared != nil {
		t.Fatalf("undone: %+v", b)
	}
	b.Clear()
	b.text = "新写的"
	b.Undo()
	if b.text != "新写的" {
		t.Fatal("undo must not replace what was written after the clear")
	}
}

func TestPreview(t *testing.T) {
	var shot bytes.Buffer
	img := image.NewRGBA(image.Rect(0, 0, 320, 200))
	for y := 0; y < 200; y++ {
		for x := 0; x < 320; x++ {
			img.Set(x, y, color.RGBA{uint8(40 + x/3), uint8(60 + y/2), 140, 255})
		}
	}
	_ = png.Encode(&shot, img)
	long := "这个报错帮我看一下，是不是 herdr 远程客户端的问题？\n第二行：顺便把截图里的日志也过一遍\n第三行：看完给个结论就行"
	states := []struct {
		name   string
		height int
		setup  func(b *bar)
	}{
		{"empty", 92, func(b *bar) {}},
		{"draft", 200, func(b *bar) {
			b.text = "这个报错帮我看一下："
			b.sel = [2]int{9, 9}
			b.attach(shot.Bytes())
			b.text += "\n还有这张，是不是 herdr 远程客户端的问题？"
			b.sel = [2]int{len([]rune(b.text)), len([]rune(b.text))}
			b.attach(shot.Bytes())
			b.text += "\n看完给个结论就行"
		}},
		{"sending", 200, func(b *bar) {
			b.text = long
			b.attach(shot.Bytes())
			b.attach(shot.Bytes())
			b.attach(shot.Bytes())
			b.busy, b.sent = true, 1
		}},
		{"preview", 420, func(b *bar) {
			b.text = "看这张"
			b.attach(shot.Bytes())
			b.attach(shot.Bytes())
			b.preview = 0
		}},
		{"error", 136, func(b *bar) {
			b.text = "hello"
			b.status, b.bad, b.retry = "没发出去：Ghostty 当前的终端变了，没有发送", true, true
		}},
		{"cleared", 92, func(b *bar) {
			b.text = "x"
			b.Clear()
		}},
		{"pinned", 92, func(b *bar) {
			b.pinned = true
			b.flash = time.Now().Add(time.Hour)
		}},
	}
	for _, s := range states {
		for _, dark := range []bool{false, true} {
			b := testBar()
			b.target = target{ID: "A", Title: "devbox: ~/project"}
			s.setup(b)
			name := s.name
			view := b.view
			if dark {
				name += "-dark"
				view = func(c *ui.Context) { c.SetTheme(ui.DarkTheme()); b.view(c) }
			}
			out := ui.Render(view, barWidth, s.height, 2)
			if dir := os.Getenv("PREVIEW"); dir != "" {
				f, err := os.Create(filepath.Join(dir, "bar-"+name+".png"))
				if err != nil {
					t.Fatal(err)
				}
				_ = png.Encode(f, out)
				f.Close()
			}
		}
	}
	tb := testBar()
	_ = ui.Render(tb.toastView, 150, 40, 2)
}
