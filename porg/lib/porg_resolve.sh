#!/usr/bin/env bash
#
# porg-resolve
# revdep + depclean unified resolver for Porg
#
# Local: /usr/lib/porg/porg-resolve  (ou /usr/local/bin/porg-resolve)
# chmod +x /usr/lib/porg/porg-resolve
#
set -euo pipefail
IFS=$'\n\t'

# -------------------- Defaults / Paths (overridable via env or /etc/porg/porg.conf) --------------------
PORG_CONF="${PORG_CONF:-/etc/porg/porg.conf}"
LOGGER_SCRIPT="${LOGGER_SCRIPT:-/usr/lib/porg/porg_logger.sh}"
DB_SCRIPT="${DB_SCRIPT:-/usr/lib/porg/porg_db.sh}"
DEPS_PY="${DEPS_PY:-/usr/lib/porg/deps.py}"
REMOVE_SCRIPT="${REMOVE_SCRIPT:-/usr/lib/porg/porg_remove.sh}"
BUILDER_CMD="${BUILDER_CMD:-porg}"                    # prefer 'porg' wrapper if present
BUILDER_SCRIPT="${BUILDER_SCRIPT:-/usr/lib/porg/porg_builder.sh}"
PORTS_DIR="${PORTS_DIR:-/usr/ports}"
LOG_DIR="${LOG_DIR:-/var/log/porg}"
REPORT_DIR="${REPORT_DIR:-${LOG_DIR}}"

# runtime flags (defaults)
DRY_RUN=false
QUIET=false
AUTO_YES=false
PARALLEL="$(nproc 2>/dev/null || echo 1)"
JSON=false

# behavior flags
DO_SCAN=false
DO_FIX=false
DO_CLEAN=false
TARGET_PKG=""

# report accumulators
REPORT_TMP="$(mktemp /tmp/porg-resolve-report.XXXXXX)"
REPORT_JSON_TMP="$(mktemp /tmp/porg-resolve-json.XXXXXX)"
trap 'rm -f "$REPORT_TMP" "$REPORT_JSON_TMP"' EXIT

# ensure directories
mkdir -p "$LOG_DIR" "$REPORT_DIR"

# -------------------- load porg.conf KEY=VAL simple --------------------
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

# -------------------- source logger & db if available --------------------
if [ -f "$LOGGER_SCRIPT" ]; then
  # shellcheck disable=SC1090
  source "$LOGGER_SCRIPT"
else
  log_init() { :; }
  log() { local lvl="$1"; shift; printf "[%s] %s\n" "$lvl" "$*"; }
  log_section() { printf "=== %s ===\n" "$*"; }
fi

if [ -f "$DB_SCRIPT" ]; then
  # shellcheck disable=SC1090
  source "$DB_SCRIPT"
else
  # provide minimal db helpers using INSTALLED_DB default
  INSTALLED_DB="${INSTALLED_DB:-/var/db/porg/installed.json}"
  _db_ensure() { [ -f "$INSTALLED_DB" ] || printf '{}' > "$INSTALLED_DB"; }
  db_list() {
    _db_ensure
    python3 - <<PY
import json,sys
p=sys.argv[1]
try:
  db=json.load(open(p,'r',encoding='utf-8'))
except:
  db={}
for k,v in db.items():
  print(k)
PY
    "$INSTALLED_DB"
  }
  db_info() {
    _db_ensure
    python3 - <<PY
import json,sys
p=sys.argv[1]; q=sys.argv[2]
try:
  db=json.load(open(p,'r',encoding='utf-8'))
  v=db.get(q)
  if v is None:
    sys.exit(1)
  print(json.dumps(v,ensure_ascii=False))
except:
  sys.exit(2)
PY
    "$INSTALLED_DB" "$1"
  }
fi

# -------------------- helpers --------------------
usage() {
  cat <<EOF
Usage: porg-resolve [options]
Options:
  --scan             : scan system for broken deps and orphans
  --fix              : attempt to repair (reinstall) broken packages
  --clean            : remove orphaned packages (safe)
  --all              : scan + fix + clean
  --pkg <pkg>        : operate only on a single package
  --dry-run          : do not perform destructive actions
  --parallel <N>     : number of parallel jobs (default: nproc)
  --quiet            : minimal output (logs still written)
  --yes              : auto-confirm prompts
  --json             : emit JSON report alongside human report
  -h|--help
EOF
}

