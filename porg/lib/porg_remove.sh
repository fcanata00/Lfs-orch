#!/usr/bin/env bash
#
# porg_remove.sh
# Remoção inteligente de pacotes para Porg
# - integrado com porg_logger.sh, porg_db.sh, deps.py
# - executa hooks de pacote (pre-remove / post-remove) localizados em:
#     /usr/ports/<categoria>/<pacote>/hooks/pre-remove
#     /usr/ports/<categoria>/<pacote>/hooks/post-remove
# - verifica reverse-deps; suporta --force, --dry-run, --recursive, --quiet, --yes
# - tenta invocar porg_revdep.sh e porg_depclean.sh se presentes; caso contrário, usa heurísticas
#
# Uso:
#   porg_remove.sh <pkgid|pkgname> [--dry-run] [--force] [--recursive] [--quiet] [--yes] [--clean-logs]
#
set -euo pipefail
IFS=$'\n\t'

# -------------------- Config / Paths (sobrescrevíveis por env ou porg.conf) --------------------
PORG_CONF="${PORG_CONF:-/etc/porg/porg.conf}"
LOGGER_SCRIPT="${LOGGER_SCRIPT:-/usr/lib/porg/porg_logger.sh}"
DB_SCRIPT="${DB_SCRIPT:-/usr/lib/porg/porg_db.sh}"
DEPS_PY="${DEPS_PY:-/usr/lib/porg/deps.py}"
REVDEP_SCRIPT="${REVDEP_SCRIPT:-/usr/lib/porg/porg_revdep.sh}"
DEPCLEAN_SCRIPT="${DEPCLEAN_SCRIPT:-/usr/lib/porg/porg_depclean.sh}"
PORTS_DIR="${PORTS_DIR:-/usr/ports}"
KEEP_LOGS_DAYS="${KEEP_LOGS_DAYS:-30}"

# flags
DRY_RUN=false
FORCE=false
RECURSIVE=false
QUIET=false
AUTO_YES=false
CLEAN_LOGS=false

# -------------------- Helpers: load porg.conf (simple KEY=VAL) --------------------
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

# -------------------- Source logger and db modules if available --------------------
if [ -f "$LOGGER_SCRIPT" ]; then
  # shellcheck disable=SC1090
  source "$LOGGER_SCRIPT"
else
  # minimal logger fallback
  log_init() { :; }
  log() { local level="$1"; shift; printf '[%s] %s\n' "$level" "$*"; }
  log_section() { printf '=== %s ===\n' "$*"; }
  log_progress() { :; }
  log_spinner() { :; }
fi

if [ -f "$DB_SCRIPT" ]; then
  # prefer to source db helpers
  # shellcheck disable=SC1090
  source "$DB_SCRIPT"
else
  # minimal DB helpers (fallback to installed.json direct access)
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
    print(k, v.get('version',''), v.get('prefix',''), v.get('installed_at',''))
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
except:
    db={}
val=db.get(q)
if val is None:
    sys.exit(1)
print(json.dumps(val,ensure_ascii=False,indent=2))
PY
    "$INSTALLED_DB" "$1"
  }
  db_unregister() {
    _db_ensure
    python3 - <<PY
import json,sys
p=sys.argv[1]; q=sys.argv[2]
try:
    db=json.load(open(p,'r',encoding='utf-8'))
except:
    db={}
removed=[]
for k in list(db.keys()):
    if k==q or k.startswith(q+'-') or k.split('-')[0]==q:
        removed.append(k)
        db.pop(k,None)
with open(p,'w',encoding='utf-8') as f:
    json.dump(db,f,indent=2,ensure_ascii=False,sort_keys=True)
for r in removed:
    print(r)
PY
    "$INSTALLED_DB" "$1"
  }
  db_get_prefix() {
    _db_ensure
    python3 - <<PY
import json,sys
p=sys.argv[1]; q=sys.argv[2]
try:
    db=json.load(open(p,'r',encoding='utf-8'))
except:
    db={}
for k,v in db.items():
    if k==q or k.startswith(q+'-') or k.split('-')[0]==q:
        print(v.get('prefix',''))
        sys.exit(0)
sys.exit(1)
PY
    "$INSTALLED_DB" "$1"
  }
fi

