# Candlet

macOS 菜单栏自选股。股票行情来自[长桥 OpenAPI](https://open.longbridge.com)，没有长桥账户也能用免费延迟行情；加密货币行情来自 [Binance](https://developers.binance.com/docs/binance-spot-api-docs)。

## 功能

- 支持 A 股、港股、美股、新加坡股和加密货币
- 实时价格与涨跌幅，含盘前、盘后、夜盘
- 分时小图，带昨收虚线
- 点击涨跌幅切换为市值，悬停查看更新时间
- 按代码或名称模糊搜索
- 自选分组，可给股票改名
- 没有长桥账户时用免费延迟行情（腾讯、Yahoo）
- App 内一键更新

## 安装

需要 macOS 27 及以上（Apple 芯片）。

1. 从 [Releases](https://github.com/tonyski/Candlet/releases) 下载 DMG，把 Candlet 拖进「应用程序」。
2. 打开面板，点「在浏览器中登录」完成长桥授权；没有长桥账户就点「只用免费行情」。

已内置[长桥 CLI](https://github.com/longbridge/longbridge-terminal)，无需另装。首次启动会开启「登录时打开」，可在 ⋯ 菜单里关闭。

股票实时行情需要已开通 OpenAPI 的长桥账户；美股实时行情还需购买「LV1 实时行情（OpenAPI）」。

## 使用

- **添加**：点 **+**，输入代码或名称（如「腾讯」「AAPL」「BTC」），从建议里选择，或直接回车添加第一条。
- **整理**：拖动排序；右键可重命名、恢复原名、删除或移到其他分组。
- **分组**：在 ⋯ 菜单里新建、重命名、删除；有两个以上分组时显示分组标签，拖动标签可调整顺序。
- **行情来源**：在 ⋯ 菜单里选择。「自动」优先用长桥，长桥不可用时改用免费行情；用免费行情时标题旁显示「延迟」。
- **更新**：有新版本时 ⋯ 旁会出现小圆点，在 ⋯ 菜单里点「更新到…」即可自动下载、安装并重启。App 所在位置不可写（比如直接从 DMG 运行）时，改为在浏览器中下载。

自选只保存在本机，与长桥 App 的自选无关。

## 常见问题

- **登录失效**：面板里会出现登录卡片，重新授权即可。只看加密货币时不显示卡片，从 ⋯ 菜单的「登录长桥…」进入。
- **在中国大陆登录美国账户**：授权页可能默认打开 longbridge.cn，它不支持美国账户，请改用 longbridge.com。
- **免费行情**：A 股、港股、美股来自腾讯，新加坡股来自 Yahoo，都是非官方接口，可能延迟或失效。面板打开时每 10 秒刷新一次，不含盘前盘后，也搜不到新加坡股。
- **登录信息存在哪**：`~/.longbridge/openapi/`，与自行安装的长桥 CLI 共用。

## 开发

1. 运行 `scripts/fetch-longbridge.sh`，把长桥 CLI（arm64）和许可证下载到 `Vendor/`。
2. 用 Xcode 27 打开 `Candlet.xcodeproj`。编译时 CLI 会被复制到 `Contents/Helpers` 并签名。

升级 CLI：修改脚本里的版本号和校验值。App 没有开沙盒，因为要启动 CLI 并读取登录信息。

| 文件 | 作用 |
| --- | --- |
| `CandletApp.swift` | 入口 |
| `Store.swift` | 自选、订阅、搜索、重连、登录 |
| `Serve.swift` | 内置 CLI 的子进程与 JSON-RPC |
| `Binance.swift` | 加密货币行情 |
| `Free.swift` | 免费延迟行情（腾讯、Yahoo） |
| `Models.swift` | 数据模型 |
| `Views.swift` | 界面 |
| `Updater.swift` | 检查、下载并安装新版本 |
| `LoginItem.swift` | 登录时打开 |

发布：运行 `scripts/release.sh`，签名、公证后的 DMG 输出到 `dist/`。
