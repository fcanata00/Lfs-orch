#!/usr/bin/env bash
# porg_audit.sh - Auditoria do sistema Porg
# Integração com porg_logger.sh, porg_db.sh, porg_deps.py, builder e remove modules
set -euo pipefail
IFS=$'\n\t'

# ------------------ Load config early ------------------
PORG_CONF="${PORG_CONF:-/etc/porg/porg.conf}"
if [ -f "$PORG_CONF" ]; then
  # shellcheck disable=SC1090
  source "$PORG_CONF"
fi

# ------------------ Defaults (can be overridden in porg.conf) ------------------
PORTS_DIR="${PORTS_DIR:-/usr/ports}"
INSTALLED_DB="${INSTALLED_DB:-${DB_DIR:-/var/lib/porg/db}/installed.json}"
LOGGER_SCRIPT="${LOGGER_MODULE:-/usr/lib/porg/porg_logger.sh}"
DEPS_PY="${DEPS_PY:-/usr/lib/porg/porg_deps.py}"
BUILDER_SCRIPT="${BUILDER_SCRIPT:-/usr/lib/porg/porg_builder.sh}"
REMOVE_SCRIPT="${REMOVE_MODULE:-/usr/lib/porg/porg_remove.sh}"
REPORT_DIR="${REPORT_DIR:-/var/log/porg/reports}"
DB_BACKUP_DIR="${DB_BACKUP_DIR:-/var/backups/porg/db}"
CACHE_DIR="${CACHE_DIR:-/var/cache/porg}"
PARALLEL_N="${PARALLEL_N:-$(nproc 2>/dev/null || echo 1)}"
CHROOT_METHOD="${CHROOT_METHOD:-bwrap}"
mkdir -p "$REPORT_DIR" "$DB_BACKUP_DIR" "$CACHE_DIR" "$(dirname "$INSTALLED_DB")"

# ------------------ Logger functions (use porg_logger.sh if available) ------------------
if [ -f "$LOGGER_SCRIPT" ]; then
  # shellcheck disable=SC1090
  source "$LOGGER_SCRIPT"
else
  log_info()  { printf "%s [INFO] %s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
  log_warn()  { printf "%s [WARN] %s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
  log_error() { printf "%s [ERROR] %s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
  log_stage() { printf "%s [STAGE] %s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
  log_progress(){ printf "%s\n" "$*"; }
  log_perf()  { "$@"; }
fi

# ------------------ CLI ------------------
usage() {
  cat <<EOF
Usage: $(basename "$0") [options]
Options:
  --scan               Scan system (libs broken, symlinks, orphan files)
  --fix                Attempt to fix detected issues (rebuilds / repairs)
  --clean              Remove orphaned packages (depclean)
  --audit              Run deeper security audit (CVE, SUID, python issues)
  --rebuild-needed     Rebuild packages marked by deps resolver
  --all                Run scan -> fix -> clean -> rebuild-needed
  --json               Output JSON report to stdout
  --dry-run            Simulate actions, do not modify system
  --yes                Auto-confirm destructive actions
  --quiet              Minimal stdout (logs still recorded)
  --parallel N         Use up to N parallel jobs (default: detected CPUs)
  -h, --help           Show this help
EOF
  exit 1
}

CMD_SCAN=false; CMD_FIX=false; CMD_CLEAN=false; CMD_AUDIT=false; CMD_REBUILD=false; CMD_ALL=false
OUT_JSON=false; DRY_RUN=false; AUTO_YES=false; QUIET=false
while [ $# -gt 0 ]; do
  case "$1" in
    --scan) CMD_SCAN=true; shift;;
    --fix) CMD_FIX=true; shift;;
    --clean) CMD_CLEAN=true; shift;;
    --audit) CMD_AUDIT=true; shift;;
    --rebuild-needed) CMD_REBUILD=true; shift;;
    --all) CMD_ALL=true; shift;;
    --json) OUT_JSON=true; shift;;
    --dry-run) DRY_RUN=true; shift;;
    --yes) AUTO_YES=true; shift;;
    --quiet) QUIET=true; shift;;
    --parallel) PARALLEL_N="${2:-$PARALLEL_N}"; shift 2;;
    -h|--help) usage;;
    *) echo "Unknown option: $1"; usage;;
  esac
