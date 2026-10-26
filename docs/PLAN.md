# Plan: a modern native rsync GUI for macOS (name: "Brook" (provisional — may change))

## Context

The only maintained native rsync front-end on the Mac is RsyncUI (rsyncOSX). It works, but it leans on rsync jargon, its UI is crowded, and its flows are hard to follow. The goal is a beautiful, minimal, native macOS app that:
- a non-technical user can set up in under a minute ("back up this folder to that drive") without ever seeing a flag, and
- gives power users full control: raw flags, filters, SSH options, hooks and a live command preview.

The project folder (`rsync-gui/`) is empty, so this is a greenfield build.

**Decisions so far:**
- **Distribution:** direct download, Developer ID signed and notarized, with Sparkle updates and a Homebrew cask. There is no sandbox.
- **Minimum OS:** macOS 26 or later. That gives native Liquid Glass and current SwiftUI with no `#available` branches.
- **rsync binary:** a bundled rsync 3.x helper (GPLv3: we publish its source and the build script). Users can switch to Homebrew or a custom binary.
- **v1 scope:** local syncs, remote syncs over SSH, time-based scheduling, a menu bar companion and notifications.
- **Roadmap (not in v1):** snapshots with `--link-dest`, drive-connect triggers, a CLI, Shortcuts support.

**Environment notes:**
- `xcode-select` currently points at CommandLineTools. You'll need to run `sudo xcode-select -s /Applications/Xcode.app` once.
- The system `/usr/bin/rsync` is openrsync (protocol 29). It must never be the default.
- Homebrew rsync 3.5.0 is installed and can be used for development until the bundled build exists.

---

## 1. Product & UX design

### Mental model (plain language, no jargon)
- **Sync**: one saved job. It has a source, a destination and a mode. ("Task" and "profile" are not user-facing words.)
- **Modes**, each explained with a small diagram in the editor:
  - **Copy new & changed** (the default): adds and updates files and never deletes anything.
  - **Mirror**: makes the destination identical to the source (`--delete`). It is shown with an orange "can delete files" badge.
  - We state clearly that rsync is one-way. There is no fake "two-way" mode.
- **Trailing slash footgun, abstracted:** a toggle reads "Copy the folder itself" / "Copy only what's inside". Next to it, a live sentence shows the result, for example "Files will end up in `/Volumes/Backup/Photos/…`".
- **Preview, then Run:** a dry run is one click and is never required, except before the first run of a Mirror sync. The preview shows counts (added / updated / deleted / size) and a browsable change list.

### Safety rails (these differentiate us from RsyncUI)
- **Missing-destination guard:** store the volume UUID for destinations under `/Volumes/…`. If the drive isn't mounted, fail with "Backup drive isn't connected" instead of letting rsync create `/Volumes/Backup` on the boot disk.
- **Deletion guard:** if a Mirror run would delete more than N files or X% of the destination (both configurable), pause and ask. A scheduled run skips and sends a notification instead.
- **Empty/unmounted source guard:** never mirror an empty source over a full destination without confirmation.
- **Human-readable errors:** translate exit codes (1, 2, 3, 5, 10, 11, 12, 23, 24, 30, 35, …) and common stderr patterns (permission denied, host key changed, no space left, connection refused) into plain sentences with a fix-it action. Exit code 24 ("files vanished") counts as a warning, not a failure.
- **Full Disk Access onboarding:** detect "Operation not permitted" on TCC-protected paths, then show an inline card with an "Open Privacy Settings" button.

### Information architecture (macOS 26 Liquid Glass, `NavigationSplitView`)
- **Sidebar:** All Syncs · user-created Groups · Activity (global run history) · Remote Hosts.
- **Content column:** sync cards showing name, icon, source → destination, last-run status chip, next scheduled run, and an inline Run button.
- **Detail:** a header with big Run / Preview buttons, a "Last run" summary, then sections for What & Where, Schedule, and History.
- **Run view:** an overall progress bar (from `--info=progress2`), current file, speed, ETA and transferred size. There are Pause (SIGSTOP/SIGCONT) and Stop controls, and an expandable live log.
- **Results view:** a summary plus a change list grouped by Added / Updated / Deleted / Errors. It has search, Reveal in Finder and Copy path.
- **Menu bar extra:** overall status icon, which animates while running. It lists syncs with Run now, shows running progress and the next scheduled run, and has an Open window item.
- **Empty state / onboarding:** template cards ("Back up a folder to an external drive", "Mirror to a server/NAS", "Download from a server"). You can also drag a folder onto the window to start a sync.
- **Keyboard:** ⌘N new · ⌘R run · ⌘⇧R preview · ⌘. stop · ⌘D duplicate · ⌘⌫ delete (with confirmation).

