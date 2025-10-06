#!/usr/bin/env bash
#
# porg-upgrade.sh
# Orquestrador de upgrade para Porg — agora com --sync (git clone / pull de PORTS_DIR)
#
# Local recomendado: /usr/lib/porg/porg-upgrade.sh
# chmod +x /usr/lib/porg/porg-upgrade.sh
#
set -euo pipefail
IFS=$'\n\t'

# -------------------- Defaults and paths (override via env or /etc/porg/porg.conf) --------------------
PORG_CONF="${PORG_CONF:-/etc/porg/porg.conf}"
PORTS_DIR="${PORTS_DIR:-/usr/ports}"
GIT_REPO="${GIT_REPO:-}"        # repository URL (can be set in porg.conf)
GIT_BRANCH="${GIT_BRANCH:-main}"
WORKDIR="${WORKDIR:-/var/tmp/porg/upgrade}"
LOG_DIR="${LOG_DIR:-/var/log/porg/upgrade}"
REPORT_DIR="${REPORT_DIR:-$LOG_DIR}"
DB_SCRIPT="${DB_SCRIPT:-/usr/lib/porg/porg_db.sh}"
LOGGER_SCRIPT="${LOGGER_SCRIPT:-/usr/lib/porg/porg_logger.sh}"
BUILDER_SCRIPT="${BUILDER_SCRIPT:-/usr/lib/porg/porg_builder.sh}"
BUILDER_CMD="${BUILDER_CMD:-porg}"
DEPS_PY="${DEPS_PY:-/usr/lib/porg/deps.py}"
REMOVE_SCRIPT="${REMOVE_SCRIPT:-/usr/lib/porg/porg_remove.sh}"
RESOLVE_CMD="${RESOLVE_CMD:-/usr/lib/porg/porg-resolve}"
STATE_FILE="${WORKDIR}/upgrade-state.json"
SYNC_DB="${DB_DIR:-/var/db/porg}/sync.json"    # file storing last sync info

# runtime flags
DRY_RUN=false
QUIET=false
AUTO_YES=false
DO_SYNC=false
DO_CHECK=false
DO_REVDEP=false
DO_CLEAN=false
DO_ROTATE=false
RESUME=false
TARGET_PKG=""
PARALLEL="$(nproc 2>/dev/null || echo 1)"

# ensure dirs
mkdir -p "$WORKDIR" "$LOG_DIR" "$REPORT_DIR" "$(dirname "$SYNC_DB")"
TMP="$(mktemp "$WORKDIR/porg-upgrade.XXXXXX")"
trap 'rm -f "$TMP"' EXIT

# -------------------- Load porg.conf simple KEY=VAL --------------------
_load_porg_conf() {
  [ -f "$PORG_CONF" ] || return 0
  while IFS= read -r raw || [ -n "$raw" ]; do
    line="${raw%%#*}"
    line="${line%$'\r'}"
    [ -z "$line" ] && continue
    if [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
      eval "$line"
    fi
  done < "$PORG_CONF"
}
_load_porg_conf

# -------------------- Source logger & db if available --------------------
if [ -f "$LOGGER_SCRIPT" ]; then
  # shellcheck disable=SC1090
  source "$LOGGER_SCRIPT"
else
  log_init() { :; }
  log() { local L="$1"; shift; printf "[%s] %s\n" "$L" "$*"; }
  log_section() { printf "=== %s ===\n" "$*"; }
  # minimal progress spinner
  progress_spinner() { printf "%s\n" "$*"; }
fi

if [ -f "$DB_SCRIPT" ]; then
  # shellcheck disable=SC1090
  source "$DB_SCRIPT"
fi

# -------------------- Helpers --------------------
usage() {
  cat <<EOF
Usage: ${0##*/} [options]
Options:
  --pkg <pkg>     Update single package
  --world         Update all installed packages (default)
  --check         Only check for updates (no install)
  --sync          Git pull/clone to update metafiles in $PORTS_DIR
  --dry-run       Show what would be done
  --quiet         Minimal stdout (logs still recorded)
  --yes           Auto confirm prompts
  --revdep        Run porg-resolve --scan --fix after upgrades
  --clean         Run porg-resolve --clean after upgrades
  --log-rotate    Request logger to rotate/clean logs
  --resume        Resume previously interrupted upgrade
  --parallel N    Number of parallel jobs (default: nproc)
  -h|--help       Show this help
EOF
}

# parse CLI
if [ "$#" -eq 0 ]; then
  # default: world upgrade
  TARGET_PKG=""
fi

while [ "$#" -gt 0 ]; do
  case "$1" in
    --pkg) TARGET_PKG="${2:-}"; shift 2 ;;
    --world) TARGET_PKG=""; shift ;;
    --check) DO_CHECK=true; shift ;;
    --sync) DO_SYNC=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --quiet) QUIET=true; shift ;;
    --yes) AUTO_YES=true; shift ;;
    --revdep) DO_REVDEP=true; shift ;;
    --clean) DO_CLEAN=true; shift ;;
    --log-rotate) DO_ROTATE=true; shift ;;
    --resume) RESUME=true; shift ;;
    --parallel) PARALLEL="${2:-$PARALLEL}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1"; usage; exit 2 ;;
  esac