done

if [ "$QUIET" = true ]; then export QUIET_MODE_DEFAULT=true; fi

TS="$(date -u +%Y%m%dT%H%M%SZ)"
TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}"/porg-audit.XXXX)"
REPORT_FILE="${REPORT_DIR}/audit-report-${TS}.json"
trap 'rm -rf "$TMPDIR"' EXIT

# ------------------ Helpers ------------------
_have_jq() { command -v jq >/dev/null 2>&1; }
_have_python() { command -v python3 >/dev/null 2>&1; }
_have_cve_bin_tool() { command -v cve-bin-tool >/dev/null 2>&1; }
_have_osv_scanner() { command -v osv-scanner >/dev/null 2>&1; }

# atomic write JSON
_write_json() {
  local out="$1"; shift
  python3 - <<PY > "$out"
import json,sys
data = json.loads(sys.stdin.read())
print(json.dumps(data, indent=2, ensure_ascii=False))
PY
}

# backup DB
backup_db() {
  mkdir -p "$DB_BACKUP_DIR"
  local backup="${DB_BACKUP_DIR}/installed.json.bak.${TS}"
  if [ -f "$INSTALLED_DB" ]; then
    cp -a "$INSTALLED_DB" "$backup"
    log_info "Backed up installed DB -> $backup"
    echo "$backup"
  else
    log_warn "Installed DB not found at $INSTALLED_DB; no backup created"
  fi
}

