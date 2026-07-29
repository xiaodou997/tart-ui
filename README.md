# TartPro

[Tart](https://github.com/openai/tart) 的原生 macOS 图形界面。

Tart 是 Apple Silicon 上基于 `Virtualization.Framework` 的虚拟机工具，功能完整但只有命令行。
TartPro 给它配一套图形界面，目标是完整覆盖 tart 的所有命令。

## 设计原则

**不修改 tart 源码，把它当外部依赖。** TartPro 通过子进程调用 `tart` 命令行，
用它原生的 `--format json` 输出取回结构化数据。这样上游 `brew upgrade tart` 可以直接受益，
不用维护 fork，也避免了虚拟化 entitlement 的签名问题——那属于 tart 二进制，与本 App 无关。

**GUI 的增值点是 Run Profile。** `tart run` 有 26 个选项，但 tart 的 `config.json`
只持久化 6 个字段（CPU、内存、显示、MAC、磁盘格式等）。也就是说命令行用户每次启动
都得重敲一长串参数。TartPro 把启动参数存成每台虚拟机的命名配置，一键启动。

**虚拟机画面沿用 tart 自带窗口。** `tart run` 本身会开一个原生的
`Virtualization.Framework` 窗口，性能最好。TartPro 只做管理面板，不做 VNC 内嵌。

## 架构

```
UI 层 (SwiftUI)          VMListView / SetupGuideView / ...
ViewModel 层 (@Observable) VMStore / RunSessionManager
Domain 层                 VMListEntry / VMDetails / RunProfile
TartKit（核心）            TartClient / TartExecutor / TartLocator
        ↓ Process + Pipe
   /opt/homebrew/bin/tart
```

`TartKit` 是不依赖任何 UI 代码的独立 target，可以脱离界面单独测试。

## 环境要求

- macOS 14.0 或更高
- Apple Silicon
- 已安装 tart：`brew install openai/tools/tart`

## 构建与运行

```bash
# 运行测试
swift test

# 打包成 .app 并启动
./scripts/bundle.sh
open .build/arm64-apple-macosx/debug/TartPro.app
```

注意必须打包成 `.app` 再运行。SwiftUI 的 `WindowGroup` 需要真实的 bundle
（含 Info.plist）才能创建窗口，直接 `swift run` 得到的裸可执行文件会启动后立刻退出。

## 测试

- **单元测试**用 mock 的执行器，验证命令参数拼装和 JSON 解码，不需要装 tart。
- **集成测试**跑真实的 tart 二进制，验证解码器和上游实际输出一致。只包含只读命令
  （`list` / `get` / `--version`），不会创建、修改或删除任何虚拟机。
  没装 tart 的机器上自动跳过。

## 已知的坑

这几条是实测踩出来的，改代码时注意：

1. **PATH。** 从 Finder 启动的 `.app` 继承的是 launchd 的最小 PATH，拿不到
   `/opt/homebrew/bin`。所以不能靠 `which tart`，必须显式探测路径。见 `TartLocator`。
2. **管道死锁。** 先 `waitUntilExit()` 再读管道，会在输出超过管道缓冲区（约 64KB）时死锁。
   必须并发读 stdout 和 stderr。`tart pull` 的输出远超这个量。见 `ProcessHandle`。
3. **schema 不一致。** 同名的 `Size` 字段，`tart list` 返回整数 GB，`tart get`
   返回字符串小数（如 `"31.057"`）。两者必须分开建模。
4. **窗口默认尺寸。** `.frame(minWidth:)` 只是下限，不决定初始尺寸，
   要用 `.defaultSize()`，否则窗口会缩到内容的固有大小。

## 进度

- [x] TartKit 地基：二进制定位、进程执行、JSON 解码、错误处理
- [x] 只读界面：虚拟机列表、状态同步
- [x] 生命周期：run / stop / suspend + Run Profile 编辑器 + 会话日志
- [ ] 创建与配置：create / clone / set / rename / delete
- [ ] 镜像仓库：pull / push / login / logout + 进度条
- [ ] 导入导出、prune、ip
- [ ] exec（先做非交互式简版）
