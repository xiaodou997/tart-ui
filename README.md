# TartUI

[简体中文](README.zh-CN.md)

TartUI is a native Apple Silicon macOS GUI for the official [Tart](https://github.com/openai/tart) CLI.

The design goal is deliberately narrow: **make common Tart commands easier to configure and run without hiding the CLI**. Tart remains the source of truth for virtual machines, runtime state and OCI data.

## What TartUI does

The main workflow is intentionally small:

- discover an existing Tart installation, or install an official Tart release when Tart is missing;
- list local VMs and OCI image-cache entries separately;
- clone an OCI image directly into a local VM;
- create macOS or Linux VMs when a blank/new VM is needed;
- start, stop, suspend, clone and delete local VMs;
- edit common VM configuration;
- cache OCI images with `tart pull`;
- log in to or out of OCI registries;
- keep one visible launch-settings value per VM, including display, suspend, sharing and network mode;
- import Tart VM exports, prune disk usage and look up a VM IP address.

Every user-triggered Tart operation keeps the CLI visible. TartUI shows the command before execution and records its state, exit code, stdout and stderr afterwards.

For example:

    tart run dev --suspendable
    tart clone ghcr.io/cirruslabs/macos-sequoia-base:latest dev
    tart set dev --cpu 4 --memory 8192
    tart stop dev

Commands can be copied and run independently in Terminal.

## What TartUI is not

TartUI is not a second virtualization platform and does not implement a replacement VM engine.

It does not:

- compile or embed a fork of Tart;
- own the VM display window;
- rewrite Tart's VM storage;
- hide OCI cache entries as runnable VMs;
- try to be an image marketplace or a large virtualization-management suite.

The VM display window and virtualization lifecycle are owned by Tart itself.

## Architecture

    TartUI (SwiftUI)
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
    official tart executable
        |
        v
    Apple Virtualization.framework

`CommandAction` is the transparency boundary: the same argv is used for the GUI preview, execution history and the actual Tart process.

## Requirements

- **macOS 26 Tahoe or newer**;
- **Apple Silicon only (M1 or newer)**;
- network access when downloading Tart releases or remote OCI images.

## Tart runtime

TartUI keeps the runtime source explicit and stable. You can choose:

- **Application Managed**: TartUI downloads the official Tart release into Application Support and manages updates and rollback;
- **System Tart**: TartUI uses Tart from Homebrew or PATH and never modifies that installation;
- **Custom Path**: TartUI uses exactly the executable you select after validating it with `tart --version`.

Once selected, TartUI stays on that source instead of silently switching when another Tart installation appears later.

Fresh installations default to **Application Managed**. System Tart and Custom Path are explicit choices; TartUI does not silently switch runtime sources.

Managed Tart runtimes are stored under:

    ~/Library/Application Support/TartUI/Runtimes

Settings show the active source, version and path, can check upstream Tart releases, update a managed runtime and roll back to a retained managed version.

TartUI does not modify Homebrew or shell configuration.

## TartUI updates

The About window shows the TartUI version, build number and active Tart version.

TartUI checks the repository's latest GitHub Release at startup. The check is informational only: updates are downloaded from the GitHub Release page rather than silently replacing the application.

Before the first tagged release exists, the About window reports that no published release is available.

## Development

Run tests:

    swift test

Build a debug app bundle:

    ./scripts/bundle.sh debug

Run it:

    open "$(swift build -c debug --product TartUI --show-bin-path)/TartUI.app"

Build and install a local release:

    ./scripts/install.sh

## Releases

A version tag such as `v0.1.0` triggers the release workflow when the required Apple signing/notarization secrets are configured.

A successful release publishes:

- `TartUI-<version>.dmg`;
- `TartUI-<version>.zip`;
- `SHA256SUMS`.

Developer ID releases use Hardened Runtime, are notarized with Apple and have the notarization ticket stapled before publication.

See [RELEASING.md](RELEASING.md) for the required GitHub Secrets and the local/manual release procedure.

## Launch settings and data

Each local VM has one TartUI launch-settings value. The settings map directly to the visible `tart run` controls and the command preview; there is no separate profile manager.

For IP lookup, TartUI uses Tart's DHCP resolver for Shared, Host Only and Softnet networking, and automatically uses the ARP resolver for Bridged networking. The exact `tart ip ...` command is shown in the VM detail view before execution.

Launch settings are stored at:

    ~/Library/Application Support/TartUI/run-settings.json

TartUI does not move or rewrite Tart's own VM storage.

## Relationship to Tart

TartUI is an independent community GUI for Tart. It is not an official OpenAI product.

Tart is distributed under its own license. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).


## Platform baseline

TartUI intentionally targets macOS 26 and Apple Silicon only. The app bundle is built as arm64-only and declares macOS 26.0 as its minimum system version. This lets the UI use the current SwiftUI design system directly instead of carrying compatibility branches for older macOS releases.
