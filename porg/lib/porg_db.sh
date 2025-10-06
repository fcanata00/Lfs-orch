#!/usr/bin/env bash
#
# porg_db.sh
# Banco de dados simples para Porg (installed DB + utilitários)
# Integra com porg_logger.sh e deps.py
#
# Coloque em /usr/lib/porg/porg_db.sh ou /usr/local/bin/porg_db.sh
# chmod +x porg_db.sh
#
set -euo pipefail
IFS=$'\n\t'

# -------------------- Config defaults (sobrescritos por /etc/porg/porg.conf) --------------------
PORG_CONF="${PORG_CONF:-/etc/porg/porg.conf}"
DB_DIR="${DB_DIR:-/var/db/porg}"
INSTALLED_DB="${INSTALLED_DB:-${DB_DIR}/installed.json}"
LOG_DIR="${LOG_DIR:-/var/log/porg}"
CACHE_DIR="${CACHE_DIR:-/var/cache/porg}"
LOGGER_SCRIPT="${LOGGER_SCRIPT:-/usr/lib/porg/porg_logger.sh}"
DEPS_PY="${DEPS_PY:-/usr/lib/porg/deps.py}"
ROTATE_LOGS="${ROTATE_LOGS:-true}"

# Make sure dirs exist
mkdir -p "$DB_DIR" "$LOG_DIR" "$CACHE_DIR"

# Try to source logger if available, otherwise provide minimal log()
if [ -f "$LOGGER_SCRIPT" ]; then
  # shellcheck disable=SC1090
  source "$LOGGER_SCRIPT"
else
  log_init() { :; }
  log() { local level="$1"; shift; printf '[%s] %s\n' "$level" "$*"; }
  log_section() { printf '=== %s ===\n' "$*"; }
  log_perf() { "$@"; }
fi

# Load porg.conf KEY=VALUE style
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
  # ensure variables from conf take effect
  mkdir -p "${DB_DIR}" "${LOG_DIR}" "${CACHE_DIR}"
}

_load_porg_conf

# -------------------- Helpers JSON (use jq if present, else python) --------------------
HAS_JQ=false
if command -v jq >/dev/null 2>&1; then HAS_JQ=true; fi

# ensure installed DB exists and is a JSON object
_db_ensure() {
  if [ ! -f "$INSTALLED_DB" ]; then
    echo "{}" > "$INSTALLED_DB"
    chmod 0644 "$INSTALLED_DB" || true
  fi
}

# read entire DB (pretty printed)
db_read_pretty() {
  _db_ensure
  if $HAS_JQ; then
    jq -S . "$INSTALLED_DB"
  else
    python3 - <<PY
import json,sys
p=sys.argv[1]
with open(p,'r',encoding='utf-8') as f:
    obj=json.load(f)
print(json.dumps(obj,ensure_ascii=False,indent=2,sort_keys=True))
PY
  fi
}

# write DB atomically with given JSON string (from stdin)
_db_write_stdin() {
  tmp="$(mktemp "${DB_DIR}/installed.json.XXXXXX")"
  cat - > "$tmp"
  # validate JSON
  if ! python3 -c "import json,sys; json.load(open('$tmp','r',encoding='utf-8'))" >/dev/null 2>&1; then
    rm -f "$tmp"
    log "ERROR" "Invalid JSON supplied to DB write"
    return 1
  fi
  mv "$tmp" "$INSTALLED_DB"
  chmod 0644 "$INSTALLED_DB" || true
  return 0
}

