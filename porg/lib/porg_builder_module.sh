#!/usr/bin/env bash
# porg_builder_mono.sh
# Monolithic Porg builder module
# - Self-contained pipeline: download, verify, extract, patch, hooks, build (bwrap), install (fakeroot), strip, package (.tar.zst), optional expand to /
# - Reads global config (default /etc/porg/porg.conf) and the package metafile YAML passed as argument
# - Minimal YAML parser included (no yq dependency)
# - Quiet mode with Portage-like progress bar + ETA + load/mem
#
# Usage:
#   ./porg_builder_mono.sh [options] /path/to/metafile.yml
# Options:
#   -q|--quiet       quiet progress (bar)
#   -i|--install     build and expand package into / (dangerous; requires confirmation)
#   -c|--clean       clean workdir/cache before running
#   -y|--yes         auto-yes for expand-root
#   -h|--help        show help
#
set -euo pipefail
IFS=$'\n\t'

### ----------------------------- Defaults & Global config -----------------------------
DEFAULT_CONFIG="/etc/porg/porg.conf"
CONFIG="${PORG_CONFIG:-$DEFAULT_CONFIG}"

# Defaults which can be overridden by the config file
PORTS_DIR="/usr/ports"
WORKDIR="/var/tmp/porg/work"
CACHE_DIR=""
LOG_DIR=""
HOOK_DIR="/etc/porg/hooks"
PATCH_DIR=""
DESTDIR_BASE=""
JOBS="$(nproc 2>/dev/null || echo 1)"
PACKAGE_FORMAT="tar.zst"
CHROOT_METHOD="bwrap"
STRICT_GPG="false"
STRIP_BINARIES="true"
LOG_MODULE=""       # optional external logger script path or command
DEPS_CMD=""         # optional dependency resolver command (porg_deps.py)
DB_CMD=""           # optional registry/db manager command
QUIET=false
AUTO_YES=false

# helper for reading key=value porg.conf style (simple)
load_global_config() {
  if [ -f "$CONFIG" ]; then
    # shell-friendly config: KEY="value" lines or key=value
    # source safely: restrict to allowed variable names
    while IFS= read -r line; do
      line="${line%%#*}"         # strip comments
      line="${line%%$'\r'}"
      [ -z "$line" ] && continue
      if [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
        # Evaluate assignment in a safe way
        eval "$line"
      fi
    done < "$CONFIG"
  fi
  # set derived defaults if empty
  : "${CACHE_DIR:=${WORKDIR}/cache}"
  : "${LOG_DIR:=${WORKDIR}/logs}"
  : "${PATCH_DIR:=${WORKDIR}/patches}"
  : "${DESTDIR_BASE:=${WORKDIR}/destdir}"
  mkdir -p "$WORKDIR" "$CACHE_DIR" "$LOG_DIR" "$PATCH_DIR" "$DESTDIR_BASE"
}

### ----------------------------- CLI parse -----------------------------
usage() {
  cat <<EOF
Usage: ${0##*/} [options] <metafile.yml>
Options:
  -q|--quiet        quiet progress (bar)
  -i|--install      build and expand into / after packaging (dangerous)
  -c|--clean        clean workdir/cache before building
  -y|--yes          auto-confirm destructive operations
  -h|--help         show this help
EOF
}

if [ "$#" -lt 1 ]; then usage; exit 1; fi

# process options
POSITIONAL=()
CLEAN_BEFORE=false
DO_EXPAND=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    -q|--quiet) QUIET=true; shift ;;
    -i|--install) DO_EXPAND=true; shift ;;
    -c|--clean) CLEAN_BEFORE=true; shift ;;
    -y|--yes) AUTO_YES=true; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    -* ) echo "Unknown option: $1"; usage; exit 2 ;;
    *) POSITIONAL+=("$1"); shift ;;
  esac
done
set -- "${POSITIONAL[@]}"
METAFILE="${1:-}"
[ -f "$METAFILE" ] || { echo "Metafile not found: $METAFILE" >&2; exit 2; }

# load porg.conf now (so env overrides if provided earlier still apply)
load_global_config

### ----------------------------- Logging -----------------------------
COLOR_RESET="\e[0m"
COLOR_INFO="\e[32m"
COLOR_WARN="\e[33m"
COLOR_ERROR="\e[31m"
LOG_FILE="${LOG_DIR}/porg-$(date -u +%Y%m%dT%H%M%SZ).log"

