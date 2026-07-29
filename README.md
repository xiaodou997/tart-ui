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

## 安装

```bash
./scripts/install.sh
```

构建 release 版本并装到「应用程序」文件夹，之后就是一个普通的 macOS 应用：
启动台、聚焦搜索（Cmd+空格）都能找到，也可以拖进程序坞常驻。

## 开发

```bash
swift test              # 运行测试
./scripts/bundle.sh     # 只打包 debug 版，不安装
```

注意必须打包成 `.app` 再运行。SwiftUI 的 `WindowGroup` 需要真实的 bundle
（含 Info.plist）才能创建窗口，直接 `swift run` 得到的裸可执行文件会启动后立刻退出。

## 换图标

```bash
./scripts/set-icon.sh 你的图.png    # 自动裁成正方形、加圆角、留白
./scripts/set-icon.sh --raw 成品.png  # 图已经做好了，跳过处理
./scripts/install.sh                # 应用新图标
```

图标源文件是 `Resources/icon.png`，打包时自动转成 `.icns`。

## 代码签名

`scripts/lib.sh` 会自动挑选签名身份：有 **Developer ID Application** 证书就用它，
否则用临时签名（ad-hoc）。本机自用临时签名完全够。

**Apple Development 和 Apple Distribution 证书被刻意跳过。** 它们签出来的应用需要
配套的描述文件（`embedded.provisionprofile`）才能启动，直接拿来打包会让 launchd
拒绝加载，报 `Launch failed`（错误 163）。那两张证书是给 Xcode 完整签名流程用的。

要分发给别人，需要在开发者后台申请 Developer ID Application 证书，装好后本脚本
会自动选用；随后还应做公证（`xcrun notarytool`），否则对方下载打开会被 Gatekeeper 拦。
手动指定身份用 `TARTPRO_SIGN_IDENTITY=<名称或指纹> ./scripts/install.sh`。

## 测试

- **单元测试**用 mock 的执行器，验证命令参数拼装和 JSON 解码，不需要装 tart。
- **集成测试**跑真实的 tart 二进制，验证解码器和上游实际输出一致。只包含只读命令
  （`list` / `get` / `--version`），不会创建、修改或删除任何虚拟机。
  没装 tart 的机器上自动跳过。
- **live 测试**有副作用，默认不跑，需显式开启：

  ```bash
  # 真实启停一台已有的虚拟机（无图形模式，约 80 秒）
  TARTPRO_LIVE_VM=<虚拟机名> swift test --filter LiveVMTests

  # 真实走一遍创建 → 改配置 → 重命名 → 删除（用完即清）
  TARTPRO_LIVE_CRUD=1 swift test --filter LiveCRUDTests
  ```

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
5. **密码只能走 stdin。** `tart login` 用 `--password-stdin`。把密码放进命令行参数
   会让它出现在 `ps` 输出里，同机任何进程都读得到。见 `TartClient+Registry`。
6. **prune 没有 dry-run。** 命令一执行就真的删。`PrunePlanner` 复刻了 tart 的
   选择逻辑做预览，但看不到 IPSW 缓存（`tart list` 不列它），界面上必须标明预览不完整。

## 进度

- [x] TartKit 地基：二进制定位、进程执行、JSON 解码、错误处理
- [x] 只读界面：虚拟机列表、状态同步
- [x] 生命周期：run / stop / suspend + Run Profile 编辑器 + 会话日志
- [x] 创建与配置：create / clone / set / rename / delete
- [x] 镜像仓库：pull / push / login / logout
- [x] 导入导出、prune、ip
- [x] exec（非交互式）
- [x] 状态自动同步（轮询 + 目录监听）
- [x] 设置：手动指定 tart 路径

至此已覆盖 tart 的全部命令。
