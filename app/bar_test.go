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
	"testing"

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
	b.deliver = func(id, text string, pics [][]byte) error {
		got = append(got, id+"|"+text)
		if text == "fail" {
			return errors.New("Ghostty 当前的终端变了，没有发送")
		}
		return nil
	}
	b.text = "没有终端"
	b.Send()
	if !b.bad || b.busy {
		t.Fatal("no terminal: refused")
	}
	b.setTarget(target{ID: "A"}, nil)
	b.text = "第一行\n第二行\n"
	b.Send()
	(<-main)()
	if b.busy || b.text != "" || got[0] != "A|第一行\n第二行" {
		t.Fatalf("%q %q", b.text, got)
	}
	b.text = "fail"
	b.Send()
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

func TestPreview(t *testing.T) {
	var shot bytes.Buffer
	_ = png.Encode(&shot, image.NewRGBA(image.Rect(0, 0, 40, 40)))
	for name, setup := range map[string]func(b *bar){
		"empty": func(b *bar) {},
		"draft": func(b *bar) {
			b.text = "这个报错帮我看一下\n第二行：顺便把截图里的日志也过一遍"
			b.attach(shot.Bytes())
			b.attach(shot.Bytes())
		},
		"error": func(b *bar) {
			b.text = "hello"
			b.terr = "没有控制 Ghostty 的权限：系统设置 → 隐私与安全性 → 自动化，打开 InputBar 下的 Ghostty"
			b.target = target{}
		},
	} {
		b := testBar()
		b.target = target{ID: "A", Title: "devbox: ~/project"}
		setup(b)
		img := ui.Render(b.view, barWidth, barHeight, 2)
		if dir := os.Getenv("PREVIEW"); dir != "" {
			f, err := os.Create(filepath.Join(dir, "inputbar-"+name+".png"))
			if err != nil {
				t.Fatal(err)
			}
			_ = png.Encode(f, img)
			f.Close()
		}
	}
}