log_internal() {
  local level="$1"; shift
  local msg="$*"
  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  # If external logger module is configured and executable, call it (non-blocking)
  if [ -n "$LOG_MODULE" ] && command -v "$LOG_MODULE" >/dev/null 2>&1; then
    # call external logger with args: level timestamp message
    "$LOG_MODULE" "$level" "$ts" "$msg" >/dev/null 2>&1 || true
  fi
  # write to file always
  printf '%s [%s] %s\n' "$ts" "$level" "$msg" >> "$LOG_FILE"
  # colored console output unless quiet
  if [ "$QUIET" != "true" ]; then
    case "$level" in
      INFO)  printf "%b[INFO]%b  %s\n" "$COLOR_INFO" "$COLOR_RESET" "$msg" ;;
      WARN)  printf "%b[WARN]%b  %s\n"  "$COLOR_WARN" "$COLOR_RESET" "$msg" ;;
      ERROR) printf "%b[ERROR]%b %s\n"  "$COLOR_ERROR" "$COLOR_RESET" "$msg" ;;
      *)     printf "[%s] %s\n" "$level" "$msg" ;;
    esac
  fi
}

_die() {
  log_internal ERROR "$*"
  cleanup_and_exit 1
}

log_internal INFO "Starting porg_builder_mono.sh for metafile: $METAFILE"
log_internal INFO "Using porg config: $CONFIG"

### ----------------------------- Tool checks -----------------------------
require_tool() {
  for t in "$@"; do
    if ! command -v "$t" >/dev/null 2>&1; then
      _die "Required tool missing: $t"
    fi
  done
}
# basic required tools - some used conditionally but check major ones
require_tool bash curl tar zstd fakeroot file find awk sed grep xargs

# prefer bwrap; if CHROOT_METHOD == bwrap, verify
if [ "$CHROOT_METHOD" = "bwrap" ]; then
  if ! command -v bwrap >/dev/null 2>&1; then
    log_internal WARN "bubblewrap requested but not found; falling back to chroot where possible"
    CHROOT_METHOD="chroot"
  fi
fi

# optional tools: git, gpg, unzip, 7z, strip
# they will be tested before use

### ----------------------------- YAML parser (lightweight) -----------------------------
# This parser supports:
# - top-level scalar keys: key: value
# - block scalars with | or > for 'build:' and 'install:' preserving newlines or folding
# - arrays with '- item' for simple lists (patches:), and arrays of maps for sources:
#   sources:
#     - url: https://...
#       sha256: ...
#       gpg: ...
#
# It will populate shell variables:
#   pkg_name, pkg_version, BUILD_CMDS, INSTALL_CMDS
#   arrays: SOURCES_URLS[], SOURCES_SHA256[], SOURCES_GPG[]
#   PATCHES[] and HOOKS_<stage>[] as bash arrays (stage names converted to uppercase underscore)
#
SOURCES_URLS=()
SOURCES_SHA256=()
SOURCES_GPG=()
PATCHES=()
declare -A HOOKS # HOOKS["pre-download"]="cmd1;;cmd2"

# helper: trim leading spaces
_ltrim() { sed -E 's/^[[:space:]]+//' <<<"$1"; }

