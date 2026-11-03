# 构建

## 前置

- macOS + Xcode（含 command line tools；本工程在 Xcode 27 上验证）
- 目标平台：Mac Catalyst，`minos 15.0`，`arm64` + `x86_64`

工程文件 `MaaPlugin.xcodeproj` 是**唯一的构建配置来源**：源文件列表、bridging header、Catalyst
平台、签名方式都在里面。`build.sh` 只是对它的封装。

## 方式一：build.sh（推荐）

```sh
./build.sh            # Release
./build.sh Debug      # Debug
```

脚本等价于：

```sh
xcodebuild -project MaaPlugin.xcodeproj -scheme MaaPlugin \
  -configuration Release \
  -destination 'generic/platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath build/xcode build
```

然后把产物复制到固定路径 `build/MaaPlugin.dylib`，方便安装时直接取用。

产物特性（已通过 `lipo` / `vtool` / `codesign` 验证）：

| 项 | 值 |
| --- | --- |
| 架构 | `x86_64` + `arm64`（universal） |
| 平台 | `MACCATALYST`，`minos 15.0` |
| 签名 | ad-hoc（`Signature=adhoc`，无 Team） |
| 依赖 | 仅系统框架，不依赖 PlayTools |

## 方式二：Xcode 图形界面

双击 `MaaPlugin.xcodeproj` → scheme 选 `MaaPlugin` → `⌘B`。产物在
`build/xcode/Build/Products/Release-maccatalyst/MaaPlugin.dylib`。

## 方式三：直接 xcodebuild

见上面的命令，`-derivedDataPath` 可换成任意目录。

## GitHub Actions

`.github/workflows/build.yml` 在推送到 `main`（或手动 `workflow_dispatch`）时构建，并把
`MaaPlugin.dylib` 作为 artifact 上传：

- runner：`macos-15`（自带 Xcode 16 / Mac Catalyst 18 SDK）；
- 步骤：checkout → `./build.sh` → 校验架构/平台/签名/导出符号 → `actions/upload-artifact@v4`；
- artifact 名 `MaaPlugin`，内含 `MaaPlugin.dylib`，保留 30 天；
- 同一分支的新提交会取消上一次未完成的构建（`concurrency`）。

仓库根目录就是 MaaPlugin 时无需改动；如果它在子目录里，把 workflow 顶部的 `PROJECT_DIR` 改成该子目录名
即可（`path` 与 `working-directory` 都引用它）。

## 清理

```sh
rm -rf build          # 中间产物 + Xcode DerivedData + 复制出的 dylib
```

`build/` 已在 `.gitignore` 中。

## 验证产物

```sh
P=build/MaaPlugin.dylib
lipo -info "$P"            # x86_64 + arm64
vtool -show-build "$P"     # platform MACCATALYST, minos 15.0
codesign -dv "$P"          # Signature=adhoc
otool -L "$P"              # 只依赖系统框架
```

## 冒烟测试

用最小 Mac Catalyst 宿主加载 dylib（不装 PlayTools）验证协议链路：

| 请求 | 结果 |
| --- | --- |
| `MAA\0` 握手 | `OKAY` |
| `VERN` | `4` |
| `SIZE` | 与宿主屏幕一致 |
| `SCRN` | `width*height*4` 字节，四边无黑边 |
| `TUCH` | 服务端不中断（注入需要 PlayTools 提供 `PTFakeMetaTouch`） |
| 抓图耗时 | 1024×768 窗口约 8–35 ms/帧 |

## 安装

1. PlayCover 中给游戏装好 PlayTools；
2. 游戏 **设置 → 杂项 → 自定义插件 → Add…** 选择 `build/MaaPlugin.dylib`；
3. 重启游戏，标题栏出现 `[localhost:1717]`。

手动拷进 `Frameworks/UserPlugins/` 也可以，但会破坏应用签名，需让 PlayCover 重新签名。