# update DB using python to avoid jq dependency when not present
_db_set_pkg() {
  # args: pkgid json_fragment (as JSON string)
  local pkgid="$1"; shift
  local content="$*"
  _db_ensure
  if $HAS_JQ; then
    # merge/assign
    tmp="$(mktemp "${DB_DIR}/tmp.XXXXXX")"
    echo '{}' > "$tmp"
    # build JSON file with key
    printf '%s\n' "$content" | jq --arg k "$pkgid" '. as $v | {($k): $v}' > "${tmp}.val"
    jq -s '.[0] * .[1]' "$INSTALLED_DB" "${tmp}.val" > "${tmp}.out"
    mv "${tmp}.out" "$INSTALLED_DB"
    rm -f "${tmp}.val" || true
  else
    python3 - <<PY
import json,sys,os
dbp=sys.argv[1]
pkg=sys.argv[2]
# content comes from stdin
content=sys.stdin.read()
try:
    val=json.loads(content)
except Exception as e:
    print("ERROR: invalid json",file=sys.stderr); sys.exit(2)
if os.path.exists(dbp):
    with open(dbp,'r',encoding='utf-8') as f:
        try:
            db=json.load(f)
        except:
            db={}
else:
    db={}
db[pkg]=val
with open(dbp,'w',encoding='utf-8') as f:
    json.dump(db,f,indent=2,ensure_ascii=False,sort_keys=True)
PY
  fi
  return 0
}

_db_delete_pkg() {
  local pkgid="$1"
  _db_ensure
  if $HAS_JQ; then
    jq "del(.\"${pkgid}\")" "$INSTALLED_DB" > "${INSTALLED_DB}.tmp" && mv "${INSTALLED_DB}.tmp" "$INSTALLED_DB"
  else
    python3 - <<PY
import json,sys
dbp=sys.argv[1]; pkg=sys.argv[2]
try:
    with open(dbp,'r',encoding='utf-8') as f:
        db=json.load(f)
except:
    db={}
if pkg in db:
    del db[pkg]
with open(dbp,'w',encoding='utf-8') as f:
    json.dump(db,f,indent=2,ensure_ascii=False,sort_keys=True)
PY
  fi
}

_db_get_pkg() {
  local pkgid="$1"
  _db_ensure
  if $HAS_JQ; then
    jq -r ".\"${pkgid}\" // empty" "$INSTALLED_DB"
  else
    python3 - <<PY
import json,sys
dbp=sys.argv[1]; pkg=sys.argv[2]
try:
    with open(dbp,'r',encoding='utf-8') as f:
        db=json.load(f)
except:
    db={}
val=db.get(pkg)
if val is None:
    sys.exit(1)
print(json.dumps(val,ensure_ascii=False,indent=2,sort_keys=True))
PY
  fi
}

# -------------------- DB operations --------------------
db_init() {
  _load_porg_conf
  mkdir -p "$DB_DIR" "$LOG_DIR" "$CACHE_DIR"
  _db_ensure
  log "INFO" "DB initialized at $INSTALLED_DB"
}

# db_register <pkgname> <version> <prefix> [deps-json]
# pkgid will be "<pkgname>-<version>" if version provided; else accept single pkgid
db_register() {
  if [ $# -lt 3 ]; then
    log "ERROR" "Usage: db_register <pkgname|pkgid> <version> <prefix> [deps-json]"
    return 2
  fi
  local name="$1"; local version="$2"; local prefix="$3"; shift 3
  local deps_json="${1:-[]}" # optional JSON array of deps
  local pkgid
  if [[ "$name" =~ -[0-9] ]]; then pkgid="$name"; else pkgid="${name}-${version}"; fi

  # call deps.py to check what deps are expected (best-effort)
  if [ -x "$DEPS_PY" ]; then
    # attempt to get resolved dependencies via deps.py resolve <name>
    if python3 "$DEPS_PY" resolve "$name" >/dev/null 2>&1; then
      resolved_json="$(python3 "$DEPS_PY" resolve "$name" 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin).get('order',[]))")" || resolved_json="[]"
    else
      resolved_json="[]"
    fi
  else
    resolved_json="[]"
  fi

  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  # build JSON fragment
  cat > /tmp/porg_db_register.json <<EOF
{
  "name": "$(printf '%s' "$name")",
  "version": "$(printf '%s' "$version")",
  "prefix": "$(printf '%s' "$prefix")",
  "installed_at": "$ts",
  "deps": $resolved_json
}
EOF
  # set into DB
  _db_set_pkg "$pkgid" "$(cat /tmp/porg_db_register.json)"
  rm -f /tmp/porg_db_register.json
  log "INFO" "Registered package $pkgid at $prefix"
  return 0
}

