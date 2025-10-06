#!/usr/bin/env bash
#
# porg_audit.sh
# Auditoria do sistema Porg: detecta e tenta corrigir problemas (libs faltando, symlinks quebrados,
# orphans, problemas python, libtool .la, toolchain, scanners de CVE etc.)
#
# Integração esperada:
# - porg_logger.sh (log colorido)
# - porg_db.sh (installed DB)
# - deps.py (resolver)
# - porg-resolve (revdep/depclean)
# - porg_remove.sh (remoção segura)
# - porg-upgrade.sh / porg (atualização)
#
# Uso:
#   porg_audit.sh --scan [--fix] [--dry-run] [--json] [--report <file>] [--quiet] [--yes]
#
set -euo pipefail
IFS=$'\n\t'

# -------------------- Config / Paths (sobrescrevíveis por env ou porg.conf) --------------------
PORG_CONF="${PORG_CONF:-/etc/porg/porg.conf}"
LOGGER_SCRIPT="${LOGGER_SCRIPT:-/usr/lib/porg/porg_logger.sh}"
DB_SCRIPT="${DB_SCRIPT:-/usr/lib/porg/porg_db.sh}"
DEPS_PY="${DEPS_PY:-/usr/lib/porg/deps.py}"
RESOLVE_CMD="${RESOLVE_CMD:-/usr/lib/porg/porg-resolve}"
REMOVE_SCRIPT="${REMOVE_SCRIPT:-/usr/lib/porg/porg_remove.sh}"
UPGRADE_CMD="${UPGRADE_CMD:-/usr/lib/porg/porg-upgrade}"
PORG_WRAPPER="${PORG_WRAPPER:-porg}"   # wrapper 'porg' if available
INSTALLED_DB="${INSTALLED_DB:-/var/db/porg/installed.json}"
REPORT_DIR="${REPORT_DIR:-/var/log/porg}"
DEFAULT_REPORT="${REPORT_DIR}/audit-$(date -u +%Y%m%dT%H%M%SZ).log"

# run flags
DO_SCAN=false
DO_FIX=false
DRY_RUN=false
QUIET=false
AUTO_YES=false
OUTPUT_JSON=false
REPORT_FILE=""

PARALLEL="$(nproc 2>/dev/null || echo 1)"

# ensure dirs
mkdir -p "${REPORT_DIR}" "$(dirname "${INSTALLED_DB}")"

# -------------------- Helpers --------------------
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

# source logger if exists
if [ -f "$LOGGER_SCRIPT" ]; then
  # shellcheck disable=SC1090
  source "$LOGGER_SCRIPT"
else
  log() { local L="$1"; shift; printf "[%s] %s\n" "$L" "$*"; }
  log_section() { printf "=== %s ===\n" "$*"; }
fi

# minimal json write
dump_json() {
  python3 - <<PY
import json,sys
obj=$1
print(json.dumps(obj,ensure_ascii=False,indent=2))
PY
}

# parse args
usage() {
  cat <<EOF
Usage: ${0##*/} --scan [--fix] [--dry-run] [--report <file>] [--json] [--quiet] [--yes]
Options:
  --scan       Run full audit (required)
  --fix        Attempt to auto-fix issues found
  --dry-run    Show actions that would be taken (no changes)
  --report     Save human-readable report to file (default: ${DEFAULT_REPORT})
  --json       Emit JSON to stdout (in addition to report)
  --quiet      Minimal stdout (logs still written)
  --yes        Assume yes for all prompts
  -h,--help    Show this help
EOF
}

if [ "$#" -eq 0 ]; then usage; exit 1; fi

while [ "$#" -gt 0 ]; do
  case "$1" in
    --scan) DO_SCAN=true; shift ;;
    --fix) DO_FIX=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --report) REPORT_FILE="${2:-$DEFAULT_REPORT}"; shift 2 ;;
    --json) OUTPUT_JSON=true; shift ;;
    --quiet) QUIET=true; shift ;;
    --yes) AUTO_YES=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1"; usage; exit 2 ;;
  esac
done

[ "${DO_SCAN}" = true ] || { echo "Error: --scan is required"; usage; exit 2; }