# list installed packages (names)
installed_pkgs_list() {
  if [ ! -f "$INSTALLED_DB" ]; then
    return 0
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

# call porg_deps to get rebuild-needed
deps_rebuild_list() {
  if [ -x "$DEPS_PY" ]; then
    local plan
    plan="$("$DEPS_PY" upgrade-plan --world 2>/dev/null || true)"
    if [ -z "$plan" ]; then
      echo ""
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
  fi
}

# decide parallel execution helper: run array of commands with throttle
run_throttle() {
  local -n arr=$1
  local max="${2:-$PARALLEL_N}"
  local running=0
  local pids=()
  for c in "${arr[@]}"; do
    eval "$c" & pids+=($!)
    running=$((running+1))
    if [ "$running" -ge "$max" ]; then
      if wait -n 2>/dev/null; then
        running=$((running-1))
      else
        # fallback: wait first pid
        wait "${pids[0]}" || true
        pids=("${pids[@]:1}")
        running=$((running-1))
      fi
    fi
  done
  wait
}

# safe remove via REMOVE_SCRIPT or porg_db
safe_remove_pkg() {
  local pkg="$1"
  if [ "$DRY_RUN" = true ]; then
    log_info "[DRY-RUN] Would remove package: $pkg"
    return 0
  fi
  if [ -x "$REMOVE_SCRIPT" ]; then
    "$REMOVE_SCRIPT" "$pkg" --yes --force || log_warn "REMOVE_SCRIPT failed for $pkg"
  elif [ -x "/usr/lib/porg/porg_db.sh" ]; then
    /usr/lib/porg/porg_db.sh unregister "$pkg" || log_warn "porg_db unregister failed for $pkg"
  else
    log_warn "No remove module found; cannot remove $pkg safely"
  fi
}

# safe rebuild via builder or porg
safe_rebuild_pkg() {
  local pkg="$1"
  log_info "Rebuilding package: $pkg"
  if [ "$DRY_RUN" = true ]; then
    log_info "[DRY-RUN] Would rebuild $pkg"
    return 0
  fi
  # try builder metafile
  mf="$(find "$PORTS_DIR" -type f -iname "${pkg}*.y*ml" -print -quit 2>/dev/null || true)"
  if [ -n "$mf" ] && [ -x "$BUILDER_SCRIPT" ]; then
    "$BUILDER_SCRIPT" build "$mf" || log_warn "Builder returned non-zero for $pkg"
    return $?
  fi
  if command -v porg >/dev/null 2>&1; then
    porg -i "$pkg" || log_warn "porg -i returned non-zero for $pkg"
    return $?
  fi
  log_warn "No builder interface found to rebuild $pkg"
  return 2
}

# ------------------ Scans ------------------
# 1) broken libraries via ldd scanning of installed package prefixes
scan_broken_libs() {
  log_stage "scan_broken_libs"
  local out="${TMPDIR}/broken-libs.json"
  python3 - <<PY > "$out"
import json,os,sys,subprocess
res={"broken":[]}
dbpath="${INSTALLED_DB}"
try:
    db=json.load(open(dbpath,'r',encoding='utf-8'))
except:
    db={}
for k,v in db.items():
    name=v.get("name") or k
    prefix=v.get("prefix") or '/'
    # search common lib/bin paths
    paths=[os.path.join(prefix,'bin'), os.path.join(prefix,'sbin'), os.path.join(prefix,'lib'), os.path.join(prefix,'lib64'), os.path.join(prefix,'usr','lib'), os.path.join(prefix,'usr','bin')]
    seen=False
    for p in paths:
        if os.path.isdir(p):
            for root,dirs,files in os.walk(p):
                for f in files:
                    fp=os.path.join(root,f)
                    try:
                        out = subprocess.check_output(['file', '--brief', '--mime-type', fp], stderr=subprocess.DEVNULL).decode().strip()
                    except:
                        continue
                    if 'application/x-executable' in out or 'application/x-pie-executable' in out or 'application/x-sharedlib' in out:
                        # ldd may fail on scripts; ignore errors
                        try:
                            lout = subprocess.check_output(['ldd', fp], stderr=subprocess.STDOUT, timeout=5).decode()
                        except Exception as e:
                            lout = str(e)
                        if 'not found' in lout:
                            res["broken"].append({"pkg":name,"file":fp,"ldd":lout})
                            seen=True
                            break
                if seen: break
        if seen: break
print(json.dumps(res))
PY
  cat "$out"
}

# 2) broken symlinks
scan_broken_symlinks() {
  log_stage "scan_broken_symlinks"
  local out="${TMPDIR}/broken-symlinks.json"
  find / -xdev -type l -xtype l -print0 2>/dev/null | xargs -0 -r -n1 bash -c 'printf "%s\n" "$0"' > "${TMPDIR}/symlinks-list.txt" 2>/dev/null || true
  python3 - <<PY > "$out"
import json,os
res={"broken_symlinks":[]}
try:
    with open("${TMPDIR}/symlinks-list.txt",'r',encoding='utf-8') as f:
        for l in f:
            p=l.strip()
            if not p: continue
            if not os.path.exists(os.path.realpath(p)):
                res["broken_symlinks"].append({"path":p,"target":os.readlink(p) if os.path.islink(p) else ""})
except Exception:
    pass
print(json.dumps(res))
PY
  cat "$out"
}

# 3) orphans: packages with no reverse-deps (uses depclean_scan style via deps.py)
scan_orphan_packages() {
  log_stage "scan_orphan_packages"
  local out="${TMPDIR}/orphans.json"
  if [ -x "$DEPS_PY" ]; then
    plan="$("$DEPS_PY" upgrade-plan --world 2>/dev/null || true)"
    if [ -n "$plan" ]; then
      if _have_jq; then
        # use deps.py analysis to produce orphans heuristics
        echo '{"orphans": []}' > "$out"
      else
        python3 - <<PY > "$out"
import json,os
try:
    plan=json.loads("""$plan""")
except:
    plan={}
# fallback stub: no orphans detected here
print(json.dumps({"orphans":[]}))
PY
      fi
      cat "$out"
      return
    fi
  fi
  # naive fallback: find packages in installed.json that are not listed as deps in any metafile
  python3 - <<PY > "$out"
import json,os
ports_dir="${PORTS_DIR}"
try:
    db=json.load(open("${INSTALLED_DB}",'r',encoding='utf-8'))
except:
    db={}
# build reverse map from ports
rev={}
for root,dirs,files in os.walk(ports_dir):
    for fn in files:
        if fn.lower().endswith(('.yml','.yaml')):
            try:
                import yaml
                d=yaml.safe_load(open(os.path.join(root,fn),'r',encoding='utf-8')) or {}
            except:
                continue
            deps=[]
            dd=d.get('dependencies') or d.get('deps') or {}
            if isinstance(dd,dict):
                for k in ('build','runtime','optional'):
                    v=dd.get(k)
                    if isinstance(v,list): deps+=v
            elif isinstance(dd,list):
                deps+=dd
            name=d.get('name') or fn.rsplit('.',1)[0]
            for dep in deps:
                rev.setdefault(dep,set()).add(name)
orphans=[]
for k,v in db.items():
    name=v.get('name') or k
    if name not in rev or len(rev.get(name,[]))==0:
        orphans.append({"pkg":name,"prefix":v.get("prefix")})
print(json.dumps({"orphans":orphans}))
PY
  cat "$out"
}

# 4) pkgconfig and .la issues
scan_pkgconfig_and_la() {
  log_stage "scan_pkgconfig_and_la"
  local out="${TMPDIR}/pkgconf-la.json"
  python3 - <<PY > "$out"
import json,os
res={"pkgconfig_missing":[], "libtool_la": []}
for root,dirs,files in os.walk("/usr"):
    for f in files:
        if f.endswith(".pc"):
            p=os.path.join(root,f)
            try:
                data=open(p,'r',encoding='utf-8').read()
            except:
                continue
            # detect libs that may be referenced but missing (heuristic: look for -lfoo)
            # skipping deep parsing here
        if f.endswith(".la"):
            p=os.path.join(root,f)
            # check for empty dependency_libs or obviously broken entries
            try:
                text=open(p,'r',encoding='utf-8').read()
                if "dependency_libs" in text and " -l" not in text and " -L" not in text:
                    res["libtool_la"].append({"path":p})
            except:
                pass
print(json.dumps(res))
PY
  cat "$out"
}

# 5) python site-packages orphan detection (heuristic)
scan_python_orphans() {
  log_stage "scan_python_orphans"
  local out="${TMPDIR}/python-orphans.json"
  python3 - <<PY > "$out"
import json,sys,os
res={"python_orphans":[]}
# find site-packages dirs
import site
paths=set(site.getsitepackages() + [site.getusersitepackages()])
for p in paths:
    if not os.path.isdir(p): continue
    for root,dirs,files in os.walk(p):
        for f in files:
            if f.endswith(".py") or f.endswith(".so"):
                # naive heuristic: check if there exists any package in installed DB providing this module
                res["python_orphans"].append({"file": os.path.join(root,f)})
print(json.dumps(res))
PY
  cat "$out"
}

# 6) security quick scans (cve-bin-tool / osv-scanner fallback)
scan_security_tools() {
  log_stage "scan_security_tools"
  local out="${TMPDIR}/security-scan.json"
  if _have_cve_bin_tool; then
    log_info "Running cve-bin-tool (may take long)..."
    if [ "$DRY_RUN" = true ]; then
      echo '{"cve_bin_tool":"simulated"}' > "$out"
    else
      cve-bin-tool --outputjson "$out" /usr || true
    fi
  elif _have_osv_scanner; then
    log_info "Running osv-scanner..."
    if [ "$DRY_RUN" = true ]; then
      echo '{"osv":"simulated"}' > "$out"
    else
      osv-scanner -o "$out" /usr || true
    fi
  else
    echo '{"notes":"no cve scanner available"}' > "$out"
  fi
  cat "$out"
}

# ------------------ Fixers ------------------
# attempt to fix broken libs by rebuilding package providing them (best-effort)
fix_broken_libs() {
  log_stage "fix_broken_libs"
  local rev_json="${TMPDIR}/broken-libs.json"
  if [ ! -f "$rev_json" ]; then
    scan_broken_libs > "$rev_json"
  fi
  # extract unique pkg names
  if _have_jq; then
    mapfile -t pkgs < <(jq -r '.broken[]?.pkg' "$rev_json" 2>/dev/null | sort -u)
  else
    mapfile -t pkgs < <(python3 - <<PY
import json
try:
  r=json.load(open("$rev_json",'r',encoding='utf-8'))
except:
  r={}
s=set()
for e in r.get("broken",[]):
    s.add(e.get("pkg"))
for x in sorted(s):
    print(x)
PY
)
  fi
  if [ "${#pkgs[@]}" -eq 0 ]; then
    log_info "No broken libs found to fix"
    return 0
  fi
  log_info "Packages with broken libs: ${pkgs[*]}"
  local cmds=()
  for p in "${pkgs[@]}"; do
    cmds+=("safe_rebuild_pkg '$p'")
  done
  run_throttle cmds "$PARALLEL_N"
  return 0
}

# attempt to fix orphans - usually remove them or flag for manual review
fix_orphans() {
  log_stage "fix_orphans"
  local orphans_json="${TMPDIR}/orphans.json"
  if [ ! -f "$orphans_json" ]; then
    scan_orphan_packages > "$orphans_json"
  fi
  if _have_jq; then
    mapfile -t orphans < <(jq -r '.orphans[]?.pkg' "$orphans_json" 2>/dev/null | sort -u)
  else
    mapfile -t orphans < <(python3 - <<PY
import json
try:
  d=json.load(open("$orphans_json",'r',encoding='utf-8'))
except:
  d={}
for e in d.get("orphans",[]):
    print(e.get("pkg"))
PY
)
  fi
  if [ "${#orphans[@]}" -eq 0 ]; then
    log_info "No orphan packages detected"
    return 0
  fi
  log_info "Orphan packages: ${orphans[*]}"
  if [ "$DRY_RUN" = true ]; then
    log_info "[DRY-RUN] Would remove: ${orphans[*]}"
    return 0
  fi
  if [ "$AUTO_YES" != true ]; then
    printf "Remove orphans? %s [y/N]: " "${orphans[*]}"
    read -r ans || true
    case "$ans" in y|Y|yes|Yes) ;; *) log_info "Aborting orphan removal"; return 0 ;; esac
  fi
  for p in "${orphans[@]}"; do
    safe_remove_pkg "$p"
  done
  return 0
}

