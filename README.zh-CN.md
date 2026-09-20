# TartUI 中文文档

[English](README.md)

TartUI 是 Tart 的原生 macOS 图形界面。

TartUI 本身不实现虚拟化。它调用官方 Tart 命令行运行时，把常见的 Tart 操作包装成 macOS GUI。

## 项目定位

Tart 是虚拟机、运行状态、网络、显示窗口、OCI 操作和 guest 集成的唯一事实来源。

TartUI 只负责：

- 查找用户已经安装的 Tart；
- 用户没有安装 Tart 时，安装官方正式版；
- 查看本地虚拟机和 OCI 缓存；
- 创建、克隆、启动、停止和挂起虚拟机；
- 修改虚拟机配置；
- 用 Run Profile 生成和保存 tart run 参数；
- OCI 仓库 pull、push、login 和 logout；
- 导入、导出、清理、IP 查询和 guest 命令执行；
- 在 GUI 中展示命令输出和错误。

虚拟机显示窗口由 Tart 自己创建和管理。

## 架构

    TartUI（SwiftUI）
        |
        v
    VMStore
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

TartUI 不再编译 Tart 源码，不维护 Tart fork，也不需要自己申请虚拟化 entitlement。

## 环境要求

- macOS 14 或更高
- 运行 Tart 虚拟机需要 Apple Silicon
- 下载托管 Tart 运行时或远程虚拟机镜像时需要网络连接

## Tart 运行时

正常情况下 TartUI 按以下方式使用 Tart：

1. 用户手动指定的 Tart 路径；
2. 系统中已经安装的 Tart，例如 /opt/homebrew/bin/tart；
3. TartUI 下载并管理的官方 Tart 正式版。

如果没有找到 Tart，首次启动页面提供三种方式：

- **安装官方 Tart**：TartUI 从 GitHub 下载官方正式版；如果上游提供校验和则先进行校验，并验证 macOS 代码签名后再启用。
- **选择已有 Tart**：手动选择电脑上的 `tart` 可执行文件。只有 `tart --version` 验证成功后才会保存该路径。
- **Homebrew**：用户也可以自行安装：

    brew install openai/tools/tart

TartUI 管理的运行时保存在：

    ~/Library/Application Support/TartUI/Runtimes

托管版本会按版本号并存。设置页可以检查官方最新版、更新 TartUI 托管的 Tart，并回退到之前保留的托管版本。系统安装或手动选择的 Tart 仍由用户原来的安装方式负责更新。

TartUI 不会修改 Homebrew，也不会修改用户的 shell 配置。

## 开发

运行测试：

    swift test

构建 debug App：

    ./scripts/bundle.sh debug

运行构建产物：

    open "$(swift build -c debug --product TartUI --show-bin-path)/TartUI.app"

构建并安装本地 release：

    ./scripts/install.sh

生成公证 DMG：

    TARTUI_VERSION=0.1.0 TARTUI_NOTARY_PROFILE=tartui ./scripts/release.sh

## 数据

Run Profile 保存在：

    ~/Library/Application Support/TartUI/run-profiles.json

TartUI 不会移动或改写 Tart 自己的虚拟机存储。

## 与 Tart 的关系

TartUI 是面向 Tart 的独立社区图形界面项目，不是 OpenAI 官方产品。

Tart 使用其自身的开源协议，详情见 THIRD_PARTY_NOTICES.md。
