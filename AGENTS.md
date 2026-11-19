# AGENTS.md

InputBar：mygo（纯 Go）写的 macOS 输入框，经 Ghostty AppleScript 把文字送进前台终端。

- 代码：`app/main.go`（入口、菜单、全局快捷键）、`app/bar.go`（界面与交互）、`app/ghostty.go`（AppleScript、剪贴板贴图）、`app/keys_*.go`（Shift 状态、原生 paste:）。
- 改完跑 `cd app && gofmt -l . && go vet ./... && GOOS=darwin GOARCH=arm64 go vet ./... && go test ./...`；看界面用 `PREVIEW=<目录> go test -run Preview`。

## 坑

- mygo 退出时逐个关窗，任何一个 OnClose 里 PreventDefault 都会取消整个退出，App 变成空壳：窗口拦关闭必须在退出时放行（`bar.quitting`）。
- mygo 的角色菜单项（RolePaste 等）直接交给 AppKit，Click 不会回到 Go：要拦 ⌘V 只能用自定义菜单项，不是图片时用 `nativePaste`（`sendAction:paste:`）交回文本框。
- mygo 的多行输入框把回车和 Shift+回车都当换行：用「只多了一个换行」加 `CGEventSourceFlagsState` 判断 Shift 来区分发送。
- 贴图靠剪贴板 + Ctrl+V，接收端读剪贴板有延迟，下一张图或恢复剪贴板前要等（`imageSettle`）。
