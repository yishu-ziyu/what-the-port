# WhatThePort

> Every dev server on your Mac, in the menu bar. WhatThePort is a free, open-source macOS menu bar app that shows what’s running on localhost: each dev server’s port, project, git branch, uptime, memory and CPU, and the Claude Code, Codex or Conductor session that started it. Stop the ones you forgot about in one click.

- Website and interactive demo: https://whattheport.dev
- Download (Apple Silicon, macOS 14 or later): https://whattheport.dev/WhatThePort.dmg
- Source code (MIT): https://github.com/tomjohndesign/what-the-port
- Guides: https://whattheport.dev/guides
- Price: free. No account.
- Made by Tom John (https://tomjohn.design)

## What it does

- **Every dev server at a glance.** Port, project name, git branch, uptime and memory for each local server, with stable port colors and a whole-Mac memory bar for servers, other apps and free RAM.
- **Knows which agent started it.** Servers launched by Claude Code, Codex or Conductor link back to the session that started them, so you can resume the conversation (`claude --resume`, `codex resume`) or find the Conductor workspace.
- **Leak detection.** When a server passes 2 GB of memory or grows more than 500 MB in ten minutes, its memory reading and the menu bar icon turn amber and you get one notification with Details, Stop and Snooze. Thresholds are adjustable.
- **Resource charts.** Ten minutes of memory and CPU history per server, summed across its own process tree.
- **Clean up.** Preselects servers from deleted git worktrees or idle for hours, then stops each server’s own process tree in bulk. Postgres, Redis, MongoDB and MySQL are protected by default. Cleanup can be Off, Ask or Automatic; leaking servers are never stopped automatically.
- **Stop and restart.** Stop sends SIGTERM to the server’s own process tree, then SIGKILL after a short delay. Restart reruns the original command in the same folder.
- **Previews and pull requests (optional).** A Vercel preview button and the branch’s pull request, through the GitHub CLI you’re already signed in to.
- **Terminal UI.** `wtp` shows the same servers, details and Clean up in your terminal. `wtp list --json` prints them as JSON for scripts and coding agents.
- **Global shortcut.** ⌥⌘P opens the popover.
- **Screenshot to clipboard.** Enable the ⌘X shortcut in Settings → General to select an area and copy the image directly to the clipboard. Esc cancels without replacing it. The shortcut is off by default because it replaces Cut in other apps while enabled.
- **Interface language.** English and Simplified Chinese, selected in Settings → General → Language. Restart to apply; terminal output and user data are unchanged.
- **Native.** Written in Swift. No Electron, no Dock icon. Light and dark mode.

## Install

1. Download https://whattheport.dev/WhatThePort.dmg and open it.
2. Drag WhatThePort onto the Applications shortcut, then open it from Applications.
3. Start a dev server, then click the dot grid in the menu bar or press ⌥⌘P.

The prebuilt download is for Apple Silicon Macs running macOS 14 Sonoma or later. Updates are signed and install automatically when you quit. To build from source you need Swift 5.9 or later: `cd WhatThePort && swift build`.

## The wtp command

Onboarding offers to install `wtp`, or click Install… in Settings → General → Terminal. It links `/usr/local/bin/wtp` to the app.

```
wtp               Browse, open and stop servers
wtp list          Print servers and exit
wtp list --json   Print servers as JSON
wtp --version     Print the version
```

`wtp list --json` prints an array of servers. Each has `port`, `url`, `pid`, `name`, `branch`, `framework`, `folder`, `command`, `startedAt`, `memoryBytes`, `cpuPercent`, `status` (`running`, `attention` or `idle`), `protected`, `processes` and, when an agent started it, `session` (`kind`, `id`, `title`).

## How it works

WhatThePort reads listening TCP sockets through `libproc`, then inspects each server’s process tree through `libproc` and `sysctl`: memory footprint, CPU time, working directory, arguments and environment. From the working directory it finds the project manifest (package.json, pyproject.toml, Cargo.toml, go.mod, Gemfile), framework and git branch. Session links come from environment variables that Claude Code and Conductor pass to the commands they run, and from Codex’s session files. It rescans every 2 seconds. In monorepos, sibling servers stay separate from their shared task runner. When one process serves several ports, each row shows the service’s usage; totals count each process once, and the memory bar divides shared usage between those ports. Stopping or restarting that process affects all ports it serves.

By default it watches ports 3000–65535 and processes that look like dev servers: node, bun, deno, python, uvicorn, gunicorn, ruby, rails, puma, php, java, go, cargo, dotnet, elixir, nginx, postgres, redis, mongod, mysql and more. Both are configurable in Settings → Ports & processes.

Frameworks it recognizes include Next.js, Nuxt, Remix, Astro, SvelteKit, Vite, Expo, Angular, Create React App, Hono, Express, Storybook, Django, FastAPI, Flask, Rails, Rust and Go.

## Privacy

There’s no account and no analytics SDK. Everything the app shows comes from your Mac and stays there. It only goes online to check for updates, to send an anonymous once-a-day count of which features were used (no identifiers, and you can turn it off), and, if you turn them on, to look up Vercel previews and pull requests through the GitHub CLI.

## FAQ

### Is WhatThePort free?

Yes. It’s free and open source under the MIT license, with no account and no paid tier. There’s an optional tip jar.

### Does it work on Intel Macs or older macOS?

The prebuilt download is for Apple Silicon Macs on macOS 14 Sonoma or later. You can build it from source with Swift 5.9 or later.

### How is it different from `lsof` or `npx kill-port`?

Those answer one question about one port. WhatThePort keeps every dev server in view all the time, names them by project and branch, shows memory and CPU for the server’s own process tree, warns you about leaks, links servers to the agent session that started them, and stops the whole tree, not just one PID.

### Will it stop my database?

Not unless you choose to. Postgres, Redis, MongoDB and MySQL are protected from Clean up by default, and you can edit the protected list.

### Can a coding agent use it?

Yes. `wtp list --json` gives agents a machine-readable list of every server, its port, folder, branch, status and the session that started it, so an agent can reuse a running server instead of starting a duplicate on the next port.

### Where is the menu bar icon?

It’s a small 5×5 dot grid showing a colon. If the menu bar is full, macOS hides icons that don’t fit: click » at its edge on macOS 27, or check System Settings → Menu Bar. Opening WhatThePort again from Finder or Spotlight shows the popover.

## Fork-only AI usage (local build 21)

The local menu adds nine provider entries: Codex, Claude, Cursor, OpenCode Go, Antigravity, z.ai, MiniMax, Kimi Code and StepFun. Provider-specific returned names, periods, reset times, third/extra windows and service rows drive Pace/Ring views. Codex Pro reporting weekly only remains one window. StepFun reporting credit quota without reset timing receives no synthetic hourly/weekly limit. Local estimates cannot establish remaining quota and receive no quota rings or pace prediction. Errors are independent; temporary failures preserve measurement time, rejected login hides current quota. The bundled CodexBar CLI 0.68.0 uses an isolated private configuration, copied once without altering the original. Browser/external account identity cannot be established before query, so non-Codex disk caches are not restored. The website examples are deterministic and explicitly labeled, never access visitor credentials. Real queries succeeded for eight providers. Claude uses an explicitly authorized read of the default Claude Code Keychain item and the official OAuth usage endpoint; the token stays in memory and third-party API environment values are removed for that query. OpenCode Go currently supplies only an estimate. Local bilingual builds keep a stable certificate identity to preserve Screen Recording grants across updates; real repeated-screenshot acceptance is still pending. Full history migration, multi-account management and CodexBar retirement remain pending. This is not a published download claim.

## Fork-only live captions

The Chinese fork adds a floating Live captions window, opened from Settings → General or the menu bar’s right-click menu. Choose StepAudio 2.5 ASR through Step Plan (audio sent to StepFun) or the separately installed local SenseVoice-Small model. English text is translated with Step 3.7 Flash through Step Plan, including when recognition is local; Chinese mode shows original captions without translation. The compact floating panel shows the current segment, Chinese translation above optional English original text. While translation is pending, the original remains readable. Review opens a fixed snapshot of recent segments; new captions do not replace those being reviewed. Model and language controls are in Caption settings and require stopping capture before changing. Controls use a single top row; review, settings and close appear on hover or keyboard focus. Solid and transparent viewing modes are available. Height follows the caption content, with scrolling for long segments. The window can be moved, resized in width and remembers its position. Short audio segments introduce latency; this is not word-by-word transcription. No microphone is captured. Closing the window stops capture and cancels model requests. Cloud capture buffers audio in memory; local recognition uses a private temporary WAV deleted after processing. Captions are not saved to files. Credentials are read from the user's existing local provider store, not embedded in the app. Provider errors are visible; there is no automatic fallback to another provider or a pay-as-you-go endpoint. This model integration remains unpublished and its installed-app acceptance is still pending.
