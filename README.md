# TartUI

[简体中文](README.zh-CN.md)

TartUI is a native macOS graphical interface for Tart.

TartUI does not implement virtualization itself. It invokes the official Tart command-line runtime and turns common Tart workflows into a macOS GUI.

## Project scope

Tart remains the source of truth for virtual machines, runtime state, networking, display windows, OCI operations and guest integration.

TartUI focuses on:

- discovering an installed Tart runtime;
- installing an official Tart release when Tart is missing;
- listing local VMs and OCI cache entries;
- creating, cloning, starting, stopping and suspending VMs;
- editing VM configuration;
- building reusable tart run arguments through Run Profiles;
- pull, push, login and logout for OCI registries;
- import, export, prune, IP lookup and guest command execution;
- showing command output and errors in the GUI.

The VM display window is created and owned by Tart itself.

## Architecture

    TartUI (SwiftUI)
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
    official tart executable
        |
        v
    Apple Virtualization.framework

TartUI does not compile Tart source code, does not vendor a Tart fork, and does not require virtualization entitlements of its own.

## Requirements

- macOS 14 or newer
- Apple Silicon for running Tart virtual machines
- network access when downloading a managed Tart runtime or remote VM images

## Tart runtime discovery

TartUI supports three normal runtime sources:

1. A path explicitly selected by the user.
2. An existing system installation, including Homebrew locations such as /opt/homebrew/bin/tart.
3. A managed official Tart release downloaded by TartUI into Application Support.

If Tart is not available, the first-run screen can install the official release for the user. Users can also install Tart themselves with Homebrew:

    brew install openai/tools/tart

Managed runtimes are stored under:

    ~/Library/Application Support/TartUI/Runtimes

TartUI does not modify Homebrew or the user's shell configuration.

## Development

Run tests:

    swift test

Build a debug app bundle:

    ./scripts/bundle.sh debug

Run the built app:

    open "$(swift build -c debug --product TartUI --show-bin-path)/TartUI.app"

Build and install a release build locally:

    ./scripts/install.sh

Create a notarized release DMG:

    TARTUI_VERSION=0.1.0 TARTUI_NOTARY_PROFILE=tartui ./scripts/release.sh

## Data

Run Profiles are stored at:

    ~/Library/Application Support/TartUI/run-profiles.json

TartUI does not move or rewrite Tart's VM storage.

## Relationship to Tart

TartUI is an independent community graphical interface for Tart. It is not an official OpenAI product.

Tart is distributed under its own license. See THIRD_PARTY_NOTICES.md for details.