db_unregister() {
  if [ $# -lt 1 ]; then log "ERROR" "Usage: db_unregister <pkgid|pkgname>"; return 2; fi
  local q="$1"
  _db_ensure
  # try exact key, else try keys that start with name-
  if grep -q "\"${q}\"" "$INSTALLED_DB" 2>/dev/null; then
    _db_delete_pkg "$q"
    log "INFO" "Unregistered $q"
    return 0
  fi
  # attempt prefix match
  keys="$(python3 - <<PY
import json,sys
p=sys.argv[1]
try:
    db=json.load(open(p,'r',encoding='utf-8'))
except:
    db={}
for k in db.keys():
    if k.startswith(sys.argv[2]+'-') or k==sys.argv[2]:
        print(k)
PY
"$INSTALLED_DB" "$q")"
  if [ -n "$keys" ]; then
    while IFS= read -r k; do
      _db_delete_pkg "$k"
      log "INFO" "Unregistered $k (matched $q)"
    done <<< "$keys"
    return 0
  fi
  log "WARN" "Package not found in DB: $q"
  return 1
}

db_list() {
  _db_ensure
  if $HAS_JQ; then
    jq -r 'to_entries[] | "\(.key) \(.value.version) \(.value.prefix) \(.value.installed_at)"' "$INSTALLED_DB" || true
  else
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
  fi
}

db_info() {
  if [ $# -lt 1 ]; then log "ERROR" "Usage: db_info <pkgid>"; return 2; fi
  local pkgid="$1"
  _db_ensure
  if $HAS_JQ; then
    jq -r ".\"${pkgid}\" // \"NOTFOUND\"" "$INSTALLED_DB"
  else
    _db_get_pkg "$pkgid" || { log "WARN" "Package $pkgid not found"; return 1; }
  fi
}

db_is_installed() {
  if [ $# -lt 1 ]; then log "ERROR" "Usage: db_is_installed <pkg|pkgid>"; return 2; fi
  local q="$1"
  _db_ensure
  python3 - <<PY
import json,sys
p=sys.argv[1]; q=sys.argv[2]
try:
    db=json.load(open(p,'r',encoding='utf-8'))
except:
    db={}
ok=False
for k in db.keys():
    if k==q or k.startswith(q+'-') or k.split('-')[0]==q:
        ok=True; break
print(0 if ok else 1)
PY
}

# db_backup <dest-tar.gz>
db_backup() {
  local dest="${1:-}"
  [ -n "$dest" ] || { log "ERROR" "Usage: db_backup <dest-tar.gz>"; return 2; }
  tar czf "$dest" -C / "${INSTALLED_DB#/}" || { log "ERROR" "Backup failed"; return 1; }
  log "INFO" "Backup created: $dest"
}

# db_restore <src-tar.gz>
db_restore() {
  local src="$1"
  [ -f "$src" ] || { log "ERROR" "Backup not found: $src"; return 2; }
  tar xzf "$src" -C / || { log "ERROR" "Restore failed"; return 1; }
  log "INFO" "Restore completed from $src"
}

# db_clean_logs <days>
db_clean_logs() {
  local days="${1:-30}"
  if [ ! -d "$LOG_DIR" ]; then log "WARN" "Log dir not found: $LOG_DIR"; return 1; fi
  find "$LOG_DIR" -type f -mtime +"$days" -print0 | xargs -0r rm -f --
  log "INFO" "Old logs (>${days}d) removed from $LOG_DIR"
}

# db_stats
db_stats() {
  _db_ensure
  log "INFO" "Computing DB statistics..."
  total_pkgs="$(python3 - <<PY
import json,sys,os
p=sys.argv[1]
try:
    db=json.load(open(p,'r',encoding='utf-8'))
except:
    db={}
print(len(db))
PY
"$INSTALLED_DB")"
  total_size="$(python3 - <<PY
import json,sys,subprocess
p=sys.argv[1]
try:
    db=json.load(open(p,'r',encoding='utf-8'))
except:
    db={}
sizes=[]
import os
for k,v in db.items():
    prefix=v.get('prefix')
    if prefix and os.path.exists(prefix):
        try:
            s=int(subprocess.check_output(['du','-sb',prefix]).split()[0])
        except:
            s=0
    else:
        s=0
    sizes.append(s)
print(sum(sizes))
PY
"$INSTALLED_DB")"
  # convert bytes to human
  human_size="$(numfmt --to=iec --suffix=B "$total_size" 2>/dev/null || echo "${total_size}B")"
  log "INFO" "Installed packages: $total_pkgs; total size: $human_size"
  # other stats: packages per day? not tracked; print sample
  echo "packages:$total_pkgs total_size:$human_size"
}

