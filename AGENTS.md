# AGENTS

Instructions for AI agents working on Founder TUI (a Linux terminal file manager in Swift).

## Build & Run

Linux (Manjaro/Arch; install the toolchain with `yay -S swift-bin`, plus the
`sudo ln -s /usr/lib/swift/bin/swift-autolink-extract /usr/bin/swift-autolink-extract`
SwiftPM compatibility link if `swift build` fails with a spawn error):

```bash
swift build              # debug build
swift test               # portable unit tests
swift run Founder        # interactive terminal UI (raw-mode ANSI, no dependencies)
```

The binary is a terminal UI: it needs a real TTY. Piping keystrokes in works for scripted
tests (remember: keys typed while the `/` filter or a prompt is active go into the text
buffer — send Enter/Escape first if you want a normal-mode key like `q`). For anything that
depends on the window size, drive it under a pty with an explicit winsize; a piped run
falls back to 24×80.

Favorites and the sort/hidden preferences persist in `~/.config/founder.config`.

## Project Structure

- `Package.swift` — SwiftPM manifest; executable target `Founder`, test target `FounderTests`
- `Sources/Founder/main.swift` — **the entire app** (top-level entry, `Terminal` raw-mode
  I/O, `TerminalConfig`, `TerminalFavoritesStore`, `TerminalUI`)
- `Tests/FounderTests/` — XCTest unit tests

This repo is the Linux-only sibling of the macOS Founder app
(https://github.com/DennisFaucher/Founder). There is no AppKit code here and no
`#if canImport(AppKit)`; the file was extracted from that project keeping the portable core
(fuzzy matching, `relativeName(for:base:)`, `isPackage`) and the terminal UI. Changes that
should apply to both may need porting back and forth.

## Architecture (all in main.swift)

1. **Entry point** — top-level code in `main.swift` (NOT `@main`; the file name `main.swift`
   makes it top-level-code entry, `@main` will not compile here). The last line is
   `exit(TerminalUI().run())`.
2. **`Terminal`** — termios raw mode (`cfmakeraw`), `poll`-based key reads, UTF-8 decoding,
   escape-sequence parsing (arrows/page/home/end), and `TIOCGWINSZ` sizing with a 24×80
   fallback.
3. **`TerminalConfig`** — `key = value` file at `$XDG_CONFIG_HOME/founder.config`
   (`~/.config/founder.config`), seeded with commented defaults on first run. Holds
   `favorite` lines plus `sort`, `sortAscending`, `showHidden`.
4. **`TerminalUI`** — owns the rows, cursor, filter, history, favorites and the input loop.
   Rendering is a full clear + redraw whenever `needsRedraw` is set; the loop also polls the
   async search and watches for terminal resizes.
5. **Search** — `FuzzyQuery` is the fzf-style matcher (terms must all match in order,
   `!` excludes, `'` is a substring, `^`/`$` anchor). Recursive search enumerates with
   `FileManager.enumerator(at:)` on a `DispatchQueue`, reporting progress under `searchLock`
   and stamping each run with a generation so stale workers can be cancelled.

## Gotchas Hit in This Project

- **`UserDefaults` never persists on Linux** — no plist is written anywhere, so preferences
  silently reset every run. That is why favorites/sort/hidden live in `founder.config`.
- Linux (swift-corelibs-foundation) gaps: `NSString.abbreviatingWithTildeInPath` does not
  exist (there is a local `abbreviate` helper); `NSString.expandingTildeInPath`,
  `ByteCountFormatter`, `Process.executableURL`/`run()` and `FileHandle.nullDevice` all DO
  work. There is no `DispatchSource` file watching (`O_EVTONLY` is Darwin-only), so the UI
  just reloads on each action. Package detection (`isPackage`) returns false by design.
- Top-level `let`s in `main.swift` are initialised as part of the executable's top-level
  code, so they read as zero for anything that `@testable import`s the module — i.e. the
  tests. Put such constants on a type (e.g. `enum FuzzyScoring { static let match = 16 }`),
  which is initialised lazily and works in both contexts.
- `FileManager.contentsOfDirectory(atPath:)` uses the link-following path API on purpose, so
  symlinked directories can be entered (`attributesOfItem`/`resourceValues` are read with
  `try?` so one unreadable child can't blank the listing).
- The help footer fits whole items only: at narrow widths trailing items are dropped instead
  of being cut mid-word. Active modes (`r recursive`, `h hidden`) render bold.
- `esc` in normal mode leaves the search results (clears the filter and recursive mode);
  in filter/prompt mode it cancels that input instead.

## Conventions

- Single-file app; split into multiple files only if requested.
- Keys mirror the macOS app where it makes sense (`n` folder, `f` file, `t` trash, …).
- Comments in the same style as the surrounding code.
