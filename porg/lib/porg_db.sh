#!/usr/bin/env bash
# porg_db.sh - Database module for Porg (robust, atomic, respects porg.conf)
# Path suggestion: /usr/lib/porg/porg_db.sh
# Usage: porg_db.sh {register|unregister|list|info|get-version|is-installed|backup|restore|stats|clean-logs} ...
set -euo pipefail
IFS=$'\n\t'

# ------------------ Load config early (so paths from porg.conf are respected) ------------------
PORG_CONF="${PORG_CONF:-/etc/porg/porg.conf}"
if [ -f "$PORG_CONF" ]; then
  # shellcheck disable=SC1090
  source "$PORG_CONF"
fi

# Defaults (only if porg.conf didn't set them)
DB_DIR="${DB_DIR:-/var/lib/porg/db}"
INSTALLED_DB="${INSTALLED_DB:-${DB_DIR}/installed.json}"
LOG_DIR="${LOG_DIR:-/var/log/porg}"
RESOLVE_MODULE="${RESOLVE_MODULE:-/usr/lib/porg/resolve.sh}"
AUTO_REVDEP_REBUILD="${AUTO_REVDEP_REBUILD:-true}"
DB_BACKUP_DIR="${DB_BACKUP_DIR:-/var/backups/porg/db}"
LOCK_DIR="${LOCK_DIR:-/var/lock/porg_db.lockdir}"

# ensure directories exist (now that we've read config)
mkdir -p "$DB_DIR" "$LOG_DIR" "$(dirname "$INSTALLED_DB")" "$DB_BACKUP_DIR"

# ------------------ Logger integration (use porg_logger if present) ------------------
LOGGER_SCRIPT="${LOGGER_MODULE:-/usr/lib/porg/porg_logger.sh}"
if [ -f "$LOGGER_SCRIPT" ]; then
  # shellcheck disable=SC1090
  source "$LOGGER_SCRIPT"
else
  # minimal logger
  _log() { local lvl="$1"; shift; printf "%s [%s] %s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$lvl" "$*" >> "${LOG_DIR}/porg_db.log"; }
  log_info()  { _log "INFO" "$*"; echo "[INFO] $*"; }
  log_warn()  { _log "WARN" "$*"; echo "[WARN] $*"; }
  log_error() { _log "ERROR" "$*"; echo "[ERROR] $*" >&2; }
fi

# ------------------ Utility helpers ------------------
_have_jq() { command -v jq >/dev/null 2>&1; }
_have_python() { command -v python3 >/dev/null 2>&1; }

_db_init_if_missing() {
  if [ ! -f "$INSTALLED_DB" ]; then
    printf "{}" > "$INSTALLED_DB"
    log_info "DB initialized at $INSTALLED_DB"
  fi
}

# Simple locking using mkdir (portable)
_db_lock_acquire() {
  local tries=0
  while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    tries=$((tries+1))
    if [ "$tries" -ge 50 ]; then
      log_error "Could not acquire db lock after multiple attempts"
      return 1
    fi
    sleep 0.1
  done
  # ensure lock is removed on exit
  trap '_db_lock_release' EXIT
  return 0
}
_db_lock_release() {
  rm -rf "$LOCK_DIR" 2>/dev/null || true
  trap - EXIT
}

# Atomic write: write to temp and mv
_db_atomic_write() {
  local dest="$1"; local tmp
  tmp="$(mktemp "${dest}.tmp.XXXX")"
  cat >"$tmp"
  mv -f "$tmp" "$dest"
  chmod 644 "$dest" || true
}

# Read DB (raw)
_db_read_raw() {
  _db_init_if_missing
  cat "$INSTALLED_DB"
}

# CLI helpers using jq or python
_db_register_py() {
  local name="$1"; local version="$2"; local prefix="$3"; shift 3
  local meta_json="$*"
  python3 - <<PY
import json,sys,time,os
dbp=os.path.expanduser("$INSTALLED_DB")
try:
    db=json.load(open(dbp,'r',encoding='utf-8'))
except:
    db={}
name=sys.argv[1]; version=sys.argv[2]; prefix=sys.argv[3]
meta={}
# parse trailing json string if present
if len(sys.argv) > 4:
    try:
        meta=json.loads(sys.argv[4])
    except:
        meta={}
key=name+"-"+version
entry={"name":name,"version":version,"prefix":prefix,"installed_at":time.strftime("%Y-%m-%dT%H:%M:%SZ",time.gmtime())}
entry.update(meta)
db[key]=entry
open(dbp,'w',encoding='utf-8').write(json.dumps(db,indent=2,ensure_ascii=False,sort_keys=True))
print("OK")
PY
}

_db_unregister_py() {
  local key="$1"
  python3 - <<PY
import json,sys,os
dbp=os.path.expanduser("$INSTALLED_DB")
try:
    db=json.load(open(dbp,'r',encoding='utf-8'))
except:
    db={}
k=sys.argv[1]
if k in db:
    del db[k]
open(dbp,'w',encoding='utf-8').write(json.dumps(db,indent=2,ensure_ascii=False,sort_keys=True))
print("OK")
PY
}