# -------------------- CLI parsing --------------------
usage() {
  cat <<EOF
Usage: ${0##*/} <pkgid|pkgname> [options]
Options:
  --dry-run       Show what would be removed
  --force         Force removal even if reverse-deps exist (will try depclean/revdep)
  --recursive     Also remove dependencies that become orphaned
  --quiet         Minimal terminal output (logs still written)
  --yes           Answer yes to prompts
  --clean-logs    Remove logs older than KEEP_LOGS_DAYS
  -h|--help       Show this help
EOF
}

if [ "$#" -lt 1 ]; then usage; exit 1; fi

PKG_ARG=""
# parse positional + flags
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --force) FORCE=true; shift ;;
    --recursive) RECURSIVE=true; shift ;;
    --quiet) QUIET=true; shift ;;
    --yes) AUTO_YES=true; shift ;;
    --clean-logs) CLEAN_LOGS=true; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    *)
      if [ -z "$PKG_ARG" ]; then PKG_ARG="$1"; shift; else echo "Unknown argument: $1"; usage; exit 2; fi
      ;;
  esac
done

if [ "$CLEAN_LOGS" = true ]; then
  log "INFO" "Cleaning logs older than ${KEEP_LOGS_DAYS} days"
  if [ -d "${LOG_DIR:-/var/log/porg}" ]; then
    find "${LOG_DIR:-/var/log/porg}" -type f -mtime +"${KEEP_LOGS_DAYS}" -print0 | xargs -0r rm -f --
    log "INFO" "Old logs removed"
  else
    log "WARN" "Log dir not found: ${LOG_DIR:-/var/log/porg}"
  fi
  # if only cleaning logs requested, exit
  if [ -z "$PKG_ARG" ]; then exit 0; fi
fi

if [ -z "$PKG_ARG" ]; then _die "Package argument required"; fi

TARGET="$PKG_ARG"

# -------------------- Utilities --------------------
confirm() {
  if [ "$AUTO_YES" = true ]; then return 0; fi
  printf "%s [y/N]: " "$1" >&2
  read -r ans
  case "$ans" in
    y|Y|yes|Yes) return 0 ;;
    *) return 1 ;;
  esac
}

# find all installed packages that depend on target
find_reverse_deps() {
  # uses installed.json to find packages whose deps include target (exact or prefix)
  # returns newline-separated pkgids
  python3 - <<PY
import json,sys,os
dbpath=sys.argv[1]; target=sys.argv[2]
try:
    db=json.load(open(dbpath,'r',encoding='utf-8'))
except:
    db={}
res=[]
for k,v in db.items():
    deps=v.get('deps') or []
    for d in deps:
        if d==target or d.split('-')[0]==target or d.startswith(target+'-'):
            res.append(k); break
print("\n".join(res))
PY
  "${INSTALLED_DB:-/var/db/porg/installed.json}" "$TARGET"
}

# get package info JSON (or fail)
get_pkg_info() {
  # try db_info (sourced) first
  if type db_info >/dev/null 2>&1; then
    if db_info "$TARGET" >/dev/null 2>&1; then
      db_info "$TARGET"
      return 0
    fi
  fi
  # fallback to direct installed json
  _db_ensure
  python3 - <<PY
import json,sys
p=sys.argv[1]; q=sys.argv[2]
try:
    db=json.load(open(p,'r',encoding='utf-8'))
except:
    db={}
for k,v in db.items():
    if k==q or k.startswith(q+'-') or k.split('-')[0]==q:
        print(json.dumps(v,ensure_ascii=False))
        sys.exit(0)
sys.exit(1)
PY
  "${INSTALLED_DB:-/var/db/porg/installed.json}" "$TARGET"
}