if [ -z "$REPORT_FILE" ]; then REPORT_FILE="$DEFAULT_REPORT"; fi
TMP_REPORT="$(mktemp /tmp/porg_audit.XXXXXX)"
TMP_JSON="$(mktemp /tmp/porg_audit_json.XXXXXX)"
trap 'rm -f "$TMP_REPORT" "$TMP_JSON"' EXIT

_log() {
  local lvl="$1"; shift
  if [ "$QUIET" = true ] && [ "$lvl" != "ERROR" ]; then
    log "$lvl" "$@" >/dev/null 2>&1 || true
  else
    log "$lvl" "$@"
  fi
  printf "[%s] %s\n" "$lvl" "$*" >>"$TMP_REPORT"
}

# load list of installed package prefixes from DB
load_installed_prefixes() {
  python3 - <<PY
import json,sys
dbp=sys.argv[1]
try:
  db=json.load(open(dbp,'r',encoding='utf-8'))
except:
  db={}
out=[]
for k,v in db.items():
  p=v.get('prefix')
  if p:
    out.append(p)
print("\\n".join(out))
PY
  "$INSTALLED_DB"
}

# helper: identify package owning a given file by comparing prefixes
find_pkg_for_path() {
  local path="$1"
  # iterate installed prefixes and check if path startswith prefix
  python3 - <<PY
import sys, json, os
pfile=sys.argv[1]
dbp=sys.argv[2]
try:
  db=json.load(open(dbp,'r',encoding='utf-8'))
except:
  db={}
candidates=[]
for k,v in db.items():
  pref=v.get('prefix')
  if pref and pfile.startswith(pref.rstrip('/') + '/'):
    candidates.append(k)
if candidates:
  print(candidates[0])
else:
  print("")
PY
  "$path" "$INSTALLED_DB"
}

# -------------------- SCAN: broken ELF libs --------------------
scan_broken_libs() {
  _log STAGE "Scanning ELF files for missing shared libraries (ldd ... 'not found')"
  local search_dirs=(/usr/bin /usr/sbin /usr/lib /usr/lib64 /usr/local/bin /usr/local/lib /opt)
  local -a elfs=()
  for d in "${search_dirs[@]}"; do
    [ -d "$d" ] || continue
    while IFS= read -r f; do
      # skip large traversal if non-regular
      [ -f "$f" ] || continue
      # check magic for ELF
      if file -b --mime-type "$f" 2>/dev/null | grep -q "application/x-executable\|application/x-sharedlib\|application/x-pie-executable"; then
        elfs+=("$f")
      fi
    done < <(find "$d" -type f -perm /111 -print 2>/dev/null || true)
  done

  printf "" > "$TMP_JSON"
  missing_count=0
  for e in "${elfs[@]}"; do
    # run ldd safely
    out="$(ldd "$e" 2>/dev/null || true)"
    if printf "%s" "$out" | grep -q "not found"; then
      missing_count=$((missing_count+1))
      # collect missing libs
      missing="$(printf "%s" "$out" | grep "not found" | awk '{print $1}' | tr '\n' ',' | sed 's/,$//')"
      _log WARN "ELF missing libs: $e -> $missing"
      # attempt to attribute to a package
      owner="$(find_pkg_for_path "$e" || true)"
      if [ -n "$owner" ]; then
        _log INFO "Binary $e appears to belong to package $owner"
      else
        _log DEBUG "No package owner found for $e"
      fi
      # write JSON entry
      python3 - <<PY >>"$TMP_JSON"
import json,sys
entry={"type":"broken-lib","file":"$e","missing":"$missing","owner":"$owner"}
print(json.dumps(entry,ensure_ascii=False))
PY
    fi
  done

  _log INFO "Broken-ELF scan complete: ${missing_count} binaries with missing libs"
  return 0
}

