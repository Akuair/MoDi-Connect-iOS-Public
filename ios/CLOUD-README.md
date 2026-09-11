# MoDi Connect — independent iOS research client

This repository contains the iOS additions to [LaoYinBai/MoDi-Connect](https://github.com/LaoYinBai/MoDi-Connect), uploaded for cloud compilation on 2026-09-11. It is not an official release or an endorsement by the upstream author.

The iOS application sources and modifications are distributed under GPL-3.0-or-later; see LICENSE. Third-party dependencies retain their own licenses; see ios/THIRD-PARTY-NOTICES.md. The proprietary MoDi binaries are not included in this repository or the iOS app. CI obtains an unchanged upstream copy with its notices solely for compatibility checks and verifies its SHA-256.

See [iOS build and usage instructions](ios/README.md) and [compatibility test status](ios/WIRE-COMPATIBILITY.md).

The workflow targets Xcode 27 and produces an **unsigned** arm64 IPA, which requires personal signing before installation. Compilation and real iPhone-to-Windows playback are not yet verified. Android and Windows implementations are unchanged and remain in the upstream repository.
