#!/usr/bin/env bash
# porg_remove.sh - Remoção segura, paralela e auditável de pacotes para Porg
# Recursos:
#  - integração com /etc/porg/porg.conf
#  - usa porg_logger.sh se disponível (cores, spinner, progresso)
#  - modo --quiet com UI compacta (spinner + progresso)
#  - suporte a múltiplos pacotes em lote e --parallel
#  - dry-run, --yes, --force, --json-log
#  - backup opcional antes da remoção e rollback suportado externamente
#  - hooks pré/post remove com contexto exportado (PKG_NAME, PKG_VERSION, PKG_PREFIX)
#  - integra com porg_db.sh, porg_deps.py, porg_audit.sh e porg_remove auxiliar
#  - gera logs coloridos e JSON em /var/log/porg/
set -euo pipefail
IFS=$'\n\t'

# -------------------- Carrega config cedo --------------------
PORG_CONF="${PORG_CONF:-/etc/porg/porg.conf}"
if [ -f "$PORG_CONF" ]; then
  # shellcheck disable=SC1090
  source "$PORG_CONF"
fi

# -------------------- Defaults que podem ser sobrescritos em porg.conf --------------------
INSTALLED_DB="${INSTALLED_DB:-${DB_DIR:-/var/lib/porg/db}/installed.json}"
LOGGER_SCRIPT="${LOGGER_MODULE:-/usr/lib/porg/porg_logger.sh}"
DB_SCRIPT="${DB_CMD:-/usr/lib/porg/porg_db.sh}"
REMOVE_SCRIPT="${REMOVE_MODULE:-/usr/lib/porg/porg_remove.sh}"   # fallback
DEPS_PY="${DEPS_PY:-/usr/lib/porg/porg_deps.py}"
AUDIT_SCRIPT="${AUDIT_SCRIPT:-/usr/lib/porg/porg_audit.sh}"
REPORT_DIR="${REPORT_DIR:-/var/log/porg}"
JSON_DIR="${JSON_DIR:-${REPORT_DIR}/json}"
BACKUP_REMOVED="${BACKUP_REMOVED:-false}"
BACKUP_DIR="${BACKUP_DIR:-/var/cache/porg/backups}"
HOOKS_ROOT="${HOOK_DIR:-/etc/porg/hooks}"
PARALLEL_N="${PARALLEL_N:-$(nproc 2>/dev/null || echo 1)}"
QUIET_MODE_DEFAULT="${QUIET_MODE_DEFAULT:-false}"
DRY_RUN_DEFAULT="${DRY_RUN_DEFAULT:-false}"
FORCE_DEFAULT="${FORCE_DEFAULT:-false}"

mkdir -p "$REPORT_DIR" "$JSON_DIR" "$BACKUP_DIR" "$(dirname "$INSTALLED_DB")"

# -------------------- Logger integration --------------------
if [ -f "$LOGGER_SCRIPT" ]; then
  # shellcheck disable=SC1090
  source "$LOGGER_SCRIPT"