# -------------------- SCAN: broken symlinks --------------------
scan_broken_symlinks() {
  _log STAGE "Scanning for broken symbolic links (common system paths)"
  local search_dirs=(/usr /bin /lib /lib64 /sbin /opt /usr/local)
  broken_links_file="$(mktemp)"
  find "${search_dirs[@]}" -type l -print 2>/dev/null | while IFS= read -r s; do
    target="$(readlink -f "$s" 2>/dev/null || true)"
    if [ -z "$target" ] || [ ! -e "$target" ]; then
      echo "$s" >> "$broken_links_file"
      _log WARN "Broken symlink: $s -> $target"
    fi
  done
  if [ -s "$broken_links_file" ]; then
    while IFS= read -r l; do
      python3 - <<PY >>"$TMP_JSON"
import json
print(json.dumps({"type":"broken-symlink","path":"$l"},ensure_ascii=False))
PY
    done <"$broken_links_file"
  fi
  rm -f "$broken_links_file"
}

# -------------------- SCAN: libtool .la files --------------------
scan_libtool_la() {
  _log STAGE "Scanning for libtool .la files (may cause link-time problems)"
  found=0
  while IFS= read -r la; do
    found=$((found+1))
    _log WARN "Found .la (libtool) file: $la"
    owner="$(find_pkg_for_path "$la" || true)"
    _log DEBUG "Owner: ${owner:-(none)}"
    python3 - <<PY >>"$TMP_JSON"
import json
print(json.dumps({"type":"libtool-la","path":"$la","owner":"${owner:-}"} , ensure_ascii=False))
PY
  done < <(find /usr /usr/local /opt -name '*.la' 2>/dev/null || true)
  _log INFO "libtool .la scan complete: ${found} found"
}

# -------------------- SCAN: orphan files (not under registered prefixes) --------------------
scan_orphans() {
  _log STAGE "Scanning for files outside registered package prefixes (candidate orphans)"
  # load prefixes
  prefixes="$(load_installed_prefixes || true)"
  # inspect common local install trees for orphan content
  search_dirs=(/usr/local /opt /srv /var/local)
  orphan_tmp="$(mktemp)"
  for d in "${search_dirs[@]}"; do
    [ -d "$d" ] || continue
    # find files (limit depth to avoid very long scans)
    find "$d" -mindepth 1 -maxdepth 4 -print 2>/dev/null | while IFS= read -r p; do
      keep=false
      while IFS= read -r pref; do
        [ -z "$pref" ] && continue
        # normalize
        if printf "%s" "$p" | grep -q "^${pref%/}/"; then
          keep=true; break
        fi
      done <<< "$prefixes"
      if [ "$keep" = false ]; then
        echo "$p" >> "$orphan_tmp"
      fi
    done
  done
  # dedupe
  sort -u "$orphan_tmp" -o "$orphan_tmp"
  if [ -s "$orphan_tmp" ]; then
    _log WARN "Potential orphan files found (first 20 shown):"
    head -n20 "$orphan_tmp" | sed 's/^/  /' | tee -a "$TMP_REPORT"
    while IFS= read -r o; do
      python3 - <<PY >>"$TMP_JSON"
import json
print(json.dumps({"type":"orphan","path":"$o"},ensure_ascii=False))
PY
    done <"$orphan_tmp"
  else
    _log INFO "No obvious orphans found under ${search_dirs[*]}"
  fi
  rm -f "$orphan_tmp"
}

# -------------------- SCAN: python problems --------------------
scan_python() {
  _log STAGE "Scanning Python environments (pip check) when possible"
  # find python3 interpreters (common)
  pythons=(/usr/bin/python3 /usr/local/bin/python3 /usr/bin/python)
  found=0
  for py in "${pythons[@]}"; do
    [ -x "$py" ] || continue
    # check pip
    if "$py" -m pip >/dev/null 2>&1; then
      found=$((found+1))
      out="$("$py" -m pip check 2>&1 || true)"
      if printf "%s" "$out" | grep -q "No broken"; then
        _log INFO "pip check OK for $py"
      elif [ -n "$out" ]; then
        _log WARN "pip check issues for $py:"
        printf "%s\n" "$out" | sed 's/^/  /' | tee -a "$TMP_REPORT"
        python3 - <<PY >>"$TMP_JSON"
import json
print(json.dumps({"type":"python-pip-check","python":"$py","output":${out!}} , ensure_ascii=False))
PY
      fi
    fi
  done
  if [ "$found" -eq 0 ]; then
    _log DEBUG "No python/pip found to run pip check"
  fi
}

