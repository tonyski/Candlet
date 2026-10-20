# Candlet

macOS 菜单栏自选股小工具。自选列表在本机自己维护，行情数据来自长桥 OpenAPI，通过 `longbridge serve`（JSON-RPC over stdio）获取，价格走实时推送，不轮询。

## 环境要求

- macOS 27 及以上，Xcode 27 及以上（Swift 6.4，语言模式 6，默认 MainActor 隔离，并提前开启了 Swift 7 的全部 upcoming feature）
- 长桥账户，并且已开通 OpenAPI 权限
- 想看美股实时行情的话，需要在长桥 App 里购买「LV1 实时行情（OpenAPI）」行情卡

## 第一次运行

```bash
# 1. 安装长桥 CLI
brew install --cask longbridge/tap/longbridge-terminal

# 2. 登录（会打印一个链接和验证码，在浏览器里完成授权）
longbridge auth login

# 3. 确认能拿到数据
longbridge check
longbridge quote AAPL.US
```

然后双击 `Candlet.xcodeproj`，按 ⌘R 运行。菜单栏会出现一个小蜡烛笑脸图标。

## 管理自选

- 右上角 **+** 添加：可以输入 `AAPL`、`700`、`600660`，也可以输入带后缀的 `700.HK`。添加时会向长桥校验代码，并取回中文名。
  - 不带后缀时：字母视为美股，6 位数字视为 A 股（6、5、9 开头是沪市，其余是深市），其他数字视为港股。
  - 新加坡股票需要带 `.SG` 后缀。
- 拖动行可以排序，右键可以删除。
- 列表保存在本机 UserDefaults 里，和长桥 App 的自选互不影响。首次运行会预置一组示例股票，可以随意删改。

> 已经关闭了 App Sandbox。沙盒里的 App 无法启动 `/opt/homebrew/bin` 下的程序，也读不到 `~/.longbridge` 里的登录 token。

## 文件结构

| 文件 | 作用 |
| --- | --- |
| `CandletApp.swift` | 入口，`MenuBarExtra(.window)`，不显示 Dock 图标 |
| `Serve.swift` | actor，管理 `longbridge serve` 子进程，按 id 对应请求和响应，推送通过 `AsyncStream` 发出 |
| `Store.swift` | `@Observable` 状态：本地自选的增删排序与保存、增量订阅、合并推送、断线后指数退避重连（未登录时不自动重试） |
| `Models.swift` | JSON 类型、自选项与代码规范化、报价（自动选取盘前 / 盘中 / 盘后 / 夜盘中最新的一组） |
| `Views.swift` | 面板、行、分时小图（Canvas 手绘，横轴按分钟序号排布） |

## 常见问题

- **提示「未找到 longbridge 命令」**：确认终端里 `which longbridge` 能找到它；App 会依次查找 `/opt/homebrew/bin`、`/usr/local/bin`、`~/.local/bin`，最后用登录 shell 的 PATH 兜底。
- **提示未登录**：重新执行 `longbridge auth login`，然后在面板右上角的 ⋯ 菜单里点「重新连接」。
- **提示 CLI 版本过旧**：执行 `longbridge update`。

## 可以继续加的功能

- 本地分组（比如「美股」「A 股」「关注」）
- 菜单栏图标旁显示某一只股票的价格和涨跌幅
- 用 `SMAppService.mainApp.register()` 实现开机自启
- 点击某一行打开详情（K 线、资金流向，对应 `quote.candlesticks`、`quote.capital_flow`）
- 面板关闭一段时间后暂停订阅，节省长连接