# remove prefix directory safely
remove_prefix() {
  local prefix="$1"
  if [ -z "$prefix" ]; then log "WARN" "Prefix empty, skipping"; return 1; fi
  # protect against accidental removal of root or important dirs
  case "$prefix" in
    "/"|"/usr"|"/bin"|"/lib"|"/lib64"|"/sbin"|"/etc")
      log "ERROR" "Refusing to remove unsafe prefix: $prefix"
      return 2
      ;;
  esac
  # check if other packages share this prefix
  if [ -f "${INSTALLED_DB:-/var/db/porg/installed.json}" ]; then
    same=$(python3 - <<PY
import json,sys,os
p=sys.argv[1]; pref=sys.argv[2]; q=sys.argv[3]
try:
    db=json.load(open(p,'r',encoding='utf-8'))
except:
    db={}
res=[]
for k,v in db.items():
    if v.get('prefix')==pref and not (k==q or k.startswith(q+'-')):
        res.append(k)
print(",".join(res))
PY
    "${INSTALLED_DB:-/var/db/porg/installed.json}" "$prefix" "$TARGET")
    if [ -n "$same" ]; then
      log "WARN" "Prefix $prefix is shared with other packages: $same. Not removing prefix directory unless --force."
      if [ "$FORCE" != true ]; then
        return 3
      fi
    fi
  fi

  if [ "$DRY_RUN" = true ]; then
    log "INFO" "[dry-run] Would remove prefix: $prefix"
    return 0
  fi

  log "INFO" "Removing prefix: $prefix"
  if rm -rf -- "$prefix"; then
    log "INFO" "Removed $prefix"
    return 0
  else
    if [ "$FORCE" = true ]; then
      log "WARN" "Failed to remove $prefix (ignored due to --force)"
      return 0
    else
      log "ERROR" "Failed to remove $prefix"
      return 4
    fi
  fi
}