# -------------------- SCAN: toolchain / gcc issues --------------------
scan_toolchain() {
  _log STAGE "Checking for GCC/toolchain anomalies (multiple versions, missing symlinks)"
  if command -v gcc >/dev/null 2>&1; then
    gccver="$(gcc --version 2>/dev/null | head -n1)"
    _log INFO "gcc detected: ${gccver}"
  else
    _log WARN "gcc not found in PATH"
  fi
  # check for multiple installed gcc prefixes in DB
  python3 - <<PY >>"$TMP_JSON"
import json
dbp="$INSTALLED_DB"
try:
  db=json.load(open(dbp,'r',encoding='utf-8'))
except:
  db={}
gccs=[]
for k,v in db.items():
  if k.startswith('gcc') or v.get('name','').lower().startswith('gcc'):
    gccs.append(k)
if gccs:
  for g in gccs:
    print(json.dumps({"type":"gcc-installed","pkg":g},ensure_ascii=False))
PY
  _log INFO "Toolchain scan complete"
}

# -------------------- SCAN: vulnerability scanners (SVE/CVE) --------------------
scan_vulns() {
  _log STAGE "Attempting vulnerability scan (using installed scanners if available)"
  if command -v sve >/dev/null 2>&1; then
    _log INFO "Running 'sve' scanner (if available)"
    if [ "$DRY_RUN" = false ]; then
      sve --output json --quiet >/tmp/porg_sve.json 2>/dev/null || true
      [ -f /tmp/porg_sve.json ] && jq . /tmp/porg_sve.json >>"$TMP_JSON" 2>/dev/null || true
    else
      _log INFO "[dry-run] would run 'sve' scanner"
    fi
    return 0
  fi
  if command -v cve-bin-tool >/dev/null 2>&1; then
    _log INFO "Running cve-bin-tool (may take long)"
    if [ "$DRY_RUN" = false ]; then
      cve-bin-tool --format json -o /tmp/porg_cve.json /usr 2>/dev/null || true
      [ -f /tmp/porg_cve.json ] && jq . /tmp/porg_cve.json >>"$TMP_JSON" 2>/dev/null || true
    else
      _log INFO "[dry-run] would run cve-bin-tool"
    fi
    return 0
  fi
  if command -v python3 >/dev/null 2>&1 && python3 -c "import osv" >/dev/null 2>&1; then
    _log INFO "OSV/python support present — running lightweight checks not implemented automatically (use manual mode)"
    # not implemented heavy scan
  else
    _log WARN "No vulnerability scanner (sve / cve-bin-tool / osv) found; skipping CVE scan"
  fi
}

# -------------------- AUTO-FIX actions (best-effort) --------------------
# NOTE: all fixers respect DRY_RUN and AUTO_YES

