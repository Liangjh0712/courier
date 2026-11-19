# InputBar

A macOS input box for the terminal: press ⌃⌥⌘I anywhere, write in a native text field (your input method, normal editing), press Enter, and it is typed into the terminal in front in [Ghostty](https://ghostty.org).

按 ⌃⌥⌘I 随处呼出的输入框：在原生输入框里写（中文输入法、正常编辑），回车后送进 Ghostty 前台窗口当前的终端。适合给终端里的 AI 编程助手写长消息、贴截图。不管终端里跑的是 shell、Claude Code 还是经 SSH 的远程会话，都和你在终端里粘贴一样。

## 功能

| 操作 | 效果 |
|---|---|
| ⌃⌥⌘I | 呼出 / 收起。框在你上次拖到的位置（按住顶部那条拖动），第一次在屏幕底部居中；配色跟系统浅色 / 深色 |
| 回车 / ⌘回车 | 发送：按粘贴送入当前终端，再按 Enter。发出后框收起，原位置提示「已发送」 |
| ⌥回车 | 只插入，不按 Enter，方便在终端里接着改 |
| Shift+回车 | 换行；框随内容长高，最多 10 行，再多在框内滚动 |
| ⌘V 剪贴板里只有图片 / 拖入图片 | 附图，输入框上方显示缩略图，点一下放大。发送时逐张放进剪贴板，给终端发 Ctrl+V（Claude Code 等程序按 Ctrl+V 贴图），每张约 1.5 秒，已发的打勾，发完恢复原剪贴板 |
| ⌘↑ / ⌘↓ | 翻最近 50 条发过的内容（只在内存里）；框里有草稿时不覆盖 |
| ⌘K / 顶部垃圾桶 | 清空草稿，几秒内可以撤销 |
| 图钉 | 钉住后发送、点别处都不收起，适合连续对话 |
| Esc / 点别处 | 收起（大图打开时先收起大图），草稿保留 |
| ⌘Q（框开着时） | 退出 |

- 草稿按 Ghostty 终端分开保存（只在内存里）；发送前核对前台终端没变，变了就不发，框里提示并可重试。
- 首次启动把自己加进登录项；没有菜单栏图标和 Dock 图标。

## 依赖

- macOS 14 及以上，Apple 芯片
- Ghostty 1.4 及以上（用到它的 AppleScript 字典：`input text`、`send key`）
- 第一次发送时 macOS 会问「InputBar 想控制 Ghostty」，点允许；拒绝过的话到 系统设置 › 隐私与安全性 › 自动化 打开

## 构建

用 Go 1.27+ 和 [mygo](https://github.com/egoist/mygo)（纯 Go、无 cgo，可以在任何机器上交叉编译）。

```sh
scripts/build-app.sh                       # 在 Mac 上：编译、签名、装到 ~/Applications 并打开
scripts/build-app.sh --package app.tgz     # 在别的机器上交叉编译打包，再到 Mac 上 scripts/install-app.sh app.tgz
```

默认临时签名，每次重新编译 macOS 都会把它当成新 App，「控制 Ghostty」要重新允许。想保持授权，设 `SIGN_IDENTITY` 用固定的签名证书（见脚本开头）。

测试：`cd app && go test ./...`；`PREVIEW=<目录>` 时把输入框渲染成 PNG，在没有显示器的机器上也能看界面。

## License

MIT
