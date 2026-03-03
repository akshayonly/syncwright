#!/usr/bin/env bash
# =============================================================================
#  backup_sync.sh — Incremental Backup & Sync Tool
#  Compatible with: macOS & Linux
#  Author: Akshay Shirsath
#  Usage:  ./backup_sync.sh [OPTIONS] <source> <destination>
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# ─── ANSI Colors ──────────────────────────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

# ─── Defaults ─────────────────────────────────────────────────────────────────
MODE="archive"          # archive | mirror
DRY_RUN=false
VERBOSE=false
LOG_FILE=""
EXCLUDE_FILE=""
BANDWIDTH_LIMIT=0       # KB/s — 0 = unlimited
CHECKSUM=false          # Use checksum instead of timestamp+size

# ─── Script Metadata ──────────────────────────────────────────────────────────
SCRIPT_NAME="$(basename "$0")"
VERSION="1.3.0"
START_TIME=$(date +%s)

# ─── Usage ────────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
${BOLD}backup_sync.sh v${VERSION}${RESET} — Incremental Backup & Sync Tool

${BOLD}USAGE:${RESET}
  ${SCRIPT_NAME} [OPTIONS] <source_dir> <destination_dir>

${BOLD}MODES:${RESET}
  --archive     (default) Keep destination files even if deleted from source.
                Safe for backup use-cases. No data is ever removed from dest.

  --mirror      Destination becomes an exact mirror of source.
                ⚠️  Files deleted from source will be DELETED from destination.

${BOLD}OPTIONS:${RESET}
  -n, --dry-run           Simulate sync without making any changes
  -v, --verbose           Show every file being processed
  -l, --log <file>        Write output to a log file in addition to stdout
  -e, --exclude <file>    Path to a file with rsync exclude patterns (one per line)
  -b, --bandwidth <KB/s>  Throttle transfer speed (e.g. 51200 = 50 MB/s)
  -c, --checksum          Use checksum comparison instead of timestamp+size
                          (slower but more accurate)
  -h, --help              Show this help message

${BOLD}EXAMPLES:${RESET}
  # Archive sync (safe default):
  ${SCRIPT_NAME} ~/Documents /Volumes/BackupDrive/Documents

  # Mirror sync with logging:
  ${SCRIPT_NAME} --mirror -l ~/sync.log ~/Projects /mnt/external/Projects

  # Dry-run with verbose output:
  ${SCRIPT_NAME} --dry-run --verbose ~/Photos /Volumes/Backup/Photos

  # Throttled sync with excludes:
  ${SCRIPT_NAME} --bandwidth 25600 --exclude ~/.sync_excludes ~/code /mnt/ext/code

${BOLD}EXCLUDE FILE FORMAT:${RESET}
  One rsync pattern per line. Example ~/.sync_excludes:
    node_modules/
    .DS_Store
    *.tmp
    build/

EOF
  exit 0
}

# ─── Logging ──────────────────────────────────────────────────────────────────
log()   { local msg="[$(date '+%H:%M:%S')] $*"; echo -e "$msg"; [[ -n "$LOG_FILE" ]] && echo -e "$msg" >> "$LOG_FILE"; }
info()  { log "${CYAN}ℹ  $*${RESET}"; }
ok()    { log "${GREEN}✓  $*${RESET}"; }
warn()  { log "${YELLOW}⚠  $*${RESET}"; }
error() { log "${RED}✗  $*${RESET}" >&2; }
die()   { error "$*"; exit 1; }

section() {
  local line="══════════════════════════════════════════════════════"
  log "${BOLD}${CYAN}${line}${RESET}"
  log "${BOLD}${CYAN}  $*${RESET}"
  log "${BOLD}${CYAN}${line}${RESET}"
}