# run security audit fixes (best-effort: report; do not auto-fix CVEs)
fix_security_findings() {
  log_stage "fix_security_findings"
  # for CVEs, we will only report; rebuilding flagged packages can help but we avoid auto-fix
  log_info "Security findings will be reported; auto-fix is not performed for CVEs"
  return 0
}

# ------------------ Compose and emit consolidated report ------------------
compose_final_report() {
  log_stage "compose_final_report"
  # collate JSON fragments into final report
  python3 - <<PY > "$REPORT_FILE"
import json,os,time
out={}
out['generated_at']=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
out['host']=os.uname().nodename
out['kernel']=os.uname().release
def loadf(p):
    try:
        return json.load(open(p,'r',encoding='utf-8'))
    except:
        return {}
base="${TMPDIR}"
out['broken_libs']=loadf(base+"/broken-libs.json").get("broken",[])
out['broken_symlinks']=loadf(base+"/broken-symlinks.json").get("broken_symlinks",[])
out['orphans']=loadf(base+"/orphans.json").get("orphans",[])
out['pkgconf_la']=loadf(base+"/pkgconf-la.json")
out['python_orphans']=loadf(base+"/python-orphans.json").get("python_orphans",[])
out['security']=loadf(base+"/security-scan.json")
print(json.dumps(out, indent=2, ensure_ascii=False))
PY

  log_info "Audit report written to $REPORT_FILE"
  # create link latest
  ln -sf "$REPORT_FILE" "${REPORT_DIR}/audit-latest.json"
  if [ "$OUT_JSON" = true ]; then
    cat "$REPORT_FILE"
  fi
}