# parse CLI
if [ "$#" -eq 0 ]; then usage; exit 1; fi
while [ "$#" -gt 0 ]; do
  case "$1" in
    --scan) DO_SCAN=true; shift ;;
    --fix) DO_FIX=true; shift ;;
    --clean) DO_CLEAN=true; shift ;;
    --all) DO_SCAN=true; DO_FIX=true; DO_CLEAN=true; shift ;;
    --pkg) TARGET_PKG="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --parallel) PARALLEL="${2:-$PARALLEL}"; shift 2 ;;
    --quiet) QUIET=true; shift ;;
    --yes) AUTO_YES=true; shift ;;
    --json) JSON=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1"; usage; exit 2 ;;
  esac
done

# default to scan if nothing requested
if [ "$DO_SCAN" = false ] && [ "$DO_FIX" = false ] && [ "$DO_CLEAN" = false ]; then
  DO_SCAN=true
fi

# small wrapper of log respecting --quiet
_log() {
  local lvl="$1"; shift
  if [ "$QUIET" = true ] && [ "$lvl" != "ERROR" ]; then
    # quiet: still write to session file via log() but suppress stdout if logger prints
    # call logger but don't print to stdout for non-error
    if declare -f log >/dev/null 2>&1; then
      # log() will handle writing; but to suppress extra printing rely on logger QUIET var
      log "$lvl" "$*"
    else
      printf "[%s] %s\n" "$lvl" "$*" >> "$REPORT_TMP"
    fi
  else
    log "$lvl" "$*"
  fi
}

