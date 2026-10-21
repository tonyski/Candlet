# Candlet

macOS 菜单栏自选股。股票行情来自[长桥 OpenAPI](https://open.longbridge.com)，加密货币来自 [Binance](https://developers.binance.com/docs/binance-spot-api-docs)，均为实时推送。

## 功能

- A 股、港股、美股、新加坡股与加密货币自选
- 实时价格与涨跌幅，含盘前 / 盘后 / 夜盘
- 分时小图，带昨收线
- 按代码或名称搜索，支持模糊匹配

## 安装

1. 从 [Releases](https://github.com/tonyski/Candlet/releases) 下载 DMG，拖进「应用程序」。
2. 安装并登录长桥 CLI：

   ```bash
   brew install --cask longbridge/tap/longbridge-terminal
   longbridge auth login
   ```

需要 macOS 27 及以上，以及开通了 OpenAPI 的长桥账户。美股实时行情需购买长桥「LV1 实时行情（OpenAPI）」。

## 使用

点 **+**，输入代码或名称（如「腾讯」「福玻」），从弹出的建议里选择即可添加。拖动排序，右键删除。

直接输入代码时：

| 输入 | 识别为 |
| --- | --- |
| `AAPL` | `AAPL.US` |
| `700` | `700.HK` |
| `600660`（6、5、9 开头） | `600660.SH` |
| `000001`（其他 6 位数字） | `000001.SZ` |
| `D05.SG` | 新加坡需带后缀 |
| `BTC/USDT` | 加密货币，涨跌为 24 小时 |

自选只保存在本机，与长桥 App 的自选无关。

## 常见问题

- **未找到 longbridge**：确认终端里 `which longbridge` 有输出。
- **登录已失效**：运行 `longbridge auth login`，再在 ⋯ 菜单里点「重新连接」。
- **CLI 版本过旧**：运行 `longbridge update`。

## 开发

用 Xcode 27 打开 `Candlet.xcodeproj`。App 未开沙盒，以便启动 `longbridge` 并读取其登录信息。

| 文件 | 作用 |
| --- | --- |
| `CandletApp.swift` | 入口 |
| `Serve.swift` | `longbridge serve` 子进程与 JSON-RPC |
| `Binance.swift` | 加密货币行情 |
| `Store.swift` | 自选、订阅、搜索、重连 |
| `Models.swift` | 数据模型 |
| `Views.swift` | 界面 |

发布：运行 `scripts/release.sh`，签名、打包、公证后的 DMG 在 `dist/`。