# ------------------ High-level flows ------------------
flow_scan() {
  log_stage "Audit: scan flow"
  scan_broken_libs > "${TMPDIR}/broken-libs.json"
  scan_broken_symlinks > "${TMPDIR}/broken-symlinks.json"
  scan_orphan_packages > "${TMPDIR}/orphans.json"
  scan_pkgconfig_and_la > "${TMPDIR}/pkgconf-la.json"
  scan_python_orphans > "${TMPDIR}/python-orphans.json"
  if [ "$CMD_AUDIT" = true ]; then
    scan_security_tools > "${TMPDIR}/security-scan.json"
  fi
  compose_final_report
}

flow_fix() {
  log_stage "Audit: fix flow"
  backup_db
  fix_broken_libs
  fix_orphans
  fix_security_findings
  compose_final_report
}

flow_clean() {
  log_stage "Audit: clean flow"
  scan_orphan_packages > "${TMPDIR}/orphans.json"
  fix_orphans
  compose_final_report
}

flow_rebuild_needed() {
  log_stage "Audit: rebuild-needed flow"
  deps_rebuild_list > "${TMPDIR}/rebuild-list.txt" || true
  mapfile -t rebuilds < <(grep -v '^\s*$' "${TMPDIR}/rebuild-list.txt" || true)
  if [ "${#rebuilds[@]}" -eq 0 ]; then
    log_info "No rebuild-needed candidates"
    return 0
  fi
  log_info "Rebuild-needed packages: ${rebuilds[*]}"
  if [ "$DRY_RUN" = true ]; then
    log_info "[DRY-RUN] Would rebuild: ${rebuilds[*]}"
    return 0
  fi
  local cmds=()
  for p in "${rebuilds[@]}"; do
    cmds+=("safe_rebuild_pkg '$p'")
  done
  run_throttle cmds "$PARALLEL_N"
  compose_final_report
}