# find metafile for a package (search PORTS_DIR)
find_metafile_for() {
  local pkg="$1"
  # prefer <ports>/<cat>/<pkg> directory
  if [ -d "$PORTS_DIR" ]; then
    for cat in "$PORTS_DIR"/*; do
      [ -d "$cat" ] || continue
      if [ -d "$cat/$pkg" ]; then
        # pick first yaml file inside
        mf=$(ls -1 "$cat/$pkg"/*.{yml,yaml} 2>/dev/null | head -n1 || true)
        [ -n "$mf" ] && { echo "$mf"; return 0; }
      fi
    done
    # fallback walk
    mf=$(find "$PORTS_DIR" -type f -iname "${pkg}*.y*ml" -print -quit 2>/dev/null || true)
    [ -n "$mf" ] && { echo "$mf"; return 0; }
  fi
  return 1
}

# call deps.py to get resolved order or missing list
deps_resolve_order() {
  local pkg="$1"
  if [ -x "$DEPS_PY" ]; then
    python3 "$DEPS_PY" resolve "$pkg" 2>/dev/null || true
  else
    # best-effort: return pkg only
    printf '{"package":"%s","order":["%s"]}' "$pkg" "$pkg"
  fi
}

deps_missing() {
  local pkg="$1"
  if [ -x "$DEPS_PY" ]; then
    python3 "$DEPS_PY" missing "$pkg" 2>/dev/null || true
  else
    printf '{"package":"%s","missing":[]}' "$pkg"
  fi
}

# check single package integrity:
# - db_info must exist
# - prefix must exist
# - run ldd on ELF files under prefix/bin and prefix/lib to detect "not found"
check_pkg_integrity() {
  local pkg="$1"
  local info
  info="$(db_info "$pkg" 2>/dev/null || true)"
  if [ -z "$info" ]; then
    echo "MISSING_DB"
    return 0
  fi
  # extract prefix
  local prefix
  prefix="$(echo "$info" | python3 -c "import sys,json;print(json.load(sys.stdin).get('prefix',''))" 2>/dev/null || echo "")"
  if [ -z "$prefix" ]; then
    echo "NO_PREFIX"
    return 0
  fi
  if [ ! -d "$prefix" ]; then
    echo "MISSING_PREFIX"
    return 0
  fi
  # look for ELF files in bin/lib/lib64
  local missing_libs=0
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    # ldd may fail on scripts; ignore errors; search for "not found"
    if ldd "$f" 2>/dev/null | grep -q "not found"; then
      missing_libs=$((missing_libs+1))
    fi
  done < <(find "$prefix" -type f \( -path "$prefix/bin/*" -o -path "$prefix/sbin/*" -o -path "$prefix/lib/*" -o -path "$prefix/lib64/*" \) -executable -print 2>/dev/null || true)
  if [ "$missing_libs" -gt 0 ]; then
    echo "BROKEN_LDD"
  else
    echo "OK"
  fi
}

# collect list of installed packages (optionally single package)
list_installed_pkgs() {
  if [ -n "$TARGET_PKG" ]; then
    echo "$TARGET_PKG"
    return 0
  fi
  # try db_list (sourced) else fallback
  if declare -f db_list >/dev/null 2>&1; then
    db_list | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$'
  else
    INSTALLED_DB="${INSTALLED_DB:-/var/db/porg/installed.json}"
    python3 - <<PY
import sys,json
p=sys.argv[1]
try:
  db=json.load(open(p,'r',encoding='utf-8'))
except:
  db={}
for k in db.keys():
  print(k)
PY
    "$INSTALLED_DB"
  fi
}

# build (reinstall) a single package
fix_package() {
  local pkg="$1"
  _log INFO "Attempting to rebuild/reinstall package: $pkg"
  if [ "$DRY_RUN" = true ]; then
    _log INFO "[dry-run] would reinstall $pkg (builder)"
    echo "FIX-DRY:$pkg" >> "$REPORT_TMP"
    return 0
  fi

  # prefer 'porg' wrapper if present
  if command -v porg >/dev/null 2>&1; then
    _log INFO "Invoking: porg -i $pkg"
    if porg -i "$pkg"; then
      _log INFO "Reinstall succeeded: $pkg"
      echo "FIXED:$pkg" >> "$REPORT_TMP"
      return 0
    else
      _log WARN "porg -i $pkg failed"
    fi
  fi

  # fallback: try to find metafile and call builder script
  if [ -x "$BUILDER_SCRIPT" ]; then
    mf="$(find_metafile_for "$pkg" || true)"
    if [ -n "$mf" ]; then
      _log INFO "Using builder script: $BUILDER_SCRIPT build $mf"
      if "$BUILDER_SCRIPT" build "$mf"; then
        _log INFO "Rebuild succeeded via builder script for $pkg"
        echo "FIXED:$pkg" >> "$REPORT_TMP"
        return 0
      else
        _log WARN "Builder script failed for $pkg"
      fi
    else
      _log WARN "Metafile not found for $pkg; cannot call builder script automatically"
    fi
  fi

  # as last resort, try apt/dnf/pacman? (not implemented) — mark as failed
  _log ERROR "Unable to automatically rebuild $pkg; manual intervention required"
  echo "FAILED:$pkg" >> "$REPORT_TMP"
  return 2
}

# remove orphan via remove script
remove_orphan() {
  local pkg="$1"
  _log INFO "Removing orphan package: $pkg"
  if [ "$DRY_RUN" = true ]; then
    _log INFO "[dry-run] Would call remove script for $pkg"
    echo "ORPHAN-DRY:$pkg" >> "$REPORT_TMP"
    return 0
  fi
  if [ -x "$REMOVE_SCRIPT" ]; then
    if "$REMOVE_SCRIPT" "$pkg" --yes --force; then
      _log INFO "Orphan removed: $pkg"
      echo "REMOVED:$pkg" >> "$REPORT_TMP"
      return 0
    else
      _log WARN "Remove script failed for orphan $pkg"
      echo "REMOVE-FAILED:$pkg" >> "$REPORT_TMP"
      return 2
    fi
  else
    # fallback: try db_unregister only
    if declare -f db_unregister >/dev/null 2>&1; then
      db_unregister "$pkg" && _log INFO "DB entry removed (orphan): $pkg" && echo "REMOVED-DB:$pkg" >> "$REPORT_TMP" || echo "REMOVE-DB-FAILED:$pkg" >> "$REPORT_TMP"
      return 0
    fi
    _log WARN "No remove script found; cannot remove orphan $pkg safely"
    echo "ORPHAN-SKIP:$pkg" >> "$REPORT_TMP"
    return 1
  fi
}

# revdep scan: find broken packages
revdep_scan() {
  _log STAGE "Starting revdep scan"
  local broken_list_file
  broken_list_file="$(mktemp)"
  touch "$broken_list_file"
  for pkg in $(list_installed_pkgs); do
    # check integrity
    status="$(check_pkg_integrity "$pkg")"
    case "$status" in
      OK) _log DEBUG "OK: $pkg" ;;
      MISSING_DB) _log WARN "Missing DB entry for $pkg"; echo "$pkg|MISSING_DB" >> "$broken_list_file" ;;
      NO_PREFIX) _log WARN "No prefix recorded for $pkg"; echo "$pkg|NO_PREFIX" >> "$broken_list_file" ;;
      MISSING_PREFIX) _log WARN "Prefix missing for $pkg"; echo "$pkg|MISSING_PREFIX" >> "$broken_list_file" ;;
      BROKEN_LDD) _log WARN "Broken (ldd) libs for $pkg"; echo "$pkg|BROKEN_LDD" >> "$broken_list_file" ;;
      *) _log WARN "Unknown status ($status) for $pkg"; echo "$pkg|$status" >> "$broken_list_file" ;;
    esac
  done
  # produce report
  if [ -s "$broken_list_file" ]; then
    _log WARN "revdep scan found broken packages:"
    cat "$broken_list_file" | sed 's/^/  /' | tee -a "$REPORT_TMP"
  else
    _log INFO "revdep scan: no broken packages found"
  fi
  awk -F'|' '{print $1}' "$broken_list_file" > "${broken_list_file}.pkgs"
  # write list to REPORT_TMP
  while IFS= read -r p; do [ -n "$p" ] && echo "BROKEN:$p" >> "$REPORT_TMP"; done < "${broken_list_file}.pkgs"
  # output file path for further steps
  printf "%s\n" "${broken_list_file}.pkgs"
}

# depclean scan: find orphaned packages
depclean_scan() {
  _log STAGE "Starting depclean scan (orphans)"
  # Read installed DB and build reverse map
  python3 - <<PY > /tmp/porg_resolve_orphans.$$ 2>/dev/null
import json,sys
p=sys.argv[1]
try:
  db=json.load(open(p,'r',encoding='utf-8'))
except:
  db={}
deps_map={}
for k,v in db.items():
  deps=v.get('deps') or []
  for d in deps:
    deps_map.setdefault(d, set()).add(k)
orphans=[]
for k,v in db.items():
  # a package is orphan if no package depends on it (consider name base)
  name=k.split('-')[0]
  relied=False
  for dep,owners in deps_map.items():
    if dep==k or dep.split('-')[0]==name or k in owners:
      relied=True; break
  if not relied:
    # skip protected base/system packages heuristics: skip packages installed to / (prefix '/')
    prefix=v.get('prefix','')
    if prefix and prefix not in ('/','/usr') :
      orphans.append(k)
print("\n".join(orphans))
PY
  INSTALLED_DB="${INSTALLED_DB:-/var/db/porg/installed.json}"
  python3 - "$INSTALLED_DB" > /tmp/porg_resolve_orphans.$$ 2>/dev/null || true
  if [ -s /tmp/porg_resolve_orphans.$$ ]; then
    _log WARN "depclean scan found orphans:"
    sed 's/^/  - /' /tmp/porg_resolve_orphans.$$ | tee -a "$REPORT_TMP"
    awk '{print $0}' /tmp/porg_resolve_orphans.$$ > /tmp/porg_resolve_orphans_list.$$
    printf "%s\n" "/tmp/porg_resolve_orphans_list.$$"
  else
    _log INFO "depclean: no orphans found"
    printf "%s\n" ""
  fi
}

# run fixes in parallel
run_fixes_parallel() {
  local file="$1"
  local n="$2"
  if [ ! -s "$file" ]; then
    _log INFO "No packages to fix"
    return 0
  fi
  # use xargs to parallelize: pass each pkg line to fix_package
  if command -v xargs >/dev/null 2>&1; then
    cat "$file" | xargs -r -n1 -P "$n" -I{} bash -c 'p="{}"; '"$(declare -f _log fix_package >/dev/null 2>&1; echo '_log() { '" ) 2>/dev/null || true
    # fallback loop if xargs not available:
    while IFS= read -r p; do fix_package "$p"; done < "$file"
  else
    while IFS= read -r p; do fix_package "$p"; done < "$file"
  fi
}

# clean orphans in parallel
run_clean_parallel() {
  local file="$1"
  local n="$2"
  if [ ! -s "$file" ]; then
    _log INFO "No orphans to remove"
    return 0
  fi
  while IFS= read -r p; do
    # run sequentially or in background controlled by PARALLEL
    # for simplicity, run sequentially but respect DRY_RUN
    remove_orphan "$p"
  done < "$file"
}

# -------------------- Orchestration functions --------------------
do_scan_only() {
  _log STAGE "Running scan-only (revdep + depclean)"
  broken_list_pkgs="$(revdep_scan)"
  orphans_list_file="$(depclean_scan)"
  # prepare human report
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  report_file="${REPORT_DIR}/resolve-report-${ts}.log"
  {
    echo "porg-resolve scan report: $ts"
    echo "--- broken packages ---"
    [ -n "$broken_list_pkgs" ] && [ -f "$broken_list_pkgs" ] && sed 's/^/  /' "$broken_list_pkgs" || echo "  (none)"
    echo "--- orphan packages ---"
    if [ -n "$orphans_list_file" ] && [ -f "$orphans_list_file" ]; then sed 's/^/  /' "$orphans_list_file"; else echo "  (none)"; fi
  } | tee "$report_file"
  _log INFO "Report written: $report_file"
  # create JSON if requested
  if [ "$JSON" = true ]; then
    jq -n --argfile b "$broken_list_pkgs" --argfile o "$orphans_list_file" '{broken: ($b // []), orphans: ($o // [])}' > "${report_file}.json" 2>/dev/null || true
  fi
}

do_fix_only() {
  _log STAGE "Running fix-only (attempt to rebuild broken packages)"
  broken_list_pkgs="$(revdep_scan)"
  if [ -z "$broken_list_pkgs" ] || [ ! -f "$broken_list_pkgs" ]; then
    _log INFO "No broken packages detected"
    return 0
  fi
  # fix each package (in parallel)
  _log INFO "Fixing packages (parallel=$PARALLEL)"
  run_fixes_parallel "$broken_list_pkgs" "$PARALLEL"
  _log INFO "Fix stage complete"
}

do_clean_only() {
  _log STAGE "Running clean-only (remove orphans)"
  orphans_file_tmp="$(mktemp)"
  # reuse depclean_scan output
  orphans_file=$(depclean_scan)
  if [ -z "$orphans_file" ] || [ ! -f "$orphans_file" ]; then
    _log INFO "No orphans detected"
    return 0
  fi
  _log INFO "Removing orphans (careful)"
  run_clean_parallel "$orphans_file" "$PARALLEL"
  _log INFO "Clean stage complete"
}

do_all() {
  _log STAGE "Running full resolve: scan -> fix -> clean"
  # 1) scan
  broken_list_pkgs="$(revdep_scan)"
  orphans_list_file="$(depclean_scan)"
  # 2) fix broken packages
  if [ -n "$broken_list_pkgs" ] && [ -f "$broken_list_pkgs" ]; then
    _log INFO "Fixing broken packages..."
    run_fixes_parallel "$broken_list_pkgs" "$PARALLEL"
  else
    _log INFO "No broken packages to fix"
  fi
  # 3) recompute orphans after fixes
  orphans_list_file="$(depclean_scan)"
  if [ -n "$orphans_list_file" ] && [ -f "$orphans_list_file" ]; then
    _log INFO "Removing orphans detected after fixes..."
    run_clean_parallel "$orphans_list_file" "$PARALLEL"
  else
    _log INFO "No orphans to remove"
  fi
  _log INFO "Full resolve completed"
}

# -------------------- Entrypoint --------------------
_start="$(date +%s)"
_log STAGE "porg-resolve started at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
_log INFO "Flags: scan=$DO_SCAN fix=$DO_FIX clean=$DO_CLEAN dryrun=$DRY_RUN parallel=$PARALLEL json=$JSON target=$TARGET_PKG"

if [ "$DO_SCAN" = true ]; then do_scan_only; fi
if [ "$DO_FIX" = true ]; then do_fix_only; fi
if [ "$DO_CLEAN" = true ]; then do_clean_only; fi
if [ "$DO_SCAN" = false ] && [ "$DO_FIX" = false ] && [ "$DO_CLEAN" = false ]; then
  _log INFO "No action requested"
fi

_end="$(date +%s)"
_duration=$(( _end - _start ))
_log INFO "porg-resolve finished in ${_duration}s"

# final report: aggregate REPORT_TMP into timestamped file
ts="$(date -u +%Y%m%dT%H%M%SZ)"
report_file="${REPORT_DIR}/resolve-report-${ts}.log"
{
  echo "porg-resolve run: $ts"
  cat "$REPORT_TMP" 2>/dev/null || true
  echo "duration_s: ${_duration}"
} > "$report_file"
_log INFO "Resolve report saved: $report_file"

if [ "$JSON" = true ]; then
  # try to create very simple JSON summary
  python3 - <<PY > "${report_file}.json"
import sys,json
lines=open(sys.argv[1]).read().splitlines()
summary = {"report_lines": lines}
print(json.dumps(summary, indent=2, ensure_ascii=False))
PY
  "$report_file"
  _log INFO "JSON report saved: ${report_file}.json"
fi

exit 0
