# Candlet

macOS 菜单栏自选股。行情来自[长桥 OpenAPI](https://open.longbridge.com)，实时推送。

## 功能

- 港股、美股、A 股、新加坡股自选，拖动排序，右键删除
- 实时价格与涨跌幅，自动切换盘前 / 盘中 / 盘后 / 夜盘
- 分时小图，带昨收虚线
- 红涨绿跌 / 绿涨红跌可切换

## 安装

1. 从 [Releases](https://github.com/tonyski/Candlet/releases) 下载 DMG，把 Candlet 拖进「应用程序」。
2. 安装并登录长桥 CLI：

   ```bash
   brew install --cask longbridge/tap/longbridge-terminal
   longbridge auth login
   ```

需要 macOS 27 及以上、已开通 OpenAPI 的长桥账户。美股实时行情需在长桥 App 购买「LV1 实时行情（OpenAPI）」。

## 使用

点右上角 **+** 输入代码，添加时会向长桥校验并取回名称：

| 输入 | 识别为 |
| --- | --- |
| `AAPL` | 美股 `AAPL.US` |
| `700`、`00700` | 港股 `700.HK` |
| `600660`（6、5、9 开头） | 沪市 `600660.SH` |
| `000001`（其他 6 位数字） | 深市 `000001.SZ` |
| `D05.SG` | 新加坡股，需带后缀 |

自选保存在本机，与长桥 App 的自选互不影响。

## 常见问题

- **未找到 longbridge 命令**：确认终端里 `which longbridge` 有输出。
- **未登录**：执行 `longbridge auth login`，再在面板 ⋯ 菜单里点「重新连接」。
- **CLI 版本过旧**：执行 `longbridge update`。

## 开发

用 Xcode 27 打开 `Candlet.xcodeproj` 运行。App 未开沙盒，以便启动 `longbridge` 并读取它的登录信息。

| 文件 | 作用 |
| --- | --- |
| `CandletApp.swift` | 入口，菜单栏面板 |
| `Serve.swift` | 管理 `longbridge serve` 子进程，JSON-RPC 收发 |
| `Store.swift` | 自选存储、订阅、推送合并、断线重连 |
| `Models.swift` | JSON、自选代码规范化、报价 |
| `Views.swift` | 面板、行、分时小图 |

发布：`scripts/release.sh` 完成签名、打 DMG、公证，产物在 `dist/`。
