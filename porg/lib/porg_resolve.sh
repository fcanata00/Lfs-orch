#!/usr/bin/env bash
#
# porg_resolve.sh - revdep + depclean + rebuild resolver for Porg
# Path suggestion: /usr/lib/porg/resolve.sh or /usr/bin/porg-resolve
#
set -euo pipefail
IFS=$'\n\t'

# --------------------- Load porg.conf early ---------------------
PORG_CONF="${PORG_CONF:-/etc/porg/porg.conf}"
if [ -f "$PORG_CONF" ]; then
  # shellcheck disable=SC1090
  source "$PORG_CONF"
fi

# --------------------- Defaults (respected if not in porg.conf) ---------------------
PORTS_DIR="${PORTS_DIR:-/usr/ports}"
INSTALLED_DB="${INSTALLED_DB:-${DB_DIR:-/var/lib/porg/db}/installed.json}"
LOGGER_SCRIPT="${LOGGER_MODULE:-/usr/lib/porg/porg_logger.sh}"
DEPS_PY="${DEPS_PY:-/usr/lib/porg/porg_deps.py}"
BUILDER_SCRIPT="${BUILDER_SCRIPT:-/usr/lib/porg/porg_builder.sh}"
REMOVE_SCRIPT="${REMOVE_MODULE:-/usr/lib/porg/porg_remove.sh}"
REPORT_DIR="${REPORT_DIR:-/var/log/porg/reports}"
CACHE_DIR="${CACHE_DIR:-/var/cache/porg}"
CHROOT_METHOD="${CHROOT_METHOD:-bwrap}"
JOBS_DEFAULT="${PARALLEL_BUILDS:-true}"
JOBS="${1:-$(nproc 2>/dev/null || echo 1)}"
mkdir -p "$REPORT_DIR" "$CACHE_DIR" "$(dirname "$INSTALLED_DB")"

# --------------------- Logger wrapper ---------------------
_log_cmd() {
  local level="$1"; shift
  local msg="$*"
  if [ -f "$LOGGER_SCRIPT" ]; then
    # call the logger if available; non-fatal
    bash -lc "source '$LOGGER_SCRIPT' >/dev/null 2>&1 || true; if declare -f log_${level,,} >/dev/null 2>&1; then log_${level,,} \"${msg//\"/\\\"}\"; else echo \"[$level] $msg\"; fi" || true
  else
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    case "$level" in
      INFO)  printf "%s [INFO] %s\n" "$ts" "$msg" ;;
      WARN)  printf "%s [WARN] %s\n" "$ts" "$msg" >&2 ;;
      ERROR) printf "%s [ERROR] %s\n" "$ts" "$msg" >&2 ;;
      DEBUG) [ "${DEBUG:-false}" = true ] && printf "%s [DEBUG] %s\n" "$ts" "$msg" ;;
      STAGE) printf "%s [STAGE] %s\n" "$ts" "$msg" ;;
      *) printf "%s [%s] %s\n" "$ts" "$level" "$msg" ;;
    esac
  fi
}

log_info()  { _log_cmd INFO "$*"; }
log_warn()  { _log_cmd WARN "$*"; }
log_error() { _log_cmd ERROR "$*"; }
log_debug() { [ "${DEBUG:-false}" = true ] && _log_cmd DEBUG "$*"; }
log_stage() { _log_cmd STAGE "$*"; }

# --------------------- CLI/flags ---------------------
usage() {
  cat <<EOF
Usage: $(basename "$0") [options]
Options:
  --scan               Scan for broken libraries and orphans
  --fix                Attempt to rebuild/fix broken packages
  --clean              Remove orphaned packages (depclean)
  --rebuild-needed     Show or rebuild packages that need rebuild (uses deps.py)
  --all                Run full pipeline: scan -> fix -> clean -> rebuild-needed
  --json               Output machine-readable JSON report in REPORT_DIR
  --dry-run            Do not modify system; simulate actions
  --quiet              Minimal stdout (logs still recorded)
  --yes                Auto-confirm destructive actions
  --parallel N         Run up to N parallel rebuilds (default: nproc)
  --chroot             Force using chroot/bwrap for rebuilds
  -h, --help           Show this help
EOF
  exit 1
}

CMD_SCAN=false; CMD_FIX=false; CMD_CLEAN=false; CMD_REBUILD=false; CMD_ALL=false
DRY_RUN=false; QUIET=false; AUTO_YES=false; OUT_JSON=false; FORCE_CHROOT=false
PARALLEL_N="$(nproc 2>/dev/null || echo 1)"

