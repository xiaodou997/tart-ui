# TartUI 中文文档

[English](README.md)

TartUI 是 [Tart](https://github.com/openai/tart) 的原生 macOS 图形界面。Tart 是一个面向 Apple Silicon、用于创建、运行和管理 macOS/Linux 虚拟机的工具集。

Tart 已经提供了虚拟化引擎和完整命令行。TartUI 增加可视化管理面板、可复用的启动配置、操作日志和更顺手的工作流。正式版本会内置固定版本的 Tart runtime，用户不需要另外安装 Tart。

## 功能

- 查看本地虚拟机和 OCI 镜像缓存，包括状态和磁盘占用。
- 启动、关机、挂起和恢复虚拟机。
- 从 IPSW 创建 macOS 虚拟机，或创建空白 Linux 虚拟机。
- 克隆、修改配置、重命名、删除、导入和导出虚拟机。
- 从 OCI 仓库拉取和推送镜像，支持登录和注销。
- 查询虚拟机 IP，并通过 `tart-guest-agent` 执行非交互式命令。
- 预览并执行镜像缓存或虚拟机清理。
- 保存显示、设备、存储、共享、网络和高级 `tart run` 参数为具名启动配置。

虚拟机画面仍然由 Tart 自带的 `Virtualization.Framework` 原生窗口提供。TartUI 只负责管理，不实现虚拟化，也不内嵌 VNC 查看器。

## 架构

```text
TartUI App（唯一用户应用和 Dock 图标）
    ↓
VMStore
    ↓
VMRuntimeCoordinator
    ├── VMRuntimeSession（状态和日志）
    ├── VMDisplayDriver（当前原生窗口，未来可嵌入 VNC）
    └── VMRuntimeService
    ↓
TartKit（与 UI 无关的命令封装层）
    ↓
TartRuntime（内置 → 托管 → 外部）
    ↓
Tart helper Agent 进程
```

TartUI 仍然把 Tart 作为独立可执行程序，通过 JSON 输出获取数据。Tart 源码由固定版本的 Git submodule 编译，然后放入 `TartUI.app/Contents/Helpers/tart.app`。helper 仍然是独立进程，便于跟随上游更新和在异常时恢复。

内置 helper 会构建为 macOS Agent，因此用户只看到一个 App 和一个 Dock 图标，虚拟机 runtime 仍然是独立进程。Tart 当前会在原生窗口模式下强制使用 regular activation policy，所以构建 helper 时会临时应用 `Resources/tart-agent.patch`，编译结束后自动恢复 Tart 源码。这个补丁很小且会在上游代码不兼容时直接让构建失败，避免 Tart 更新后静默恢复第二个 Dock 图标。

## 环境要求

- macOS 14.0 或更高
- Apple Silicon
- 安装或更新托管备用运行时需要网络连接

## 安装

正式版本会内置固定版本的 Tart runtime。构建签名后的 release 应用并安装到「应用程序」文件夹：

```bash
./scripts/install.sh
```

脚本会先构建 Tart submodule，使用项目维护的虚拟化 entitlement 签名 helper，再签名外层 App。如果本机有 Developer ID 证书会优先使用，否则使用适合本机自用的临时签名。对外分发还需要 Developer ID 签名和公证。

用户下载项目发布的 App 后只需要打开 `TartUI.app`。如果内置运行时缺失，TartUI 会把官方最新 Tart 下载到自己的托管备用目录，不会修改 Homebrew 或 shell 配置。为了保留 Agent 集成和单 Dock 图标行为，内置 runtime 始终优先；内置 Tart 通过固定 submodule 和定期更新 workflow 随新版 TartUI 一起更新。

## 开发

运行单元测试和集成测试：

```bash
swift test
```

初始化只读 Tart 源码并查看当前固定版本：

```bash
git submodule update --init --recursive
git -C Vendor/tart log -1 --oneline
```

只构建 debug `.app`，不安装：

```bash
./scripts/bundle.sh
```

脚本优先使用 `Vendor/tart`，开发时也兼容旁边的 `../tart`。从源码构建时会临时应用 Agent 集成补丁，编译后恢复源码。如需指定其他源码或已有二进制：

```bash
TARTUI_TART_SOURCE_DIR=/path/to/tart ./scripts/bundle.sh debug
TARTUI_TART_BINARY=/path/to/tart ./scripts/bundle.sh debug
```

外部传入的预编译 Tart 无法自动获得 TartUI Agent 集成补丁。要实现单 Dock 图标，请使用项目内置的源码构建；外部 Tart 仍可作为诊断和兼容性备用运行时。

如需使用 Apple Development 证书和 Xcode 下载的 Tart helper Profile：

```bash
TARTUI_SIGN_IDENTITY=<Apple-Development-SHA1> \
TARTUI_TART_PROVISION_PROFILE=/path/to/TartUI-Tart-Helper-Development.provisionprofile \
./scripts/bundle.sh debug
```

打包脚本也会自动扫描 Xcode 本地 Profile 缓存。Profile 不会提交到仓库。macOS 26 的 Apple 门户 VMNet 能力授予的是 `com.apple.developer.networking.vmnet`；而 Tart 当前的 `--net-bridged` 实现使用另一个受限的 `com.apple.vm.networking` entitlement。因此，在 Apple 额外授予该受限权限前，建议使用共享（NAT）网络。

如需生成可直接分发的公证 DMG，先把公证 profile 保存到本机钥匙串，再执行：

```bash
TARTUI_VERSION=0.1.0 \
TARTUI_NOTARY_PROFILE=tartui \
./scripts/release.sh
```

签名证书和公证凭据必须保存在本机钥匙串或 CI secrets 中，不能提交到仓库。

运行构建出的应用：

```bash
open .build/arm64-apple-macosx/debug/TartUI.app
```

需要以真实 `.app` bundle 运行。直接执行 `swift run` 得到的裸可执行文件没有 SwiftUI `WindowGroup` 所需的 bundle 元数据。

### 更新 Tart

Tart 通过固定版本的 submodule 管理，不会在构建时静默使用上游最新代码。手动更新：

```bash
./scripts/update-tart.sh
```

GitHub Actions 每周自动检查最新稳定版，如果有更新就创建 PR。PR 必须通过 TartUI 测试和打包检查后才能合并发布。

## 国际化

英文是开发语言和默认语言，项目同时内置简体中文 `zh-Hans`。

本地化资源位于：

```text
Sources/TartUI/Resources/en.lproj/Localizable.strings
Sources/TartUI/Resources/zh-Hans.lproj/Localizable.strings
```

增加新语言时，新建 `<language>.lproj/Localizable.strings`，并在 `scripts/bundle.sh` 的应用 bundle 元数据中加入对应 locale。英文 key 是源文案，其他语言文件只需提供翻译值。

## 数据和兼容性

启动配置保存在：

```text
~/Library/Application Support/TartUI/run-profiles.json
```

TartUI 会自动读取旧版 `TartPro` 目录和 tart 路径设置；之后的新改动写入 `TartUI` 目录。Tart 自己的虚拟机数据不会被移动或修改。

运行日志保存在：

```text
~/Library/Logs/TartUI
```

## 开源协议和归属

TartUI 使用 Functional Source License, Version 1.1, ALv2 Future License。Tart 及其依赖继续使用各自原始协议，详见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) 和未修改的 `Vendor/tart/LICENSE`。

TartUI 是面向 Tart 的独立社区图形界面项目，与 OpenAI 没有关联，也不代表 OpenAI 的官方产品。

## 测试策略

- 单元测试使用 mock executor，验证命令参数和 JSON 解码。
- 集成测试使用真实 Tart，但只执行只读命令。
- 真实虚拟机测试默认关闭，需要显式开启：

  ```bash
  TARTUI_LIVE_VM=<虚拟机名> swift test --filter LiveVMTests
  TARTUI_LIVE_CRUD=1 swift test --filter LiveCRUDTests
  ```

## 已知限制

- 虚拟机画面仍由 Tart 的 Virtualization Framework 原生窗口提供；显示驱动边界已预留，后续可以实现内嵌 VNC。
- `exec` 要求虚拟机内安装 `tart-guest-agent`。
- Tart 的 `prune` 没有 dry-run，缓存预览无法看到 IPSW 安装包缓存。
- 退出 TartUI 不会关闭正在运行的虚拟机；确认退出后它们会继续在后台运行。