_db_list_py() {
  python3 - <<PY
import json,sys,os
dbp=os.path.expanduser("$INSTALLED_DB")
try:
    db=json.load(open(dbp,'r',encoding='utf-8'))
except:
    db={}
for k,v in db.items():
    print(k, v.get('version',''), v.get('prefix',''))
PY
}

_db_info_py() {
  local pkg="$1"
  python3 - <<PY
import json,sys,os
dbp=os.path.expanduser("$INSTALLED_DB")
k=sys.argv[1]
try:
    db=json.load(open(dbp,'r',encoding='utf-8'))
except:
    db={}
for key,v in db.items():
    if key==k or key.startswith(k+'-') or v.get('name','')==k:
        print(json.dumps(v,indent=2,ensure_ascii=False))
        sys.exit(0)
print("")
PY
}

_db_get_version_py() {
  local pkg="$1"
  python3 - <<PY
import json,sys,os
p=sys.argv[1]
dbp=os.path.expanduser("$INSTALLED_DB")
try:
    db=json.load(open(dbp,'r',encoding='utf-8'))
except:
    db={}
for k,v in db.items():
    if k==p or k.startswith(p+'-') or v.get('name','')==p:
        print(v.get('version',''))
        sys.exit(0)
print("")
PY
}

_db_is_installed_py() {
  local pkg="$1"
  python3 - <<PY
import json,sys,os
p=sys.argv[1]
dbp=os.path.expanduser("$INSTALLED_DB")
try:
    db=json.load(open(dbp,'r',encoding='utf-8'))
except:
    db={}
ok=False
for k,v in db.items():
    if k==p or k.startswith(p+'-') or v.get('name','')==p:
        ok=True
        break
print("1" if ok else "0")
PY
}

_db_stats_py() {
  python3 - <<PY
import json,sys,os
dbp=os.path.expanduser("$INSTALLED_DB")
try:
    db=json.load(open(dbp,'r',encoding='utf-8'))
except:
    db={}
print("packages:", len(db))
size=0
for k,v in db.items():
    try:
        import os
        p=v.get('prefix')
        if p and os.path.exists(p):
            for root,_,files in os.walk(p):
                for f in files:
                    try:
                        size += os.path.getsize(os.path.join(root,f))
                    except:
                        pass
    except:
        pass
print("approx_installed_bytes:", size)
PY
}

# ------------------ Higher-level functions ------------------
db_register() {
  local name="$1"; local version="$2"; local prefix="${3:-/}"; shift 3 || true
  local meta_raw="${*:-}"

  # validate prefix exists or create if under /var (do not create arbitrary system prefixes)
  if [ -n "$prefix" ] && [ "$prefix" != "/" ]; then
    if [ ! -d "$prefix" ]; then
      log_warn "Prefix '$prefix' does not exist. Attempting to create..."
      if ! mkdir -p "$prefix"; then
        log_error "Cannot create prefix '$prefix'. Aborting registration."
        return 3
      fi
    fi
    if [ ! -w "$prefix" ]; then
      log_warn "Prefix '$prefix' not writable by current user. Registration may be inconsistent."
    fi
  fi

  _db_lock_acquire || return 2
  if _have_jq; then
    # use jq path: read into tmp, update, write atomically
    tmp="$(mktemp "${INSTALLED_DB}.tmp.XXXX")"
    # prepare metadata JSON snippet or empty
    if [ -n "$meta_raw" ]; then meta_json="$meta_raw"; else meta_json="{}"; fi
    python3 - <<PY >"$tmp"
import json,sys,os,time
dbp=sys.argv[1]
name=sys.argv[2]
version=sys.argv[3]
prefix=sys.argv[4]
meta_str=sys.argv[5]
try:
    db=json.load(open(dbp,'r',encoding='utf-8'))
except:
    db={}
try:
    meta=json.loads(meta_str)
except:
    meta={}
key=name+"-"+version
entry={"name":name,"version":version,"prefix":prefix,"installed_at":time.strftime("%Y-%m-%dT%H:%M:%SZ",time.gmtime())}
entry.update(meta)
db[key]=entry
open(dbp,'w',encoding='utf-8').write(json.dumps(db,indent=2,ensure_ascii=False,sort_keys=True))
print("OK")
PY
    mv -f "$tmp" "$INSTALLED_DB"
    _db_lock_release
    log_info "Registered package $name-$version (prefix=$prefix)"
    return 0
  else
    # fallback to python-only writer
    _db_register_py "$name" "$version" "$prefix" "$meta_raw"
    _db_lock_release
    log_info "Registered package $name-$version (prefix=$prefix)"
    return 0
  fi
}