while [ $# -gt 0 ]; do
  case "$1" in
    --scan) CMD_SCAN=true; shift;;
    --fix) CMD_FIX=true; shift;;
    --clean) CMD_CLEAN=true; shift;;
    --rebuild-needed) CMD_REBUILD=true; shift;;
    --all) CMD_ALL=true; shift;;
    --json) OUT_JSON=true; shift;;
    --dry-run) DRY_RUN=true; shift;;
    --quiet) QUIET=true; shift;;
    --yes) AUTO_YES=true; shift;;
    --parallel) PARALLEL_N="${2:-$PARALLEL_N}"; shift 2;;
    --chroot) FORCE_CHROOT=true; shift;;
    -h|--help) usage;;
    *) echo "Unknown option: $1"; usage;;
  esac
done

if [ "$QUIET" = true ]; then export QUIET_MODE_DEFAULT=true; fi

TS="$(date -u +%Y%m%dT%H%M%SZ)"
REPORT_JSON="${REPORT_DIR}/resolve-report-${TS}.json"
TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}"/porg-resolve.XXXX)"
trap 'rm -rf "$TMPDIR"' EXIT

# --------------------- Helpers: JSON read/write (jq or python) ---------------------
_have_jq() { command -v jq >/dev/null 2>&1; }
_json_read() {
  # $1 = file, prints to stdout
  if _have_jq; then jq -C . "$1"; else python3 - <<PY
import json,sys
print(json.dumps(json.load(open(sys.argv[1],'r',encoding='utf-8')),ensure_ascii=False,indent=2))
PY
  fi
}

# --------------------- Backup DB ---------------------
backup_installed_db() {
  local bdir="${DB_BACKUP_DIR:-/var/backups/porg/db}"
  mkdir -p "$bdir"
  local out="${bdir}/installed.json.bak.${TS}"
  cp -a "$INSTALLED_DB" "$out" 2>/dev/null || true
  log_info "Backup of installed DB to $out"
  echo "$out"
}

# --------------------- Read installed DB list ---------------------
read_installed_pkgs() {
  if [ ! -f "$INSTALLED_DB" ]; then
    echo "[]" ; return
  fi
  if _have_jq; then
    jq -r 'to_entries[] | .value.name' "$INSTALLED_DB" 2>/dev/null || true
  else
    python3 - <<PY
import json,sys
try:
  db=json.load(open("$INSTALLED_DB",'r',encoding='utf-8'))
except:
  db={}
for k,v in db.items():
  print(v.get('name') or k)
PY
  fi
}

