#!/usr/bin/env bash
#
# porg-upgrade.sh
# Orquestrador de upgrade para Porg
# Integra com porg_logger.sh, porg_db.sh, porg_builder.sh, deps.py, porg-resolve, porg_remove.sh
#
# Principais opções:
#   --pkg <pkg>    Atualiza apenas <pkg>
#   --world        Atualiza todo o sistema (padrão)
#   --check        Apenas verifica atualizações disponíveis
#   --sync         Atualiza metafiles via git (no PORTS_DIR)
#   --dry-run      Não altera nada, só mostra o que faria
#   --quiet        Saída mínima
#   --yes          Auto confirmar
#   --revdep       Roda porg-resolve --scan --fix depois
#   --clean        Roda porg-resolve --clean depois
#   --log-rotate   Roda rotação/limpeza de logs via porg_logger
#   --resume       Retoma um upgrade interrompido
#
set -euo pipefail
IFS=$'\n\t'

# -------------------- Defaults and paths (override via environment / porg.conf) --------------------
PORG_CONF="${PORG_CONF:-/etc/porg/porg.conf}"
PORTS_DIR="${PORTS_DIR:-/usr/ports}"
WORKDIR="${WORKDIR:-/var/tmp/porg/upgrade}"
LOG_DIR="${LOG_DIR:-/var/log/porg/upgrade}"
REPORT_DIR="${REPORT_DIR:-$LOG_DIR}"
DB_SCRIPT="${DB_SCRIPT:-/usr/lib/porg/porg_db.sh}"
LOGGER_SCRIPT="${LOGGER_SCRIPT:-/usr/lib/porg/porg_logger.sh}"
BUILDER_SCRIPT="${BUILDER_SCRIPT:-/usr/lib/porg/porg_builder.sh}"
BUILDER_CMD="${BUILDER_CMD:-porg}"   # prefer wrapper 'porg' if present
DEPS_PY="${DEPS_PY:-/usr/lib/porg/deps.py}"
REMOVE_SCRIPT="${REMOVE_SCRIPT:-/usr/lib/porg/porg_remove.sh}"
RESOLVE_CMD="${RESOLVE_CMD:-/usr/lib/porg/porg-resolve}"  # porg-resolve
STATE_FILE="${WORKDIR}/upgrade-state.json"
REPORT_FILE=""
KEEP_LOGS_DAYS="${KEEP_LOGS_DAYS:-30}"

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

# ensure dirs
mkdir -p "$WORKDIR" "$LOG_DIR" "$REPORT_DIR"
# temp files
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
  log_progress() { :; }
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
  --sync          Git pull to update metafiles in $PORTS_DIR
  --dry-run       Show what would be done
  --quiet         Minimal stdout (logs still recorded)
  --yes           Auto confirm prompts
  --revdep        Run porg-resolve --scan --fix after upgrades
  --clean         Run porg-resolve --clean after upgrades
  --log-rotate    Request logger to rotate/clean logs
  --resume        Resume previously interrupted upgrade
  -h|--help       Show this help
EOF
}

# parse CLI
if [ "$#" -eq 0 ]; then
  # default to world upgrade
  DO_CHECK=false
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
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1"; usage; exit 2 ;;
  esac
done

# wrapper for log respecting --quiet
_logger() {
  local level="$1"; shift
  if [ "$QUIET" = true ] && [ "$level" != "ERROR" ]; then
    # still call log so logger handles session file; logger may suppress stdout if configured
    log "$level" "$@"
  else
    log "$level" "$@"
  fi
}

# small JSON write/read helpers using python
json_write() {
  python3 - "$1" > "$2" <<'PY'
import sys,json
data=sys.stdin.read()
obj=json.loads(data)
open(sys.argv[1],'w',encoding='utf-8').write(json.dumps(obj,indent=2,ensure_ascii=False))
PY
}

json_read_field() {
  # json_read_field <file> <jq-path-like> (simple)
  python3 - "$1" "$2" - <<'PY'
import json,sys
f=sys.argv[1]; p=sys.argv[2]
try:
    obj=json.load(open(f,'r',encoding='utf-8'))
except:
    sys.exit(1)
# support top-level keys only (simple)
print(obj.get(p,""))
PY
}

# confirm helper
confirm() {
  if [ "$AUTO_YES" = true ]; then return 0; fi
  printf "%s [y/N]: " "$1" >&2
  read -r ans || return 1
  case "$ans" in y|Y|yes|Yes) return 0 ;; *) return 1 ;; esac
}