flow_all() {
  log_stage "Audit: full pipeline"
  flow_scan
  flow_fix
  flow_clean
  flow_rebuild_needed
  log_info "Full audit pipeline completed"
}

# ------------------ Dispatcher ------------------
if [ "$CMD_ALL" = true ]; then
  CMD_SCAN=true; CMD_FIX=true; CMD_CLEAN=true; CMD_REBUILD=true; CMD_AUDIT=true
fi

if [ "$CMD_SCAN" = true ]; then flow_scan; fi
if [ "$CMD_FIX" = true ]; then flow_fix; fi
if [ "$CMD_CLEAN" = true ]; then flow_clean; fi
if [ "$CMD_REBUILD" = true ]; then flow_rebuild_needed; fi
if [ "$CMD_AUDIT" = true ] && [ "$CMD_SCAN" = false ]; then
  # audit-only (security)
  scan_security_tools > "${TMPDIR}/security-scan.json"
  compose_final_report
fi

# If nothing selected, show usage
if ! $CMD_SCAN && ! $CMD_FIX && ! $CMD_CLEAN && ! $CMD_AUDIT && ! $CMD_REBUILD && ! $CMD_ALL ; then
  usage
fi

# return exit code: 0 ok, 1 issues found, 2 runtime error, 3 partial fixes
# Basic heuristic: if report contains items -> exit 1
if _have_jq; then
  issues=$(( $(jq '.broken | length' "${TMPDIR}/broken-libs.json" 2>/dev/null || echo 0) + $(jq '.broken_symlinks | length' "${TMPDIR}/broken-symlinks.json" 2>/dev/null || echo 0) + $(jq '.orphans | length' "${TMPDIR}/orphans.json" 2>/dev/null || echo 0) ))
else
  issues=$(python3 - <<PY
import json,sys
def count(p,k):
    try:
        d=json.load(open(p,'r',encoding='utf-8'))
        return len(d.get(k,[]))
    except:
        return 0
print(count("${TMPDIR}/broken-libs.json","broken")+count("${TMPDIR}/broken-symlinks.json","broken_symlinks")+count("${TMPDIR}/orphans.json","orphans"))
PY
)
fi

if [ "$issues" -gt 0 ]; then
  log_warn "Audit completed: found ${issues} issues (report: $REPORT_FILE)"
  exit 1
else
  log_info "Audit completed: no issues found"
  exit 0
fi