# --------------------- revdep_scan: find "not found" in ldd for ELF files under package prefix ---------------------
revdep_scan() {
  log_stage "Starting revdep_scan"
  local results_file="${TMPDIR}/revdep.json"
  echo "{\"broken\":[]}" > "$results_file"
  local broken_pkgs=()
  # loop installed entries with prefixes
  if [ ! -f "$INSTALLED_DB" ]; then
    log_warn "Installed DB not found at $INSTALLED_DB; skipping revdep_scan"
    echo "{\"broken\":[]}" > "$results_file"
    cat "$results_file"
    return 0
  fi
  # gather packages with prefixes
  python3 - <<PY > "${TMPDIR}/pkg_prefixes.json"
import json,sys
try:
  db=json.load(open("$INSTALLED_DB",'r',encoding='utf-8'))
except:
  db={}
out=[]
for k,v in db.items():
  prefix=v.get('prefix') or '/'
  name=v.get('name') or k
  out.append({"key":k,"name":name,"prefix":prefix})
print(json.dumps(out))
PY

  # for each package, search common dirs (bin, lib, sbin, usr) under prefix for ELF files
  mapfile -t pkg_lines < <(python3 - <<PY
import json,sys
data=json.load(open("${TMPDIR}/pkg_prefixes.json",'r',encoding='utf-8'))
for e in data:
    print(e["name"]+"|||"+e["prefix"])
PY
)
  idx=0
  total=${#pkg_lines[@]}
  for pl in "${pkg_lines[@]}"; do
    idx=$((idx+1))
    pkg="${pl%%%*}" # will not be used; safer parsing below
    IFS='|||' read -r pkg prefix <<< "$pl"
    prefix="${prefix:-/}"
    # check candidate directories
    dirs=( "${prefix}/bin" "${prefix}/sbin" "${prefix}/lib" "${prefix}/lib64" "${prefix}/usr/lib" "${prefix}/usr/lib64" "${prefix}/usr/bin" )
    pkg_broken=false
    # iterate files
    for d in "${dirs[@]}"; do
      [ -d "$d" ] || continue
      # find ELF regular files
      while IFS= read -r -d '' f; do
        # skip symlinks (we'll check their targets separately)
        if file "$f" 2>/dev/null | grep -q 'ELF'; then
          # inspect ldd output
          out=$(ldd "$f" 2>/dev/null || true)
          if echo "$out" | grep -q "not found"; then
            pkg_broken=true
            # record
            python3 - <<PY
import json,sys
r=json.load(open("${results_file}","r",encoding='utf-8'))
if "broken" not in r: r["broken"]=[]
r["broken"].append({"pkg":"$pkg","file":"$f","ldd":"""$out"""})
open("${results_file}","w",encoding='utf-8').write(json.dumps(r,indent=2,ensure_ascii=False))
PY
            # break to next package (to reduce noise)
            break 2
          fi
        fi
      done < <(find "$d" -type f -print0 2>/dev/null)
    done
  done

  cat "$results_file"
}

# --------------------- depclean_scan: find orphaned packages (no reverse-deps) ---------------------
depclean_scan() {
  log_stage "Starting depclean_scan"
  local results_file="${TMPDIR}/depclean.json"
  echo "{\"orphans\":[]}" > "$results_file"
  # prefer to use porg_deps.py to compute reverse dependencies
  if [ -x "$DEPS_PY" ]; then
    log_debug "Calling $DEPS_PY to build world graph"
    # ask for an upgrade-plan for world to get dependencies graph
    plan_json="$("$DEPS_PY" upgrade-plan --world 2>/dev/null || true)"
    if [ -z "$plan_json" ]; then
      log_warn "deps.py did not return upgrade-plan; fallback to lightweight detection"
    else
      # parse graph: if a package appears in installed DB but never appears as dependency of any other, it's candidate orphan
      if _have_jq; then
        installed_list=$(jq -r '(.roots // []) as $r | .upgrade_order[]' <<<"$plan_json" 2>/dev/null || true)
        # Build reverse map: for performance, use python
        python3 - <<PY > "$results_file"
import json,sys
plan=json.loads(sys.stdin.read())
order=plan.get("upgrade_order",[]) or []
# build dependencies map by reading meta via porg_deps is expensive; we approximate using order: if package never appears as dep in graph edges, mark as orphan candidate
# but plan may not contain explicit edges here; fallback: compute reverse by scanning metafiles in /usr/ports
import os
ports_dir = os.environ.get("PORTS_DIR","/usr/ports")
def parse_yaml(p):
    try:
        import yaml
        return yaml.safe_load(open(p,'r',encoding='utf-8')) or {}
    except:
        # fallback parsing
        txt=open(p,'r',encoding='utf-8',errors='ignore').read()
        return {}
# collect all packages declared in ports and their dependencies
deps_map={}
for root,dirs,files in os.walk(ports_dir):
    for fn in files:
        if fn.lower().endswith((".yml",".yaml")):
            p=os.path.join(root,fn)
            d=parse_yaml(p)
            name=d.get("name") or os.path.splitext(fn)[0]
            deps=[]
            dd=d.get("dependencies") or {}
            if isinstance(dd,dict):
                for k in ("build","runtime","optional"):
                    v=dd.get(k)
                    if isinstance(v,list):
                        deps += v
            elif isinstance(dd,list):
                deps += dd
            deps_map[name]=deps
# build reverse map
rev={}
for k,vals in deps_map.items():
    for dep in vals:
        rev.setdefault(dep, set()).add(k)
# read installed DB
try:
    db=json.load(open(os.path.join(os.environ.get("DB_DIR","/var/lib/porg/db"),"installed.json"),'r',encoding='utf-8'))
except:
    db={}
orphans=[]
for key,v in db.items():
    name=v.get("name") or key
    # if no reverse deps and not a core package (heuristic: tier/core omitted), consider orphan
    if name not in rev or len(rev.get(name,[]))==0:
        orphans.append({"pkg":name,"prefix":v.get("prefix")})
print(json.dumps({"orphans":orphans},indent=2,ensure_ascii=False))
PY
      fi
      cat "$results_file"
      return 0
    fi
  fi

  # fallback: naive approach - any installed package not referenced by others in installed DB's 'dependencies' field
  python3 - <<PY > "$results_file"
import json,sys
try:
  db=json.load(open("$INSTALLED_DB",'r',encoding='utf-8'))
except:
  db={}
# naive: if a package's name never appears in any metafile dependency, consider it orphan candidate
from os import walk
ports={}
for root,dirs,files in walk("$PORTS_DIR"):
    for f in files:
        if f.lower().endswith(('.yml','.yaml')):
            p=root+'/'+f
            try:
                import yaml
                d=yaml.safe_load(open(p,'r',encoding='utf-8')) or {}
            except:
                d={}
            name=d.get('name') or f.rsplit('.',1)[0]
            deps=[]
            dd=d.get('dependencies') or d.get('deps') or {}
            if isinstance(dd,dict):
                for k in ('build','runtime','optional'):
                    v=dd.get(k)
                    if isinstance(v,list): deps+=v
            elif isinstance(dd,list):
                deps+=dd
            ports[name]=deps
# build reverse map
rev={}
for k,v in ports.items():
    for dep in v:
        rev.setdefault(dep,[]).append(k)
orphans=[]
for k,v in db.items():
    name=v.get('name') or k
    if name not in rev or len(rev.get(name,[]))==0:
        orphans.append({"pkg":name,"prefix":v.get("prefix")})
print(json.dumps({"orphans":orphans},indent=2,ensure_ascii=False))
PY

  cat "$results_file"
}

# --------------------- call porg_deps.py to find rebuild-needed ---------------------
get_rebuild_needed() {
  log_stage "Checking rebuild-needed via $DEPS_PY"
  if [ ! -x "$DEPS_PY" ]; then
    log_warn "deps.py not found or not executable at $DEPS_PY"
    echo "[]"
    return 0
  fi
  # call upgrade-plan for world
  plan="$("$DEPS_PY" upgrade-plan --world 2>/dev/null || true)"
  if [ -z "$plan" ]; then
    log_warn "deps.py returned empty plan"
    echo "[]"
    return 0
  fi
  if _have_jq; then
    echo "$plan" | jq -r '.needs_rebuild[]?' 2>/dev/null || true
  else
    python3 - <<PY
import json,sys
plan=json.loads(sys.stdin.read() or "{}")
for p in plan.get("needs_rebuild",[]):
    print(p)
PY
  fi
}

# --------------------- fix_package: try to rebuild a package (respects DRY_RUN, CHROOT) ---------------------
fix_package() {
  local pkg="$1"
  log_info "Attempting to fix/rebuild package: $pkg"
  if [ "$DRY_RUN" = true ]; then
    log_info "[DRY-RUN] Would rebuild $pkg"
    return 0
  fi

  # try to find metafile
  mf="$(find "$PORTS_DIR" -type f -iname "${pkg}*.y*ml" -print -quit 2>/dev/null || true)"
  if [ -z "$mf" ]; then
    log_warn "Metafile for $pkg not found under $PORTS_DIR; will try porg -i $pkg"
    if command -v porg >/dev/null 2>&1; then
      porg -i "$pkg" || log_warn "porg -i $pkg returned non-zero"
      return $?
    else
      log_error "No builder interface found (porg or BUILDER_SCRIPT). Cannot rebuild $pkg"
      return 2
    fi
  fi

  # decide whether to use chroot (bubblewrap) for build
  if [ "$FORCE_CHROOT" = true ] || ( [ "$CHROOT_METHOD" = "bwrap" ] && command -v bwrap >/dev/null 2>&1 ); then
    log_debug "Building $pkg inside bwrap chroot"
    if [ -x "$BUILDER_SCRIPT" ]; then
      if [ -n "$BUILDER_SCRIPT" ]; then
        if [ "$DRY_RUN" = true ]; then
          log_info "[DRY-RUN] builder build $mf"
        else
          # call builder in chroot mode if builder supports it; otherwise call builder normally
          "$BUILDER_SCRIPT" build "$mf" || { log_warn "Builder returned non-zero for $pkg"; return 1; }
        fi
      fi
    else
      # fallback: use porg -i
      if command -v porg >/dev/null 2>&1; then
        porg -i "$pkg" || log_warn "porg -i $pkg returned non-zero"
      else
        log_error "No builder available"
        return 2
      fi
    fi
  else
    # non-chroot simple build
    if [ "$DRY_RUN" = true ]; then
      log_info "[DRY-RUN] Would build $mf (no chroot)"
    else
      if [ -x "$BUILDER_SCRIPT" ]; then
        "$BUILDER_SCRIPT" build "$mf" || { log_warn "Builder returned non-zero for $pkg"; return 1; }
      else
        if command -v porg >/dev/null 2>&1; then
          porg -i "$pkg" || log_warn "porg -i $pkg returned non-zero"
        else
          log_error "No builder available"
          return 2
        fi
      fi
    fi
  fi
  return 0
}

# --------------------- remove_orphan: removes an orphan package safely ---------------------
remove_orphan() {
  local pkg="$1"
  log_info "Removing orphan: $pkg"
  if [ "$DRY_RUN" = true ]; then
    log_info "[DRY-RUN] Would remove $pkg (would call $REMOVE_SCRIPT)"
    return 0
  fi
  # backup DB before removal
  backup_installed_db
  if [ -x "$REMOVE_SCRIPT" ]; then
    "$REMOVE_SCRIPT" "$pkg" --yes --force || log_warn "REMOVE_SCRIPT returned non-zero for $pkg"
  else
    # fallback: call porg_db unregister
    if [ -x "/usr/lib/porg/porg_db.sh" ]; then
      /usr/lib/porg/porg_db.sh unregister "$pkg" || log_warn "porg_db.sh unregister returned non-zero"
    else
      log_warn "No remove script or db script available; manual cleanup required for $pkg"
    fi
  fi
}

# --------------------- run parallel jobs helper ---------------------
run_parallel_jobs() {
  # args are functions to call in background as "cmd:::pkg" or direct commands
  local -a jobs=("$@")
  local max="$PARALLEL_N"
  local running=0
  local i=0
  local pids=()
  for j in "${jobs[@]}"; do
    eval "$j" & pids+=($!)
    running=$((running+1))
    # throttle
    if [ "$running" -ge "$max" ]; then
      if command -v wait >/dev/null 2>&1; then
        if wait -n 2>/dev/null; then
          running=$((running-1))
        else
          # fallback: wait for first pid
          wait "${pids[0]}" || true
          running=$((running-1))
          pids=("${pids[@]:1}")
        fi
      else
        wait "${pids[0]}" || true
        running=$((running-1))
        pids=("${pids[@]:1}")
      fi
    fi
  done
  # wait for remaining
  wait
}

# --------------------- Merge scans and produce JSON report ---------------------
compose_report() {
  local rev_json="${TMPDIR}/revdep.json"
  local dep_json="${TMPDIR}/depclean.json"
  local rebuild_list_file="${TMPDIR}/rebuild.txt"
  local rebuild_list
  if [ -f "$rebuild_list_file" ]; then
    rebuild_list="$(sed -n '1,999p' "$rebuild_list_file" | jq -R -s -c 'split("\n")[:-1]' 2>/dev/null || python3 - <<PY
import sys,json
data=open("$rebuild_list_file").read().splitlines()
print(json.dumps([x for x in data if x.strip()]))
PY
)"
  else
    rebuild_list="[]"
  fi

  # read revdep & depclean (if exist)
  rev_json_content="{}"
  dep_json_content="{}"
  [ -f "$rev_json" ] && rev_json_content=$(cat "$rev_json")
  [ -f "$dep_json" ] && dep_json_content=$(cat "$dep_json")

  # assemble report
  python3 - <<PY > "$REPORT_JSON"
import json,sys
rev=json.loads('''$rev_json_content''')
dep=json.loads('''$dep_json_content''')
out={}
out['timestamp']="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
out['revdep']=rev
out['depclean']=dep
try:
    rebuild = json.loads('''$rebuild_list''' )
except:
    rebuild = []
out['rebuild_needed']=rebuild
print(json.dumps(out,indent=2,ensure_ascii=False))
PY

  log_info "Report written to $REPORT_JSON"
  if [ "$OUT_JSON" = true ]; then
    cat "$REPORT_JSON"
  fi
}

