# TartUI 中文文档

[English](README.md)

TartUI 是仅面向 Apple Silicon 的原生 macOS 应用，也是官方 [Tart](https://github.com/openai/tart) CLI 的原生 macOS 图形界面。

项目定位刻意保持简单：**让常用 Tart 命令更容易配置和执行，但不隐藏 CLI**。虚拟机、运行状态和 OCI 数据仍然以 Tart 为唯一事实来源。

## TartUI 负责什么

当前主流程只保留常用操作：

- 查找系统中已经安装的 Tart，或者在缺少 Tart 时安装官方正式版；
- 明确区分本地虚拟机与 OCI 镜像缓存；
- 从 OCI 镜像直接 Clone 成本地虚拟机；
- 按需创建新的 macOS 或 Linux 虚拟机；
- 启动、停止、挂起、克隆和删除本地虚拟机；
- 修改常见 VM 配置；
- 使用 `tart pull` 缓存 OCI 镜像；
- 登录和注销 OCI Registry；
- 每台虚拟机只保留一份可见的启动设置，包括显示、挂起、目录共享和网络模式；
- 导入 Tart VM、清理磁盘空间、查询 VM IP。

所有用户主动触发的 Tart 操作都会保持 CLI 透明：执行前展示命令，执行后保留状态、退出码、stdout 和 stderr。

例如：

    tart run dev --suspendable
    tart clone ghcr.io/cirruslabs/macos-sequoia-base:latest dev
    tart set dev --cpu 4 --memory 8192
    tart stop dev

这些命令都可以复制到 Terminal 中脱离 TartUI 独立执行。

## TartUI 不负责什么

TartUI 不是另一套虚拟化平台，也不是 Tart 的替代实现。

它不会：

- 编译或内置 Tart fork；
- 接管虚拟机显示窗口；
- 改写 Tart 的 VM 存储；
- 把 OCI Cache 伪装成可以直接运行的 VM；
- 做成镜像市场或复杂的虚拟化管理平台。

虚拟机窗口与真正的虚拟化生命周期仍由 Tart 自己管理。

## 架构

    TartUI（SwiftUI）
        |
        v
    VMStore + CommandAction
        |
        v
    TartKit
        |
        v
    Foundation.Process
        |
        v
    官方 tart 可执行文件
        |
        v
    Apple Virtualization.framework

`CommandAction` 是 CLI 透明层的边界：GUI 预览、执行历史和真正交给 Tart 的参数来自同一份 argv。

## 环境要求

- **macOS 26 Tahoe 或更高**；
- **仅支持 Apple Silicon（M1 及更新芯片）**；
- 下载 Tart 正式版或远程 OCI 镜像时需要网络连接。

## Tart 运行时

TartUI 现在把 Tart 来源作为一个明确、稳定的用户选择：

- **应用管理**：由 TartUI 下载官方 Tart 正式版到 Application Support，并负责更新与版本回退；
- **系统 Tart**：使用 Homebrew 或 PATH 中已有的 Tart，TartUI 只使用、不修改；
- **自定义路径**：只使用用户选择的可执行文件，并在保存前通过 `tart --version` 验证。

来源一旦选定就会保持稳定，不会因为之后安装了另一个 Tart 而在后台自动切换。

全新安装默认使用**应用管理**。系统 Tart 和自定义路径都由用户明确选择，TartUI 不会在后台自动切换运行时来源。

应用管理的 Tart 位于：

    ~/Library/Application Support/TartUI/Runtimes

设置页会显示当前来源、版本和路径，可以检查 Tart 官方更新、更新应用管理版本，以及回退到之前保留的版本。

TartUI 不会修改 Homebrew 或 shell 配置。

## TartUI 更新

“关于 TartUI”窗口会显示 TartUI 版本、构建号和当前 Tart 版本。

应用启动时会检查仓库最新的 GitHub Release。这个检查只负责提示，不会静默替换应用；更新仍然从 GitHub Release 页面下载。

在第一个正式 Release 发布之前，关于窗口会明确显示“目前还没有已发布的 TartUI 正式版”。

## 开发

运行测试：

    swift test

构建 debug App：

    ./scripts/bundle.sh debug

运行构建产物：

    open "$(swift build -c debug --product TartUI --show-bin-path)/TartUI.app"

构建并安装本地 release：

    ./scripts/install.sh

## 发布

推送类似 `v0.1.0` 的版本 tag 后，如果仓库已经配置 Apple 签名和公证 Secrets，GitHub Actions 会自动执行正式发布流程。

成功后 Release 会包含：

- `TartUI-<version>.dmg`；
- `TartUI-<version>.zip`；
- `SHA256SUMS`。

正式包使用 Developer ID + Hardened Runtime 签名，并在发布前完成 Apple 公证和 stapling。

所需 GitHub Secrets、打 tag 方法和本地手动发布流程见 [RELEASING.md](RELEASING.md)。

## 启动设置与数据

每台本地虚拟机只有一份 TartUI 启动设置。设置项直接对应界面中可见的 `tart run` 控件和命令预览，不再存在单独的 Profile 管理器。

查询 IP 时，共享网络、仅宿主机和 Softnet 使用 Tart 的 DHCP resolver；桥接网络会自动使用 ARP resolver。VM 详情页会在执行前显示实际的 `tart ip ...` 命令。

启动设置保存在：

    ~/Library/Application Support/TartUI/run-settings.json

TartUI 不会移动或改写 Tart 自己的虚拟机存储。

## 与 Tart 的关系

TartUI 是面向 Tart 的独立社区图形界面项目，不是 OpenAI 官方产品。

Tart 使用其自身的开源协议，详情见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。


## 平台基线

TartUI 现在明确以 macOS 26 + Apple Silicon 为唯一支持基线。应用包只构建 arm64 架构，并声明 macOS 26.0 为最低系统版本，因此可以直接使用当前 SwiftUI 设计系统，不再为旧版 macOS 保留兼容分支。