# ─── Argument Parsing ─────────────────────────────────────────────────────────
parse_args() {
  [[ $# -eq 0 ]] && usage

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --archive)        MODE="archive" ;;
      --mirror)         MODE="mirror" ;;
      -n|--dry-run)     DRY_RUN=true ;;
      -v|--verbose)     VERBOSE=true ;;
      -c|--checksum)    CHECKSUM=true ;;
      -l|--log)         shift; LOG_FILE="$1" ;;
      -e|--exclude)     shift; EXCLUDE_FILE="$1" ;;
      -b|--bandwidth)   shift; BANDWIDTH_LIMIT="$1" ;;
      -h|--help)        usage ;;
      -*)               die "Unknown option: $1. Use --help for usage." ;;
      *)
        if [[ -z "${SOURCE_DIR:-}" ]]; then
          SOURCE_DIR="$1"
        elif [[ -z "${DEST_DIR:-}" ]]; then
          DEST_DIR="$1"
        else
          die "Too many arguments. Expected: <source> <destination>"
        fi
        ;;
    esac
    shift
  done

  [[ -z "${SOURCE_DIR:-}" ]] && die "Missing source directory. Use --help for usage."
  [[ -z "${DEST_DIR:-}"   ]] && die "Missing destination directory. Use --help for usage."
}

# ─── Dependency Checks ────────────────────────────────────────────────────────
check_dependencies() {
  local missing=()
  for cmd in rsync du find; do
    command -v "$cmd" &>/dev/null || missing+=("$cmd")
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    die "Missing required tools: ${missing[*]}. Please install them and retry."
  fi

  # Verify rsync version supports --info flag (rsync >= 3.1)
  local rsync_version
  rsync_version=$(rsync --version | awk 'NR==1{print $3}')
  local major minor
  IFS='.' read -r major minor _ <<< "$rsync_version"
  if [[ "$major" -lt 3 ]] || { [[ "$major" -eq 3 ]] && [[ "$minor" -lt 1 ]]; }; then
    warn "rsync $rsync_version detected. Version ≥ 3.1 recommended for best stats."
  fi

  ok "Dependencies verified (rsync ${rsync_version})"
}

# ─── Platform Detection ───────────────────────────────────────────────────────
detect_platform() {
  OS="$(uname -s)"
  case "$OS" in
    Darwin) PLATFORM="macOS" ;;
    Linux)  PLATFORM="Linux" ;;
    *)      warn "Unrecognized OS: $OS. Proceeding with generic settings." ; PLATFORM="generic" ;;
  esac
  ok "Platform: ${PLATFORM}"
}