# db_purge_removed: remove DB entries whose 'prefix' no longer exists
db_purge_removed() {
  _db_ensure
  python3 - <<PY
import json,os,sys
p=sys.argv[1]
try:
    db=json.load(open(p,'r',encoding='utf-8'))
except:
    db={}
removed=[]
for k,v in list(db.items()):
    prefix=v.get('prefix')
    if not prefix or not os.path.exists(prefix):
        removed.append(k)
        del db[k]
if removed:
    with open(p,'w',encoding='utf-8') as f:
        json.dump(db,f,indent=2,ensure_ascii=False,sort_keys=True)
print("REMOVED:"+",".join(removed))
PY
  ret=$?
  if [ "$ret" -ne 0 ]; then log "WARN" "db_purge_removed had issues"; else log "INFO" "db_purge_removed complete"; fi
}

# db_export <out.json|out.csv>
db_export() {
  local out="${1:-}"
  [ -n "$out" ] || { log "ERROR" "Usage: db_export <out.json|out.csv>"; return 2; }
  _db_ensure
  if [[ "$out" =~ \.json$ ]]; then
    cp -f "$INSTALLED_DB" "$out"
    log "INFO" "DB exported to $out"
    return 0
  fi
  # CSV export
  python3 - <<PY
import json,sys,csv
p=sys.argv[1]; out=sys.argv[2]
try:
    db=json.load(open(p,'r',encoding='utf-8'))
except:
    db={}
with open(out,'w',newline='',encoding='utf-8') as f:
    w=csv.writer(f)
    w.writerow(['pkgid','name','version','prefix','installed_at','deps'])
    for k,v in db.items():
        w.writerow([k, v.get('name',''), v.get('version',''), v.get('prefix',''), v.get('installed_at',''), ';'.join(v.get('deps',[]))])
PY
  "$INSTALLED_DB" "$out"
  log "INFO" "DB exported to $out (CSV)"
}