# parse the YAML file
parse_metafile() {
  local file="$1"
  # state variables
  local in_block="" block_key="" block_indent=0
  local current_array_key="" # for arrays of scalars like patches
  local current_map=""       # for an item in array of maps (like sources)
  while IFS= read -r line || [ -n "$line" ]; do
    # remove CR
    line="${line%$'\r'}"
    # skip comments and blank lines when not in block
    if [ -z "$in_block" ]; then
      local tl
      tl="$(echo "$line" | sed -e 's/^[[:space:]]*//')"
      [ -z "$tl" ] && continue
    fi

    # If currently inside a block scalar, capture lines until indentation less than block_indent
    if [ -n "$in_block" ]; then
      # if line is less indented than block_indent -> block ends
      # measure leading spaces
      leading="${line%%[! ]*}"
      leading_len=${#leading}
      if [ "$leading_len" -lt "$block_indent" ] && [ -n "$(echo "$line" | sed -e 's/^[[:space:]]*//')" ]; then
        # end block
        in_block=""
        block_key=""
        block_indent=0
        # reprocess this line as normal (fallthrough)
      else
        # append to the block variable preserving newlines
        eval "$block_key"='+$'"'\n'"$(printf "%s\n" "$(echo "$line" | sed -e "s/^[[:space:]]\\{${block_indent}\\}//")")"
        continue
      fi
    fi

    # Trim left whitespace for parsing
    stripped="$(echo "$line" | sed -e 's/^[[:space:]]*//')"

    # Detect array item (starts with '- ')
    if [[ "$stripped" =~ ^- ]]; then
      # array item; determine parent key by looking back (we keep current_array_key)
      # Example:
      # sources:
      #   - url: ...
      #     sha256: ...
      # patches:
      #   - fix.patch
      item="${stripped#- }"
      # if item contains key: value -> it's a map entry under current map
      if [[ "$item" =~ ^[A-Za-z0-9_\-]+:[[:space:]]*.* ]]; then
        # begin a new map entry (used for sources)
        current_map=""
        # parse 'key: val' in this line
        mapkey="${item%%:*}"
        mapval="$(echo "${item#*:}" | sed -e 's/^ *//;s/ *$//')"
        # start a new temporary associative array for the current map
        declare -A tmpmap=()
        tmpmap["$mapkey"]="$mapval"
        current_map_keys=("$mapkey")
        # store tmpmap to a temporary file representation: we'll capture following indented lines into it
        # Keep it in variables: TMPMAP_KEY and values stored in TMPMAP_*
        TMPMAP_KEYCOUNT=1
        TMPMAP_KV="${mapkey}:::${mapval}"
        # read following indented lines to capture rest of map entries
        while IFS= read -r cont || [ -n "$cont" ]; do
          # measure indentation
          if [ -z "$cont" ]; then break; fi
          prefix_len=$(echo "$cont" | sed -n 's/^\([[:space:]]*\).*$/\1/p' | awk '{print length}')
          if [ "$prefix_len" -le 2 ]; then
            # not indented enough => end of map block, re-process this line
            # use REPLY-like trick: put it into a variable for next outer loop iteration
            # We'll use a fifo approach by saving to a tmp file and then sourcing it back. Simpler: push it onto a temp file and then cat + process; due to complexity, break and allow next while outer read to pick it up (but we already consumed the line). To avoid complex refeed, keep this parser simpler: 'sources' map entries must be fully inline (no additional indented map lines). We'll support only map entries where all fields are on same indentation band or immediately subsequent lines with extra indent.
            # fallback: if next line not indented > current indentation, break
            break
          fi
          # else parse 'key: val' from cont (strip leading whitespace)
          cont_stripped="$(echo "$cont" | sed -e 's/^[[:space:]]*//')"
          if [[ "$cont_stripped" =~ ^([A-Za-z0-9_\-]+):[[:space:]]*(.*) ]]; then
            k="${BASH_REMATCH[1]}"; v="${BASH_REMATCH[2]}"
            TMPMAP_KV="${TMPMAP_KV};;${k}:::${v}"
          fi
        done
        # now TMPMAP_KV holds k:::v pairs separated by ';;'
        # convert TMPMAP_KV for known fields (url, sha256, gpg)
        IFS=';;' read -r -a kvs <<< "$TMPMAP_KV"
        local _url="" _sha="" _gpg=""
        for kv in "${kvs[@]}"; do
          kf="${kv%%:::*}"
          vf="${kv#*:::}"
          case "$kf" in
            url) _url="$vf" ;;
            sha256) _sha="$vf" ;;
            gpg) _gpg="$vf" ;;
            *) ;; # ignore
          esac
        done
        if [ -n "$_url" ]; then
          SOURCES_URLS+=("$_url")
          SOURCES_SHA256+=("$_sha")
          SOURCES_GPG+=("$_gpg")
        fi
        continue
      else
        # item is scalar list element (e.g., patches)
        if [ -n "$item" ]; then
          # Append to PATCHES if we are in patches context (detect by last top-level key)
          # naive approach: detect last non-empty top-level key by reading backwards - too complex
          # Simpler: if the last seen top-level key name was 'patches' (stored in variable LAST_KEY), use that
          if [ "${LAST_KEY:-}" = "patches" ]; then
            PATCHES+=("$item")
          else
            # other simple arrays: treat as hooks list if LAST_KEY starts with hooks
            if [[ "${LAST_KEY:-}" =~ ^hooks\. ]]; then
              stage="${LAST_KEY#hooks.}"
              # append command to HOOKS[stage]
              if [ -n "${HOOKS[$stage]:-}" ]; then
                HOOKS[$stage]="${HOOKS[$stage]};;${item}"
              else
                HOOKS[$stage]="${item}"
              fi
            fi
          fi
        fi
        continue
      fi
    fi

    # Not an array item. Look for 'key: value' or block scalar indicator
    if [[ "$stripped" =~ ^([A-Za-z0-9_.-]+):[[:space:]]*(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"
      val="${BASH_REMATCH[2]}"
      # Save last top-level key
      LAST_KEY="$key"
      # Block scalar?
      if [[ "$val" =~ ^[|>]$ ]]; then
        # enter block mode
        in_block="yes"
        block_key="$key"
        block_indent="$(echo "$line" | sed -n 's/^\([[:space:]]*\).*$/\1/p' | awk '{print length}')"
        # initialize variable empty (will append)
        eval "$key=\"\""
        continue
      fi
      # plain scalar
      # remove quotes if present
      val="$(echo "$val" | sed -e 's/^\"//' -e 's/\"$//' -e \"s/^'//\" -e \"s/'$//\")"
      # Known keys
      case "$key" in
        name|pkgname) pkg_name="$val" ;;
        version) pkg_version="$val" ;;
        source|source_url|url) SOURCE_URL="$val" ;;
        build) BUILD_CMDS="$val" ;;
        install) INSTALL_CMDS="$val" ;;
        patches) LAST_KEY="patches" ;; # next array items go to PATCHES
        hooks)
          # Expect hooks mapping lines to follow
          LAST_KEY="hooks"
          ;;
        *)
          # If matches hooks.<stage> e.g. hooks.pre-download: "cmd"
          if [[ "$key" =~ ^hooks\.([A-Za-z0-9_-]+)$ ]]; then
            stage="${BASH_REMATCH[1]}"
            # value may be a command string or comma-separated list
            HOOKS[$stage]="$val"
          else
            # Unknown key: create variable
            eval "$key=\"\$val\""
          fi
          ;;
      esac
    else
      # unrecognized line; ignore
      continue
    fi
  done < "$file"

  # final adjustments: if BUILD_CMDS or INSTALL_CMDS were empty and there is block scalar in variables with newlines, they already are set.
  : "${pkg_name:=${PKG_NAME:-}}"
  : "${pkg_version:=${PKG_VERSION:-}}"
  # If a single SOURCE_URL provided by top-level 'source' key and SOURCES_URLS empty, use it
  if [ -z "${SOURCES_URLS[*]:-}" ] && [ -n "${SOURCE_URL:-}" ]; then
    SOURCES_URLS+=("$SOURCE_URL")
    SOURCES_SHA256+=("${SHA256:-}")
    SOURCES_GPG+=("${GPG_SIG_URL:-}")
  fi
}