else
  log_info(){ printf "%s [INFO] %s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
  log_warn(){ printf "%s [WARN] %s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
  log_error(){ printf "%s [ERROR] %s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
  log_debug(){ [ "${DEBUG:-false}" = true ] && printf "%s [DEBUG] %s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
  log_stage(){ printf "%s [STAGE] %s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
  # basic spinner/progress placeholders
  _spinner_start(){ :; }
  _spinner_stop(){ :; }
  log_progress(){ printf "%s\n" "$*"; }
fi

# -------------------- Helpers --------------------
_die(){ log_error "$*"; exit 2; }
_have(){ command -v "$1" >/dev/null 2>&1; }
_timestamp(){ date -u +%Y%m%dT%H%M%SZ; }

# -------------------- CLI parsing --------------------
usage(){
  cat <<EOF
Usage: $(basename "$0") [options] <pkg> [pkg...]
Options:
  --parallel N      Number of parallel removals (default: detected CPUs)
  --dry-run         Do not change system; simulate actions
  --yes             Auto-confirm destructive actions
  --force           Force removal even if dependents exist
  --quiet           Compact UI (spinner/progress)
  --json-log        Write structured JSON report per package in $JSON_DIR
  --backup          Create backup tar.zst of package prefix before removal
  --help            Show this help
Examples:
  porg-remove --parallel 4 gcc bash coreutils
EOF
  exit 1
}

PARALLEL_N="${PARALLEL_N}"
DRY_RUN="$DRY_RUN_DEFAULT"
AUTO_YES=false
QUIET="$QUIET_MODE_DEFAULT"
FORCE="$FORCE_DEFAULT"
OUT_JSON=false
DO_BACKUP=false

ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --parallel) PARALLEL_N="${2:-$PARALLEL_N}"; shift 2;;
    --dry-run) DRY_RUN=true; shift;;
    --yes) AUTO_YES=true; shift;;
    --force) FORCE=true; shift;;
    --quiet) QUIET=true; shift;;
    --json-log) OUT_JSON=true; shift;;
    --backup) DO_BACKUP=true; shift;;
    -h|--help) usage;;
    --) shift; while [ $# -gt 0 ]; do ARGS+=("$1"); shift; done; break;;
    -*)
      echo "Unknown option: $1" >&2; usage;;
    *)
      ARGS+=("$1"); shift;;
  esac
done

if [ "${#ARGS[@]}" -eq 0 ]; then usage; fi

# respect quiet env
if [ "$QUIET" = true ]; then export QUIET_MODE_DEFAULT=true; fi

TS="$(_timestamp)"
GLOBAL_REPORT="${REPORT_DIR}/porg-remove-report-${TS}.json"
TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}"/porg-remove.XXXX)"
trap 'rm -rf "$TMPDIR"' EXIT

# -------------------- JSON helpers --------------------
_have_jq(){ _have jq; }
_json_write(){
  local out="$1"; shift
  python3 - <<PY > "$out"
import json,sys
print(json.dumps(sys.stdin.read() and json.loads(sys.stdin.read()) or {}, indent=2, ensure_ascii=False))
PY
}

# write per-package JSON (best-effort, using python)
_write_pkg_json(){
  local out="$1"; shift
  python3 - <<PY > "$out"
import json,sys
d=json.loads("""$*""")
print(json.dumps(d, indent=2, ensure_ascii=False))
PY
}

# -------------------- DB helpers (read installed.json) --------------------
read_installed_db_raw(){
  if [ -f "$INSTALLED_DB" ]; then
    cat "$INSTALLED_DB"
  else
    echo "{}"
  fi
}

# get package record by name (best-effort: matches prefix of key or name field)
get_pkg_record(){
  local pkg="$1"
  if _have_jq; then
    jq -r --arg pkg "$pkg" 'to_entries[] | select(.value.name == $pkg or (.key|startswith($pkg + "-"))) | .value | @json' "$INSTALLED_DB" 2>/dev/null || echo ""
  else
    python3 - <<PY
import json,sys
pkg=sys.argv[1]
try:
  db=json.load(open("${INSTALLED_DB}",'r',encoding='utf-8'))
except:
  db={}
for k,v in db.items():
  if v.get('name')==pkg or k.startswith(pkg+"-"):
    print(json.dumps(v))
    sys.exit(0)
print("",end="")
PY
  fi
}

# get installed prefix for pkg
get_pkg_prefix(){
  local pkg="$1"
  local rec
  rec="$(get_pkg_record "$pkg")" || true
  if [ -z "$rec" ]; then
    echo ""
    return
  fi
  if _have_jq; then
    echo "$rec" | jq -r '.prefix // empty' || echo ""
  else
    python3 - <<PY
import json,sys
s=sys.stdin.read()
try:
  d=json.loads(s)
  print(d.get('prefix',''))
except:
  print("")
PY
"$rec"
  fi
}

