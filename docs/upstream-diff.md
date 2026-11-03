# 与上游源码的对应关系

源码基线：[`hguandl/PlayTools`](https://github.com/hguandl/PlayTools) 的 `MaaTools` 分支，
commit `6497f81`（"fix: Avoid ScreenCaptureKit before iOS 18.2"）。

## 复用情况

| 文件 | sha256 前缀 | 状态 |
| --- | --- | --- |
| `Hguandl/MaaTools.swift` | `bbb0b478a6e929c1`（本仓库） | **一处补丁**，见下 |
| `Hguandl/MetalCapture.swift` | `71ed3bdc81324f7c` | 与上游逐字节一致 |
| `Hguandl/ArknightsMetalCapture.swift` | `47df920862eb445f` | 与上游逐字节一致 |
| `Hguandl/MetalCaptureHook.h` | `f5abb82894367d93` | 与上游逐字节一致 |
| `Hguandl/MetalCaptureHook.m` | `90e643c8bdcbc79c` | 与上游逐字节一致 |

可以用 `shasum -a 256` 对照上游仓库确认。

## `MaaTools.swift` 的补丁

只改 `setupWindow()`：协议尺寸完全交给插件 shim 决定。

```swift
private func setupWindow() {
    // MaaPlugin: the plugin shim owns the protocol size. It waits until
    // PlayTools' UIScreen swizzle and the window have settled, so do *not*
    // fall back to reading `UIScreen` here — that fallback used to lock a
    // stale (sometimes portrait) size on the very first pass, which showed
    // up as a vertically stretched picture.
    if let metrics = AKInterface.shared?.screenMetrics {
        scale = metrics.scale
        width = Int(metrics.size.width.rounded())
        height = Int(metrics.size.height.rounded())
    }

    windowTitle = AKInterface.shared?.windowTitle
}
```

原实现是直接读 `UIScreen.nativeScale` / `nativeBounds`（带 `else if` 兜底）。问题在于：

- PlayTools 的 `UIScreen` swizzle 在插件加载之后才生效，最初几次读到的可能是显示器尺寸；
- 开启 `inverseScreenValues` 后 `nativeBounds` 会是竖屏值，与横屏窗口不匹配。

原实现的第一轮就会把不稳定值锁进 `SIZE`，之后整场都错。补丁把"是否稳定/朝向如何"的判断移到
shim（见 [architecture.md](architecture.md#尺寸与朝向)），并且**去掉了兜底**：未稳定时保持
`width/height = 0`，让 `initialize()` 的等待循环下一秒重试。

## 未改动的上游行为

- Metal 抓取仍只对 `com.hypergryph.arknights` 安装 hook（`ArknightsMetalCapture` 的白名单原文如此），
  终末地不会走 `MTL` 命令；
- 协议命令集合、握手、帧格式与上游一致（见 [protocol.md](protocol.md)）；
- 监听仍用 `NWListener(using: .tcp, on: port)`，绑定所有网卡。

## 为什么需要 shim

`MaaTools.swift` 依赖 PlayTools 进程内的符号，插件里并不存在：

| 上游符号 | 上游实现 | 本仓库替身 |
| --- | --- | --- |
| `PlaySettings.shared` | 读 PlayCover per-app plist | `PlaySettingsShim` 读同一个文件，字段可选 + 环境变量兜底 |
| `AKInterface.shared` | `AKInterface.bundle`（macOS、AppKit） | `AKInterfaceShim`：Catalyst 没有 AppKit，改用 UIKit + CGWindowList + ScreenCaptureKit |
| `PlayInput.touchQueue` | 串行队列 | `PlayInputShim` 同名队列 |
| `Toucher.touchcam` | 调 `PTFakeMetaTouch` | `ToucherShim` 保持相同相位语义，运行时查找注入类 |
| `ArknightsMetalCapture` / `MetalCapture*` | 同仓 | 整份复制 |

`MaaTools.swift` 里用到了 `UIApplication` / `UIWindowScene` 却没有 `import UIKit`，是因为 PlayTools
通过 umbrella header 引入；所以 bridging header 也 import 了 UIKit，这份文件才能保持其余部分不变。

## 为什么不直接链接 PlayTools

| 做法 | 结论 |
| --- | --- |
| `import PlayTools` / `-framework PlayTools` 调 Swift API | **不可行**：安装的 `PlayTools.framework/Modules` 是空的，没有 `.swiftmodule`/`.swiftinterface`；自行生成 module 会把插件钉死在某一次 PlayTools 构建的 Swift ABI 上 |
| `dlsym("_OBJC_CLASS_$_PTFakeMetaTouch")` | 与现在的 `NSClassFromString` 等价，只是多一层手写符号名 |
| ObjC 运行时按类名 + 选择器（当前做法） | **惯用且最稳**：`PTFakeMetaTouch` 是 `@interface` 类，解析一次后缓存 IMP，失败只告警一次 |

其余符号本就不该复用：`AKInterface` 是 macOS/AppKit 实现（Catalyst 编译期不可用），`PlaySettings`
本质是读 plist，`PlayInput` 只是一个队列，`Toucher` 是薄封装。