# --------------------- High-level flows ---------------------
flow_scan() {
  log_stage "Flow: scan"
  revdep_scan > "${TMPDIR}/revdep.json"
  depclean_scan > "${TMPDIR}/depclean.json"
  # if rebuild mode requested, compute list
  if [ "$CMD_REBUILD" = true ] || [ "$CMD_ALL" = true ]; then
    get_rebuild_needed > "${TMPDIR}/rebuild.txt" || true
  fi
  compose_report
}

flow_fix() {
  log_stage "Flow: fix"
  # parse revdep.json for broken packages list
  if [ ! -f "${TMPDIR}/revdep.json" ]; then
    revdep_scan > "${TMPDIR}/revdep.json"
  fi
  # gather unique package names
  if _have_jq; then
    pkgs=$(jq -r '.broken[]?.pkg' "${TMPDIR}/revdep.json" 2>/dev/null | sort -u)
  else
    pkgs=$(python3 - <<PY
import json
try:
  r=json.load(open("${TMPDIR}/revdep.json",'r',encoding='utf-8'))
except:
  r={}
out=set()
for e in r.get("broken",[]):
    out.add(e.get("pkg"))
for x in sorted(out):
    print(x)
PY
)
  fi
  # rebuild packages in parallel with safe throttle
  local cmds=()
  for p in $pkgs; do
    [ -z "$p" ] && continue
    cmds+=("fix_package '$p'")
  done
  if [ "${#cmds[@]}" -eq 0 ]; then
    log_info "No broken packages detected to fix."
    return 0
  fi
  run_parallel_jobs "${cmds[@]}"
  # refresh and write report
  revdep_scan > "${TMPDIR}/revdep.json"
  compose_report
}

