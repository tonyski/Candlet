# Candlet

macOS 菜单栏自选股。股票行情来自[长桥 OpenAPI](https://open.longbridge.com)，加密货币来自 [Binance](https://developers.binance.com/docs/binance-spot-api-docs)，都是实时推送。

## 功能

- A 股、港股、美股、新加坡股和加密货币
- 实时价格与涨跌幅，含盘前、盘后、夜盘
- 分时小图，带昨收线
- 点击涨跌幅切换为市值，悬停查看更新时间
- 按代码或名称模糊搜索
- 自选分组

## 安装

1. 从 [Releases](https://github.com/tonyski/Candlet/releases) 下载 DMG，拖进「应用程序」。
2. 打开面板，点「在浏览器中登录」完成长桥授权。

已内置[长桥 CLI](https://github.com/longbridge/longbridge-terminal)，无需另装。首次启动会开启「登录时打开」，可在 ⋯ 菜单里关闭。

需要 macOS 27 及以上。股票行情需要开通 OpenAPI 的长桥账户，美股实时行情还需购买「LV1 实时行情（OpenAPI）」。只看加密货币无需登录。

## 使用

- **添加**：点 **+**，输入代码或名称（如「腾讯」「AAPL」「BTC」），选择建议或直接回车添加第一条。
- **整理**：拖动排序；右键删除或移到其他分组。
- **分组**：在 ⋯ 菜单里新建、重命名、删除；有两个以上分组时显示分组标签。
- **更新**：有新版本时 ⋯ 旁会出现小圆点。

自选只存在本机，与长桥 App 的自选无关。

## 常见问题

- **登录失效**：面板里会出现登录卡片，重新授权即可。只看加密货币时，从 ⋯ 菜单的「登录长桥…」进入。
- **在中国大陆登录美国账户**：授权页可能默认是 longbridge.cn，它不支持美国账户，请改用 longbridge.com。
- **登录信息在哪**：`~/.longbridge/openapi/`，与自行安装的长桥 CLI 共用。

## 开发

1. 运行 `scripts/fetch-longbridge.sh`，把长桥 CLI（arm64）和许可证下载到 `Vendor/`。
2. 用 Xcode 27 打开 `Candlet.xcodeproj`。编译时 CLI 会复制到 `Contents/Helpers` 并签名。

升级 CLI：改脚本里的版本和校验值。App 未开沙盒，以便启动 CLI 并读取登录信息。

| 文件 | 作用 |
| --- | --- |
| `CandletApp.swift` | 入口 |
| `Store.swift` | 自选、订阅、搜索、重连、登录 |
| `Serve.swift` | 内置 CLI 的子进程与 JSON-RPC |
| `Binance.swift` | 加密货币行情 |
| `Models.swift` | 数据模型 |
| `Views.swift` | 界面 |
| `Updater.swift` | 检查新版本 |
| `LoginItem.swift` | 登录时打开 |

发布：运行 `scripts/release.sh`，签名、公证后的 DMG 在 `dist/`。
