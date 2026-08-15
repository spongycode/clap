<p align="center">
  <img src="Resources/banner.png" alt="clap banner" width="100%">
</p>

<h1 align="center">clap</h1>

<p align="center">
  <strong>Native, high-performance, local-first macOS clipboard & shell history manager.</strong>
</p>

<p align="center">
  <a href="https://github.com/spongycode/clap/releases"><img src="https://img.shields.io/github/v/release/spongycode/clap?style=flat-square&color=black" alt="Release"></a>
  <img src="https://img.shields.io/badge/platform-macOS%2014%2B-blue?style=flat-square" alt="Platform">
  <img src="https://img.shields.io/badge/swift-6.0-orange?style=flat-square" alt="Swift 6">
  <img src="https://img.shields.io/badge/telemetry-zero-green?style=flat-square" alt="Zero Telemetry">
</p>

<br/>

- **Massive history** — 100,000 text entries, 500 images, and 50,000 shell commands by default with zero slowdown.
- **Instant** — Hash-indexed dedup, SQLite WAL + FTS5 search, virtualized SwiftUI list, thumbnail cache.
- **Keyboard-first & Fast** — `⌘⇧B` opens the panel; single click or `Enter` copies, closes, and pastes directly.
- **Shell History Ingestion** — Automatically captures and indexes commands from `~/.zsh_history` and `~/.bash_history`.
- **Local-first & Private** — No network, no accounts, no telemetry, no analytics.
- **Full CLI** — `clap` controls everything from your terminal or shell scripts.

---

## Installation

### Option 1: One-line install (Recommended)

Run in your terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/spongycode/clap/main/install.sh | bash
```

This compiles release binaries, places `clap.app` in `/Applications/`, symlinks the `clap` CLI into your `$PATH`, and launches the app.

---

### Option 2: Homebrew

```bash
brew tap spongycode/tap
brew install --cask clap
```

---

### Option 3: Direct Download

Download the latest `clap-vX.X.X.zip` from [GitHub Releases](https://github.com/spongycode/clap/releases), unzip, and drag `clap.app` to `/Applications`.

---

### Option 4: Build from Source

Requires macOS 14+ and Xcode Command Line Tools (`xcode-select --install`):

```bash
git clone https://github.com/spongycode/clap.git
cd clap
./Scripts/make_app.sh
open dist/clap.app
ln -sf "$PWD/dist/bin/clap" /usr/local/bin/clap
```

For development & testing:

```bash
swift build          # Build ClapApp + clap CLI
swift test           # Run 88 unit tests
.build/debug/ClapApp # Run debug app directly
```

---

## Usage

Press **⌘⇧B** to open the panel.

| Key / Action | Description |
| :--- | :--- |
| **Single Click** | Copy entry, close panel, and paste directly into active app |
| **↑ / ↓** | Navigate entries |
| **Enter** | Copy selected entry, close, and paste into active app |
| **⌘1 / ⌘2 / ⌘3** | Switch tabs: **Classic** · **Media** · **Shell** |
| **⌘F** | Focus search bar |
| **⌘P** | Pin / unpin selected entry (pinned items are immune to eviction) |
| **⌘D** or **⌥⌫** | Delete selected entry |
| **⌘R** | Toggle regex search mode (or click the `.*` button) |
| **Esc** | Close panel |

- **Hover Selection**: Hovering over any row selects it and opens a rich preview (full scrollable text/command or high-res image, plus metadata).
- **Direct Paste**: Pastes straight into your frontmost application (requires Accessibility permission prompted on first launch).
- **Move & Resize**: Drag the panel background to reposition and drag edges to resize. Position and dimensions persist across restarts.

---

## Full CLI Reference

`clap` includes a standalone CLI that interacts with the store and running application:

```bash
clap                                              # Open clipboard UI
clap list [--images] [--shell] [--limit N]        # List recent clipboard or shell entries
clap search <query> [--type text|image|shell]     # Full-text search
clap search --regex "^docker.*"                   # Regex search
clap get <id>                                     # Show entry (pipe-friendly raw output)
clap copy <id>                                    # Copy entry to pasteboard
clap delete <id> | --text <str> | --regex <pat>   # Delete entries (alias: clap out)
clap pin <id> / clap unpin <id>                   # Pin/unpin entries
clap clear [--force]                              # Wipe history (preserves pinned)
clap stats [--json]                               # Storage and activity metrics
clap config get [key] / set <key> <val>           # Manage limits, retention, exclusions
clap doctor                                       # System diagnostic checks
clap import shell-history [--file <path>]         # Backfill shell history (zsh/bash)
clap import maccy [--db <path>]                   # Migrate history from Maccy
clap pause / clap resume                          # Toggle clipboard monitoring
```

---

## Data & Storage

- Storage Directory: `~/Library/Application Support/clap/` (`clap.sqlite`, `images/`, `thumbnails/`).
- Configurable via `CLAP_DATA_DIR` environment variable or `--data-dir <path>`.
- Default Limits: Text (100k entries / 50 MB), Image (500 entries / 100 MB), Shell (50k entries / 10 MB).
- Automatic LRU eviction and configurable retention policies (7 / 30 / 90 / 365 days / forever).

---

## Privacy

- Clipboard and shell commands never leave your Mac.
- Zero network requests, zero telemetry, zero analytics.
- Password managers and concealed clipboard types are automatically ignored.
- Exclude any app by bundle ID via Settings UI or `clap config set exclusions '["com.example.app"]'`.
