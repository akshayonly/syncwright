# syncwright
- backup_sync.sh — Incremental Backup & Sync Tool

A production-grade, cross-platform CLI backup script for macOS and Linux.
Wraps `rsync` with intelligent defaults, safety guards, and clean reporting.

---

## Why not just copy-paste the directory?

It's a fair question. Here's where plain `cp -r` or Finder drag-and-drop breaks down at scale:

| Problem | Copy-paste | This script |
|---|---|---|
| **Always transfers everything** | Yes — full 15 GB every run | No — only changed files |
| **"Newer wins" logic** | None — blindly overwrites | Skips files that haven't changed; never downgrades |
| **Interrupted transfers** | Leaves a corrupt half-state | Resumes from where it stopped (`--partial`) |
| **Feedback & logging** | Silent | File count, data moved, errors, elapsed time |
| **Automatable / scriptable** | No | Yes — cron, launchd, systemd timers |
| **Exclude patterns** | No | Yes — skip `node_modules/`, `.DS_Store`, etc. |

> If you have a 50 MB folder you back up once a month and don't care about any of the above — copy-paste is fine. This script is built for **repeated, reliable, efficient** sync at scale.

---

## Quick Start

```bash
# Make executable
chmod +x backup_sync.sh

# Archive sync (safest — never deletes from destination)
./backup_sync.sh ~/Documents /Volumes/ExternalDrive/Documents

# Mirror sync (exact copy — deletes orphaned files from destination)
./backup_sync.sh --mirror ~/Projects /mnt/external/Projects

# Dry run first to preview what would change
./backup_sync.sh --dry-run --verbose ~/Photos /Volumes/Backup/Photos
```

---

## Options

| Flag | Description |
|---|---|
| `--archive` | (default) Safe backup — files are never deleted from destination |
| `--mirror` | Exact mirror — deletes files from dest if removed from source |
| `-n, --dry-run` | Simulate sync, make no changes |
| `-v, --verbose` | Show every file being processed |
| `-l, --log <file>` | Write full output to a log file |
| `-e, --exclude <file>` | Path to rsync exclude patterns file |
| `-b, --bandwidth <KB/s>` | Throttle speed (e.g. `51200` = 50 MB/s) |
| `-c, --checksum` | Use SHA-1 checksum instead of timestamp+size |
| `-h, --help` | Show usage |

---

## How Incremental Sync Works

| Scenario | Action |
|---|---|
| File exists in source only | **Copied** to destination |
| File identical (same size + timestamp) | **Skipped** — no I/O |
| Source file is **newer** than destination | **Overwritten** |
| Destination file is newer than source | **Skipped** (–update flag) |
| File deleted from source | **Kept** (archive) or **Deleted** (mirror) |
| Hidden files (`.git`, `.env`, `.zshrc`) | **Always included** |

---

## Mode Selection: Archive vs Mirror

```
ARCHIVE (default) — Recommended for backups
  Source:       [A] [B]    [D]
  Destination:  [A] [B] [C] [D]   ← C is preserved
  Use when: You want a safety net. Accidental deletes won't lose data.

MIRROR — Recommended for live sync
  Source:       [A] [B]    [D]
  Destination:  [A] [B]    [D]   ← C is removed
  Use when: Destination must be an exact clone of source.
```

⚠️ **Always run `--dry-run` before first use in mirror mode.**

---

## Example Workflows

### Daily personal backup
```bash
./backup_sync.sh \
  --log ~/logs/backup-$(date +%F).log \
  --exclude ~/sync_excludes.example \
  ~/  \
  /Volumes/MyPassport/HomeBackup
```

### Throttled sync over slow USB 2.0
```bash
./backup_sync.sh \
  --bandwidth 20480 \
  ~/Projects \
  /Volumes/OldDrive/Projects
```

### Verified sync with checksums (slower, paranoid mode)
```bash
./backup_sync.sh --checksum ~/ImportantData /mnt/backup/ImportantData
```

---

## Sample Output

```
══════════════════════════════════════════════════════
  backup_sync.sh v1.3.0
══════════════════════════════════════════════════════
[10:42:01] ✓  Dependencies verified (rsync 3.2.7)
[10:42:01] ✓  Platform: macOS
[10:42:01] ✓  Source      : /Users/akshay/Projects
[10:42:01] ✓  Destination : /Volumes/BackupDrive/Projects
[10:42:01] ℹ  Source size: 4.2G
[10:42:01] ℹ  ARCHIVE MODE: Files are never deleted from destination.
[10:42:01] ℹ  Starting sync at 2025-08-14 10:42:01 ...

══════════════════════════════════════════════════════
  SYNC SUMMARY
══════════════════════════════════════════════════════
  Status          : SUCCESS
  Mode            : ARCHIVE
  Source          : /Users/akshay/Projects
  Destination     : /Volumes/BackupDrive/Projects
  Source Size     : 4.2G

  Files Scanned   : 18,432
  Files Synced    : 247
  Files Skipped   : 18,185  (already up-to-date)
  Data Moved      : 312.40 MB
  Elapsed Time    : 00:01:43
```

---

## Requirements

- `rsync` ≥ 3.1 (pre-installed on macOS 10.14+, most Linux distros)
- `bash` ≥ 4.0
- `bc` (for arithmetic — pre-installed everywhere)

### Install rsync on macOS (if needed)
```bash
brew install rsync
```

### Install rsync on Linux
```bash
sudo apt install rsync    # Debian/Ubuntu
sudo dnf install rsync    # Fedora/RHEL
```

