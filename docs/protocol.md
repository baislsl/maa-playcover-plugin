# MaaTools v4 协议

TCP，默认端口 `1717`（可由环境变量 `MAATOOLS_PORT` 覆盖）。本节描述的是本插件实际实现的
语义，与 hguandl/PlayTools 的 `MaaTools.swift` 一致。

## 握手

```
client → server : 4 字节 "MAA\0"
server → client : 4 字节 "OKAY"
```

握手失败或超时，服务端断开连接。

## 帧格式

握手之后，所有请求都是：

```
┌──────────────┬───────────────────────┐
│ u16 长度 (BE) │ payload（长度字节）     │
└──────────────┴───────────────────────┘
                  payload[0..4) = magic
```

应答由各命令自行定义（多数没有长度前缀，直接是固定结构或 `u32 长度 + 数据`）。

## 命令表

| magic | 方向 | payload | 应答 |
| --- | --- | --- | --- |
| `VERN` | 请求 | 空 | `u32` 版本号，当前 4 |
| `SIZE` | 请求 | 空 | `u16 width` + `u16 height` |
| `BNDL` | 请求 | 空 | `u32 长度` + UTF-8 bundle id |
| `RECT` | 请求 | 空 | 8 × `u16`：窗口 frame(x,y,w,h) + 内容区(x,y,w,h) |
| `SCRN` | 请求 | 空 | `u32 长度` + RGBA8888 像素（`width*height*4`） |
| `BGR\x01` | 请求 | 空 | `u32 w` + `u32 h` + `u32 长度` + RGB888 |
| `MTL\0` | 请求 | 空 | 同上，数据来自 Metal drawable |
| `TUCH` | 请求 | `phase(1)` + `x(u16 BE)` + `y(u16 BE)` + `contact(1)` | 无 |
| `TERM` | 请求 | 空 | 无，随后进程退出 |

说明：

- `SCRN` 的像素尺寸**永远等于** `SIZE` 回报的尺寸；服务端会把抓到的画面缩放到该缓冲区。
- `TUCH` 的 `phase`：`0` = began，`1` = moved，`3` = ended；坐标除以
  `scale = SIZE.width / UIWindow.bounds.width` 得到 UIKit 点坐标，再交给 `PTFakeMetaTouch`。
  `contact` 是手指编号，支持多指。
- `BGR`/`MTL` 各自携带真实宽高，允许与 `SIZE` 不同。
- `MTL` 只有在 Metal hook 安装成功且 bundle id 在白名单内时才有效，否则回 `0,0,0` 头部。

## 版本与兼容

| 客户端 | 要求的最低版本 | 使用的命令 |
| --- | --- | --- |
| MaaFramework（MaaEnd 的 `PlayCover` 控制器） | 2 | `VERN` `SIZE` `SCRN` `TUCH` `TERM` |
| MAA（明日方舟，`PlayToolsController`） | 3 | 额外使用 `BGR` `RECT` `BNDL`，配置 `MacBGR`/`MacSCK` 时要求 ≥3 |
| 本插件实现 | 4 | 增加 `MTL` |

版本不满足时客户端会主动拒绝连接，因此升级两端时要一起看版本。
