# Founder TUI

A fast, dependency-free terminal file manager, written in Swift.

This is the Linux front-end of [Founder](https://github.com/DennisFaucher/Founder) — the
same navigation and search rules as the macOS Finder clone, rendered in a raw-mode ANSI
terminal UI instead of AppKit. The whole program is a single Swift file and links nothing
beyond Foundation and the system C library.

```
 ~/Documents/Projects
 Favorites  1) Desktop  2) Documents  3) Downloads  4) Music  5) Pictures
 Name                                        Size            Modified
 Projects/                                     --          Oct 17 18:33
 docs/                                         --          Oct 12 09:10
 notes.md                                    4 KB          Oct 16 22:41
 ─────────────────────────────────────────────────────────────────────────
 3 items                                                            1/3
 ↑↓/jk move · ⏎ open · ⌫ parent · q quit · [ ] history · / filter · r recursive
 A add favorite · n new folder · f new file · m rename · t trash · D delete
```

## Features

- Two-line status + help footer; the terminal is cleared and redrawn on every key, and the
  layout follows resizes.
- Browsing with back/forward history, parent directory, page up/down, home/end.
- **Fuzzy filter** (`/`) in the spirit of fzf: whitespace-separated terms that must all
  appear in order, matched characters highlighted in the listing.
- **Recursive search** (`r`): the filter matches paths relative to the current folder and
  traversal runs asynchronously on a background queue with live `N searched · M found`
  progress. Generation-stamped, so a new search or navigation cancels the old one.
- **Favorites**: toggle the current folder with `A`, jump with `1`–`9`.
- Column sorting (`s` cycles name/size/date and ascending/descending), folders always first.
- Hidden-file toggle (`h`).
- New folder (`n`), new file (`f`), rename (`m`), trash via `gio trash` (`t`), permanent
  delete (`D`, asks first), open with the desktop handler (`o` / `⏎` on a file), and a Get
  Info line (`i`).
- Small details: name-collision handling (`notes.txt` → `notes 1.txt`), package/bundle
  detection is stubbed out on Linux, and help items for active modes render bold.

## Requirements

- Linux (uses `Glibc`/`Musl` termios; there is no AppKit path in this repository)
- A Swift 5.9+ toolchain. On Arch/Manjaro: `yay -S swift-bin`

## Build and run

```bash
swift build            # debug build
swift test             # portable unit tests (fuzzy matcher, relative names)
swift run Founder      # launch the TUI — needs a real TTY
```

## Install

```bash
swift build -c release
install -Dm755 .build/out/Products/Release-linux-x86_64/Founder ~/.local/bin/founder
```

Or build the binary path with `swift build -c release --show-bin-path`. To add it to a
desktop menu, drop this in `~/.local/share/applications/founder.desktop`:

```ini
[Desktop Entry]
Type=Application
Name=Founder
Comment=Browse files and folders (terminal UI)
Exec=/home/YOU/.local/bin/founder
Icon=system-file-manager
Terminal=true
Categories=System;FileManager;FileTools;
```

## Keys

| Key | Action |
| --- | --- |
| `↑` `↓` / `j` `k` | move |
| `PgUp` / `PgDn` / `Home` / `End` | move by a page / to the ends |
| `⏎` | open: enter a folder, launch a file |
| `⌫` / `-` | go to the parent folder |
| `[` / `]` | history back / forward |
| `/` | fuzzy filter (`⏎` keeps it, `esc` clears it) |
| `r` | toggle recursive search |
| `esc` | leave the search results, back to browsing |
| `g` | go to a path (`~` is expanded) |
| `h` | show/hide hidden files |
| `s` | cycle sort order |
| `A` | add/remove the current folder as a favorite |
| `1`–`9` | jump to a favorite |
| `n` / `f` | new folder / new file |
| `m` | rename |
| `t` / `D` | move to trash / delete permanently |
| `o` | open with the desktop handler (`xdg-open`) |
| `i` | Get Info line |
| `q` / `Ctrl-C` | quit |

While a `/` filter or a prompt is open, keystrokes go into its text buffer — press `⏎` or
`esc` first if you meant a normal-mode key.

## Configuration

Favorites, sort order and the hidden-files toggle are stored in a plain text file at
`$XDG_CONFIG_HOME/founder.config` (`~/.config/founder.config`), created with commented
defaults on first run:

```ini
# Founder — terminal UI configuration
# One favorite per line; ~ expands to your home directory.
# Keys: favorite, sort (name|size|date), sortAscending, showHidden
#
favorite = ~/Desktop
favorite = ~/Documents
favorite = ~/Downloads
favorite = ~/Music
favorite = ~/Pictures

sort = name
sortAscending = true
showHidden = false
```

(`UserDefaults` is not used: Swift's Linux runtime never persists it, so preferences would
silently reset on every launch.)

## Project structure

```
Package.swift                 SwiftPM manifest (executable target + test target)
Sources/Founder/main.swift    the entire TUI — raw-mode terminal I/O, rendering, actions
Tests/FounderTests/           XCTest unit tests (fuzzy matcher, relative-name helper)
AGENTS.md                     notes and conventions for agents working on the project
```

## Notes / limitations

- No file watching: the listing reloads on each action and after each search.
- Very narrow windows drop whole help items rather than truncating them mid-word.
- The TUI starts in your home directory.
- Trash uses `gio trash` (glib), so it works on the freedesktop/XFCE setup it was built on.