done

_logger() {
  local level="$1"; shift
  if [ "$QUIET" = true ] && [ "$level" != "ERROR" ]; then
    # still call log for file recording
    log "$level" "$@" 2>/dev/null || true
  else
    log "$level" "$@"
  fi
}

confirm() {
  if [ "$AUTO_YES" = true ]; then return 0; fi
  printf "%s [y/N]: " "$1" >&2
  read -r ans || return 1
  case "$ans" in y|Y|yes|Yes) return 0 ;; *) return 1 ;; esac
}

save_state() {
  local state_json="$1"
  mkdir -p "$WORKDIR"
  echo "$state_json" > "$STATE_FILE"
  _logger INFO "Estado salvo em $STATE_FILE"
}

load_state() {
  [ -f "$STATE_FILE" ] || return 1
  cat "$STATE_FILE"
}

clear_state() {
  rm -f "$STATE_FILE" || true
}

# -------------------- SYNC implementation --------------------
# Performs git clone or git pull in PORTS_DIR to update metafiles.
# Records result (commit, timestamp) in $SYNC_DB.
sync_ports_repo() {
  _logger STAGE "Starting sync of ports tree: $PORTS_DIR"
  local start_ts
  start_ts=$(date +%s)
  local logpath="${LOG_DIR}/sync-$(date -u +%Y%m%dT%H%M%SZ).log"
  mkdir -p "$(dirname "$logpath")"
  touch "$logpath"
  # dry-run: only show message
  if [ "$DRY_RUN" = true ]; then
    _logger INFO "[dry-run] Would sync ports repo in $PORTS_DIR from $GIT_REPO (branch $GIT_BRANCH)"
    return 0
  fi

  # Ensure git available
  if ! command -v git >/dev/null 2>&1; then
    _logger ERROR "git not found; cannot perform --sync"
    return 2
  fi

  # If PORTS_DIR doesn't exist, clone
  if [ ! -d "$PORTS_DIR" ] || [ -z "$(ls -A "$PORTS_DIR" 2>/dev/null || true)" ]; then
    if [ -z "$GIT_REPO" ]; then
      _logger ERROR "PORTS_DIR empty but GIT_REPO not configured (set GIT_REPO in porg.conf)"
      return 3
    fi
    _logger INFO "Cloning ports repository: $GIT_REPO (branch $GIT_BRANCH) -> $PORTS_DIR"
    mkdir -p "$PORTS_DIR"
    if git clone --depth 1 -b "$GIT_BRANCH" "$GIT_REPO" "$PORTS_DIR" >>"$logpath" 2>&1; then
      _logger INFO "Clone completed"
    else
      _logger ERROR "Clone failed (see $logpath)"
      return 4
    fi
  else
    # If it is a git repo: fetch+pull; else try to init remote
    if [ -d "$PORTS_DIR/.git" ]; then
      _logger INFO "Updating existing repo in $PORTS_DIR (git fetch & pull)"
      (
        cd "$PORTS_DIR" || exit 1
        # fetch latest
        if ! git fetch --all --tags --prune >>"$logpath" 2>&1; then
          _logger WARN "git fetch returned non-zero (see $logpath)"
        fi
        if git rev-parse --abbrev-ref HEAD >/dev/null 2>&1; then
          # try to checkout branch and pull
          if git checkout "$GIT_BRANCH" >>"$logpath" 2>&1; then
            if git pull --ff-only origin "$GIT_BRANCH" >>"$logpath" 2>&1; then
              _logger INFO "git pull completed"
            else
              _logger WARN "git pull returned non-zero (see $logpath)"
            fi
          else
            _logger WARN "git checkout $GIT_BRANCH failed (see $logpath)"
          fi
        else
          _logger WARN "Cannot determine current branch in $PORTS_DIR (see $logpath)"
        fi
      )
    else
      # not a git repo but not empty: attempt to init remote and pull (dangerous; log and skip)
      if [ -n "$GIT_REPO" ]; then
        _logger WARN "$PORTS_DIR is not a git repo. Attempting to initialize and pull from $GIT_REPO"
        (
          cd "$PORTS_DIR" || exit 1
          git init >>"$logpath" 2>&1 || true
          git remote add origin "$GIT_REPO" >>"$logpath" 2>&1 || true
          if git fetch --depth 1 origin "$GIT_BRANCH" >>"$logpath" 2>&1; then
            git reset --hard FETCH_HEAD >>"$logpath" 2>&1 || true
            _logger INFO "Initialized and updated $PORTS_DIR from $GIT_REPO"
          else
            _logger ERROR "Failed to fetch branch $GIT_BRANCH from $GIT_REPO (see $logpath)"
            return 5
          fi
        )
      else
        _logger ERROR "PORTS_DIR is not a git repository and GIT_REPO not configured"
        return 6
      fi
    fi
  fi

  # gather commit info
  local commit_info=""
  if [ -d "$PORTS_DIR/.git" ]; then
    commit_info="$(cd "$PORTS_DIR" && git rev-parse --short HEAD 2>/dev/null || true)"
  fi
  local end_ts
  end_ts=$(date +%s)
  local duration=$((end_ts - start_ts))
  # write sync DB with timestamp & commit
  python3 - <<PY
import json,sys,time,os
db_path=sys.argv[1]
info={"last_sync":"$(date -u +%Y-%m-%dT%H:%M:%SZ)","commit":"$commit_info","repo":"$GIT_REPO","branch":"$GIT_BRANCH","ports_dir":"$PORTS_DIR"}
os.makedirs(os.path.dirname(db_path),exist_ok=True)
try:
    existing={}
    if os.path.exists(db_path):
        existing=json.load(open(db_path,'r',encoding='utf-8'))
    existing.update(info)
    open(db_path,'w',encoding='utf-8').write(json.dumps(existing,indent=2,ensure_ascii=False))
    print("OK")
except Exception as e:
    print("ERR:"+str(e))
    sys.exit(2)
PY
  "$SYNC_DB" >>"$logpath" 2>&1 || true

  _logger INFO "Sync completed in ${duration}s (commit: ${commit_info:-unknown}). Log: $logpath"
  return 0
}