fix_broken_libs() {
  _log STAGE "Attempting to fix missing library issues (best-effort)"
  # read entries from TMP_JSON with type broken-lib
  python3 - <<PY
import json,sys
from pathlib import Path
f=sys.argv[1]
try:
  lines=open(f).read().splitlines()
except:
  lines=[]
items=[]
for line in lines:
  if not line.strip(): continue
  try:
    obj=json.loads(line)
  except:
    continue
  if obj.get('type')=='broken-lib':
    items.append(obj)
print(json.dumps(items))
PY
  "$TMP_JSON" > /tmp/porg_audit_brokenlibs.json || true

  # iterate and attempt to repair: if owner known, attempt to reinstall via porg
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    pkg="$(python3 -c "import json,sys;print(json.loads(sys.stdin.read())[0].get('owner',''))" <<<"$line" 2>/dev/null || true)"
    file="$(python3 -c "import json,sys;print(json.loads(sys.stdin.read())[0].get('file',''))" <<<"$line" 2>/dev/null || true)"
    missing="$(python3 -c "import json,sys;print(json.loads(sys.stdin.read())[0].get('missing',''))" <<<"$line" 2>/dev/null || true)"
    # decide action
    if [ -n "$pkg" ]; then
      _log INFO "Trying to rebuild/install owner package $pkg to restore libs for $file"
      if [ "$DRY_RUN" = true ]; then
        _log INFO "[dry-run] would run: ${PORG_WRAPPER} -i $pkg"
        continue
      fi
      if command -v "$PORG_WRAPPER" >/dev/null 2>&1; then
        _log INFO "Invoking: ${PORG_WRAPPER} -i $pkg"
        $PORG_WRAPPER -i "$pkg" || _log WARN "porg wrapper failed for $pkg"
      elif [ -x "$UPGRADE_CMD" ]; then
        _log INFO "Invoking: $UPGRADE_CMD --pkg $pkg"
        "$UPGRADE_CMD" --pkg "$pkg" || _log WARN "porg-upgrade failed for $pkg"
      else
        _log WARN "No porg wrapper or upgrade script found — cannot auto-rebuild $pkg"
      fi
    else
      # owner unknown: try porg-resolve to rebuild possible dependents
      if [ -x "$RESOLVE_CMD" ]; then
        _log INFO "Owner unknown for $file. Invoking porg-resolve --fix to attempt system-wide repair"
        if [ "$DRY_RUN" = false ]; then
          "$RESOLVE_CMD" --fix || _log WARN "porg-resolve --fix returned non-zero"
        else
          _log INFO "[dry-run] would run: $RESOLVE_CMD --fix"
        fi
      else
        _log WARN "Owner unknown and porg-resolve not available; manual investigation required for $file (missing libs: $missing)"
      fi
    fi
  done < <(jq -c '.[]' /tmp/porg_audit_brokenlibs.json 2>/dev/null || true)
}

fix_broken_symlinks() {
  _log STAGE "Fixing broken symlinks (remove or re-create if possible)"
  # list broken symlinks previously detected (in TMP_REPORT)
  while IFS= read -r s; do
    [ -z "$s" ] && continue
    _log INFO "Considering broken symlink: $s"
    if [ "$DRY_RUN" = true ]; then
      _log INFO "[dry-run] would remove $s"
      continue
    fi
    if [ "$AUTO_YES" = true ]; then
      rm -f -- "$s" && _log INFO "Removed $s"
    else
      if confirm "Remove broken symlink $s?"; then
        rm -f -- "$s" && _log INFO "Removed $s"
      else
        _log INFO "Skipped $s"
      fi
    fi
  done < <(grep '"broken-symlink"' -n "$TMP_REPORT" 2>/dev/null | cut -d: -f1 || true)
}

fix_orphans() {
  _log STAGE "Handling orphan files (best-effort)"
  # read orphans from TMP_REPORT (we stored them earlier)
  # Instead of risking mass deletion, propose to call porg_remove for orphan packages if safe
  # If orphan is a directory, propose manual removal or archive
  _log INFO "Orphan handling: listing orphans and suggesting removal. Auto-removal only with --fix --yes"
  # parse TMP_JSON for 'orphan' entries
  jq -r 'select(.type=="orphan") | .path' "$TMP_JSON" 2>/dev/null | while IFS= read -r p; do
    [ -z "$p" ] && continue
    _log WARN "Orphan candidate: $p"
    if [ "$DRY_RUN" = true ]; then
      _log INFO "[dry-run] would consider removal of $p"
      continue
    fi
    if [ "$AUTO_YES" = true ]; then
      rm -rf -- "$p" && _log INFO "Removed orphan $p" || _log WARN "Failed to remove $p"
    else
      if confirm "Remove orphan $p?"; then
        rm -rf -- "$p" && _log INFO "Removed orphan $p" || _log WARN "Failed to remove $p"
      else
        _log INFO "Skipped orphan $p"
      fi
    fi
  done
}