### ----------------------------- Utilities: system metrics & progress -----------------------------
# fetch loadavg, approximate CPU% (using /proc/stat delta), memory used (in MB)
_prev_idle=0; _prev_total=0
cpu_percent() {
  # reads /proc/stat first line
  read -r cpu user nice system idle iowait irq softirq steal guest < /proc/stat
  idle_now=$((idle + iowait))
  total_now=$((user + nice + system + idle + iowait + irq + softirq + steal))
  if [ "$_prev_total" -eq 0 ]; then
    _prev_idle=$idle_now; _prev_total=$total_now; echo "0"; return
  fi
  diff_idle=$((idle_now - _prev_idle))
  diff_total=$((total_now - _prev_total))
  _prev_idle=$idle_now; _prev_total=$total_now
  if [ "$diff_total" -le 0 ]; then echo "0"; return; fi
  usage=$((100 * (diff_total - diff_idle) / diff_total))
  echo "$usage"
}

mem_used_mb() {
  # use /proc/meminfo MemTotal and MemAvailable
  awk '/MemTotal:/ {t=$2} /MemAvailable:/ {a=$2} END {printf "%d", (t-a)/1024}' /proc/meminfo 2>/dev/null || echo "0"
}

# Progress bar: show name, [bar], percent, ETA, load, cpu, mem
progress_draw() {
  local name=$1 percent=$2 eta=$3
  local loadavg="$(cut -d' ' -f1 /proc/loadavg 2>/dev/null || echo 0.00)"
  local cpu=$(cpu_percent)
  local mem=$(mem_used_mb)
  # bar length
  local width=30
  local filled=$((percent * width / 100))
  local empty=$((width - filled))
  local bar="$(printf '%0.s█' $(seq 1 $filled))$(printf '%0.s░' $(seq 1 $empty))"
  printf "\r%s  [%s] %3d%% ETA:%s load:%s cpu:%s%% mem:%sMB" "$name" "$bar" "$percent" "$eta" "$loadavg" "$cpu" "$mem"
}

# ETA helper: estimate duration left given elapsed/time fraction
eta_fmt() {
  local secs=$1
  printf "%02d:%02d:%02d" $((secs/3600)) $(((secs%3600)/60)) $((secs%60))
}

### ----------------------------- Cleanup trap -----------------------------
TMP_DIRS=()
cleanup_and_exit() {
  local code="${1:-0}"
  # remove temporary dirs we created
  for d in "${TMP_DIRS[@]:-}"; do
    if [ -n "$d" ] && [ -d "$d" ]; then
      rm -rf "$d" 2>/dev/null || true
    fi
  done
  # final newline for progress line
  if [ "$QUIET" = true ]; then printf "\n"; fi
  log_internal INFO "Exiting porg_builder_mono.sh with code $code"
  exit "$code"
}
trap 'log_internal WARN "Interrupted by user"; cleanup_and_exit 130' INT
trap 'cleanup_and_exit $?' EXIT