# ─── Validate Paths ───────────────────────────────────────────────────────────
validate_paths() {
  # Resolve absolute paths
  SOURCE_DIR="$(cd "$SOURCE_DIR" 2>/dev/null && pwd)" \
    || die "Source directory does not exist: $SOURCE_DIR"

  # Ensure source ends WITHOUT trailing slash (rsync semantics)
  SOURCE_DIR="${SOURCE_DIR%/}"

  # Create destination if it doesn't exist
  if [[ ! -d "$DEST_DIR" ]]; then
    warn "Destination does not exist. Creating: $DEST_DIR"
    mkdir -p "$DEST_DIR" || die "Cannot create destination: $DEST_DIR"
  fi
  DEST_DIR="$(cd "$DEST_DIR" && pwd)"
  DEST_DIR="${DEST_DIR%/}"

  # Safety guard: prevent syncing a directory into itself
  [[ "$SOURCE_DIR" == "$DEST_DIR" ]] && die "Source and destination are the same path!"

  # Guard against syncing parent into child (would cause infinite loop)
  if [[ "$DEST_DIR" == "$SOURCE_DIR"/* ]]; then
    die "Destination ($DEST_DIR) is inside source ($SOURCE_DIR). Aborting."
  fi

  ok "Source      : $SOURCE_DIR"
  ok "Destination : $DEST_DIR"
}

# ─── Source Size ──────────────────────────────────────────────────────────────
get_source_size() {
  du -sh "$SOURCE_DIR" 2>/dev/null | awk '{print $1}'
}

# ─── Build rsync Command ──────────────────────────────────────────────────────
build_rsync_cmd() {
  RSYNC_ARGS=(
    rsync
    --archive           # -a: preserve perms, times, symlinks, owner, group
    --human-readable    # human-readable sizes in output
    --partial           # keep partially transferred files for resume
    --progress          # per-file progress (shown in verbose mode)
    --stats             # summary statistics at end
    --info=progress2    # live aggregated progress bar (rsync ≥ 3.1)
    --no-inc-recursive  # scan full tree first for accurate progress
  )

  # Checksum vs timestamp+size comparison
  if $CHECKSUM; then
    RSYNC_ARGS+=(--checksum)
    info "Comparison method: SHA-1 checksum (slower, more accurate)"
  else
    RSYNC_ARGS+=(--update)    # skip files that are newer on destination
    info "Comparison method: timestamp + file size (fast)"
  fi

  # Mirror mode: delete files from dest that don't exist in source
  if [[ "$MODE" == "mirror" ]]; then
    RSYNC_ARGS+=(--delete --delete-after)
    warn "MIRROR MODE: Files removed from source will be deleted from destination."
  else
    info "ARCHIVE MODE: Files are never deleted from destination."
  fi

  # Verbose output
  $VERBOSE && RSYNC_ARGS+=(--verbose)

  # Dry run
  $DRY_RUN && RSYNC_ARGS+=(--dry-run) && warn "DRY RUN — no files will be modified."

  # Bandwidth throttle
  if [[ "$BANDWIDTH_LIMIT" -gt 0 ]]; then
    RSYNC_ARGS+=(--bwlimit="$BANDWIDTH_LIMIT")
    info "Bandwidth limit: ${BANDWIDTH_LIMIT} KB/s"
  fi

  # Exclude file
  if [[ -n "$EXCLUDE_FILE" ]]; then
    [[ -f "$EXCLUDE_FILE" ]] || die "Exclude file not found: $EXCLUDE_FILE"
    RSYNC_ARGS+=(--exclude-from="$EXCLUDE_FILE")
    info "Exclude patterns loaded from: $EXCLUDE_FILE"
  fi

  # Always include hidden files (rsync includes them by default with --archive,
  # but we add explicit dot-file handling for clarity)
  # Hidden files like .git, .zshrc, .env are included automatically via --archive.

  # Log file: pipe output but still capture
  # Source with trailing slash means "contents of dir", not the dir itself.
  # We intentionally sync "source/" → "dest/" so the dest mirrors source contents.
  RSYNC_ARGS+=("${SOURCE_DIR}/")
  RSYNC_ARGS+=("${DEST_DIR}/")
}

# ─── Run Sync ─────────────────────────────────────────────────────────────────
run_sync() {
  local rsync_log
  rsync_log="$(mktemp /tmp/backup_sync_rsync.XXXXXX)"
  trap "rm -f '$rsync_log'" EXIT

  if $VERBOSE; then
    # Tee to both terminal and temp log
    "${RSYNC_ARGS[@]}" 2>&1 | tee "$rsync_log" | while IFS= read -r line; do
      log "$line"
    done
  else
    # Run quietly, capture output
    "${RSYNC_ARGS[@]}" > "$rsync_log" 2>&1
  fi

  RSYNC_EXIT="${PIPESTATUS[0]:-$?}"
  RSYNC_OUTPUT="$(cat "$rsync_log")"
}

# ─── Parse rsync Stats ────────────────────────────────────────────────────────
parse_rsync_stats() {
  FILES_TRANSFERRED=$(echo "$RSYNC_OUTPUT" | grep -oP 'Number of (regular )?files transferred: \K[0-9,]+' | tr -d ',' | head -1 || echo "0")
  BYTES_TRANSFERRED=$(echo "$RSYNC_OUTPUT" | grep -oP 'Total transferred file size: \K[\d,]+' | tr -d ',' | head -1 || echo "0")
  TOTAL_FILES=$(echo "$RSYNC_OUTPUT" | grep -oP 'Number of files: \K[0-9,]+' | tr -d ',' | head -1 || echo "0")
  FILES_SKIPPED=$(( TOTAL_FILES - FILES_TRANSFERRED )) 2>/dev/null || FILES_SKIPPED=0
  [[ "$FILES_SKIPPED" -lt 0 ]] && FILES_SKIPPED=0

  # Convert bytes to human-readable
  if [[ "$BYTES_TRANSFERRED" -ge $((1024*1024*1024)) ]]; then
    DATA_MOVED="$(echo "scale=2; $BYTES_TRANSFERRED / 1073741824" | bc) GB"
  elif [[ "$BYTES_TRANSFERRED" -ge $((1024*1024)) ]]; then
    DATA_MOVED="$(echo "scale=2; $BYTES_TRANSFERRED / 1048576" | bc) MB"
  elif [[ "$BYTES_TRANSFERRED" -ge 1024 ]]; then
    DATA_MOVED="$(echo "scale=1; $BYTES_TRANSFERRED / 1024" | bc) KB"
  else
    DATA_MOVED="${BYTES_TRANSFERRED} B"
  fi
}

# ─── Error Interpretation ─────────────────────────────────────────────────────
interpret_rsync_exit() {
  # https://download.samba.org/pub/rsync/rsync.1#EXIT_VALUES
  case "$RSYNC_EXIT" in
    0)  SYNC_STATUS="${GREEN}SUCCESS${RESET}" ;;
    23) SYNC_STATUS="${YELLOW}PARTIAL (some files skipped — permission/IO errors)${RESET}" ;;
    24) SYNC_STATUS="${YELLOW}PARTIAL (some source files vanished during sync)${RESET}" ;;
    11) die "rsync error: Destination path error (check mount point / disk space)." ;;
    12) die "rsync error: Data stream error — possible network/USB issue." ;;
    23|24) SYNC_STATUS="${YELLOW}PARTIAL SUCCESS${RESET}" ;;
    *)  SYNC_STATUS="${RED}FAILED (rsync exit code: $RSYNC_EXIT)${RESET}" ;;
  esac
}

# ─── Summary Report ───────────────────────────────────────────────────────────
print_summary() {
  local end_time elapsed_sec elapsed_fmt
  end_time=$(date +%s)
  elapsed_sec=$(( end_time - START_TIME ))
  elapsed_fmt="$(printf '%02d:%02d:%02d' $(( elapsed_sec/3600 )) $(( (elapsed_sec%3600)/60 )) $(( elapsed_sec%60 )))"

  section "SYNC SUMMARY"
  log ""
  log "  ${BOLD}Status          :${RESET} ${SYNC_STATUS}"
  log "  ${BOLD}Mode            :${RESET} ${MODE^^}"
  $DRY_RUN && log "  ${BOLD}Dry Run         :${RESET} ${YELLOW}YES — no changes were made${RESET}"
  log "  ${BOLD}Source          :${RESET} ${SOURCE_DIR}"
  log "  ${BOLD}Destination     :${RESET} ${DEST_DIR}"
  log "  ${BOLD}Source Size     :${RESET} $(get_source_size)"
  log ""
  log "  ${BOLD}Files Scanned   :${RESET} ${TOTAL_FILES}"
  log "  ${BOLD}Files Synced    :${RESET} ${GREEN}${FILES_TRANSFERRED}${RESET}"
  log "  ${BOLD}Files Skipped   :${RESET} ${FILES_SKIPPED}  (already up-to-date)"
  log "  ${BOLD}Data Moved      :${RESET} ${DATA_MOVED}"
  log "  ${BOLD}Elapsed Time    :${RESET} ${elapsed_fmt}"
  log ""

  if [[ "$RSYNC_EXIT" -ne 0 ]]; then
    warn "Errors were encountered. Relevant rsync output:"
    echo "$RSYNC_OUTPUT" | grep -iE '(error|failed|denied|permission|no space)' | while IFS= read -r line; do
      warn "  $line"
    done
  fi

  if [[ -n "$LOG_FILE" ]]; then
    ok "Full log saved to: ${LOG_FILE}"
  fi

  log ""
  section "DONE"
}

# ─── Entry Point ──────────────────────────────────────────────────────────────
main() {
  parse_args "$@"

  # Initialize log file
  if [[ -n "$LOG_FILE" ]]; then
    mkdir -p "$(dirname "$LOG_FILE")"
    echo "=== backup_sync.sh run: $(date) ===" > "$LOG_FILE"
  fi

  section "backup_sync.sh v${VERSION}"

  check_dependencies
  detect_platform
  validate_paths

  info "Source size: $(get_source_size)"
  log ""

  build_rsync_cmd

  info "Starting sync at $(date '+%Y-%m-%d %H:%M:%S') ..."
  log ""

  run_sync
  interpret_rsync_exit
  parse_rsync_stats
  print_summary

  [[ "$RSYNC_EXIT" -eq 0 ]] || [[ "$RSYNC_EXIT" -eq 23 ]] || [[ "$RSYNC_EXIT" -eq 24 ]]
}

main "$@"