# sync status read helper
read_sync_status() {
  if [ -f "$SYNC_DB" ]; then
    python3 - <<PY
import json,sys
try:
  print(json.dumps(json.load(open(sys.argv[1],'r',encoding='utf-8')),ensure_ascii=False,indent=2))
except:
  print("{}")
PY
    "$SYNC_DB"
  else
    echo "{}"
  fi
}

# -------------------- (Rest of upgrade flow) helper stubs (build/remove/install/db update) --------------------
# For brevity, we reuse functions from previous design: find_metafile, metafile_version, installed_version, build_package, expand_package_to_root, remove_old_package, update_db_after_upgrade.
# Implement minimal versions here (or rely on previously provided builder/db scripts if present).

find_metafile() {
  local pkg="$1"
  if [ -d "$PORTS_DIR" ]; then
    for d in "$PORTS_DIR"/*/"$pkg"; do
      [ -d "$d" ] || continue
      mf=$(ls -1 "$d"/*.{yml,yaml} 2>/dev/null | head -n1 || true)
      [ -n "$mf" ] && { echo "$mf"; return 0; }
    done
    mf=$(find "$PORTS_DIR" -type f -iname "${pkg}*.y*ml" -print -quit 2>/dev/null || true)
    [ -n "$mf" ] && { echo "$mf"; return 0; }
  fi
  return 1
}

metafile_version() {
  local mf="$1"
  if [ -z "$mf" ] || [ ! -f "$mf" ]; then echo ""; return 0; fi
  python3 - <<PY
import sys, re
p=sys.argv[1]
v=""
try:
    import yaml
    with open(p,'r',encoding='utf-8') as f:
        d=yaml.safe_load(f) or {}
        v=d.get('version') or d.get('ver') or ""
        if v:
            print(v); sys.exit(0)
except:
    pass
# fallback
with open(p,'r',encoding='utf-8') as f:
    for line in f:
        m=re.match(r'^\s*version\s*:\s*(.+)$',line)
        if m:
            print(m.group(1).strip().strip('"').strip("'"))
            sys.exit(0)
print("")
PY
  "$mf"
}

installed_version() {
  local pkg="$1"
  if declare -f db_list >/dev/null 2>&1 && declare -f db_info >/dev/null 2>&1; then
    python3 - "$pkg" <<PY
import json,sys
p=sys.argv[1]
dbp="/var/db/porg/installed.json"
try:
  db=json.load(open(dbp,'r',encoding='utf-8'))
except:
  db={}
for k,v in db.items():
  if k==p or k.startswith(p+'-') or k.split('-')[0]==p:
    print(v.get('version',''))
    sys.exit(0)
print("")
PY
  else
    echo ""
  fi
}

# A minimal builder invocation helper: prefer wrapper 'porg', else builder script
build_package() {
  local mf="$1"; local pkgid="$2"
  _logger INFO "Building $pkgid from metafile $mf"
  if [ "$DRY_RUN" = true ]; then
    _logger INFO "[dry-run] builder would run for $pkgid"
    echo "DRY_RUN:$pkgid"
    return 0
  fi
  if command -v porg >/dev/null 2>&1; then
    _logger INFO "Using 'porg build' wrapper for $pkgid"
    if porg build "$mf"; then
      _logger INFO "porg build returned success"
      # attempt to find package in cache
      echo "$(find /var/cache/porg -type f -name "${pkgid}*.tar.*" -o -name "${pkgid}*.tar" 2>/dev/null | sort -r | head -n1 || true)"
      return 0
    else
      _logger ERROR "porg build failed for $pkgid"
      return 1
    fi
  fi
  if [ -x "$BUILDER_SCRIPT" ]; then
    if "$BUILDER_SCRIPT" build "$mf"; then
      # attempt to find package in cache
      echo "$(find /var/cache/porg -type f -name "${pkgid}*.tar.*" -o -name "${pkgid}*.tar" 2>/dev/null | sort -r | head -n1 || true)"
      return 0
    else
      _logger ERROR "$BUILDER_SCRIPT build failed for $pkgid"
      return 1
    fi
  fi
  _logger ERROR "No builder available to build $pkgid"
  return 2
}

expand_package_to_root() {
  local pkgfile="$1"
  _logger INFO "Expanding package $pkgfile into /"
  if [ "$DRY_RUN" = true ]; then
    _logger INFO "[dry-run] Would expand $pkgfile to /"
    return 0
  fi
  case "$pkgfile" in
    *.zst) zstd -d "$pkgfile" -c | tar -xf - -C / ;;
    *.xz) xz -d "$pkgfile" -c | tar -xf - -C / ;;
    *.tar) tar -xf "$pkgfile" -C / ;;
    *) _logger ERROR "Unknown package format: $pkgfile"; return 2 ;;
  esac
  return 0
}

remove_old_package() {
  local pkgid="$1"
  _logger INFO "Removing old package $pkgid"
  if [ "$DRY_RUN" = true ]; then
    _logger INFO "[dry-run] remove script would be invoked for $pkgid"
    return 0
  fi
  if [ -x "$REMOVE_SCRIPT" ]; then
    "$REMOVE_SCRIPT" "$pkgid" --yes --force || _logger WARN "remove script returned non-zero for $pkgid"
  else
    if declare -f db_unregister >/dev/null 2>&1; then
      db_unregister "$pkgid" || _logger WARN "db_unregister failed for $pkgid"
    else
      _logger WARN "No remove script or db_unregister available; manual cleanup required for $pkgid"
    fi
  fi
  return 0
}

update_db_after_upgrade() {
  local name="$1" version="$2" prefix="$3"
  if [ "$DRY_RUN" = true ]; then
    _logger INFO "[dry-run] DB update would register $name-$version"
    return 0
  fi
  if declare -f db_register >/dev/null 2>&1; then
    db_register "$name" "$version" "$prefix" || _logger WARN "db_register failed for $name"
  else
    python3 - "$name" "$version" "$prefix" <<PY
import json,sys,time,os
dbp="/var/db/porg/installed.json"
try:
  db=json.load(open(dbp,'r',encoding='utf-8'))
except:
  db={}
pkgid=sys.argv[1]+"-"+sys.argv[2]
db[pkgid]={"name":sys.argv[1],"version":sys.argv[2],"prefix":sys.argv[3],"installed_at":time.strftime("%Y-%m-%dT%H:%M:%SZ",time.gmtime())}
open(dbp,'w',encoding='utf-8').write(json.dumps(db,indent=2,ensure_ascii=False,sort_keys=True))
print("OK")
PY
  fi
}

# version compare: returns 0 if new > old
version_newer() {
  local a="$1"; local b="$2"
  [ -z "$a" ] && return 1
  [ -z "$b" ] && return 0
  python3 - <<PY
import sys
def norm(x):
    return tuple(int(p) if p.isdigit() else p for p in x.replace('-', '.').split('.'))
a=sys.argv[1]; b=sys.argv[2]
try:
    print(1 if norm(a) > norm(b) else 0)
except:
    print(1 if a > b else 0)
PY
  "$a" "$b"
  # python prints 1 if a>b, else 0; invert to return success when newer
  if [ "$?" -ne 0 ]; then
    # fallback lexicographic
    if [ "$a" \> "$b" ]; then return 0; else return 1; fi
  else
    # read output
    out=$(python3 - <<PY
import sys
def norm(x):
    return tuple(int(p) if p.isdigit() else p for p in x.replace('-', '.').split('.'))
a=sys.argv[1]; b=sys.argv[2]
try:
    print(1 if norm(a) > norm(b) else 0)
except:
    print(1 if a > b else 0)
PY
  "$a" "$b")
    if [ "$out" = "1" ]; then return 0; else return 1; fi
  fi
}

# upgrade pipeline for one package
upgrade_one_pkg() {
  local pkg="$1"
  _logger STAGE "Processing $pkg"
  mf="$(find_metafile "$pkg" || true)"
  if [ -z "$mf" ]; then
    _logger WARN "Metafile not found for $pkg under $PORTS_DIR"
    return 1
  fi
  new_ver="$(metafile_version "$mf" | tr -d '[:space:]')"
  inst_ver="$(installed_version "$pkg" | tr -d '[:space:]')"
  if [ -n "$inst_ver" ]; then
    if version_newer "$new_ver" "$inst_ver"; then
      _logger INFO "Upgrade available: $pkg $inst_ver -> $new_ver"
    else
      _logger INFO "No update for $pkg (installed: $inst_ver, metafile: $new_ver)"
      return 0
    fi
  else
    _logger INFO "Package $pkg not installed; will install $new_ver"
  fi

  # resolve deps before build
  if [ -x "$DEPS_PY" ]; then
    _logger INFO "Resolving dependencies for $pkg via deps.py"
    if ! python3 "$DEPS_PY" resolve "$pkg" >/dev/null 2>&1; then
      _logger WARN "deps.py reported issues resolving dependencies for $pkg"
    fi
  fi

  # build
  pkgid="${pkg}-${new_ver}"
  _logger STAGE "Building $pkgid"
  pkgfile="$(build_package "$mf" "$pkgid" 2>&1 || true)"
  if [ -z "$pkgfile" ] || [[ "$pkgfile" =~ ^FAILED|^$ ]]; then
    _logger ERROR "Build failed for $pkg. Saving state for resume."
    state=$(cat <<JSON
{"target":"$pkg","metafile":"$mf","new_version":"$new_ver","installed_version":"$inst_ver","timestamp":"$(date -u +%Y-%m-%dT%H:%M:%SZ)"}
JSON
)
    save_state "$state"
    return 2
  fi
  _logger INFO "Build successful: $pkgfile"

  # remove old only after successful build
  if [ -n "$inst_ver" ]; then
    old_pkgid="${pkg}-${inst_ver}"
    remove_old_package "$old_pkgid"
  fi

  # install new
  if ! expand_package_to_root "$pkgfile"; then
    _logger ERROR "Install (expand) failed for $pkg. Saving state for resume."
    state=$(cat <<JSON
{"target":"$pkg","metafile":"$mf","new_version":"$new_ver","installed_version":"$inst_ver","pkgfile":"$pkgfile","timestamp":"$(date -u +%Y-%m-%dT%H:%M:%SZ)","phase":"install-failed"}
JSON
)
    save_state "$state"
    return 3
  fi

  # update DB
  update_db_after_upgrade "$pkg" "$new_ver" "/"

  _logger INFO "Upgrade complete: $pkg $inst_ver -> $new_ver"
  return 0
}

# -------------------- Main flow --------------------
_logger STAGE "porg-upgrade starting at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
_logger INFO "Flags: sync=$DO_SYNC check=$DO_CHECK dryrun=$DRY_RUN quiet=$QUIET resume=$RESUME target=$TARGET_PKG parallel=$PARALLEL"

# 1) SYNC if requested
if [ "$DO_SYNC" = true ]; then
  if ! sync_ports_repo; then
    _logger WARN "Sync did not complete successfully. You can retry with --sync"
  fi
fi

# 2) Resume if requested
if [ "$RESUME" = true ]; then
  if [ -f "$STATE_FILE" ]; then
    st="$(cat "$STATE_FILE")"
    pkg="$(python3 - <<PY
import json,sys
print(json.load(open(sys.argv[1],'r',encoding='utf-8'))['target'])
PY
"$STATE_FILE")"
    _logger INFO "Resuming interrupted upgrade for $pkg"
    if upgrade_one_pkg "$pkg"; then
      _logger INFO "Resume: package $pkg rebuilt/installed successfully. Clearing state."
      clear_state
    else
      _logger ERROR "Resume failed for $pkg. Correct the issue and retry --resume"
      exit 2
    fi
  else
    _logger INFO "No resume state found ($STATE_FILE)"
  fi
fi

# 3) build target list
targets=()
if [ -n "$TARGET_PKG" ]; then
  targets=("$TARGET_PKG")
else
  # world (all installed)
  if declare -f db_list >/dev/null 2>&1; then
    while IFS= read -r l; do
      [ -z "$l" ] && continue
      # db_list prints lines like: "pkgid version prefix installed_at"
      pkgkey=$(echo "$l" | awk '{print $1}')
      # base name extraction (split before first -digit group)
      base=$(echo "$pkgkey" | sed -E 's/^([^-]+).*/\1/')
      targets+=("$base")
    done < <(db_list 2>/dev/null || true)
  else
    _logger ERROR "db_list not available; cannot run --world"
    exit 2
  fi
fi

# 4) check-only mode
if [ "$DO_CHECK" = true ]; then
  _logger STAGE "Check-only: comparing installed vs metafile versions"
  for pkg in "${targets[@]}"; do
    mf="$(find_metafile "$pkg" || true)"
    [ -z "$mf" ] && { _logger DEBUG "Metafile not found for $pkg"; continue; }
    new_ver="$(metafile_version "$mf" | tr -d '[:space:]')"
    inst_ver="$(installed_version "$pkg" | tr -d '[:space:]')"
    if [ -z "$inst_ver" ]; then
      _logger INFO "NEW: $pkg -> $new_ver (not installed)"
    else
      if version_newer "$new_ver" "$inst_ver"; then
        _logger INFO "UPDATE: $pkg $inst_ver -> $new_ver"
      else
        _logger DEBUG "No update: $pkg (installed $inst_ver, metafile $new_ver)"
      fi
    fi
  done
  exit 0
fi

# 5) main sequential upgrade loop (stop and save state on build/install failure)
for pkg in "${targets[@]}"; do
  if upgrade_one_pkg "$pkg"; then
    _logger INFO "Upgraded $pkg successfully; continuing"
    continue
  else
    rc=$?
    if [ "$rc" -eq 2 ] || [ "$rc" -eq 3 ]; then
      _logger ERROR "Upgrade interrupted at $pkg (code $rc). State saved to $STATE_FILE. Fix and run --resume"
      exit $rc
    else
      _logger WARN "Upgrade step for $pkg returned non-zero ($rc); continuing with next package"
      # per your instruction: do not stop completely except on build/install failure; continue and record
      continue
    fi
  fi
done

# 6) post actions: rotate logs, revdep, clean
if [ "$DO_ROTATE" = true ]; then
  if declare -f _rotate_if_needed >/dev/null 2>&1; then
    _rotate_if_needed || true
    _logger INFO "Log rotation requested"
  fi
fi

if [ "$DO_REVDEP" = true ] && [ -x "$RESOLVE_CMD" ]; then
  _logger INFO "Running porg-resolve --scan --fix"
  if [ "$DRY_RUN" = true ]; then
    _logger INFO "[dry-run] would call $RESOLVE_CMD --scan --fix"
  else
    "$RESOLVE_CMD" --scan --fix || _logger WARN "porg-resolve returned non-zero"
  fi
fi

if [ "$DO_CLEAN" = true ] && [ -x "$RESOLVE_CMD" ]; then
  _logger INFO "Running porg-resolve --clean"
  if [ "$DRY_RUN" = true ]; then
    _logger INFO "[dry-run] would call $RESOLVE_CMD --clean"
  else
    "$RESOLVE_CMD" --clean || _logger WARN "porg-resolve --clean returned non-zero"
  fi
fi

# final report
ts="$(date -u +%Y%m%dT%H%M%SZ)"
REPORT_FILE="${REPORT_DIR}/upgrade-report-${ts}.log"
{
  echo "porg-upgrade run: $ts"
  echo "targets: ${targets[*]}"
  echo "dry-run: $DRY_RUN"
  echo "quiet: $QUIET"
  echo "sync: $DO_SYNC"
  echo "resume: $RESUME"
  echo "state-file: $STATE_FILE"
} > "$REPORT_FILE"
_logger INFO "Upgrade finished; report saved to $REPORT_FILE"

exit 0
