# Candlet

macOS 菜单栏自选股，支持 A 股、港股、美股和加密货币。打开就能用，无需账户；有长桥账户可以改用长桥行情。

## 功能

- 价格与涨跌幅，美股含盘前盘后
- 分时小图，带昨收虚线
- 点击涨跌幅切换为市值，悬停查看更新时间
- 点击自选查看详情：分时、日 K、周 K、月 K、年 K 和当日行情，右上角标出数据来源
- 按代码或名称模糊搜索
- 自选分组，可给股票改名
- App 内一键更新

## 安装

需要 macOS 27 及以上（Apple 芯片）。从 [Releases](https://github.com/tonyski/Candlet/releases) 下载 DMG，把 Candlet 拖进「应用程序」。

首次启动会开启「登录时打开」，可在 ⋯ 菜单里关闭。

## 使用

- **添加**：点 **+**，输入代码或名称（如「腾讯」「AAPL」「BTC」），从建议里选择，或直接回车添加第一条。
- **详情**：点击一行查看分时与 K 线，点左上角返回。
- **整理**：拖动排序；右键可重命名、恢复原名、删除或移到其他分组。
- **分组**：在 ⋯ 菜单里新建、重命名、删除；有两个以上分组时显示分组标签，拖动标签可调整顺序。
- **更新**：有新版本时 ⋯ 旁会出现小圆点，在 ⋯ 菜单里点「更新到…」即可自动下载、安装并重启。App 所在位置不可写（比如直接从 DMG 运行）时，改为在浏览器中下载。

自选只保存在本机，与长桥 App 的自选无关。

## 行情来源

| 市场 | 免费行情（默认） | 长桥行情 |
| --- | --- | --- |
| A 股、港股 | 实时（腾讯） | 实时推送 |
| 美股 | 含盘前盘后（新浪） | 实时推送，含夜盘 |

加密货币始终来自 [Binance](https://developers.binance.com/docs/binance-spot-api-docs)，实时推送。

免费行情来自非官方接口，可能失效，只在面板打开时刷新：每 10 秒一次。

**使用长桥行情**：在 ⋯ 菜单里打开「使用长桥行情」，再点「在浏览器中登录」完成授权。需要已开通 OpenAPI 的[长桥](https://open.longbridge.com)账户；美股实时行情还需购买「LV1 实时行情（OpenAPI）」。长桥断开或登录失效时，自动退回免费行情。App 已内置[长桥 CLI](https://github.com/longbridge/longbridge-terminal)，只在使用长桥行情时启动。

## 常见问题

- **登录失效**：面板里会出现登录卡片，重新授权即可；不想用长桥了就点「不连接」。
- **在中国大陆登录美国账户**：授权页可能默认打开 longbridge.cn，它不支持美国账户，请改用 longbridge.com。
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
| `Free.swift` | 免费行情（腾讯、新浪、Yahoo） |
| `Models.swift` | 数据模型、市场 |
| `Views.swift` | 自选列表界面 |
| `Components.swift` | 列表行、分时小图、数字格式 |
| `Detail.swift` | 详情页与 K 线图 |
| `Updater.swift` | 检查、下载并安装新版本 |
| `LoginItem.swift` | 登录时打开 |

发布：运行 `scripts/release.sh`，签名、公证后的 DMG 输出到 `dist/`。