# get version
get_pkg_version(){
  local pkg="$1"
  local rec
  rec="$(get_pkg_record "$pkg")" || true
  if [ -z "$rec" ]; then
    echo ""
    return
  fi
  if _have_jq; then
    echo "$rec" | jq -r '.version // empty' || echo ""
  else
    python3 - <<PY
import json,sys
s=sys.stdin.read()
try:
  d=json.loads(s)
  print(d.get('version',''))
except:
  print("")
PY
"$rec"
  fi
}

# find dependents (reverse deps) using deps.py if available, else naive scan of installed.json metadata
find_dependents(){
  local pkg="$1"
  if [ -x "$DEPS_PY" ]; then
    # use deps.py graph to find who depends on pkg
    if _have_jq; then
      plan="$("$DEPS_PY" upgrade-plan --world 2>/dev/null || true)"
      echo "$plan" | jq -r --arg pkg "$pkg" '[.upgrade_order[]? as $p | $p] | map(select(. == $pkg)) | []' 2>/dev/null || true
      # fallback naive: return empty (we'll do naive below)
    else
      # fallback: we don't parse graph; use naive scan
      :
    fi
  fi
  # naive: scan installed DB for dependency lists in metadata (best-effort)
  if _have_jq; then
    jq -r --arg pkg "$pkg" 'to_entries[] | select(.value.dependencies != null) | select(.value.dependencies | index($pkg)) | .value.name' "$INSTALLED_DB" 2>/dev/null || true
  else
    python3 - <<PY
import json,sys
pkg=sys.argv[1]
try:
  db=json.load(open("${INSTALLED_DB}",'r',encoding='utf-8'))
except:
  db={}
out=[]
for k,v in db.items():
  deps=v.get('dependencies') or v.get('depends') or []
  if isinstance(deps,str):
    deps=[deps]
  if pkg in deps:
    out.append(v.get('name') or k)
for x in out:
  print(x)
PY
"$pkg"
  fi
}

