# Releasing TartUI

TartUI releases are expected to be Developer ID signed and Apple-notarized. Do not publish the ad-hoc-signed output from a normal development build as an official release.

## Release artifacts

For version `0.1.0`, `scripts/release.sh` creates:

- `dist/TartUI-0.1.0.dmg`;
- `dist/TartUI-0.1.0.zip`;
- `dist/SHA256SUMS`.

The app is notarized and stapled before the final ZIP is created. The DMG is then notarized and stapled separately.

## GitHub Actions secrets

The `.github/workflows/release.yml` workflow requires these repository secrets:

| Secret | Contents |
| --- | --- |
| `MACOS_CERTIFICATE` | Developer ID Application certificate exported as a `.p12`, then base64 encoded |
| `MACOS_CERTIFICATE_PASSWORD` | Password used when exporting the `.p12` |
| `KEYCHAIN_PASSWORD` | Temporary CI keychain password |
| `APPLE_NOTARY_KEY` | App Store Connect API private key (`AuthKey_*.p8`), base64 encoded |
| `APPLE_API_KEY_ID` | App Store Connect API key ID |
| `APPLE_API_ISSUER_ID` | App Store Connect API issuer ID |

On macOS, files can be encoded without line wrapping with:

    base64 -i DeveloperID.p12 | pbcopy
    base64 -i AuthKey_XXXXXXXXXX.p8 | pbcopy

Keep the original certificate and API key private. Do not commit them to the repository.

## Creating a GitHub Release

1. Confirm `main` is green in CI.
2. Choose a semantic version such as `0.1.0`.
3. Create and push the version tag:

       git switch main
       git pull --ff-only
       git tag v0.1.0
       git push origin v0.1.0

4. The **Release** workflow imports the Developer ID certificate, configures `notarytool`, runs `scripts/release.sh`, verifies `SHA256SUMS`, and creates the GitHub Release.
5. Download the published DMG on another Mac and perform a first-launch smoke test.

The tag without its leading `v` becomes `CFBundleShortVersionString`. The GitHub Actions run number is used as `CFBundleVersion`.

## Local/manual release

First make sure a **Developer ID Application** certificate is available:

    security find-identity -v -p codesigning

Create a reusable notarytool profile, for example:

    xcrun notarytool store-credentials tartui \
      --key /path/to/AuthKey_XXXXXXXXXX.p8 \
      --key-id XXXXXXXXXX \
      --issuer 00000000-0000-0000-0000-000000000000

Then run:

    TARTUI_VERSION=0.1.0 \
    TARTUI_BUILD_NUMBER=1 \
    TARTUI_NOTARY_PROFILE=tartui \
      ./scripts/release.sh

Verify the generated checksums:

    cd dist
    shasum -a 256 -c SHA256SUMS

## Smoke-test checklist

Before announcing a release, verify:

- TartUI launches without a Gatekeeper warning on a clean test Mac;
- About shows the expected TartUI version and build number;
- Tart detection/managed installation still works;
- Clone Image shows and executes the same `tart clone ...` command;
- a local VM can Start, Stop and Suspend where supported;
- command history shows the actual command, state, stdout and stderr;
- OCI Image Cache entries cannot be started as local VMs;
- both English and Simplified Chinese resources load;
- the GitHub Release contains DMG, ZIP and `SHA256SUMS`.

## First public release

Before the first public tag, update the README screenshots using a notarized build so the UI shown in documentation matches the shipped application.
