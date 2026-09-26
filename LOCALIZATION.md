# Native interface localization

The macOS interface supports English and Simplified Chinese. Settings → General → Language offers System default, 简体中文 and English. Changes apply after restarting so active scans and sessions retain their state.

Translations use standard `Localizable.strings` resources in `en.lproj` and `zh-Hans.lproj`. `L10n` selects the persisted language and resolves the packaged resource bundle; missing keys fall back to English. Format placeholders preserve dynamic names and values. Commands, project paths, branch names, brands, CLI/TUI output and JSON keys are not translated.

`swift build` processes the resources, while `./build-app.sh` embeds the SwiftPM resource bundle in the application. The resolver checks that embedded bundle before the development-build fallback. SwiftPM may normalize localization folder names, so lookup uses the resource bundle's declared spelling.

For validation, `swift test` checks language selection, actual Chinese resource lookup, matching key sets and format placeholders. The existing `--snapshot` mode accepts `--ui-language zh-Hans` or `--ui-language en` to render each language without saving preferences. Popover snapshots use AppKit window capture for native controls, as the settings and onboarding snapshots already do.

English remains the default fallback. The website and marketing demo still show the unchanged English variant. Language selection is a native Settings control with no corresponding marketing demo screen; no new website language UI is introduced.

## Independent fork builds

This fork additionally provides `./WhatThePort/build-localized.sh`. It builds version 2.5.1, uses `com.whattheport.app.local.zh`, includes license notices and disables the upstream updater. This packaging policy is not included in the upstream localization PR. The fork's Actions workflow is manual and builds an artifact without deploying a website or publishing a release.