# -------------------- Hooks runner (pre/post remove) --------------------
run_pkg_hooks(){
  local stage="$1"; local pkgname="$2"; local pkgver="$3"; local pkgprefix="$4"
  # global hooks at HOOKS_ROOT/<stage> and per-package at HOOKS_ROOT/<pkg>/<stage>
  local hooks=()
  [ -d "${HOOKS_ROOT}/${stage}" ] && for h in "${HOOKS_ROOT}/${stage}"/*; do [ -x "$h" ] && hooks+=("$h"); done
  [ -d "${HOOKS_ROOT}/${pkgname}/${stage}" ] && for h in "${HOOKS_ROOT}/${pkgname}/${stage}"/*; do [ -x "$h" ] && hooks+=("$h"); done
  # export context
  export PKG_NAME="${pkgname}"
  export PKG_VERSION="${pkgver}"
  export PKG_PREFIX="${pkgprefix}"
  export PORG_CONF
  for h in "${hooks[@]}"; do
    log_info "Executing hook: $h (stage=$stage) for $pkgname"
    if [ "$DRY_RUN" = true ]; then
      log_info "[DRY-RUN] Would run hook: $h"
    else
      ( "$h" ) || log_warn "Hook $h exited with non-zero"
    fi
  done
}

# -------------------- Backup package prefix --------------------
backup_prefix(){
  local pkg="$1"; local prefix="$2"
  [ -z "$prefix" ] && { log_warn "No prefix for $pkg; skip backup"; return 1; }
  local ts="$(_timestamp)"
  local out="${BACKUP_DIR}/${pkg}-${ts}.tar.zst"
  if [ "$DRY_RUN" = true ]; then
    log_info "[DRY-RUN] Would create backup ${out} of ${prefix}"
    echo "$out"
    return 0
  fi
  log_info "Creating backup of ${prefix} -> ${out}"
  # tar and zstd (if available)
  if _have zstd; then
    tar -C "${prefix%/*}" -cf - "$(basename "$prefix")" 2>/dev/null | zstd -T0 -19 -o "$out"
  else
    tar -C "${prefix%/*}" -cf "${out%.zst}.tar" "$(basename "$prefix")"
    out="${out%.zst}.tar"
  fi
  echo "$out"
}

# -------------------- Actual removal worker for a single package --------------------
_remove_one_pkg(){
  local pkg="$1"
  local report_file="$TMPDIR/remove-${pkg}-${TS}.json"
  local start_ts=$(date +%s)
  local status="skipped"; local message=""; local freed_bytes=0; local removed_files=0
  local rec_prefix rec_version
  rec_prefix="$(get_pkg_prefix "$pkg")" || rec_prefix=""
  rec_version="$(get_pkg_version "$pkg")" || rec_version=""
  # run pre-remove hooks
  run_pkg_hooks "pre-remove" "$pkg" "$rec_version" "$rec_prefix"

  # check dependents
  mapfile -t dependents < <(find_dependents "$pkg" | sed '/^\s*$/d' || true)

  if [ "${#dependents[@]}" -gt 0 ] && [ "$FORCE" != true ]; then
    message="Package has dependents: ${dependents[*]}"
    log_warn "Refusing to remove $pkg: $message"
    status="blocked"
    # produce JSON and exit
    python3 - <<PY > "$report_file"
{
  "package":"$pkg",
  "version":"$rec_version",
  "prefix":"$rec_prefix",
  "status":"$status",
  "message":"$message",
  "dependents": $(python3 - <<PY2
import json,sys
dep=${dependents[@]+"${dependents[@]}"}
print(json.dumps([x for x in (${dependents[@]+"${dependents[@]}"})]) if dep else "[]")
PY2
)
}
PY
    return 1
  fi

  # backup if requested or configured globally
  local backup_path=""
  if [ "$DO_BACKUP" = true ] || [ "$BACKUP_REMOVED" = true ]; then
    backup_path="$(backup_prefix "$pkg" "$rec_prefix" || echo "")" || true
  fi

  # perform removal via REMOVE_SCRIPT or DB unregister fallback
  if [ "$DRY_RUN" = true ]; then
    log_info "[DRY-RUN] Would remove $pkg at prefix $rec_prefix"
    status="dry-run"
    message="Simulated removal"
  else
    if [ -x "$REMOVE_SCRIPT" ]; then
      log_info "Calling remove script: $REMOVE_SCRIPT $pkg --yes --force=${FORCE}"
      if "$REMOVE_SCRIPT" "$pkg" --yes --force="${FORCE}" >/dev/null 2>&1; then
        status="removed"
        message="Removed via external remove script"
      else
        log_warn "REMOVE_SCRIPT failed for $pkg; attempting fallback"
        # fallback to db unregister & prefix deletion
      fi
    fi

    if [ "$status" != "removed" ]; then
      # fallback: unregister from DB and remove files under prefix (careful)
      if [ -x "/usr/lib/porg/porg_db.sh" ]; then
        log_info "Unregistering $pkg via porg_db.sh"
        if /usr/lib/porg/porg_db.sh unregister "$pkg" >/dev/null 2>&1; then
          status="db-unregistered"
        else
          log_warn "DB unregister failed for $pkg"
        fi
      fi
      # physically remove prefix only if safe and prefix not in critical dirs
      if [ -n "$rec_prefix" ]; then
        case "$rec_prefix" in
          /|/usr|/bin|/sbin|/lib|/lib64|/etc) 
            log_warn "Refusing to remove critical prefix '$rec_prefix' for $pkg"; status="refused"; message="critical-prefix";;
          *)
            # remove prefix
            log_info "Removing prefix $rec_prefix for $pkg (this may free space)"
            if rm -rf --one-file-system "$rec_prefix"; then
              status="${status:-removed-files}"
              message="Prefix removed"
            else
              log_warn "Failed to remove $rec_prefix"
              status="partial-failure"
            fi
            ;;
        esac
      else
        log_warn "No prefix known for $pkg; cannot remove files"
        status="${status:-no-prefix}"
      fi
    fi
  fi

  # post-remove hooks
  run_pkg_hooks "post-remove" "$pkg" "$rec_version" "$rec_prefix"

  # optional: run depclean/revdep/audit sequence if forced
  if [ "$FORCE" = true ]; then
    log_info "Force requested: running depclean/revdep/audit flows"
    if [ -x "/usr/bin/porg-resolve" ] || [ -x "/usr/lib/porg/resolve.sh" ]; then
      if [ -x "/usr/lib/porg/resolve.sh" ]; then
        /usr/lib/porg/resolve.sh --clean --quiet || true
      fi
    fi
    if [ -x "$AUDIT_SCRIPT" ]; then
      "$AUDIT_SCRIPT" --quick --quiet || true
    fi
  fi

  # compute removed files and freed bytes (best-effort)
  if [ -n "$rec_prefix" ] && [ -d "$rec_prefix" ]; then
    # if still exists, try du before/after? best-effort skip
    removed_files=0; freed_bytes=0
  else
    # if removed, try to estimate by backup size or by previous metadata
    if [ -n "$backup_path" ] && [ -f "$backup_path" ]; then
      freed_bytes=$(stat -c%s "$backup_path" 2>/dev/null || echo 0)
      removed_files=$(tar -tf "$backup_path" 2>/dev/null | wc -l 2>/dev/null || echo 0) || true
    fi
  fi

  local end_ts=$(date +%s)
  local duration_s=$((end_ts - start_ts))

  # produce per-package JSON report
  local json_report="${JSON_DIR}/remove-${pkg}-${TS}.json"
  if [ "$OUT_JSON" = true ] || [ "$DO_BACKUP" = true ]; then
    mkdir -p "$JSON_DIR"
    python3 - <<PY > "$json_report"
{
  "package":"$pkg",
  "version":"$rec_version",
  "prefix":"$rec_prefix",
  "status":"$status",
  "message":"$message",
  "dependents": $(python3 - <<PY2
import json,sys
deps=${dependents[@]+"${dependents[@]}"}
print(json.dumps([x for x in (${dependents[@]+"${dependents[@]}"})]) if deps else "[]")
PY2
),
  "backup":"${backup_path:-}",
  "removed_files": $removed_files,
  "freed_bytes": $freed_bytes,
  "duration_s": $duration_s,
  "timestamp":"$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
PY
  fi

  # UI / logs
  if [ "$QUIET" = true ]; then
    if [ "$status" = "removed" ] || [ "$status" = "db-unregistered" ] || [ "$status" = "removed-files" ]; then
      printf "\r[OK] %s removed (%.0fs)\n" "$pkg" "$duration_s"
    else
      printf "\r[! ] %s: %s\n" "$pkg" "$status"
    fi
  else
    log_info "Remove result for $pkg: status=$status message=$message duration=${duration_s}s freed_bytes=${freed_bytes}"
  fi

  return 0
}

# -------------------- Parallel execution orchestration --------------------
# If gnu parallel available prefer it for nice handling; else use background jobs with wait -n or manual throttle
run_removals_parallel(){
  local -a pkgs=("$@")
  local n="${PARALLEL_N:-1}"
  if _have parallel; then
    # use GNU parallel; shell-escape each pkg
    printf "%s\n" "${pkgs[@]}" | parallel -j "$n" --no-notice --lb bash -c 'p="$0"; /usr/lib/porg/porg_remove.sh_internal "$p"' 
    # Note: we will call internal function via a wrapper below if needed
    return 0
  fi

  # fallback: spawn background jobs and throttle
  local running=0
  local pids=()
  for pkg in "${pkgs[@]}"; do
    # call internal via current script function in background: use bash -c to invoke this script with special internal mode
    bash -c "DRY_RUN=${DRY_RUN} QUIET=${QUIET} OUT_JSON=${OUT_JSON} DO_BACKUP=${DO_BACKUP} PARALLEL_N=${PARALLEL_N} \"$0\" --internal-remove \"$pkg\"" &
    pids+=($!)
    running=$((running+1))
    if [ "$running" -ge "$n" ]; then
      if wait -n 2>/dev/null; then
        running=$((running-1))
      else
        wait "${pids[0]}" || true
        pids=("${pids[@]:1}")
        running=$((running-1))
      fi
    fi
  done
  wait
}

# -------------------- Internal entrypoint for background removals --------------------
# This allows calling this script recursively for backgrounds while preserving functions
if [ "${1:-}" = "--internal-remove" ]; then
  shift
  if [ $# -eq 0 ]; then _die "internal-remove requires pkg"; fi
  pkg="$1"
  # import previously parsed flags from env or defaults
  DRY_RUN="${DRY_RUN:-$DRY_RUN_DEFAULT}"
  QUIET="${QUIET:-$QUIET_MODE_DEFAULT}"
  OUT_JSON="${OUT_JSON:-false}"
  DO_BACKUP="${DO_BACKUP:-false}"
  PARALLEL_N="${PARALLEL_N:-1}"
  # call the worker
  _remove_one_pkg "$pkg"
  exit $?
fi

# -------------------- Main orchestration --------------------
main_start_ts=$(date +%s)
log_stage "porg_remove: starting removal of ${#ARGS[@]} packages (parallel=${PARALLEL_N})"
# show quiet spinner if requested
if [ "$QUIET" = true ]; then
  _spinner_start "Removing packages..."
fi

# Confirmation if not auto-yes and not dry-run
if [ "$AUTO_YES" != true ] && [ "$DRY_RUN" != true ]; then
  printf "Confirm removal of packages: %s ? [y/N]: " "${ARGS[*]}"
  read -r ans || true
  case "$ans" in [yY]|[yY][eE][sS]) ;; *) log_info "Aborted by user"; exit 0 ;; esac
fi

# If PARALLEL_N==1 call sequential, else parallel
if [ "${PARALLEL_N:-1}" -le 1 ]; then
  for pkg in "${ARGS[@]}"; do
    _remove_one_pkg "$pkg" &
    wait $!
  done
else
  # call run_removals_parallel
  # For portability, call internal mode
  for pkg in "${ARGS[@]}"; do
    bash -c " \"$0\" --internal-remove \"$pkg\"" &
    # throttle
    while [ "$(jobs -rp | wc -l)" -ge "$PARALLEL_N" ]; do sleep 0.2; done
  done
  wait
fi

if [ "$QUIET" = true ]; then
  _spinner_stop 0
fi

# Final audit integration
if [ -x "$AUDIT_SCRIPT" ]; then
  log_info "Running quick audit after removals"
  if [ "$DRY_RUN" = true ]; then
    log_info "[DRY-RUN] Would call $AUDIT_SCRIPT --quick"
  else
    "$AUDIT_SCRIPT" --quick --quiet || log_warn "Audit script returned non-zero"
  fi
fi

main_end_ts=$(date +%s)
main_elapsed=$((main_end_ts - main_start_ts))

# Compose global JSON summary
python3 - <<PY > "${GLOBAL_REPORT}"
import json,glob,os,time
out={}
out['timestamp']=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
out['packages']=[]
for f in glob.glob("${TMPDIR}/remove-*.json"):
    try:
        out['packages'].append(json.load(open(f,'r',encoding='utf-8')))
    except:
        pass
# also include per-pkg JSONs from JSON_DIR
for f in glob.glob("${JSON_DIR}/remove-*.json"):
    try:
        out['packages'].append(json.load(open(f,'r',encoding='utf-8')))
    except:
        pass
out['summary']={}
out['summary']['total_packages']=${#ARGS[@]}
out['summary']['duration_s']=${main_elapsed}
print(json.dumps(out,indent=2,ensure_ascii=False))
PY

log_info "Removal run completed in ${main_elapsed}s. Global report: ${GLOBAL_REPORT}"
if [ "$OUT_JSON" = true ]; then
  cat "${GLOBAL_REPORT}"
fi

exit 0
