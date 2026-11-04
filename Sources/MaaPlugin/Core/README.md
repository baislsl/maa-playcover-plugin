# Core — 上游代码

本目录下的文件来自 **hguandl/PlayTools** 的 `MaaTools` 分支，不是本项目原创：

| 项 | 值 |
| --- | --- |
| 仓库 | <https://github.com/hguandl/PlayTools> |
| 分支 | `MaaTools` |
| 基线提交 | `6497f81`（"fix: Avoid ScreenCaptureKit before iOS 18.2"） |
| 许可 | AGPL-3.0（与本项目一致，见 [../../../LICENSE](../../../LICENSE)） |

## 文件

| 文件 | 作用 | 与上游的差异 |
| --- | --- | --- |
| `MaaTools.swift` | MaaTools v4 协议服务端（TCP、截图缓冲、命令分发） | 仅 `setupWindow()` 一处补丁 |
| `MetalCapture.swift` | Metal 帧池与抓取状态机 | 逐字节一致 |
| `ArknightsMetalCapture.swift` | Metal drawable 抓取（安装 hook） | 逐字节一致 |
| `MetalCaptureHook.h` / `.m` | `CAMetalLayer` / `MTLCommandBuffer` swizzle | 逐字节一致 |

补丁内容与原因见 [docs/upstream-diff.md](../../../docs/upstream-diff.md)。

## 校验

```sh
shasum -a 256 Sources/MaaPlugin/Core/*
```

与上游对应文件对比即可确认除 `MaaTools.swift` 外均为原样。

## 修改约定

- 尽量不改这些文件；适配逻辑放到 `Sources/MaaPlugin/Shim/`（那部分不属于上游）；
- 如果确实要改，请同步更新 `docs/upstream-diff.md` 里的差异说明和 sha256；
- 所有修改都受 AGPL-3.0 约束，分发时需一并提供对应源码。