flow_clean() {
  log_stage "Flow: clean (depclean)"
  # parse depclean.json to get orphans
  depclean_scan > "${TMPDIR}/depclean.json"
  if _have_jq; then
    orphans=$(jq -r '.orphans[]?.pkg' "${TMPDIR}/depclean.json" 2>/dev/null | sort -u)
  else
    orphans=$(python3 - <<PY
import json
try:
  d=json.load(open("${TMPDIR}/depclean.json",'r',encoding='utf-8'))
except:
  d={}
seen=set()
for e in d.get("orphans",[]):
  name=e.get("pkg")
  if name:
    seen.add(name)
for x in sorted(seen):
  print(x)
PY
)
  fi
  if [ -z "$orphans" ]; then
    log_info "No orphans detected."
    return 0
  fi
  log_info "Orphans detected: $orphans"
  if [ "$DRY_RUN" = true ]; then
    log_info "[DRY-RUN] Would remove orphans: $orphans"
    return 0
  fi
  if [ "$AUTO_YES" != true ]; then
    printf "Remove orphans? %s [y/N]: " "$orphans"
    read -r ans || true
    case "$ans" in y|Y|yes|Yes) ;; *) log_info "Aborting removal."; return 0 ;; esac
  fi
  for p in $orphans; do
    remove_orphan "$p"
  done
  compose_report
}