### ----------------------------- Implement Steps -----------------------------
# Parse metafile
parse_metafile "$METAFILE"
# set defaults if not present
: "${pkg_name:=${pkg_name:-unknown}}"
: "${pkg_version:=${pkg_version:-0.0.0}}"
: "${BUILD_CMDS:=${BUILD_CMDS:-}}"
: "${INSTALL_CMDS:=${INSTALL_CMDS:-}}"

PKG_ID="${pkg_name}-${pkg_version}"
WORK_PKG_DIR="${WORKDIR}/${PKG_ID}"
DESTDIR="${DESTDIR_BASE}/${PKG_ID}"
mkdir -p "$WORK_PKG_DIR" "$DESTDIR"
TMP_DIRS+=("$WORK_PKG_DIR")

log_internal INFO "Parsed metafile: name=${pkg_name}, version=${pkg_version}"
log_internal INFO "Work dir: $WORK_PKG_DIR, Destdir: $DESTDIR"

# Optional cleaning
if [ "$CLEAN_BEFORE" = true ]; then
  log_internal INFO "Cleaning workdir and cache per request"
  rm -rf "$WORK_PKG_DIR" "$CACHE_DIR"/* 2>/dev/null || true
  mkdir -p "$WORK_PKG_DIR"
fi

# Steps list
STEPS=(download verify extract patch build install strip package expand)
ACTIVE_STEPS=()
# Determine active steps based on metafile contents and config
ACTIVE_STEPS+=("download")
ACTIVE_STEPS+=("verify")   # verify is attempted if checksum/gpg provided
ACTIVE_STEPS+=("extract")
if [ "${#PATCHES[@]}" -gt 0 ]; then ACTIVE_STEPS+=("patch"); fi
ACTIVE_STEPS+=("build")
ACTIVE_STEPS+=("install")
if [ "$STRIP_BINARIES" = "true" ]; then ACTIVE_STEPS+=("strip"); fi
ACTIVE_STEPS+=("package")
if [ "$DO_EXPAND" = true ] || [ "${EXPAND_TO_ROOT:-false}" = "true" ]; then ACTIVE_STEPS+=("expand"); fi

TOTAL_STEPS=${#ACTIVE_STEPS[@]}
STEP_IDX=0

# helpers to mark step and show progress
start_step() {
  STEP_IDX=$((STEP_IDX + 1))
  STEP_NAME="$1"
  log_internal INFO "STEP [$STEP_IDX/$TOTAL_STEPS] $STEP_NAME start"
  step_start_time=$(date +%s)
}
end_step() {
  local rc=${1:-0}
  step_end_time=$(date +%s)
  duration=$((step_end_time - step_start_time))
  log_internal INFO "STEP [$STEP_IDX/$TOTAL_STEPS] $STEP_NAME done (duration ${duration}s)"
}

# ----------------------------- Download -----------------------------
start_step "download"

# Try each source entry in SOURCES_URLS in order
downloaded_file=""
for idx in "${!SOURCES_URLS[@]}"; do
  url="${SOURCES_URLS[$idx]}"
  sha="${SOURCES_SHA256[$idx]:-}"
  gpg="${SOURCES_GPG[$idx]:-}"
  if [[ "$url" =~ ^git\+ ]]; then
    require_tool git
    repo="${url#git+}"
    dest="${CACHE_DIR}/git-$(basename "$repo" .git)"
    if [ -d "$dest/.git" ]; then
      log_internal INFO "Refreshing git repo ${repo}"
      git -C "$dest" fetch --all --tags --prune || true
    else
      log_internal INFO "Cloning git repo ${repo} -> $dest"
      git clone --depth 1 "$repo" "$dest" || { log_internal WARN "git clone failed: $repo"; continue; }
    fi
    downloaded_file="$dest"
    # no verify for git here except optional patches; break
    break
  else
    fname="$(basename "$url")"
    out="$CACHE_DIR/$fname"
    mkdir -p "$CACHE_DIR"
    if [ -f "$out" ]; then
      log_internal INFO "Using cached $out"
      downloaded_file="$out"
    else
      # download with progress; use curl with --progress-bar unless QUIET; but we want custom spinner/progress
      log_internal INFO "Downloading $url -> $out"
      # Start curl in background with -sS to suppress progress; track bytes to compute percent with Content-Length
      # Try to get content length
      content_length=$(curl -sI "$url" | awk -F': ' '/^Content-Length:/ {print $2}' | tr -d '\r\n' || echo "")
      # start curl
      curl -L --fail --output "$out.part" "$url" &
      curl_pid=$!
      # show progress while curl running
      if [ "$QUIET" = true ]; then
        # compute basic progress by checking file size vs content_length
        start_ts=$(date +%s); last_size=0
        while kill -0 "$curl_pid" 2>/dev/null; do
          sleep 1
          if [ -n "$content_length" ] && [ "$content_length" -gt 0 ]; then
            cur_size=$(stat -c%s "$out.part" 2>/dev/null || echo 0)
            percent=$((cur_size * 100 / content_length))
            elapsed=$(( $(date +%s) - start_ts ))
            if [ "$percent" -gt 0 ]; then
              est_total=$((elapsed * 100 / percent))
              left=$((est_total - elapsed))
            else
              left=0
            fi
            eta=$(eta_fmt $left)
            progress_draw "$pkg_name" "$percent" "$eta"
          else
            # unknown size: spinner only
            printf "\r%s [ downloading... ]" "$pkg_name"
          fi
        done
        wait "$curl_pid" || { rm -f "$out.part"; log_internal WARN "curl failed"; continue; }
        printf "\n"
      else
        wait "$curl_pid" || { rm -f "$out.part"; log_internal WARN "curl failed"; continue; }
      fi
      mv "$out.part" "$out"
      downloaded_file="$out"
    fi
  fi

  # verify if sha/gpg provided
  if [ -n "$sha" ]; then
    require_tool sha256sum
    log_internal INFO "Verifying sha256 for $downloaded_file"
    if ! echo "$sha  $downloaded_file" | sha256sum -c - >/dev/null 2>&1; then
      log_internal WARN "sha256 mismatch for $downloaded_file; trying next source"
      rm -f "$downloaded_file"
      downloaded_file=""
      continue
    fi
  fi
  if [ -n "$gpg" ]; then
    require_tool gpg curl
    sigfile="$CACHE_DIR/$(basename "$gpg")"
    curl -L --fail -o "$sigfile.part" "$gpg" && mv "$sigfile.part" "$sigfile"
    if ! gpg --verify "$sigfile" "$downloaded_file" >/dev/null 2>&1; then
      log_internal WARN "GPG verify failed for $downloaded_file; trying next source"
      rm -f "$downloaded_file"
      downloaded_file=""
      continue
    fi
  fi
  # if we got here, download + verify succeeded
  break
done

[ -n "$downloaded_file" ] || _die "No source could be downloaded and verified"
end_step 0

# ----------------------------- Extract -----------------------------
start_step "extract"
EXTRACT_DIR="${WORK_PKG_DIR}/src"
rm -rf "$EXTRACT_DIR"
mkdir -p "$EXTRACT_DIR"

if [ -d "$downloaded_file" ]; then
  # git or directory
  log_internal INFO "Source is directory (git); copying to extract dir"
  cp -a "$downloaded_file"/. "$EXTRACT_DIR"/
else
  fn="$downloaded_file"
  case "$fn" in
    *.tar.zst|*.tzst)
      require_tool tar zstd
      # compute size for progress estimate
      total_size=$(stat -c%s "$fn" 2>/dev/null || echo 0)
      if [ "$QUIET" = true ] && [ "$total_size" -gt 0 ]; then
        # extract in background while watching file growth of decompressed stream is complex; we'll show spinner
        (tar --use-compress-program=unzstd -xf "$fn" -C "$EXTRACT_DIR") &
        pid=$!; while kill -0 $pid 2>/dev/null; do progress_draw "$pkg_name" 0 "??:??:??"; sleep 0.3; done; printf "\n"
        wait $pid
      else
        tar --use-compress-program=unzstd -xf "$fn" -C "$EXTRACT_DIR"
      fi
      ;;
    *.tar.xz|*.txz)
      require_tool tar xz
      tar -xf "$fn" -C "$EXTRACT_DIR"
      ;;
    *.tar.gz|*.tgz)
      require_tool tar gzip
      tar -xf "$fn" -C "$EXTRACT_DIR"
      ;;
    *.zip)
      require_tool unzip
      unzip -qq "$fn" -d "$EXTRACT_DIR"
      ;;
    *.7z)
      require_tool 7z
      7z x -y -o"$EXTRACT_DIR" "$fn" >/dev/null
      ;;
    *)
      _die "Unsupported archive format for extraction: $fn"
      ;;
  esac
fi

# find top-level dir if any
topdir=$(find "$EXTRACT_DIR" -mindepth 1 -maxdepth 1 -type d | head -n1 || true)
if [ -n "$topdir" ]; then
  SRC_DIR="$topdir"
else
  SRC_DIR="$EXTRACT_DIR"
fi
end_step 0

# ----------------------------- Patch -----------------------------
if [ "${#PATCHES[@]}" -gt 0 ]; then
  start_step "patch"
  require_tool patch
  run_hooks_pre_download() { :; } # placeholder if needed
  for p in "${PATCHES[@]}"; do
    # patch path may be absolute or relative to metafile dir
    if [ -f "$p" ]; then ppath="$p"; else ppath="$(dirname "$METAFILE")/$p"; fi
    if [ ! -f "$ppath" ]; then _die "Patch not found: $ppath"; fi
    log_internal INFO "Applying patch $ppath"
    (cd "$SRC_DIR" && patch -p1 < "$ppath") || _die "Patch failed: $ppath"
  done
  end_step 0
fi

# ----------------------------- Hooks -----------------------------
# run_hooks <stage>
run_hooks() {
  local stage="$1"
  log_internal INFO "Running hooks stage=$stage"
  # package-local hooks: HOOKS associative array entries (from parse stage)
  if [ -n "${HOOKS[$stage]:-}" ]; then
    IFS=';;' read -r -a cmds <<< "${HOOKS[$stage]}"
    for c in "${cmds[@]}"; do
      [ -z "$c" ] && continue
      log_internal INFO "pkg-hook: $c"
      bash -c "$c" || log_internal WARN "pkg-hook failed: $c"
    done
  fi
  # global hooks dir
  hd="$HOOK_DIR/$stage"
  if [ -d "$hd" ]; then
    for h in "$hd"/*; do
      [ -x "$h" ] || continue
      log_internal INFO "global-hook: $h"
      "$h" || log_internal WARN "global hook failed: $h"
    done
  fi
}

run_hooks "pre-download"
run_hooks "post-download"

# ----------------------------- Build in chroot (bubblewrap) -----------------------------
start_step "build"

# Prepare chroot root dir
CHROOT_ROOT="${WORK_PKG_DIR}/chroot_root"
rm -rf "$CHROOT_ROOT" || true
mkdir -p "$CHROOT_ROOT/$pkg_name"
# copy source into chroot root
cp -a "$SRC_DIR"/. "$CHROOT_ROOT/$pkg_name"/

# construct build script to run inside chroot
# we want to export DESTDIR inside chroot as /DESTDIR_REL where DESTDIR_REL is the DESTDIR path without leading /
DESTDIR_REL="${DESTDIR#/}"
BUILD_SCRIPT=""
if [ -n "${BUILD_CMDS:-}" ]; then
  # ensure commands separated; keep newlines
  BUILD_SCRIPT+="${BUILD_CMDS};"
fi
if [ -n "${INSTALL_CMDS:-}" ]; then
  # run install under fakeroot
  BUILD_SCRIPT+="fakeroot sh -c '${INSTALL_CMDS//\'/\'\\\'\'}';"
fi

# run pre-build hooks
run_hooks "pre-build"

# Run with bubblewrap preferred
if [ "$CHROOT_METHOD" = "bwrap" ] && command -v bwrap >/dev/null 2>&1; then
  # Mount minimal FS: bind chroot root as /, bind /usr read-only, mount proc/dev etc.
  # We'll run sh -c 'cd /<pkg_name> ; export DESTDIR=/<DESTDIR_REL> ; <build_script>'
  inner_cmd="set -euo pipefail; export JOBS=${JOBS}; export DESTDIR=/${DESTDIR_REL}; cd /${pkg_name}; ${BUILD_SCRIPT}"
  # run in background and show progress
  if [ "$QUIET" = true ]; then
    bwrap --ro-bind "$CHROOT_ROOT" / --dev /dev --proc /proc --tmpfs /tmp --ro-bind /usr /usr --unshare-net /bin/sh -c "$inner_cmd" &
    bpid=$!
    # basic percent estimate: we can't know exact; show spinner and CPU/mem stats
    while kill -0 "$bpid" 2>/dev/null; do
      cpu=$(cpu_percent); mem=$(mem_used_mb)
      printf "\rBuilding %s ... CPU:%s%% MEM:%sMB" "$pkg_name" "$cpu" "$mem"
      sleep 0.6
    done
    wait "$bpid" || _die "Build failed inside bwrap"
    printf "\n"
  else
    # verbose mode: stream output
    bwrap --ro-bind "$CHROOT_ROOT" / --dev /dev --proc /proc --tmpfs /tmp --ro-bind /usr /usr --unshare-net /bin/sh -c "$inner_cmd"
  fi
else
  # fallback to chroot - requires root
  if [ "$(id -u)" -ne 0 ]; then
    log_internal WARN "chroot fallback requires root; running with available privileges (may fail)"
  fi
  inner_cmd="set -euo pipefail; export JOBS=${JOBS}; export DESTDIR=/${DESTDIR_REL}; cd /${pkg_name}; ${BUILD_SCRIPT}"
  chroot "$CHROOT_ROOT" /bin/sh -c "$inner_cmd"
fi

run_hooks "post-build"
end_step 0

# ----------------------------- install stage -----------------------------
start_step "install"
# Files should have been installed into CHROOT_ROOT/${DESTDIR_REL}
INSTALLED_ROOT="${CHROOT_ROOT}/${DESTDIR_REL}"
if [ -d "$INSTALLED_ROOT" ]; then
  mkdir -p "$DESTDIR"
  cp -a "$INSTALLED_ROOT"/. "$DESTDIR"/
  log_internal INFO "Installed files merged into $DESTDIR"
else
  log_internal WARN "No installed files found at $INSTALLED_ROOT; perhaps install commands put files elsewhere"
fi
run_hooks "post-install"
end_step 0

# ----------------------------- strip binaries -----------------------------
if [ "$STRIP_BINARIES" = "true" ]; then
  start_step "strip"
  if command -v strip >/dev/null 2>&1 && command -v file >/dev/null 2>&1; then
    while IFS= read -r -d '' f; do
      if file "$f" | grep -q "ELF"; then
        strip --strip-unneeded "$f" || log_internal WARN "strip failed for $f"
      fi
    done < <(find "$DESTDIR" -type f -print0)
  else
    log_internal WARN "strip or file not available; skipping strip"
  fi
  end_step 0
fi

# ----------------------------- package -----------------------------
start_step "package"
mkdir -p "${WORK_PKG_DIR}/packages"
pkg_base="${WORK_PKG_DIR}/packages/${PKG_ID}.tar"
tar -C "$DESTDIR" -cf "$pkg_base" .
pkg_file=""
case "$PACKAGE_FORMAT" in
  tar.zst)
    if command -v zstd >/dev/null 2>&1; then
      zstd -T0 -19 "$pkg_base" -o "${pkg_base}.zst"
      pkg_file="${pkg_base}.zst"
    else
      log_internal WARN "zstd not available; leaving uncompressed tar"
      pkg_file="${pkg_base}"
    fi
    ;;
  tar.xz)
    if command -v xz >/dev/null 2>&1; then
      xz -9 "$pkg_base"
      pkg_file="${pkg_base}.xz"
    else
      pkg_file="${pkg_base}"
    fi
    ;;
  *)
    pkg_file="${pkg_base}"
    ;;
esac
log_internal INFO "Package created: $pkg_file"
run_hooks "post-package"
end_step 0

# ----------------------------- expand into / (dangerous) -----------------------------
if [ "$DO_EXPAND" = true ] || [ "${EXPAND_TO_ROOT:-false}" = "true" ]; then
  start_step "expand"
  if [ "$AUTO_YES" != true ]; then
    printf "\nWARNING: You are about to extract package '%s' into / (root). This will overwrite files.\nType 'yes' to proceed: " "$pkg_file" >&2
    read -r ans
    if [ "$ans" != "yes" ]; then
      log_internal WARN "User declined expand-root; skipping"
      end_step 1
      DO_EXPAND=false
    fi
  fi
  if [ "$DO_EXPAND" = true ]; then
    run_hooks "pre-expand-root"
    case "$pkg_file" in
      *.zst) zstd -d "$pkg_file" -c | tar -xf - -C / ;;
      *.tar) tar -xf "$pkg_file" -C / ;;
      *.xz) xz -d "$pkg_file" -c | tar -xf - -C / ;;
      *) _die "Unsupported package type to expand: $pkg_file" ;;
    esac
    run_hooks "post-expand-root"
    log_internal INFO "Package expanded into /"
  fi
  end_step 0
fi

# ----------------------------- final summary -----------------------------
total_end=$(date +%s)
# compute overall duration from log file header time: we stored start earlier; approximate by last step durations sum not available -> compute by file mtimes
log_internal INFO "Build finished for ${PKG_ID}. Package: ${pkg_file}"
# Optionally, call dependency manager or DB updater if configured
if [ -n "$DEPS_CMD" ] && command -v "$DEPS_CMD" >/dev/null 2>&1; then
  log_internal INFO "Invoking dependency manager: $DEPS_CMD"
  "$DEPS_CMD" --register "$PKG_ID" --manifest "$pkg_file" || log_internal WARN "deps manager returned non-zero"
fi
if [ -n "$DB_CMD" ] && command -v "$DB_CMD" >/dev/null 2>&1; then
  log_internal INFO "Registering package in DB: $DB_CMD"
  "$DB_CMD" add --name "$pkg_name" --version "$pkg_version" --file "$pkg_file" || log_internal WARN "db add returned non-zero"
fi

# cleanup temporary dirs if desired (kept by default)
log_internal INFO "All done. Package available at: $pkg_file"
# success exit (trap will run cleanup)
exit 0
