package main

// Ghostty is driven through its AppleScript dictionary (Ghostty 1.4+): the
// focused terminal of the front window gets text "as if pasted" and key
// events. Nothing here knows what runs in the terminal. A picture goes the way
// a person pastes one: it is put on the clipboard and the terminal gets
// Ctrl+V (herdr's remote client uploads it then, a local Claude Code reads the
// clipboard itself); the clipboard is put back afterwards.

import (
	"bytes"
	"errors"
	"image"
	_ "image/gif"
	_ "image/jpeg"
	"image/png"
	"os/exec"
	"strings"
	"time"

	"github.com/egoist/mygo"
	"github.com/egoist/mygo/transfer"
	_ "golang.org/x/image/webp"
)

// Waits around a picture: the program reads the clipboard some time after the
// Ctrl+V, so the next picture (or the restored clipboard) must not come sooner.
var (
	imageSettle  = 1500 * time.Millisecond
	osascriptBin = "/usr/bin/osascript"
)

// target is the terminal a message goes to: its Ghostty ID, and the title of
// its window to show.
type target struct {
	ID, Title string
}

const probeScript = `on run argv
	if application "Ghostty" is not running then error "Ghostty 没有在运行" number 1001
	tell application "Ghostty"
		if (count of windows) is 0 then error "Ghostty 没有打开的窗口" number 1002
		set w to front window
		set t to focused terminal of selected tab of w
		return (id of t) & linefeed & (name of w)
	end tell
end run`

// sendScript: argv is the terminal ID expected, then what to do: "image"
// (Ctrl+V), "enter", or "insert" and a text to type in. It refuses when the
// focused terminal is no longer that one.
const sendScript = `on run argv
	set expected to item 1 of argv
	set what to item 2 of argv
	if application "Ghostty" is not running then error "Ghostty 没有在运行" number 1001
	tell application "Ghostty"
		if (count of windows) is 0 then error "Ghostty 没有打开的窗口" number 1002
		set t to focused terminal of selected tab of front window
		if (id of t) is not expected then error "Ghostty 当前的终端变了，没有发送" number 1003
		if what is "image" then
			send key "v" modifiers "control" to t
		else if what is "enter" then
			delay 0.15
			send key "enter" to t
		else
			set msg to item 3 of argv
			if msg is not "" then input text msg to t
		end if
	end tell
end run`

// osascript runs a script with arguments and returns its output, or its
// error message made readable.
func osascript(script string, args ...string) (string, error) {
	cmd := exec.Command(osascriptBin, append([]string{"-e", script}, args...)...)
	var out, errb bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errb
	if err := cmd.Run(); err != nil {
		return "", scriptError(errb.String(), err)
	}
	return strings.TrimRight(out.String(), "\n"), nil
}

// scriptError turns "…: execution error: MESSAGE (NUMBER)" into MESSAGE, and
// a refused Apple event (-1743) into where to allow it.
func scriptError(stderr string, err error) error {
	s := strings.TrimSpace(stderr)
	if strings.Contains(s, "-1743") || strings.Contains(s, "Not authorized") {
		return errors.New("没有控制 Ghostty 的权限：系统设置 → 隐私与安全性 → 自动化，打开 InputBar 下的 Ghostty")
	}
	if i := strings.Index(s, "execution error: "); i >= 0 {
		s = s[i+len("execution error: "):]
		if j := strings.LastIndex(s, " ("); j > 0 {
			s = s[:j]
		}
	}
	if s == "" {
		s = err.Error()
	}
	return errors.New(s)
}

// probe reads the focused terminal of Ghostty's front window.
func probe() (target, error) {
	out, err := osascript(probeScript)
	if err != nil {
		return target{}, err
	}
	id, title, _ := strings.Cut(out, "\n")
	if id == "" {
		return target{}, errors.New("Ghostty 没有回答当前终端")
	}
	return target{ID: id, Title: title}, nil
}

// segment is a piece of a message: a text to type in, or a PNG picture.
type segment struct {
	Text    string
	Picture []byte
}

// settle is how long to wait after a picture's Ctrl+V: the program reads the
// clipboard and (a remote client) uploads it before the next piece may come.
func settle(picture []byte) time.Duration {
	return imageSettle + time.Duration(len(picture)>>20)*300*time.Millisecond
}

// deliver types the pieces into terminal id in order, then Enter unless
// insert. done is called after each picture with how many went; the
// clipboard, used for pictures, is restored at the end.
func deliver(id string, pieces []segment, insert bool, done func(n int)) error {
	pictures := 0
	for _, p := range pieces {
		if p.Picture != nil {
			pictures++
		}
	}
	if pictures > 0 {
		saved, rerr := mygo.Clipboard.Read()
		defer func() {
			if rerr == nil {
				_ = mygo.Clipboard.Write(saved)
			}
		}()
	}
	sent := 0
	for _, p := range pieces {
		if p.Picture == nil {
			if p.Text == "" {
				continue
			}
			if _, err := osascript(sendScript, id, "insert", p.Text); err != nil {
				return err
			}
			continue
		}
		if err := mygo.Clipboard.Write(transfer.New(transfer.NewItem(transfer.Bytes(transfer.PNG, p.Picture)))); err != nil {
			return errors.New("图片放不进剪贴板：" + err.Error())
		}
		if _, err := osascript(sendScript, id, "image"); err != nil {
			return err
		}
		time.Sleep(settle(p.Picture))
		sent++
		done(sent)
	}
	if insert {
		return nil
	}
	_, err := osascript(sendScript, id, "enter")
	return err
}

// asPNG gives a picture's bytes as PNG, converting JPEG, GIF and WebP.
func asPNG(data []byte) ([]byte, error) {
	if bytes.HasPrefix(data, []byte("\x89PNG\r\n\x1a\n")) {
		return data, nil
	}
	img, _, err := image.Decode(bytes.NewReader(data))
	if err != nil {
		return nil, errors.New("不是能识别的图片")
	}
	var b bytes.Buffer
	if err := png.Encode(&b, img); err != nil {
		return nil, err
	}
	return b.Bytes(), nil
}
