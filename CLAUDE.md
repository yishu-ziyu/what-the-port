# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Read `AGENTS.md` first: its rules (never commit the DMG or `public/updates/`, keep the marketing demo in sync with the native UI, guide authoring rules) apply here too and are not repeated below.

## What this repo is

An unofficial Simplified Chinese fork of Tom John's WhatThePort (`upstream` remote). Two products share the repo:

- `WhatThePort/` — the native macOS menu bar app (SwiftPM, Swift 5.9, macOS 14+). Source of truth for product behavior.
- Repo root — the Next.js 14 marketing site (`app/`, `content/`, `lib/`), inherited from upstream. The fork does not deploy it.

Branches: `feature/simplified-chinese` carries only generic localization for an upstream PR; `main` adds fork-only packaging (own bundle ID, no updater), release notes and future features. Keep generic fixes upstreamable and fork policy out of that branch.

## Commands

Native app (run from `WhatThePort/`):

```sh
swift build                               # debug build
swift run                                 # run the menu bar app
swift run WhatThePort --tui               # terminal UI (same as the `wtp` symlink)
swift test --jobs 4                       # all tests (Swift Testing, not XCTest)
swift test --filter LocalizationTests     # one suite; append /methodName for one test
./build-localized.sh                      # fork release: .build/WhatThePort.app, bundle id com.whattheport.app.local.zh, updater removed, ad-hoc signed
./build-app.sh                            # upstream-style bundle (Sparkle feed from update-config.env)
```

Snapshot rendering without saving preferences: run the built binary with `--snapshot <dir>` or `--snapshot-onboarding <dir>`, plus `--ui-language zh-Hans|en`.

Website (repo root): `npm run dev`, `npm run build`. `prebuild` runs `scripts/check-*.mjs`; `check-usage-features` fails if `middleware.ts` and `Usage.Feature` in `Usage.swift` disagree.

CI: `.github/workflows/deploy.yml` in this fork is manual-only (`workflow_dispatch`) — it runs tests, `build-localized.sh`, and uploads a zip artifact. It does not deploy the site or publish a release. README sections in `UPSTREAM_README.md` about automatic Vercel deployment describe upstream, not this fork.

## Native app architecture

One executable, three modes, chosen in `WhatThePortApp.swift` `Main.main()`: terminal (`TerminalCommand.isRequested` — invoked as `wtp` or with `--tui`), snapshot rendering (`--snapshot*`, used for screenshots), or the SwiftUI `MenuBarExtra` app.

Scan pipeline (`Engine/`):
- `ServerMonitor` (ObservableObject, main actor) owns a timer at `Preferences.scanInterval` and publishes results to the UI.
- `ScanEngine` does one scan: `SocketScanner` (libproc socket fds, LISTEN/ESTABLISHED TCP; mirrors lsof's semantics) → `ProcessInspector` (libproc/sysctl: memory, CPU, cwd, args, env) → `ProjectResolver` (manifest, framework, git branch, worktree) → `AgentSessions` (links servers to Claude Code / Conductor / Codex sessions via env vars and Codex session files). It keeps cross-scan state (CPU deltas, history, caches), so reuse the instance.
- `AlertCenter` watches scans and posts notifications; `ProcessControl` stops process trees; `AppUsage` folds helper processes into per-app memory.
- Homebrew services are detected from their launchd label (`sh.brew.*` or legacy `homebrew.mxcl.*`) and set `Server.brewService`. They count as protected (no Clean up, no alerts) and are stopped/restarted via `brew services`, never by signal — launchd `KeepAlive` would restart them.
- Scans run every 2 s, so the app's own cost matters (target: under 1% CPU). Don't launch a subprocess per scan; cache anything fixed for a process's lifetime by `(pid, startTime)`. `AppUsage` only runs while the popover is open (`showsOtherApps`), else every 30 s. Measure with `sample <pid>` on a release build.
- The terminal UI (`Terminal/`) drives the same `ScanEngine`, so engine changes affect both surfaces.

`Preferences.swift` is the single registry of UserDefaults keys and defaults (views use `@AppStorage(Preferences.x)`). Guides and marketing claims must match these defaults.

## Localization

- UI strings go through `L10n.text("English text")`; the English string is the key and the fallback. Add every new key to both `Resources/en.lproj/Localizable.strings` and `Resources/zh-Hans.lproj/Localizable.strings` — `LocalizationTests` checks key sets match and format placeholders agree.
- Do not translate commands, paths, branch names, brands, CLI/TUI output, or JSON keys. `wtp` output stays English.
- Language changes apply after restart. `L10n` resolves the resource bundle embedded by `build-app.sh` before the dev-build fallback; SwiftPM may normalize `.lproj` folder names, so don't hardcode their spelling.
- The website stays English; see `LOCALIZATION.md`.

## Docs

User-facing docs (`README.md`, `ROADMAP.md`) are in Chinese; `ROADMAP.md` lists planned app-resource features that are not implemented — don't describe them as shipped. Development logs go in `docs/development/`.