# execute hooks for this package (relative to package dir)
run_pkg_hooks() {
  local stage="$1"  # pre-remove | post-remove
  # attempt to find package dir under PORTS_DIR
  # try to locate directory containing package name
  local found=""
  if [ -d "$PORTS_DIR" ]; then
    # find directories matching package name
    while IFS= read -r d; do
      # prefer exact match /usr/ports/*/<pkg>
      if [ -d "$d/hooks/$stage" ]; then
        found="$d/hooks/$stage"
        break
      fi
    done < <(find "$PORTS_DIR" -maxdepth 3 -type d -name "$TARGET" 2>/dev/null || true)
  fi
  # fallback: search for any hooks path containing the pkg name
  if [ -z "$found" ]; then
    cand=$(find "$PORTS_DIR" -type d -path "*/$TARGET" 2>/dev/null | head -n1 || true)
    if [ -n "$cand" ] && [ -d "$cand/hooks/$stage" ]; then
      found="$cand/hooks/$stage"
    fi
  fi

  if [ -z "$found" ]; then
    log "DEBUG" "No hooks found for $TARGET at stage $stage"
    return 0
  fi

  log "INFO" "Executing $stage hooks in $found"
  for hook in "$found"/*; do
    [ -x "$hook" ] || continue
    log "INFO" "Running hook: $hook"
    if [ "$DRY_RUN" = true ]; then
      log "INFO" "[dry-run] would execute $hook"
      continue
    fi
    if ! "$hook"; then
      log "WARN" "Hook $hook returned non-zero"
      if [ "$FORCE" != true ]; then
        log "ERROR" "Aborting due to hook failure: $hook"
        return 1
      fi
    fi
  done
  return 0
}

# -------------------- Main removal workflow --------------------
log_section "porg_remove: starting removal of $TARGET"
SESSION_START=$(date +%s)

# fetch package info
pkg_json="$(get_pkg_info 2>/dev/null || true)"
if [ -z "$pkg_json" ]; then
  log "ERROR" "Package not found in DB: $TARGET"
  exit 1
fi

# extract useful fields using python
pkg_name="$(python3 - <<PY
import json,sys
try:
    obj=json.loads(sys.stdin.read())
    print(obj.get('name') or obj.get('pkg') or '')
except:
    pass
PY
<<<"$pkg_json")"
pkg_version="$(python3 - <<PY
import json,sys
try:
    obj=json.loads(sys.stdin.read())
    print(obj.get('version') or '')
except:
    pass
PY
<<<"$pkg_json")"
pkg_prefix="$(python3 - <<PY
import json,sys
try:
    obj=json.loads(sys.stdin.read())
    print(obj.get('prefix') or '')
except:
    pass
PY
<<<"$pkg_json")"

log "INFO" "Target: $TARGET (name=$pkg_name version=$pkg_version prefix=$pkg_prefix)"

# find reverse deps
revdeps="$(find_reverse_deps)"
if [ -n "$revdeps" ]; then
  log "WARN" "Reverse dependencies found for $TARGET:"
  echo "$revdeps" | sed 's/^/  - /'
  if [ "$FORCE" = false ]; then
    log "ERROR" "Package has dependents; aborting. Use --force to remove and attempt recovery (revdep/depclean)."
    exit 2
  else
    log "WARN" "--force specified: will attempt to handle dependents (revdep/depclean)."
    # attempt to call revdep script if exists
    if [ -x "$REVDEP_SCRIPT" ]; then
      if [ "$DRY_RUN" = true ]; then
        log "INFO" "[dry-run] Would invoke revdep script: $REVDEP_SCRIPT ${revdeps%%$'\n'*}"
      else
        log "INFO" "Invoking revdep script to attempt repair: $REVDEP_SCRIPT"
        "$REVDEP_SCRIPT" repair $TARGET || log "WARN" "revdep script failed or returned non-zero"
      fi
    else
      log "INFO" "No revdep script found at $REVDEP_SCRIPT; will attempt heuristic: mark dependents as requiring rebuild"
      # heuristic: print instruction
      echo "Dependents that may break: "
      echo "$revdeps" | sed 's/^/  * /'
      log "INFO" "After removal consider rebuilding these packages manually via porg: porg -i <pkg>"
    fi
  fi
else
  log "DEBUG" "No reverse dependencies found for $TARGET"
fi

# run pre-remove hooks for this package
if ! run_pkg_hooks "pre-remove"; then
  log "ERROR" "pre-remove hooks signaled failure. Aborting."
  exit 3
fi

# Determine removal action:
# Prefer to remove prefix directory; if prefix empty, try to derive install location
if [ -z "$pkg_prefix" ] || [ "$pkg_prefix" = "/" ]; then
  log "WARN" "Package prefix is empty or '/'. Removing file-by-file not possible because DB does not track file lists."
  if [ "$FORCE" != true ]; then
    log "ERROR" "Refusing to remove ambiguous install location. Use --force to proceed (dangerous)."
    exit 4
  fi
fi

# Confirm
if [ "$DRY_RUN" = false ] && [ "$AUTO_YES" = false ]; then
  if ! confirm "Proceed to remove $TARGET (prefix: $pkg_prefix) ?"; then
    log "INFO" "User cancelled removal"
    exit 0
  fi
fi

# perform removal (prefix removal)
if [ -n "$pkg_prefix" ] && [ "$pkg_prefix" != "/" ]; then
  remove_prefix "$pkg_prefix" || {
    rc=$?
    if [ "$rc" -ge 2 ] && [ "$FORCE" != true ]; then
      log "ERROR" "Prefix removal failed with code $rc; aborting."
      exit $rc
    fi
  }
else
  # fallback: try to remove known bin paths for package name
  candidates=( "/usr/bin/${pkg_name}" "/usr/sbin/${pkg_name}" "/usr/lib/${pkg_name}" "/usr/lib64/${pkg_name}" "/usr/share/${pkg_name}" )
  any_removed=false
  for f in "${candidates[@]}"; do
    if [ -e "$f" ]; then
      if [ "$DRY_RUN" = true ]; then
        log "INFO" "[dry-run] Would remove $f"
        any_removed=true
      else
        rm -rf -- "$f" 2>/dev/null || true
        log "INFO" "Removed $f"
        any_removed=true
      fi
    fi
  done
  if [ "$any_removed" = false ]; then
    log "WARN" "No files removed (no prefix and no common candidate files found). Consider manual cleanup."
  fi
fi

# unregister from DB
if [ "$DRY_RUN" = true ]; then
  log "INFO" "[dry-run] Would unregister $TARGET from DB"
else
  if type db_unregister >/dev/null 2>&1; then
    removed_keys="$(db_unregister "$TARGET" 2>/dev/null || true)"
    log "INFO" "Unregistered from DB: ${removed_keys:-(unknown)}"
  else
    # fallback: use python to remove
    if [ -f "${INSTALLED_DB:-/var/db/porg/installed.json}" ]; then
      python3 - <<PY
import json,sys
p=sys.argv[1]; q=sys.argv[2]
try:
    db=json.load(open(p,'r',encoding='utf-8'))
except:
    db={}
removed=[]
for k in list(db.keys()):
    if k==q or k.startswith(q+'-') or k.split('-')[0]==q:
        removed.append(k); db.pop(k,None)
with open(p,'w',encoding='utf-8') as f:
    json.dump(db,f,indent=2,ensure_ascii=False,sort_keys=True)
print(",".join(removed))
PY
      "${INSTALLED_DB:-/var/db/porg/installed.json}" "$TARGET"
      log "INFO" "Unregistered $TARGET (fallback)"
    else
      log "WARN" "Cannot unregister $TARGET: installed DB not found"
    fi
  fi
fi

# If recursive: find package deps that became orphans and remove them
if [ "$RECURSIVE" = true ] || [ "$FORCE" = true ]; then
  # determine orphans: installed packages that are not depended upon by any remaining package
  log "INFO" "Calculating orphaned dependencies..."
  orphans="$(python3 - <<PY
import json,sys
dbp=sys.argv[1]
try:
    db=json.load(open(dbp,'r',encoding='utf-8'))
except:
    db={}
# build reverse map
deps_map={}
for k,v in db.items():
    deps=v.get('deps') or []
    for d in deps:
        deps_map.setdefault(d, set()).add(k)
orphans=[]
for k,v in db.items():
    # if no other package depends on k
    name=k.split('-')[0]
    depended=False
    for dep,owners in deps_map.items():
        if k in owners or dep.split('-')[0]==name:
            depended=True
            break
    if not depended:
        orphans.append(k)
print("\\n".join(orphans))
PY
  "${INSTALLED_DB:-/var/db/porg/installed.json}")"
  if [ -n "$orphans" ]; then
    log "INFO" "Orphaned packages detected:"
    echo "$orphans" | sed 's/^/  - /'
    if [ "$DRY_RUN" = true ]; then
      log "INFO" "[dry-run] Would remove orphans above"
    else
      for o in $orphans; do
        # avoid removing the package we just removed again
        if [ "$o" = "$TARGET" ]; then continue; fi
        log "INFO" "Removing orphan: $o"
        # call this script recursively for each orphan with --yes --force
        "${BASH_SOURCE[0]}" "$o" --yes --force || log "WARN" "Failed to remove orphan $o"
      done
    fi
  else
    log "DEBUG" "No orphans detected"
  fi
fi

# Try to run depclean if available (to clean leftover libs)
if [ -x "$DEPCLEAN_SCRIPT" ]; then
  if [ "$DRY_RUN" = true ]; then
    log "INFO" "[dry-run] Would invoke depclean: $DEPCLEAN_SCRIPT"
  else
    log "INFO" "Invoking depclean: $DEPCLEAN_SCRIPT"
    "$DEPCLEAN_SCRIPT" || log "WARN" "depclean returned non-zero"
  fi
else
  log "DEBUG" "depclean script not found at $DEPCLEAN_SCRIPT; skipping"
fi

# run post-remove hooks
if ! run_pkg_hooks "post-remove"; then
  log "WARN" "post-remove hooks returned non-zero"
fi

# final summary
SESSION_END=$(date +%s)
DURATION=$((SESSION_END-SESSION_START))
LOADAVG="$(cut -d' ' -f1 /proc/loadavg 2>/dev/null || echo 0.00)"
CPU_PERCENT="$(python3 - <<PY
read=0
try:
    import time,sys
    import os
    a=open('/proc/stat').readline().split()
    time.sleep(0.05)
    b=open('/proc/stat').readline().split()
    a_sum=sum(int(x) for x in a[1:])
    b_sum=sum(int(x) for x in b[1:])
    a_idle=int(a[4]); b_idle=int(b[4])
    diff_total=b_sum-a_sum
    diff_idle=b_idle-a_idle
    if diff_total>0:
        print(int(100*(diff_total-diff_idle)/diff_total))
    else:
        print(0)
except:
    print(0)
PY
)"
MEM_MB="$(awk '/MemTotal:/ {t=$2} /MemAvailable:/ {a=$2} END {printf \"%d\", (t-a)/1024}' /proc/meminfo 2>/dev/null || echo 0)"
log "INFO" "Removal complete: $TARGET duration=${DURATION}s load=${LOADAVG} cpu=${CPU_PERCENT}% mem=${MEM_MB}MB"

exit 0
