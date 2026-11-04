# 架构与实现

## 组件

```
Sources/MaaPlugin/
├── MaaPluginEntry.swift        插件入口（constructor 调用 MaaPluginStart）
├── PluginBootstrap.m           __attribute__((constructor)) → 主队列 → 启动
├── MaaPlugin-Bridging-Header.h 暴露 ObjC 头给 Swift
├── Core/                       原样保留的上游实现
│   ├── MaaTools.swift          MaaTools v4 服务端（TCP、协议解析、截图缓冲）
│   ├── MetalCapture.swift      Metal 帧缓冲池 / 状态机
│   ├── ArknightsMetalCapture.swift  Metal drawable 抓取（hook 安装）
│   └── MetalCaptureHook.h/.m   CAMetalLayer / MTLCommandBuffer swizzle
└── Shim/                       脱离 PlayTools 的适配层
    ├── PlaySettingsShim.swift  PlaySettings.shared（读 PlayCover per-app plist）
    ├── AKInterfaceShim.swift   AKInterface.shared（窗口/截图/标题/结束进程）
    ├── PlayInputShim.swift     PlayInput.touchQueue
    ├── ToucherShim.swift       Toucher.touchcam（转调 PTFakeMetaTouch）
    └── MaaPluginDebug.swift    MAATOOLS_DEBUG=1 才启用的日志
```

## 加载与启动

1. PlayCover 把插件 dylib 复制到 `游戏.app/Frameworks/UserPlugins/`，PlayTools 启动时对该目录下所有
   `*.dylib` 执行 `dlopen`（`UserPluginLoader.swift`）。
2. `PluginBootstrap.m` 的 constructor 把 `MaaPluginStart()` 投递到主队列。
3. 入口读取 `PlaySettings`（可选地安装 Metal hook），调用 `MaaTools.shared.initialize()`。
4. `initialize()` 轮询 `AKInterface.screenMetrics`，直到参数稳定，然后开始在配置端口监听 TCP。
5. 监听就绪后把 `[localhost:<port>]` 追加到窗口标题，方便客户端确认地址。

启动会多等约 2–3 秒：`screenMetrics` 要求 `UIScreen.nativeBounds` 连续 1 秒不变（PlayTools 的
`UIScreen` swizzle 在插件加载后才生效），没有配置窗口尺寸时还要求窗口 frame 稳定 1 秒。

## 请求处理

`MaaTools` 是 `@MainActor` 的，每个连接一个串行任务：

```
握手（MAA\0 → OKAY）
  └─ 循环：读 2 字节长度 → 读 payload → 按前 4 字节 magic 分发
        SCRN  → await AKInterface.windowImage() → 绘制到 SIZE 缓冲 → 回 u32 长度 + RGBA
        BGR   → 同上，转 RGB888 后回头部 + 数据
        TUCH  → PlayInput.touchQueue.async → Toucher.touchcam
        SIZE/VERN/BNDL/RECT → 立即回
        TERM  → 结束进程
```

协议细节见 [protocol.md](protocol.md)。

## 截图

`MaaTools.screenshot()` 把 `AKInterface.windowImage()` 拿到的 `CGImage` 画进
`width × height × 4` 的缓冲区（`width/height` 就是上报给客户端的 `SIZE`），再整体发送。

`windowImage()` 的取图顺序：

1. **ScreenCaptureKit**（macOS 15.2 / Catalyst 18.2 及以上）
   - 缓存 `SCShareableContent` 5 秒，避免每帧枚举；
   - `SCContentFilter(desktopIndependentWindow:)` + `sourceRect`（窗口内容，裁掉标题栏）；
   - 输出尺寸 = 内容原生像素（`content × pointPixelScale`）。**不能让 SCK 输出更大的尺寸**：
     它不会放大内容，而是把画面钉在左上、其余留黑。
2. **CGWindowListCreateImage**：系统低于 18.2（`sckAvailable == false`）或 SCK 抛错时兜底，
   在后台线程执行。

窗口几何（窗口 id、frame、内容区）每帧重新解析，窗口移动/重建无需额外处理。

### 尺寸与朝向

`AKInterface.screenMetrics` 决定 `SIZE` 与触控换算比例：

- 候选值取 `UIScreen.nativeBounds`，但必须**连续 1 秒稳定**；
- 朝向参考优先用 PlayCover 配置里的 `windowWidth/windowHeight`，没有配置才用稳定的窗口 frame；
- 最后用游戏自身的 `UIWindow.bounds` 兜底：横屏 UI 不可能对应竖屏 `SIZE`；
- `scale = size.width / uiBounds.width`，`TUCH` 坐标除以它即可回到 UIKit 点坐标系。

这样即使开启 `inverseScreenValues`（PlayTools 会把 `nativeBounds` 报成竖屏）也不会出现宽高翻转。

## 触控

`Toucher.touchcam` 保持 PlayTools 的语义（`.began` 分配 id、`.ended` 释放），命中测试后通过
`PTFakeMetaTouch` 注入：

- `PTFakeMetaTouch` 是注入的 PlayTools 里的 ObjC 类，PlayTools 没有发布 Swift module，因此按类名 +
  选择器解析，首次成功后缓存 IMP；
- 缺失时启动阶段会记录一条错误，之后每次触摸静默失败（不会崩溃）。

## 配置读取

插件**不往 PlayCover 的设置里写任何键**：安装 dylib 本身就是开关，其余开关全部读环境变量。

| 环境变量 | 默认 | 说明 |
| --- | --- | --- |
| `MAATOOLS_ENABLE` | `true` | 是否启动服务 |
| `MAATOOLS_PORT` | `1717` | 监听端口 |
| `MAATOOLS_METAL` | `false` | 是否安装 Metal hook |
| `MAATOOLS_DEBUG` | 关闭 | 是否写调试日志 |

唯一从文件读取的是 PlayCover 自己拥有的 `windowWidth`/`windowHeight`
（`~/Library/Containers/io.playcover.PlayCover/App Settings/<bundle-id>.plist`），用于在启动时判定
窗口尺寸/朝向；缺失时退回"窗口 frame 稳定 1 秒"的判断。

## 标题栏

`UIWindowScene.title` 对 PlayCover 的游戏窗口不生效，插件通过 ObjC runtime 取
`NSApplication.sharedApplication.windows.first` 并 KVC 写入 `title`，写入后再观察 30 秒，被改回就重写。

## 线程模型

| 工作 | 线程 |
| --- | --- |
| 协议解析、截图、绘制 | 主 actor（游戏主线程空闲时才执行） |
| 触摸注入 | `PlayInput.touchQueue`（独立串行队列） |
| CG 兜底抓图 | 后台线程 |
| Metal 抓取 | 游戏渲染线程 + blit 回调 |

截图在主 actor 上串行执行，因此单帧耗时直接决定客户端看到的最大帧率；实测窗口 1024×768 时
SCK 单帧 8–35 ms。