fix_python_issues() {
  _log STAGE "Attempting to fix Python environment issues (pip check)"
  # attempt to run pip check and pip install --upgrade for problematic packages
  if command -v python3 >/dev/null 2>&1; then
    if python3 -m pip >/dev/null 2>&1; then
      out="$(python3 -m pip check 2>&1 || true)"
      if [ -n "$out" ]; then
        _log WARN "pip check reported issues: $out"
        # try to parse package names and attempt upgrade
        pkgs="$(python3 - <<PY
import re,sys
s=sys.stdin.read()
names=set()
for line in s.splitlines():
  m=re.match(r'([^ ]+)',line)
  if m:
    names.add(m.group(1))
print(" ".join(names))
PY
)"
        if [ -n "$pkgs" ]; then
          for p in $pkgs; do
            _log INFO "Attempting pip install --upgrade $p"
            if [ "$DRY_RUN" = true ]; then
              _log INFO "[dry-run] pip install --upgrade $p"
            else
              python3 -m pip install --upgrade "$p" || _log WARN "pip upgrade failed for $p"
            fi
          done
        fi
      else
        _log INFO "pip check: no issues detected"
      fi
    else
      _log DEBUG "pip not available for system python3"
    fi
  fi
}

fix_vulns_actions() {
  _log STAGE "Attempting to remediate vulnerable packages reported by scanners"
  # If TMP_JSON contains entries from scanners, attempt to upgrade packages listed
  # Look for keys that indicate package names in known scanner outputs — best-effort.
  if [ "$DRY_RUN" = true ]; then
    _log INFO "[dry-run] would try to call porg-upgrade for vulnerable packages found"
    return
  fi
  # Example: cve-bin-tool or sve outputs may contain 'package' or 'path' - try to extract package names and call porg-upgrade
  jq -r 'select(.type=="vulnerability" or .package) | .package // .path // empty' "$TMP_JSON" 2>/dev/null | sort -u | while IFS= read -r item; do
    [ -z "$item" ] && continue
    # if item looks like a path, try find_pkg_for_path
    if [ -f "$item" ]; then
      pkg="$(find_pkg_for_path "$item" || true)"
    else
      pkg="$item"
    fi
    if [ -n "$pkg" ]; then
      _log INFO "Attempting to upgrade vulnerable package: $pkg"
      if command -v "$PORG_WRAPPER" >/dev/null 2>&1; then
        $PORG_WRAPPER -i "$pkg" || _log WARN "porg wrapper failed to upgrade $pkg"
      elif [ -x "$UPGRADE_CMD" ]; then
        "$UPGRADE_CMD" --pkg "$pkg" || _log WARN "porg-upgrade failed for $pkg"
      else
        _log WARN "No upgrade mechanism available for $pkg"
      fi
    fi
  done
}

# -------------------- Orchestrator --------------------
_log STAGE "Starting Porg audit: scan=$(date -u +%Y-%m-%dT%H:%M:%SZ) fix=${DO_FIX} dryrun=${DRY_RUN}"

# run scans
scan_broken_libs
scan_broken_symlinks
scan_libtool_la
scan_orphans
scan_python
scan_toolchain
scan_vulns

# assemble JSON report lines into an array
# TMP_JSON contains per-line JSON entries; convert to array
if [ -f "$TMP_JSON" ] && [ -s "$TMP_JSON" ]; then
  python3 - <<PY >"${TMP_JSON}.arr"
import json,sys
items=[]
for line in open(sys.argv[1],'r',encoding='utf-8').read().splitlines():
  try:
    items.append(json.loads(line))
  except:
    pass
print(json.dumps(items,ensure_ascii=False))
PY
  mv "${TMP_JSON}.arr" "$TMP_JSON"
else
  echo "[]" > "$TMP_JSON"
fi

# write human-readable report
{
  echo "Porg Audit Report - $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  cat "$TMP_REPORT"
  echo
  echo "JSON summary (first 2000 chars):"
  head -c 2000 "$TMP_JSON" || true
} > "$REPORT_FILE"

_log INFO "Audit report saved to $REPORT_FILE"

# optionally output JSON to stdout
if [ "$OUTPUT_JSON" = true ]; then
  cat "$TMP_JSON"
fi

# fixes (best-effort) if requested
if [ "$DO_FIX" = true ]; then
  _log STAGE "Attempting automatic fixes (best-effort) -- DRY_RUN=${DRY_RUN}"
  fix_broken_libs
  fix_broken_symlinks
  fix_orphans
  fix_python_issues
  fix_vulns_actions
  _log INFO "Auto-fix attempt completed (check logs and report)"
fi

_log INFO "Porg audit complete"
exit 0
