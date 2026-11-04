# 排查

## 打开日志

默认**不写任何文件**。需要时：

```sh
launchctl setenv MAATOOLS_DEBUG 1     # 之后重启游戏
# ... 复现问题 ...
tail -100 ~/Downloads/maaplugin-com.hypergryph.endfield.log
launchctl unsetenv MAATOOLS_DEBUG     # 用完关掉
```

`launchctl setenv` 是全局 GUI 环境变量，会影响所有从图形界面启动的进程，用完记得 unset。

日志文件名是 `maaplugin-<bundle-id>.log`。游戏在沙盒里，写不了 `/tmp`，所以按顺序尝试：

1. `$MAATOOLS_LOG_DIR/maaplugin-<bundle-id>.log`
2. `/tmp/maaplugin-<bundle-id>.log`（无沙盒宿主）
3. `~/Downloads/maaplugin-<bundle-id>.log`（PlayCover 给游戏 `files.downloads.read-write`）
4. `~/Library/Containers/io.playcover.PlayCover/MaaPluginLogs/`
5. `NSTemporaryDirectory()`

实际路径会在启动时用 NSLog 打印一次，日志第一行也带 `start: log=…`。

## 日志里有什么

| 行 | 含义 |
| --- | --- |
| `start: log=… port=… maaTools=… metal=…` | 启动参数与落盘位置 |
| `screen: bounds=… native=… scale=… windows=…` | 启动时的 UIScreen / 窗口状态 |
| `screen metrics: native=… reference=… uiBounds=… scale=…` | **最终锁定的 SIZE 与触控比例** |
| `screen metrics: swapping …` / `overriding …` | 朝向被校正过（正常；缺失才说明设置与实际一致） |
| `geometry: id=… frame=… uiBounds=… content=…` | 窗口几何变化（窗口移动/重建时出现） |
| `capture: window=… content=… titleBar=…` | 截图区域与标题栏高度 |
| `capture: SCK 15 ms -> 2660x1662` | 单帧抓图耗时与尺寸 |
| `capture: SCK 1500 ms gave up` | 超时，正在回放上一帧 |
| `touch: PTFakeMetaTouch found in PlayTools` | 触摸注入可用 |

## 常见现象

### 画面被拉伸（上下拉长、左右压缩）

说明上报的 `SIZE` 是竖屏。看启动日志里的 `screen metrics:` 行：

- 正常应出现一次 `swapping …`（开启了 `inverseScreenValues` 时）且最终 `scale` 与
  `SIZE.width / uiBounds.width` 一致；
- 如果 `SIZE` 仍然是竖的，把该行发出来。

插件会等 `nativeBounds` 稳定 1 秒后才锁定尺寸，所以启动比游戏晚 2–3 秒才监听，属正常。

### 截图里出现标题栏 / 白色栏

看 `capture: window=… content=… titleBar=…`：`titleBar` 应为窗口高度减内容区高度（约 27pt）。
若为 0 但画面仍有标题栏，说明该系统版本的 SCK 对 `contentRect` 语义不同，需要调整裁剪。

### 画面只占客户端的左上角、其余黑

历史问题，根因是让 SCK 输出比内容更大的尺寸（SCK 不会放大，只会把内容钉在左上）。现在按内容原生
像素取图、由服务端缩放到 `SIZE`，日志里 `capture: … -> WxH` 应等于内容尺寸 × 像素比。

### 客户端画面定住不更新

先判断是插件还是客户端：

1. 日志里 `capture:` 行是否还在持续输出？
   - **停止输出**：没有新的截图请求到达（插件侧没有收到数据）。此时进程通常仍存活，问题在客户端。
   - **持续输出且耗时正常**：服务端一直在回图，问题在客户端处理或显示。
2. 连接是否断开：日志出现异常或重新握手即说明断连。

已知 MaaEnd 的实时预览在长时间运行后可能停更（任务本身仍可继续），此时暂停/重新开始任务即可恢复；
插件侧每次请求都在 8–35 ms 内返回。

### 触摸无效

启动日志应出现 `touch: PTFakeMetaTouch found in PlayTools`。没有则说明 PlayTools 未注入该游戏
（插件不复制该实现，依赖 PlayTools 提供）。

### 客户端连不上

1. 标题栏是否出现 `[localhost:<port>]`；没有则服务未启动或端口被占；
2. `lsof -nP -iTCP -sTCP:LISTEN | grep -i endfield` 查实际端口；
3. 端口可通过环境变量 `MAATOOLS_PORT` 修改（插件不读取 PlayCover 设置里的端口）。

## 收集信息

```sh
# 插件日志（最后 100 行）
tail -100 ~/Downloads/maaplugin-com.hypergryph.endfield.log

# 端口占用
lsof -nP -iTCP:1717 -sTCP:LISTEN

# 进程与签名
pgrep -fl Endfield
codesign -dv "/Users/$USER/Library/Containers/io.playcover.PlayCover/Applications/com.hypergryph.endfield.app"
```
