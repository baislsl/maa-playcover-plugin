# MaaPlugin

该项目实现PlayCover Plugin支持MaaEnd控制终末地游戏，理论上只要支持MaaTools协议的客户端都能使用。无需安装fork后魔改PlayCover版本，只需安装最新版PlayCover。

当前实现主要将 [hguandl/PlayTools](https://github.com/hguandl/PlayTools)（`MaaTools` 分支）里的 **MaaTools 控制端点**
打包成一个 PlayCover「用户插件」dylib。装上之后，游戏进程会在 `127.0.0.1:1717` 上提供 MaaTools v4 协议，MaaEnd（或任何同协议的客户端）
选 `PlayCover` 控制器即可直接截图、点击。

## 为什么不再需要魔改PlayCover

PlayCover 自带用户自定义插件机制（设置 → 杂项 → 自定义插件），PlayTools 会把插件 dylib `dlopen`
进游戏进程。因此：

- **不需要** hguandl 的 PlayCover fork；
- **不需要** 改动上游 PlayCover 或 PlayTools；
- 协议实现直接复用上游源码，只有一处小补丁。

## 架构

```
┌──────────┐   MaaTools v4 (TCP)   ┌─────────────────────────────────────┐
│  MaaEnd  │ ────────────────────► │ 游戏进程 (Mac Catalyst)              │
└──────────┘ ◄──────────────────── │                                     │
                                   │  PlayTools (PlayCover 注入)          │
                                   │    └─ dlopen Frameworks/UserPlugins/ │
                                   │         MaaPlugin.dylib              │
                                   │           ├─ Hguandl/  协议服务端     │
                                   │           ├─ Shim/     适配层         │
                                   │           └─ 系统 API: SCK / CG / HID │
                                   └─────────────────────────────────────┘
```

| 组成 | 作用 |
| --- | --- |
| `Sources/MaaPlugin/Hguandl/` | 原样保留的 MaaTools 协议服务端与 Metal 抓图 |
| `Sources/MaaPlugin/Shim/` | 让上述代码脱离 PlayTools 独立运行的适配层 |
| `Sources/MaaPlugin/*.m/.swift` | 插件入口（`dlopen` 构造函数 → 启动服务） |

## 关键技术

- **协议原样复用**：4 个文件与上游逐字节一致，`MaaTools.swift` 仅一处补丁（见
  [docs/upstream-diff.md](docs/upstream-diff.md)）。
- **截图**：ScreenCaptureKit 窗口滤镜；按窗口内容裁剪标题栏、按内容原生像素取图、单帧 1.5 s 超时并
  回放上一帧，避免窗口被遮挡时卡死连接。
- **尺寸与朝向**：以 PlayCover 配置的窗口尺寸 + 游戏自身 `uiBounds` 对齐 `nativeBounds`，解决
  `inverseScreenValues` 导致的宽高翻转。
- **触控**：运行时调用注入的 PlayTools `PTFakeMetaTouch`（解析一次并缓存 IMP），不复制实现。
- **配置**：读取 PlayCover 的 per-app 设置 plist，`MAATOOLS_ENABLE / PORT / METAL` 环境变量可覆盖。
- **零侵入**：插件自启动（ObjC constructor），不修改游戏二进制与 PlayCover 本体。

## 快速开始

```sh
cd MaaPlugin
./build.sh          # 产物：build/MaaPlugin.dylib（universal，MACCATALYST 15.0）
```

1. PlayCover终末地游戏 **设置 → 杂项 → 自定义插件 → Add…** 选中 `MaaPlugin.dylib`；
2. 重启游戏，标题栏出现 `[localhost:1717]`；
3. MaaEnd 连接设置里选 `PlayCover`，地址填 `127.0.0.1:1717`。

也可以用 Xcode 打开 `MaaPlugin.xcodeproj` 直接构建；推送到 `main` 时 GitHub Actions 会自动构建并
上传 `MaaPlugin.dylib` artifact。详见 [docs/build.md](docs/build.md)。

## 重要声明

- **License：AGPL-3.0**（协议与抓图代码来自 PlayTools），见 [LICENSE](LICENSE)。
- **必须已注入 PlayTools**：PlayCover 运行游戏本身就依赖它，插件只借用其触摸注入能力。
- **监听所有网卡**：服务用 `NWListener(using: .tcp, on: port)`（上游原实现），只在本机使用时请自行
  用防火墙限制。
- **日志默认关闭**：只有设置 `MAATOOLS_DEBUG=1` 才落盘（位置与用法见
  [docs/troubleshooting.md](docs/troubleshooting.md)）。
- **平台**：仅 macOS / Apple Silicon（Mac Catalyst，最低 15.0）；协议版本 v4。

## 文档

| 文档 | 内容 |
| --- | --- |
| [docs/architecture.md](docs/architecture.md) | 组件划分、请求流程、截图与触控实现细节 |
| [docs/protocol.md](docs/protocol.md) | MaaTools v4 协议：握手、帧格式、命令表 |
| [docs/build.md](docs/build.md) | build.sh / Xcode 两种构建方式、产物与验证 |
| [docs/upstream-diff.md](docs/upstream-diff.md) | 与上游源码的对应关系、补丁内容、为何不直接链接 PlayTools |
| [docs/troubleshooting.md](docs/troubleshooting.md) | 日志开关、常见现象与排查方法 |