### Progressive disclosure in the editor (one sheet, three tiers)
1. **Basic:** source, destination (local picker or remote host plus remote browser), mode, folder-vs-contents toggle and schedule.
2. **Options (collapsed):** exclude rules with presets (`.DS_Store`, caches, `node_modules`, `.git`) and a pattern tester ("this would exclude 1,204 files"), plus checksum compare, compression, bandwidth limit, preserve xattrs/ACLs, keep partial files, backup changed files to a folder (`--backup-dir`), and deletion-guard thresholds.
3. **Advanced (collapsed):** raw extra arguments (a token field), SSH overrides, remote `--rsync-path`, pre/post shell hooks (with an abort-on-failure option), environment variables and the rsync binary override.
- **Always visible at the bottom:** a monospaced **command preview** with a Copy button. It updates live and is the power user's ground truth.

### Visual language
Native controls only, SF Symbols, Liquid Glass toolbar and sidebar, and one accent color. Each sync has a user-chosen icon and color. Status colors are green (ok), orange (warnings), red (failed) and grey (never run). Labels use sentence case and plain words; flag names appear only as tooltips in Options and Advanced. The app supports VoiceOver labels on every control, Reduce Motion and full keyboard navigation.

---

## 2. Architecture

### Process model (one process, simple and robust)
- There is a single app with a `Window` scene and a `MenuBarExtra`, registered as a login item via `SMAppService.mainApp`.
- Closing the window switches the activation policy to `.accessory`, so the app keeps living in the menu bar and keeps running schedules. Quitting stops schedules, and Settings says so clearly.
- This avoids XPC between an agent and the UI in v1. All runs go through one `RunCoordinator` actor, which queues runs and serialises runs per destination.

### Modules (local Swift package `SyncCore` plus a thin app target)
```
rsync-gui/
  project.yml                 # XcodeGen → Brook.xcodeproj (diffable project)
  App/                        # SwiftUI app target
    BrookApp.swift            # scenes: Window, MenuBarExtra, Settings
    Features/{Sidebar,SyncList,SyncDetail,Editor,Run,Results,History,Hosts,Onboarding,MenuBar,Settings}/
  Packages/SyncCore/
    Sources/SyncModel/       # SyncJob, Endpoint, RemoteHost, Schedule, RsyncOptions, RunRecord (Codable, Sendable)
    Sources/RsyncCore/        # CommandBuilder, RsyncRunner, ProgressParser, ItemizeParser, StatsParser,
                              # ExitCode + ErrorTranslator, RsyncLocator, Preflight (volume/source/deletion guards)
    Sources/SSHKit/           # SSHConfigParser (~/.ssh/config aliases), ConnectionTester, KeyAssistant,
                              # RemoteBrowser (rsync --list-only), HostKeyTrust
    Sources/SyncStore/       # JobStore (JSON), HistoryStore (run records + log files, retention)
    Sources/SyncScheduler/   # next-fire computation, timers, wake/launch catch-up
    Tests/…                   # unit tests + fixtures; integration tests run real rsync on temp dirs
  Vendor/rsync/               # build-rsync.sh, pinned version + checksum, COPYING, source link
  scripts/                    # release.sh (sign, notarize, DMG, Sparkle appcast)
```

### Key components
- **`CommandBuilder`:** a pure function `(SyncJob, RsyncCapabilities) -> [String]`. It builds an argument array and never a shell string, so there is no injection risk. Base flags are `-a` (adjusted per the chosen options), `--info=progress2,stats2` and `--itemize-changes` for parsing. The builder is the single source of truth for both execution and the command preview, and it gets the heaviest unit testing.
- **`RsyncRunner`:**
  - Launches the process with `Foundation.Process` and reads stdout/stderr through pipes, splitting on both `\r` and `\n` because progress2 uses carriage returns.
  - Emits an `AsyncStream<RunEvent>` (progress, fileChanged, logLine, finished).
  - Stop sends SIGINT, then SIGTERM after a timeout. Pause and resume use SIGSTOP/SIGCONT.
  - Holds `ProcessInfo.beginActivity(.userInitiated + idleSystemSleepDisabled)` during runs.
- **Parsers:** `ItemizeParser` turns `YXcstpoguax` codes and `*deleting` lines into a `Change` list. `StatsParser` reads the `--stats` block, and `ProgressParser` reads progress2 lines. All are tested against captured fixtures from rsync 3.x.
- **`RsyncLocator`:** the bundled helper is the default (`Contents/Helpers/rsync`), with Homebrew or a custom path as alternatives. It probes `--version` to fill `RsyncCapabilities`, and refuses openrsync, or warns about it, if a user selects it.
- **SSH:**
  - Uses the system `/usr/bin/ssh` via `-e "ssh -p … -i … -o BatchMode=yes"`. Scheduled runs always use BatchMode, so they never hang on a prompt.
  - Hosts can be picked from `~/.ssh/config` aliases.
  - "Test connection" checks reachability, authentication and remote rsync version, and warns if the remote has only openrsync or 2.6.x.
  - A key assistant generates an ed25519 key, shows and copies the public key, and optionally installs it once via `SSH_ASKPASS` and a password prompt.
  - Unknown host keys show their fingerprint for the user to confirm before being added to `known_hosts`.
  - A remote folder browser uses `rsync --list-only`.
  - Remote → remote syncs are disallowed with a clear message.