# state management for resume
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

# find metafile for a package under PORTS_DIR (search subpastas)
find_metafile() {
  local pkg="$1"
  # prefer directory /usr/ports/*/pkg/*
  if [ -d "$PORTS_DIR" ]; then
    for d in "$PORTS_DIR"/*/"$pkg"; do
      [ -d "$d" ] || continue
      mf=$(ls -1 "$d"/*.{yml,yaml} 2>/dev/null | head -n1 || true)
      if [ -n "$mf" ]; then echo "$mf"; return 0; fi
    done
    # fallback to any matching file
    mf=$(find "$PORTS_DIR" -type f -iname "${pkg}*.y*ml" -print -quit 2>/dev/null || true)
    [ -n "$mf" ] && { echo "$mf"; return 0; }
  fi
  return 1
}

# determine installed version from DB for a pkg
installed_version() {
  local pkg="$1"
  if declare -f db_list >/dev/null 2>&1 && declare -f db_info >/dev/null 2>&1; then
    # list entries and pick matching
    python3 - "$pkg" <<PY
import json,sys
p=sys.argv[1]
dbp="/var/db/porg/installed.json"
try:
    db=json.load(open(dbp,'r',encoding='utf-8'))
except:
    print("")
    sys.exit(0)
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

# parse metafile to get version
metafile_version() {
  local mf="$1"
  if [ -z "$mf" ] || [ ! -f "$mf" ]; then echo ""; return 0; fi
  python3 - "$mf" <<'PY'
import yaml,sys,json
p=sys.argv[1]
try:
    import yaml
    d=yaml.safe_load(open(p,'r',encoding='utf-8')) or {}
    v=d.get('version') or d.get('ver') or d.get('pkg_version') or ""
    if isinstance(v, (list,dict)):
        v=str(v)
    print(v)
except Exception:
    # fallback simple grep
    import re
    for line in open(p,'r',encoding='utf-8'):
        m=re.match(r'^\s*version\s*:\s*(.+)$',line)
        if m:
            print(m.group(1).strip().strip('"').strip("'")); sys.exit(0)
    print("")
PY
}

# sync repo: git pull in PORTS_DIR root (only update metafiles)
do_sync() {
  if [ "$DO_SYNC" = false ]; then return 0; fi
  if [ "$DRY_RUN" = true ]; then
    _logger INFO "[dry-run] Would git pull in $PORTS_DIR to update metafiles"
    return 0
  fi
  if [ ! -d "$PORTS_DIR/.git" ]; then
    _logger WARN "PORTS_DIR $PORTS_DIR is not a git repository; skipping --sync"
    return 0
  fi
  _logger STAGE "Sincronizando metafiles (git pull) em $PORTS_DIR"
  (cd "$PORTS_DIR" && git fetch --all --tags --prune && git pull) || _logger WARN "git pull retornou não-zero"
}

# build package using builder; returns package file path or empty on failure
build_package() {
  local mf="$1"
  local pkgid="$2"
  _logger INFO "Iniciando build para $pkgid a partir de $mf"
  if [ "$DRY_RUN" = true ]; then
    _logger INFO "[dry-run] Would call builder for $mf"
    echo "DRY_RUN_PKG:$pkgid"
    return 0
  fi
  # prefer porg wrapper if exists
  if command -v porg >/dev/null 2>&1; then
    # invocation: porg build <metafile>  OR porg -i <pkg> ??? assume builder script strategy
    if porg build "$mf"; then
      # porg wrapper / builder must echo package path or write to WORKDIR; attempt to find package created recently
      # find newest package in /var/cache/porg/packages or WORKDIR
      pkgpath=$(find /var/cache/porg -type f -name "${pkgid}*.tar.*" -o -name "${pkgid}*.tar" 2>/dev/null | sort -r | head -n1 || true)
      echo "$pkgpath"
      return 0
    else
      return 1
    fi
  fi

  # fallback to builder script
  if [ -x "$BUILDER_SCRIPT" ]; then
    if pkgpath="$("$BUILDER_SCRIPT" build "$mf" 2>&1 | tee "$TMP" | tail -n1)"; then
      # builder usually echoes package path as last line; try to validate
      if [ -n "$pkgpath" ] && [ -f "$pkgpath" ]; then
        echo "$pkgpath"
        return 0
      else
        # try to find package in cache
        pkgpath=$(find /var/cache/porg -type f -iname "$(basename "$pkgid")*.tar.*" -print -quit 2>/dev/null || true)
        echo "$pkgpath"
        return 0
      fi
    else
      return 1
    fi
  fi

  _logger ERROR "Nenhum builder disponível (porg ou $BUILDER_SCRIPT) para construir $pkgid"
  return 1
}

# expand package into /
expand_package_to_root() {
  local pkgfile="$1"
  if [ "$DRY_RUN" = true ]; then
    _logger INFO "[dry-run] Would expand package $pkgfile into /"
    return 0
  fi
  if [ -x "$BUILDER_SCRIPT" ]; then
    _logger INFO "Expandindo pacote $pkgfile em / via $BUILDER_SCRIPT expand-root"
    "$BUILDER_SCRIPT" expand-root "$pkgfile"
    return $?
  fi
  # fallback: use tar to extract
  _logger INFO "Expandindo pacote $pkgfile em / (tar fallback)"
  case "$pkgfile" in
    *.zst) zstd -d "$pkgfile" -c | tar -xf - -C / ;;
    *.xz) xz -d "$pkgfile" -c | tar -xf - -C / ;;
    *.tar) tar -xf "$pkgfile" -C / ;;
    *) _logger ERROR "Formato de pacote não reconhecido: $pkgfile"; return 2 ;;
  esac
  return 0
}

# remove old package using remove script
remove_old_package() {
  local pkgid="$1"
  _logger INFO "Removendo versão antiga $pkgid"
  if [ "$DRY_RUN" = true ]; then
    _logger INFO "[dry-run] Would call $REMOVE_SCRIPT $pkgid --yes --force"
    return 0
  fi
  if [ -x "$REMOVE_SCRIPT" ]; then
    "$REMOVE_SCRIPT" "$pkgid" --yes --force || {
      _logger WARN "remove script retornou não-zero para $pkgid"
    }
  else
    # fallback: call db_unregister to remove DB entry but not files
    if declare -f db_unregister >/dev/null 2>&1; then
      db_unregister "$pkgid" || _logger WARN "db_unregister falhou para $pkgid"
    else
      _logger WARN "Nenhum remove script disponível; DB não atualizado"
    fi
  fi
  return 0
}

# update DB after successful install
update_db_after_upgrade() {
  local name="$1" version="$2" prefix="$3"
  if [ "$DRY_RUN" = true ]; then
    _logger INFO "[dry-run] DB would be updated: $name $version $prefix"
    return 0
  fi
  if declare -f db_register >/dev/null 2>&1; then
    db_register "$name" "$version" "$prefix" || _logger WARN "db_register falhou para $name"
  else
    # fallback: write JSON entry
    python3 - "$name" "$version" "$prefix" <<PY
import json,sys,os,time
dbp="/var/db/porg/installed.json"
try:
    db=json.load(open(dbp,'r',encoding='utf-8'))
except:
    db={}
pkgid=sys.argv[1]+"-"+sys.argv[2]
db[pkgid]={"name":sys.argv[1],"version":sys.argv[2],"prefix":sys.argv[3],"installed_at":time.strftime("%Y-%m-%dT%H:%M:%SZ",time.gmtime())}
with open(dbp,'w',encoding='utf-8') as f:
    json.dump(db,f,indent=2,ensure_ascii=False,sort_keys=True)
print("OK")
PY
  fi
}

# compare version strings (simple lexicographic fallback)
version_newer() {
  local a="$1" b="$2"
  # if equal or empty
  [ -z "$a" ] && return 0
  [ -z "$b" ] && return 1
  # try to compare by splitting numbers
  if python3 - <<PY >/dev/null 2>&1
import sys
a=sys.argv[1]; b=sys.argv[2]
def norm(x):
    return tuple(int(p) if p.isdigit() else p for p in x.replace('-', '.').split('.'))
try:
    sys.exit(0 if norm(a) >= norm(b) else 2)
except:
    sys.exit(0 if a>=b else 2)
PY
  "$a" "$b"; then
    # a >= b => NOT newer
    return 1
  else
    return 0
  fi
}

# build pipeline for a single package: find metafile -> build -> if success remove old -> expand -> update db
upgrade_one_pkg() {
  local pkg="$1"
  local mf
  mf="$(find_metafile "$pkg" || true)"
  if [ -z "$mf" ]; then
    _logger WARN "Metafile não encontrado para $pkg em $PORTS_DIR/subpastas"
    return 1
  fi
  local new_ver
  new_ver="$(metafile_version "$mf" | tr -d '[:space:]')"
  if [ -z "$new_ver" ]; then
    _logger WARN "Versão não encontrada no metafile $mf; pulando"
    return 1
  fi
  local inst_ver
  inst_ver="$(installed_version "$pkg" | tr -d '[:space:]')"
  if [ -n "$inst_ver" ]; then
    if version_newer "$new_ver" "$inst_ver"; then
      _logger INFO "Nova versão detectada para $pkg: $inst_ver -> $new_ver"
    else
      _logger INFO "Sem atualização para $pkg (instalado: $inst_ver, metafile: $new_ver)"
      return 0
    fi
  else
    _logger INFO "Package $pkg não instalado (will install) -> version $new_ver"
  fi

  # resolve deps before build
  if [ -x "$DEPS_PY" ]; then
    _logger INFO "Chamando deps.py resolve para $pkg"
    if ! python3 "$DEPS_PY" resolve "$pkg" >/dev/null 2>&1; then
      _logger WARN "deps.py detectou problema ao resolver dependências de $pkg"
      # still proceed if user wants, but advise
    fi
  fi

  # build new package
  pkgid="${pkg}-${new_ver}"
  _logger STAGE "Construindo pacote novo: $pkgid"
  pkgfile="$(build_package "$mf" "$pkgid" 2>&1 || true)"
  if [ -z "$pkgfile" ] || [[ "$pkgfile" =~ ^FAILED|^$ ]]; then
    _logger ERROR "Build falhou para $pkg ($mf). Estado salvo para resume."
    # save state and exit so user can fix and resume
    state=$(cat <<JSON
{
  "target":"$pkg",
  "metafile":"$mf",
  "new_version":"$new_ver",
  "installed_version":"$inst_ver",
  "timestamp":"$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
JSON
)
    save_state "$state"
    return 2
  fi

  _logger INFO "Build bem-sucedido, pacote: $pkgfile"

  # run pre-upgrade hooks if any (hooks are in package hooks directory)
  if run_hooks_pre_post=""; then :; fi
  # attempt to remove old package
  if [ -n "$inst_ver" ]; then
    old_pkgid="${pkg}-${inst_ver}"
    _logger INFO "Removendo versão antiga $old_pkgid (apenas após build bem-sucedido)"
    remove_old_package "$old_pkgid"
  fi

  # expand/install new package
  _logger INFO "Instalando novo pacote $pkgid a partir de $pkgfile"
  if ! expand_package_to_root "$pkgfile"; then
    _logger ERROR "Falha ao instalar $pkgid (expansão). Estado salvo para resume."
    state=$(cat <<JSON
{
  "target":"$pkg",
  "metafile":"$mf",
  "new_version":"$new_ver",
  "installed_version":"$inst_ver",
  "pkgfile":"$pkgfile",
  "timestamp":"$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "phase":"install-failed"
}
JSON
)
    save_state "$state"
    return 3
  fi

  # update DB
  update_db_after_upgrade "$pkg" "$new_ver" "/"

  _logger INFO "Upgrade de $pkg concluído com sucesso: $inst_ver -> $new_ver"

  return 0
}

# -------------------- Main flow --------------------
_logger STAGE "porg-upgrade started at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
_logger INFO "Flags: dryrun=$DRY_RUN quiet=$QUIET sync=$DO_SYNC check=$DO_CHECK revdep=$DO_REVDEP clean=$DO_CLEAN resume=$RESUME target=$TARGET_PKG"

# sync if requested
if [ "$DO_SYNC" = true ]; then
  do_sync
fi

# handle resume
if [ "$RESUME" = true ]; then
  if [ -f "$STATE_FILE" ]; then
    st="$(cat "$STATE_FILE")"
    _logger INFO "Resume: estado encontrado em $STATE_FILE"
    pkg="$(python3 - <<PY
import json,sys
print(json.load(open(sys.argv[1]))['target'])
PY
"$STATE_FILE")"
    _logger INFO "Tentando retomar upgrade interrompido para: $pkg"
    # attempt to rebuild/install the pkg
    rc=0
    if upgrade_one_pkg "$pkg"; then
      _logger INFO "Resume: pacote $pkg reconstruído com sucesso, removendo estado"
      clear_state
      rc=0
    else
      _logger ERROR "Resume: rebuild falhou para $pkg. Corrija o problema e execute --resume novamente."
      rc=2
    fi
    exit $rc
  else
    _logger INFO "Resume solicitado mas nenhum estado encontrado em $STATE_FILE"
  fi
fi

# build list of targets
targets=()
if [ -n "$TARGET_PKG" ]; then
  targets=("$TARGET_PKG")
else
  # world: list all installed packages from DB
  if declare -f db_list >/dev/null 2>&1; then
    while IFS= read -r l; do
      [ -z "$l" ] && continue
      # db_list prints lines "pkgid version prefix time"
      pkgname=$(echo "$l" | awk '{print $1}' | sed 's/-[0-9].*$//')
      # better: take full key and split name by '-'; simpler: use first token and extract base
      # attempt to extract base name (part before first dash + digits)
      # fallback: use whole key
      if [[ "$pkgname" =~ ^([a-zA-Z0-9._+-]+)-[0-9] ]]; then
        base="${BASH_REMATCH[1]}"
      else
        base="$pkgname"
      fi
      targets+=("$base")
    done < <(db_list 2>/dev/null || true)
  else
    _logger ERROR "db_list não disponível; não posso realizar --world"
    exit 2
  fi
fi

# if check-only, simply detect metafile versions vs installed and print
if [ "$DO_CHECK" = true ]; then
  _logger STAGE "Verificando atualizações (check mode)"
  for pkg in "${targets[@]}"; do
    mf="$(find_metafile "$pkg" || true)"
    if [ -z "$mf" ]; then
      _logger DEBUG "Metafile não encontrado para $pkg"
      continue
    fi
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

# main upgrade loop: sequential (stop on first failure)
for pkg in "${targets[@]}"; do
  _logger STAGE "Processing package: $pkg"
  if upgrade_one_pkg "$pkg"; then
    _logger INFO "Package $pkg upgraded successfully; continuing..."
    # continue to next
  else
    code=$?
    if [ "$code" -eq 2 ] || [ "$code" -eq 3 ]; then
      _logger ERROR "Upgrade interrupted at package $pkg (code $code). Estado salvo para resume em $STATE_FILE"
      _logger INFO "Corrija o erro (veja logs em $LOG_DIR) e execute: porg-upgrade --resume"
      exit $code
    else
      _logger WARN "Upgrade step returned non-zero ($code) for $pkg; stopping"
      exit $code
    fi
  fi
done

# post-upgrade actions
if [ "$DO_ROTATE" = true ]; then
  if declare -f _rotate_if_needed >/dev/null 2>&1; then
    _rotate_if_needed
    _logger INFO "Log rotation requested/completed"
  fi
fi

if [ "$DO_REVDEP" = true ]; then
  if [ -x "$RESOLVE_CMD" ]; then
    _logger INFO "Running resolve (revdep) --scan --fix"
    if [ "$DRY_RUN" = true ]; then
      _logger INFO "[dry-run] would call: $RESOLVE_CMD --scan --fix"
    else
      "$RESOLVE_CMD" --scan --fix || _logger WARN "porg-resolve returned non-zero"
    fi
  fi
fi

if [ "$DO_CLEAN" = true ]; then
  if [ -x "$RESOLVE_CMD" ]; then
    _logger INFO "Running resolve (depclean) --clean"
    if [ "$DRY_RUN" = true ]; then
      _logger INFO "[dry-run] would call: $RESOLVE_CMD --clean"
    else
      "$RESOLVE_CMD" --clean || _logger WARN "porg-resolve --clean returned non-zero"
    fi
  fi
fi

# summary report
ts="$(date -u +%Y%m%dT%H%M%SZ)"
REPORT_FILE="${REPORT_DIR}/upgrade-report-${ts}.log"
{
  echo "porg-upgrade report: $ts"
  echo "targets: ${targets[*]}"
  echo "dry-run: $DRY_RUN"
  echo "quiet: $QUIET"
  echo "sync: $DO_SYNC"
  echo "revdep: $DO_REVDEP"
  echo "clean: $DO_CLEAN"
  echo "state-file: $STATE_FILE"
} > "$REPORT_FILE"
_logger INFO "Upgrade finished; report saved to $REPORT_FILE"

exit 0
