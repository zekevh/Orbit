<div align="center">
  <h1>Orbit</h1>
</div>

<p align="center">
  <a href="https://github.com/zekevh/Orbit/releases/latest"><img src="https://img.shields.io/badge/download-latest-brightgreen?style=flat-square"></a>
  <img src="https://img.shields.io/badge/platform-macOS-blue?style=flat-square">
  <img src="https://img.shields.io/badge/built%20with-Swift-orange?style=flat-square">
</p>

Orbit is a native macOS contact workspace that mirrors Apple Contacts and layers notes, insights, follow-ups, and WhatsApp-assisted verification on top.

## Install

```sh
brew install --cask zekevh/tap/orbit
```

Or download the latest DMG from the [GitHub releases page](https://github.com/zekevh/Orbit/releases/latest).

## Build

Requirements:

- Xcode 16+
- macOS 15+ for local development

Open the project in Xcode:

```sh
open Orbit.xcodeproj
```

Or build from the command line:

```sh
./scripts/run-build.sh
```

## Release

Pushing a tag in the form `v1.0.0` triggers the release workflow in GitHub Actions. That workflow:

- archives and exports `Orbit.app`
- creates `Orbit-<version>.dmg`
- publishes the DMG to GitHub Releases
- updates `Casks/orbit.rb` in `zekevh/homebrew-tap`

Required GitHub secret:

- `TAP_GITHUB_TOKEN`: token with push access to `zekevh/homebrew-tap`
