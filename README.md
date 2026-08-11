# TartUI

[中文文档](README.zh-CN.md)

TartUI is a native macOS graphical interface for [Tart](https://github.com/openai/tart), the Apple Silicon virtualization toolset for building, running, and managing macOS and Linux virtual machines.

Tart already provides the virtualization engine and a complete CLI. TartUI adds a management dashboard, reusable run profiles, operation logs, and a friendlier workflow. Release builds bundle a pinned Tart runtime, so users do not need to install Tart separately.

## What it does

- List local VMs and OCI image caches, including state and disk usage.
- Start, stop, suspend, and resume VMs.
- Create macOS VMs from IPSW files or create blank Linux VMs.
- Clone, configure, rename, delete, import, and export VMs.
- Pull from and push to OCI registries, including login and logout.
- Look up VM IP addresses and run non-interactive commands through `tart-guest-agent`.
- Preview and run cache or VM pruning operations.
- Save named run profiles for display, devices, storage, sharing, networking, and advanced `tart run` options.

The VM display is still provided by Tart's native `Virtualization.Framework` window. TartUI is the management layer; it does not embed a VNC viewer or implement virtualization itself.

## Architecture

```text
TartUI App (the only user-facing app and Dock icon)
    ↓
VMStore
    ↓
VMRuntimeCoordinator
    ├── VMRuntimeSession (state + logs)
    ├── VMDisplayDriver (native window today, embedded VNC later)
    └── VMRuntimeService
    ↓
TartKit (UI-independent command wrapper)
    ↓
TartRuntime (bundled → managed → external)
    ↓
the Tart helper Agent process
```

TartUI keeps Tart as an independent executable and consumes its JSON output. Tart is compiled from a pinned Git submodule and placed inside `TartUI.app/Contents/Helpers/tart.app`. The helper remains a separate process so the upstream runtime can be updated without an in-process rewrite.

The bundled helper is built as a macOS Agent, so the user sees one App and one Dock icon even though the VM runtime remains a separate process. Tart currently forces a regular activation policy for its native window; `Resources/tart-agent.patch` is therefore applied only during helper compilation and automatically reverted afterward. The same integration emits a private window-ready event after Tart creates the native VM window. TartUI uses that event to update the runtime state and bring the correct process window forward. The patch is intentionally kept as a small, fail-fast integration boundary: if an upstream Tart update changes that lifecycle code, the build stops and the patch must be reviewed instead of silently bringing back a second Dock icon or losing the window lifecycle signal.

## Requirements

- macOS 14.0 or later
- Apple Silicon
- An internet connection when installing or updating the managed fallback runtime

## Install

Release builds include the pinned Tart runtime. Build a signed release app and install it into Applications:

```bash
./scripts/install.sh
```

The script builds the Tart submodule, signs the helper with the project-owned virtualization entitlements, signs the outer App, and uses a Developer ID certificate when available. It falls back to an ad-hoc signature suitable for local use. Distribution requires Developer ID signing and notarization.

For an already-built release distributed by the project, users only need to open `TartUI.app`. If the bundled runtime is missing, TartUI can download the official latest Tart release into its managed fallback directory without modifying Homebrew or shell configuration. The bundled runtime remains preferred so the Agent integration and single-Dock-icon behavior stay intact; bundled Tart updates are delivered through the pinned submodule and the scheduled update workflow.

## Development

Run the unit and integration test suite:

```bash
swift test
```

Initialize the read-only Tart source and inspect the pinned version:

```bash
git submodule update --init --recursive
git -C Vendor/tart log -1 --oneline
```

Build a debug `.app` without installing it:

```bash
./scripts/bundle.sh
```

The script uses `Vendor/tart` first and the sibling `../tart` checkout as a development fallback. When building from source, it temporarily applies the Agent integration patch and restores the checkout after compilation. To use another checkout or an existing binary:

```bash
TARTUI_TART_SOURCE_DIR=/path/to/tart ./scripts/bundle.sh debug
TARTUI_TART_BINARY=/path/to/tart ./scripts/bundle.sh debug
```

An externally supplied prebuilt Tart binary cannot receive the TartUI Agent integration patch. Use the bundled source build for the single-Dock-icon experience; external Tart remains a supported diagnostic fallback.

To use an Apple Development identity and the Tart helper provisioning profile downloaded by Xcode:

```bash
TARTUI_SIGN_IDENTITY=<Apple-Development-SHA1> \
TARTUI_TART_PROVISION_PROFILE=/path/to/TartUI-Tart-Helper-Development.provisionprofile \
./scripts/bundle.sh debug
```

The bundler can also find a matching profile in Xcode's local profile cache. The profile is never committed to the repository. On macOS 26, Apple's portal VMNet capability grants `com.apple.developer.networking.vmnet`. Tart's current `--net-bridged` implementation uses the separately restricted `com.apple.vm.networking` entitlement, so Shared (NAT) is the supported network mode until Apple grants that restricted entitlement.

To create a notarized DMG, first store a notarytool profile in your login keychain and then run:

```bash
TARTUI_VERSION=0.1.0 \
TARTUI_NOTARY_PROFILE=tartui \
./scripts/release.sh
```

Signing certificates and notarization credentials must stay in the local keychain or CI secrets; they are never committed to this repository.

Run the resulting app with:

```bash
open .build/arm64-apple-macosx/debug/TartUI.app
```

The app should be run as a real `.app` bundle. A bare `swift run` executable does not have the bundle metadata needed by SwiftUI's `WindowGroup`.

### Updating Tart

Tart is kept as a pinned submodule so an upstream change is never picked up silently. Update it locally with:

```bash
./scripts/update-tart.sh
```

The scheduled GitHub Actions workflow runs this check weekly and opens a pull request when a new stable Tart tag is available. The PR must pass TartUI tests and packaging checks before it is merged and released.

## Localization

English is the development language and the first-run default, independently of the macOS system language. Choose **TartUI > Settings > Language** to switch immediately between English, Simplified Chinese, and the macOS system language. The choice persists across launches.

Localized UI resources live under:

```text
Sources/TartUI/Resources/en.lproj/Localizable.strings
Sources/TartUI/Resources/zh-Hans.lproj/Localizable.strings
```

To add another language, create a new `<language>.lproj/Localizable.strings` directory and add its locale to the app bundle metadata in `scripts/bundle.sh`. Keep the English key as the source-of-truth key and add the translated value in the new string table.

## Data and compatibility

Run profiles are stored at:

```text
~/Library/Application Support/TartUI/run-profiles.json
```

TartUI automatically reads the previous `TartPro` profile directory and binary-path preference, then writes new changes to the `TartUI` locations. Existing VM data under Tart's own home directory is not moved or modified.

Runtime logs are stored under:

```text
~/Library/Logs/TartUI
```

## Licensing and attribution

TartUI uses the Functional Source License, Version 1.1, ALv2 Future License. Tart and its dependencies retain their original licenses; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) and the unmodified license at `Vendor/tart/LICENSE`.

TartUI is an independent community UI for Tart. It is not affiliated with or endorsed by OpenAI.

## Testing strategy

- Unit tests use a mock executor for command construction and JSON decoding.
- Integration tests use the real Tart binary but only run read-only commands.
- Live VM tests are opt-in because they start, stop, create, rename, and delete real VMs:

  ```bash
  TARTUI_LIVE_VM=<vm-name> swift test --filter LiveVMTests
  TARTUI_LIVE_CRUD=1 swift test --filter LiveCRUDTests
  ```

## Known limitations

- Tart's VM display is still provided by its native Virtualization Framework window; the display-driver boundary is ready for a future embedded VNC implementation.
- `exec` requires `tart-guest-agent` inside the guest.
- Tart's `prune` command has no dry-run mode. The cache preview cannot see IPSW installer caches.
- Quitting TartUI does not stop running VMs; they continue in the background after confirmation.