- **Persistence:**
  - Sync definitions are stored as human-readable JSON in `~/Library/Application Support/Brook/syncs.json`, written atomically. This makes import, export and backup trivial.
  - Run history is stored as one JSON record per run plus a raw log file, pruned by retention settings (count or age).
  - Secrets are never stored. SSH keys stay in `~/.ssh`, and passphrases stay in the ssh-agent / Keychain via `UseKeychain`.
- **Scheduler:**
  - Supported schedules: every N hours, daily at a time, weekly on chosen days, and monthly.
  - The next fire date is computed from `Calendar`.
  - A single `Task` sleeps until the earliest due job and re-arms after edits, wake (`NSWorkspace.didWakeNotification`) and launch.
  - Per-job "catch up missed run" option, plus an optional "skip when on battery" setting.
- **Notifications:** `UserNotifications`. Failures and deletion-guard skips always notify. Success notifications are opt-in. A notification's action opens the run's results.
- **Updates and release:**
  - Sparkle 2 handles updates.
  - `release.sh` signs with hardened runtime, including the rsync helper, notarizes with `notarytool`, staples, builds the DMG and updates the appcast.
  - A Homebrew cask is the other distribution channel.
- **Bundled rsync:**
  - `build-rsync.sh` builds the latest rsync 3.x as a universal binary (arm64 + x86_64; macOS 26 still supports Intel).
  - It links xxhash, lz4 and zstd statically, or disables them, and codesigns the result.
  - The GPLv3 text and a source link go in About and Acknowledgements.

### Dependencies
Sparkle is the only planned dependency, plus XcodeGen as a build-time tool. Everything else is Apple frameworks: SwiftUI, Observation, ServiceManagement, UserNotifications and OSLog. The code is Swift 6 with strict concurrency.

---

## 3. Milestones

| # | Milestone | Done when |
|---|---|---|
| M0 | **Foundations:** XcodeGen project, `SyncCore` package, `build-rsync.sh`, bundled helper wired in, OSLog categories | App launches and shows the bundled rsync version in About |
| M1 | **Core engine:** model, CommandBuilder, Runner, parsers, ErrorTranslator, Preflight guards, JobStore and HistoryStore | `swift test` is green, and integration tests mirror, copy, filter and delete on temp dirs with real rsync |
| M2 | **Main UI:** sidebar, list, detail, three-tier editor with command preview, onboarding templates, Preview/Run/Results views, history, FDA card | A non-technical walkthrough (folder → external drive) completes without seeing a flag |
| M3 | **Remote over SSH:** Remote Hosts screen, ssh-config import, connection test, key assistant, host-key trust, remote browser | Push and pull against a real SSH host, both with a key and through a config alias |
| M4 | **Scheduling, menu bar and notifications:** scheduler, catch-up, login item, accessory mode on window close, menu bar extra, notifications, deletion-guard behaviour for unattended runs | A schedule set for one minute out fires with the window closed; a missed run catches up after sleep |
| M5 | **Polish and ship:** accessibility pass, String Catalog (localization-ready), empty and error states, Sparkle, notarized DMG, Homebrew cask, README and short docs | `spctl -a -vv` accepts the DMG; a clean-machine install works end to end |

**Roadmap after v1:**
1. Snapshots / versioned backups (`--link-dest`) with retention and a restore browser.
2. Run on drive connect.
3. A `brook` CLI and App Intents for Shortcuts.
4. Import from RsyncUI configs.
5. Widgets.
6. Pre-run checksum verification.
7. An XPC background agent, if "quit app = no schedules" proves to be a problem.

---

## 4. Verification

- **Unit:** `swift test` in `Packages/SyncCore`.
  - CommandBuilder snapshot tests for every option combination, including trailing-slash semantics, remote quoting and SSH flags.
  - Parser tests against captured rsync 3.x output fixtures.
  - ErrorTranslator tests for each exit code.
  - Scheduler next-fire tests, including DST transitions and end-of-month dates.
- **Integration:** tests that create temp trees and run the bundled rsync.
  - Copy, Mirror (verifying deletions), excludes and folder-vs-contents.
  - Deletion guard tripping.
  - Unmounted-volume guard, using a fake `/Volumes` path with a UUID mismatch.
  - Pause, resume and stop.
- **SSH:** an opt-in test suite against `localhost` with Remote Login enabled, or a user-provided host via env var. Covers key auth, BatchMode failure messaging and the `--list-only` browser.
- **Manual / UI:**
  - Build and run the app; drive the main flows with computer-use screenshots.
  - Check VoiceOver on the editor and run views, and check light/dark mode and Reduce Transparency.
- **Scheduling:** create a schedule set for one minute out, close the window, and confirm it runs and notifies. Then sleep the Mac past a scheduled time and confirm the catch-up run on wake.
- **Release:** `codesign --verify --deep --strict`, `spctl -a -vv Brook.app`, notarization log clean, Sparkle update from version N-1 to N.