# db_import <file.json|file.csv>
db_import() {
  local in="$1"
  [ -f "$in" ] || { log "ERROR" "Import file not found: $in"; return 2; }
  if [[ "$in" =~ \.json$ ]]; then
    # merge JSON keys
    python3 - <<PY
import json,sys,os
dbp=sys.argv[1]; inp=sys.argv[2]
try:
    base=json.load(open(dbp,'r',encoding='utf-8'))
except:
    base={}
try:
    add=json.load(open(inp,'r',encoding='utf-8'))
except:
    print("ERROR reading input"); sys.exit(2)
base.update(add)
with open(dbp,'w',encoding='utf-8') as f:
    json.dump(base,f,indent=2,ensure_ascii=False,sort_keys=True)
print("OK")
PY
    "$INSTALLED_DB" "$in"
    log "INFO" "Imported JSON into DB: $in"
    return 0
  fi
  if [[ "$in" =~ \.csv$ ]]; then
    python3 - <<PY
import csv,json,sys
dbp=sys.argv[1]; inp=sys.argv[2]
try:
    db=json.load(open(dbp,'r',encoding='utf-8'))
except:
    db={}
with open(inp,'r',encoding='utf-8') as f:
    r=csv.DictReader(f)
    for row in r:
        pkgid=row.get('pkgid') or (row.get('name')+'-'+row.get('version'))
        db[pkgid]={
            'name':row.get('name',''),
            'version':row.get('version',''),
            'prefix':row.get('prefix',''),
            'installed_at':row.get('installed_at',''),
            'deps': row.get('deps','').split(';') if row.get('deps') else []
        }
with open(dbp,'w',encoding='utf-8') as f:
    json.dump(db,f,indent=2,ensure_ascii=False,sort_keys=True)
print("OK")
PY
    "$INSTALLED_DB" "$in"
    log "INFO" "Imported CSV into DB: $in"
    return 0
  fi
  log "ERROR" "Unsupported import format: $in"
  return 2
}

# db_verify: consistency check (verify prefixes exist and expected files present)
db_verify() {
  _db_ensure
  python3 - <<PY
import json,sys,os
p=sys.argv[1]
try:
    db=json.load(open(p,'r',encoding='utf-8'))
except:
    db={}
errors=[]
for k,v in db.items():
    prefix=v.get('prefix')
    if not prefix:
        errors.append((k,"no-prefix"))
        continue
    if not os.path.exists(prefix):
        errors.append((k,"prefix-missing"))
        continue
    # simple check: prefix/bin or prefix/usr/bin should exist
    if not (os.path.exists(os.path.join(prefix,'bin')) or os.path.exists(os.path.join(prefix,'usr','bin'))):
        errors.append((k,"no-binaries"))
if errors:
    for e in errors:
        print("ERR",e[0],e[1])
    sys.exit(2)
print("OK")
PY
  ret=$?
  if [ "$ret" -eq 0 ]; then log "INFO" "DB verify: OK"; else log "WARN" "DB verify: issues found"; fi
  return $ret
}

# -------------------- CLI dispatch --------------------
usage() {
  cat <<EOF
Usage: ${0##*/} <command> [args]
Commands:
  init                           Initialize DB paths
  register <name> <ver> <prefix> [deps-json]   Register package (name/vers/prefix)
  unregister <pkgid|name>        Unregister package
  list                           List installed packages
  info <pkgid>                   Show package info
  is-installed <pkg|pkgid>       Exit 0 if installed, 1 otherwise
  backup <dest-tar.gz>           Create tar.gz backup of DB
  restore <src-tar.gz>           Restore DB from backup
  clean-logs [days]              Remove logs older than days (default 30)
  stats                          Print DB stats
  purge-removed                  Remove DB entries whose prefix no longer exists
  export <out.json|out.csv>      Export DB
  import <in.json|in.csv>        Import DB (merge)
  verify                         Verify consistency (prefixes/files)
  help
EOF
}

case "${1:-}" in
  init) db_init ;;
  register) shift; db_register "$@" ;;
  unregister) shift; db_unregister "$@" ;;
  list) db_list ;;
  info) shift; db_info "$@" ;;
  is-installed) shift; db_is_installed "$@" ;;
  backup) shift; db_backup "$@" ;;
  restore) shift; db_restore "$@" ;;
  clean-logs) shift; db_clean_logs "$@" ;;
  stats) db_stats ;;
  purge-removed) db_purge_removed ;;
  export) shift; db_export "$@" ;;
  import) shift; db_import "$@" ;;
  verify) db_verify ;;
  help|--help|-h|*) usage ;;
esac

exit 0