db_unregister() {
  local key_or_name="$1"
  _db_lock_acquire || return 2
  # find keys to remove
  keys_to_remove="$(python3 - <<PY
import json,sys,os
dbp=sys.argv[1]
k=sys.argv[2]
try:
    db=json.load(open(dbp,'r',encoding='utf-8'))
except:
    db={}
res=[]
for key,v in db.items():
    if key==k or key.startswith(k+'-') or v.get('name','')==k:
        res.append(key)
print(json.dumps(res))
PY
"$INSTALLED_DB" "$key_or_name")"

  if [ -z "$keys_to_remove" ] || [ "$keys_to_remove" = "[]" ]; then
    _db_lock_release
    log_warn "No matching package entry found for $key_or_name"
    return 1
  fi

  # remove entries
  python3 - <<PY
import json,sys,os
dbp=sys.argv[1]
keys=json.loads(sys.argv[2])
try:
    db=json.load(open(dbp,'r',encoding='utf-8'))
except:
    db={}
for k in keys:
    if k in db:
        del db[k]
open(dbp,'w',encoding='utf-8').write(json.dumps(db,indent=2,ensure_ascii=False,sort_keys=True))
print("OK")
PY
  _db_lock_release
  log_info "Unregistered ${key_or_name} -> removed keys: ${keys_to_remove}"
  # trigger resolve if configured and allowed
  if [ -x "$RESOLVE_MODULE" ] && [ "${AUTO_REVDEP_REBUILD}" = true ]; then
    log_info "Triggering resolver to fix reverse-deps (via $RESOLVE_MODULE)"
    # best-effort, non-blocking
    "$RESOLVE_MODULE" --scan --fix >/dev/null 2>&1 || log_warn "Resolver returned non-zero"
  fi
  return 0
}

db_list() {
  _db_list_py
}

db_info() {
  local pkg="$1"
  _db_info_py "$pkg"
}

db_get_version() {
  local pkg="$1"
  _db_get_version_py "$pkg"
}

db_is_installed() {
  local pkg="$1"
  _db_is_installed_py "$pkg"
}

db_backup() {
  local dest_dir="${1:-$DB_BACKUP_DIR}"
  mkdir -p "$dest_dir"
  local ts; ts=$(date -u +%Y%m%dT%H%M%SZ)
  local out="${dest_dir}/installed.json.backup.${ts}"
  cp -a "$INSTALLED_DB" "$out"
  log_info "DB backup saved to $out"
  echo "$out"
}

db_restore() {
  local src="$1"
  if [ ! -f "$src" ]; then log_error "Backup file not found: $src"; return 2; fi
  _db_lock_acquire || return 2
  cp -a "$src" "$INSTALLED_DB"
  _db_lock_release
  log_info "DB restored from $src"
}

db_stats() {
  _db_stats_py
}

db_clean_logs() {
  local days="${1:-30}"
  find "$LOG_DIR" -type f -name "*.log" -mtime +"$days" -print -exec rm -f {} \; || true
  log_info "Cleaned logs older than ${days} days in $LOG_DIR"
}

# ------------------ CLI dispatch ------------------
cmd="${1:-help}"; shift || true
case "$cmd" in
  register)
    # usage: register <name> <version> <prefix> [meta-json]
    name="${1:-}"; version="${2:-}"; prefix="${3:-/}"; meta="${4:-}"
    if [ -z "$name" ] || [ -z "$version" ]; then
      echo "Usage: $0 register <name> <version> <prefix> [meta-json]" >&2; exit 2
    fi
    db_register "$name" "$version" "$prefix" "$meta"
    ;;
  unregister)
    # usage: unregister <name|name-version|key>
    key="${1:-}"; [ -n "$key" ] || { echo "Usage: $0 unregister <name|name-version|key>" >&2; exit 2; }
    db_unregister "$key"
    ;;
  list)
    db_list
    ;;
  info)
    arg="${1:-}"; [ -n "$arg" ] || { echo "Usage: $0 info <pkg>" >&2; exit 2; }
    db_info "$arg"
    ;;
  get-version)
    arg="${1:-}"; [ -n "$arg" ] || { echo "Usage: $0 get-version <pkg>" >&2; exit 2; }
    db_get_version "$arg"
    ;;
  is-installed)
    arg="${1:-}"; [ -n "$arg" ] || { echo "Usage: $0 is-installed <pkg>" >&2; exit 2; }
    db_is_installed "$arg"
    ;;
  backup)
    db_backup "$1"
    ;;
  restore)
    [ -n "${1:-}" ] || { echo "Usage: $0 restore <backup-file>" >&2; exit 2; }
    db_restore "$1"
    ;;
  stats)
    db_stats
    ;;
  clean-logs)
    db_clean_logs "${1:-30}"
    ;;
  help|*)
    cat <<EOF
porg_db.sh - DB helper for Porg
Usage:
  $0 register <name> <version> <prefix> [meta-json]
  $0 unregister <name|name-version|key>
  $0 list
  $0 info <pkg>
  $0 get-version <pkg>
  $0 is-installed <pkg>
  $0 backup [dest-dir]
  $0 restore <backup-file>
  $0 stats
  $0 clean-logs [days]
EOF
    exit 0
    ;;
esac