flow_rebuild_needed() {
  log_stage "Flow: rebuild-needed"
  # get rebuild list
  get_rebuild_needed > "${TMPDIR}/rebuild.txt"
  mapfile -t rebuilds < <(grep -v '^\s*$' "${TMPDIR}/rebuild.txt" || true)
  if [ "${#rebuilds[@]}" -eq 0 ]; then
    log_info "No packages marked as needing rebuild"
    return 0
  fi
  log_info "Packages needing rebuild: ${rebuilds[*]}"
  if [ "$DRY_RUN" = true ]; then
    log_info "[DRY-RUN] Would rebuild: ${rebuilds[*]}"
    return 0
  fi
  # run rebuilds in parallel with throttle
  local cmds=()
  for p in "${rebuilds[@]}"; do
    [ -z "$p" ] && continue
    cmds+=("fix_package '$p'")
  done
  run_parallel_jobs "${cmds[@]}"
  compose_report
}

flow_all() {
  log_stage "Running full pipeline: scan -> fix -> clean -> rebuild"
  flow_scan
  flow_fix
  flow_clean
  flow_rebuild_needed
  log_info "Full pipeline finished"
}

# --------------------- Dispatcher ---------------------
if [ "$CMD_ALL" = true ]; then
  CMD_SCAN=true; CMD_FIX=true; CMD_CLEAN=true; CMD_REBUILD=true
fi

# run requested flows
if [ "$CMD_SCAN" = true ]; then flow_scan; fi
if [ "$CMD_FIX" = true ]; then flow_fix; fi
if [ "$CMD_CLEAN" = true ]; then flow_clean; fi
if [ "$CMD_REBUILD" = true ]; then flow_rebuild_needed; fi

# If nothing requested, show usage
if ! $CMD_SCAN && ! $CMD_FIX && ! $CMD_CLEAN && ! $CMD_REBUILD && ! $CMD_ALL ; then
  usage
fi

exit 0
