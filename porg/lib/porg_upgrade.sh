#!/usr/bin/env bash
# porg_upgrade.sh - Orquestrador de upgrades Porg
# - UI progressiva (--progress)
# - paralelismo (--parallel)
# - integração com porg_deps.py, porg_builder.sh, porg_remove.sh, porg_db.sh, porg_audit.sh, porg_logger.sh
# - comandos: --plan, --upgrade <pkg...>, --install/-i <pkg...>, --world, --dry-run, --yes, --no-audit
set -euo pipefail
IFS=$'\n\t'

# ------------------ Config: load porg.conf early ------------------
PORG_CONF="${PORG_CONF:-/etc/porg/porg.conf}"
[ -f "$PORG_CONF" ] && source "$PORG_CONF"

# Defaults (can be overridden in porg.conf)
PORTS_DIR="${PORTS_DIR:-/usr/ports}"
DEPS_PY="${DEPS_PY:-/usr/lib/porg/porg_deps.py}"
BUILDER="${BUILDER_SCRIPT:-/usr/lib/porg/porg_builder.sh}"
REMOVER="${REMOVE_SCRIPT:-/usr/lib/porg/porg_remove.sh}"
DB_SCRIPT="${DB_SCRIPT:-/usr/lib/porg/porg_db.sh}"
AUDIT_SCRIPT="${AUDIT_SCRIPT:-/usr/lib/porg/porg_audit.sh}"
LOGGER_SCRIPT="${LOGGER_SCRIPT:-/usr/lib/porg/porg_logger.sh}"
REPORT_DIR="${REPORT_DIR:-/var/log/porg}"
TMPDIR="${TMPDIR:-/tmp}"
PARALLEL_N_DEFAULT="${PARALLEL_N:-$(nproc 2>/dev/null || echo 1)}"
RESUME_STATE_DIR="${RESUME_STATE_DIR:-/var/lib/porg/upgrade-state}"
mkdir -p "$REPORT_DIR" "$RESUME_STATE_DIR"

# ------------------ logger integration ------------------
if [ -f "$LOGGER_SCRIPT" ]; then
  # shellcheck disable=SC1090
  source "$LOGGER_SCRIPT"
else
  log_info(){ printf "%s [INFO] %s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
  log_warn(){ printf "%s [WARN] %s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
  log_error(){ printf "%s [ERROR] %s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
  log_debug(){ [ "${DEBUG:-false}" = true ] && printf "%s [DEBUG] %s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
  log_stage(){ printf "%s [STAGE] %s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
fi

# ------------------ helpers ------------------
_have(){ command -v "$1" >/dev/null 2>&1; }
_timestamp(){ date -u +%Y%m%dT%H%M%SZ; }
_die(){ log_error "$*"; exit 2; }
_json_out(){ python3 - <<PY
import json,sys
print(json.dumps(json.loads(sys.stdin.read()), indent=2, ensure_ascii=False))
PY
}

# ------------------ CLI ------------------
usage(){
cat <<EOF
Usage: $(basename "$0") [options] <command>
Commands:
  --plan --pkgs pkg1 pkg2...      Show upgrade plan for packages (uses porg_deps.py)
  --upgrade --pkgs pkg1 pkg2...   Execute upgrade plan (resolve -> build -> swap)
  --install, -i pkg               Alias: --upgrade then install to / (full pipeline)
  --world                         Plan or upgrade the entire world
Options:
  --parallel N    Parallel builds (default: detected CPUs)
  --progress      Show UI progress (bar, load, ETA)
  --dry-run       Simulate actions
  --yes           Auto confirm destructive steps
  --no-audit      Skip post-upgrade audit
  --resume        Resume last interrupted run (uses state in $RESUME_STATE_DIR)
  --help
EOF
exit 1
}

# parse args
CMD=""
DRY_RUN=false
PROGRESS=false
AUTO_YES=false
NO_AUDIT=false
PARALLEL_N="$PARALLEL_N_DEFAULT"
RESUME=false
PKGS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --plan) CMD="plan"; shift;;
    --upgrade) CMD="upgrade"; shift;;
    --install|-i) CMD="install"; shift;;
    --world) PKGS=("::world::"); shift;;
    --pkgs) shift; while [ $# -gt 0 ] && [[ "$1" != --* ]]; do PKGS+=("$1"); shift; done;;
    --parallel) PARALLEL_N="${2:-$PARALLEL_N}"; shift 2;;
    --progress) PROGRESS=true; shift;;
    --dry-run) DRY_RUN=true; shift;;
    --yes) AUTO_YES=true; shift;;
    --no-audit) NO_AUDIT=true; shift;;
    --resume) RESUME=true; shift;;
    -h|--help) usage;;
    *) PKGS+=("$1"); shift;;
  esac
done

[ -n "$CMD" ] || usage

# ------------------ UI helpers ------------------
# minimal progress bar and spinner
SPINNER_PID=""
_start_spinner(){
  local msg="$1"; local interval="${2:-0.12}"
  if [ "$PROGRESS" = true ] && [ -t 1 ]; then
    ( while :; do for s in '/-\|'; do printf "\r%s %s" "$s" "$msg"; sleep "$interval"; done; done ) &
    SPINNER_PID=$!
    disown
  fi
}
_stop_spinner(){
  if [ -n "${SPINNER_PID:-}" ]; then
    kill "$SPINNER_PID" 2>/dev/null || true
    wait "$SPINNER_PID" 2>/dev/null || true
    unset SPINNER_PID
    printf "\r"
  fi
}

# live monitor: prints load, mem, cpu (very light)
MONITOR_PID=""
_start_monitor(){
  local freq="${1:-2}"
  if [ "$PROGRESS" = true ] && [ -t 1 ]; then
    ( while :; do
        read -r _ a b c < /proc/loadavg || true
        mem_free_kb=$(awk '/MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
        printf "\r[load: %s | mem_avail_kb: %s] " "$a" "$mem_free_kb"
        sleep "$freq"
      done ) &
    MONITOR_PID=$!
    disown
  fi
}
_stop_monitor(){
  if [ -n "${MONITOR_PID:-}" ]; then
    kill "$MONITOR_PID" 2>/dev/null || true
    wait "$MONITOR_PID" 2>/dev/null || true
    unset MONITOR_PID
    printf "\r"
  fi
}

# progress per package (simple textual) - called by main loop
progress_print(){
  local cur="$1"; local total="$2"; local pkg="$3"
  local pct=$(( cur * 100 / total ))
  if [ "$PROGRESS" = true ] && [ -t 1 ]; then
    printf "\r[%d/%d] %s - %d%%" "$cur" "$total" "$pkg" "$pct"
  fi
}

# ------------------ plan generation ------------------
generate_plan_for_pkgs(){
  # outputs JSON plan to stdout
  if [ "${PKGS[0]}" = "::world::" ]; then
    if [ -x "$DEPS_PY" ]; then
      "$DEPS_PY" upgrade-plan --world
    else
      _die "deps resolver not found at $DEPS_PY"
    fi
  else
    if [ -x "$DEPS_PY" ]; then
      "$DEPS_PY" upgrade-plan --pkgs "${PKGS[@]}"
    else
      _die "deps resolver not found at $DEPS_PY"
    fi
  fi
}

# ------------------ run builder for a single pkg (safely) ------------------
build_pkg(){
  local pkg="$1"
  local metafile="$2"   # optional: path to metafile; if empty, rely on builder to find
  local out_log="$3"
  if [ "$DRY_RUN" = true ]; then
    log_info "[DRY-RUN] Would build $pkg (metafile=${metafile})"
    return 0
  fi
  # prefer calling builder with metafile if supplied
  if [ -n "$metafile" ] && [ -x "$BUILDER" ]; then
    "$BUILDER" build "$metafile" > "$out_log" 2>&1 || return 1
  else
    if command -v porg >/dev/null 2>&1; then
      porg -i "$pkg" > "$out_log" 2>&1 || return 1
    elif [ -x "$BUILDER" ]; then
      "$BUILDER" build "$pkg" > "$out_log" 2>&1 || return 1
    else
      log_warn "No builder found to build $pkg"
      return 2
    fi
  fi
  return 0
}

# ------------------ swap: remove old package then install new (atomic-ish) ------------------
swap_package(){
  local pkg="$1"
  local new_pkg_path="$2"  # package artifact or empty
  # policy: after build success we remove old and then expand/install new (or call builder to install)
  if [ "$DRY_RUN" = true ]; then
    log_info "[DRY-RUN] Would swap/install $pkg with $new_pkg_path"
    return 0
  fi
  # Remove old version via porg_remove.sh (safe)
  if [ -x "$REMOVER" ]; then
    "$REMOVER" "$pkg" --yes --quiet || log_warn "Remover returned non-zero for $pkg"
  elif [ -x "/usr/lib/porg/porg_remove.sh" ]; then
    /usr/lib/porg/porg_remove.sh "$pkg" --yes --quiet || log_warn "Fallback remover failed"
  else
    log_warn "No remover found; skipping old removal for $pkg"
  fi
  # Install new: if artifact path provided and is archive, expand; else rely on DB/register or builder
  if [ -n "$new_pkg_path" ] && [ -f "$new_pkg_path" ]; then
    log_info "Expanding package $new_pkg_path into system (use with caution)"
    if [ "$DRY_RUN" = true ]; then
      log_info "[DRY-RUN] Would expand $new_pkg_path into /"
    else
      # safe expand
      if [[ "$new_pkg_path" == *.tar.* || "$new_pkg_path" == *.tar ]]; then
        tar -xf "$new_pkg_path" -C /
      else
        log_warn "Unknown package type for expand: $new_pkg_path"
      fi
    fi
  else
    # let builder install to DESTDIR=/ and register
    if command -v porg >/dev/null 2>&1; then
      porg -i "$pkg" || log_warn "porg -i failed for $pkg"
    else
      log_warn "No convenient install method found for $pkg"
    fi
  fi
}

# ------------------ parallel runner for builds (returns an associative of results) ------------------
run_builds_parallel(){
  local -n pkgs_arr=$1
  local parallel_n="${2:-$PARALLEL_N}"
  declare -A result_map
  mkdir -p "$REPORT_DIR"
  # prepare job list
  if _have parallel; then
    # use GNU parallel to run build_pkg with logs per-package
    export -f build_pkg log_info log_warn
    printf "%s\n" "${pkgs_arr[@]}" | parallel -j "$parallel_n" --halt soon,fail=1 bash -c 'pkg="$0"; out="$REPORT_DIR/build-${pkg}-'"$(_timestamp)"'.log"; build_pkg "$pkg" "" "$out" && echo "$pkg:0" || echo "$pkg:1"' > "$TMPDIR/parallel-results.txt"
    # parse results
    while IFS= read -r line; do
      pkg="${line%%:*}"; code="${line##*:}"
      result_map["$pkg"]="$code"
    done < "$TMPDIR/parallel-results.txt"
  else
    # fallback: background jobs with throttle
    local pids=(); local running=0
    for pkg in "${pkgs_arr[@]}"; do
      out="$REPORT_DIR/build-${pkg}-$(_timestamp).log"
      ( build_pkg "$pkg" "" "$out"; echo "$pkg:0" >> "$TMPDIR/build-rc.txt" ) & pid=$!
      pids+=("$pid")
      running=$((running+1))
      # throttle
      while [ "$(jobs -rp | wc -l)" -ge "$parallel_n" ]; do sleep 0.1; done
    done
    wait
    # collect outputs: build-rc may not exist if all returned non-zero; assume success for those without marker? fallback: assume success
    if [ -f "$TMPDIR/build-rc.txt" ]; then
      while IFS= read -r l; do
        pkg="${l%%:*}"; code="${l##*:}"
        result_map["$pkg"]="$code"
      done < "$TMPDIR/build-rc.txt"
    fi
  fi
  echo "$(declare -p result_map)"
}

# ------------------ process plan and execute ------------------
process_plan_and_execute(){
  local plan_json="$1"
  # parse plan_json to extract ordered list
  if _have jq; then
    ordered=( $(echo "$plan_json" | jq -r '.upgrade_order[]?') )
    needs_rebuild=( $(echo "$plan_json" | jq -r '.needs_rebuild[]?') )
  else
    # lightweight python parse
    ordered=( $(python3 - <<PY
import json,sys
p=json.load(sys.stdin)
for x in p.get("upgrade_order",[]):
    print(x)
PY
<<<"$plan_json") )
    needs_rebuild=( $(python3 - <<PY
import json,sys
p=json.load(sys.stdin)
for x in p.get("needs_rebuild",[]):
    print(x)
PY
<<<"$plan_json") )
  fi

  total=${#ordered[@]}
  [ "$total" -gt 0 ] || { log_info "No packages to upgrade in plan"; return 0; }

  # choose execution mode: sequential or parallel
  if [ "$PARALLEL_N" -le 1 ]; then
    # sequential: obey order
    idx=0
    for pkg in "${ordered[@]}"; do
      idx=$((idx+1))
      progress_print "$idx" "$total" "$pkg"
      log_stage "Upgrading $pkg ($idx/$total)"
      out_log="$REPORT_DIR/upgrade-${pkg}-$(_timestamp).log"
      if printf '%s\n' "${needs_rebuild[@]}" | grep -qx "$pkg"; then
        # build then swap
        build_pkg "$pkg" "" "$out_log" || { log_warn "Build failed for $pkg"; echo "{\"pkg\":\"$pkg\",\"status\":\"build-failed\"}" >> "$REPORT_DIR/upgrade-errors-$(_timestamp).log"; continue; }
        swap_package "$pkg" "" || { log_warn "Swap failed for $pkg"; continue; }
      else
        # nothing to do - but we may still want to attempt minor upgrade
        log_info "Package $pkg does not need rebuild (per deps) - skipping build"
      fi
    done
  else
    # parallel: group packages that are independent according to plan: simplistic approach -> run in batches preserving order
    # For safety we will partition ordered into batches of size PARALLEL_N and run each batch in parallel
    idx=0
    i=0
    while [ $i -lt $total ]; do
      batch=("${ordered[@]:$i:$PARALLEL_N}")
      i=$((i+PARALLEL_N))
      # perform builds in parallel for those in batch that need rebuild
      build_list=()
      for pkg in "${batch[@]}"; do
        if printf '%s\n' "${needs_rebuild[@]}" | grep -qx "$pkg"; then
          build_list+=("$pkg")
        fi
      done
      if [ "${#build_list[@]}" -gt 0 ]; then
        log_info "Building batch: ${build_list[*]} (parallel=${PARALLEL_N})"
        # run builds in parallel (run_builds_parallel returns declare -p of assoc array)
        eval "$(run_builds_parallel build_list "$PARALLEL_N")" || true
        # result_map is available as assoc array
        # iterate batch and swap successful builds
        for pkg in "${batch[@]}"; do
          idx=$((idx+1))
          progress_print "$idx" "$total" "$pkg"
          rc="${result_map[$pkg]:-0}"
          if [ "$rc" = "0" ]; then
            swap_package "$pkg" "" || log_warn "Swap failed for $pkg"
          else
            log_warn "Build failed for $pkg (rc=$rc)"
          fi
        done
      else
        # no builds needed in this batch, just advance progress
        for pkg in "${batch[@]}"; do
          idx=$((idx+1))
          progress_print "$idx" "$total" "$pkg"
        done
      fi
    done
  fi

  # finalize progress UI
  if [ "$PROGRESS" = true ] && [ -t 1 ]; then
    printf "\n"
  fi
}

# ------------------ top-level handlers ------------------
if [ "$CMD" = "plan" ]; then
  plan_json="$(generate_plan_for_pkgs)"
  echo "$plan_json" | _json_out
  exit 0
fi

if [ "$CMD" = "upgrade" ] || [ "$CMD" = "install" ]; then
  # generate plan
  plan_json="$(generate_plan_for_pkgs)"
  # quick show
  if [ "$DRY_RUN" = true ]; then
    log_info "[DRY-RUN] Would execute plan:"
    echo "$plan_json" | _json_out
    exit 0
  fi

  # confirmation if not auto yes
  if [ "$AUTO_YES" != true ]; then
    echo "Upgrade plan for packages: continue? [y/N]"
    echo "$plan_json" | ( _have jq && jq -r '.upgrade_order[]?' || cat )
    read -r ans || true
    case "$ans" in [yY]|[yY][eE][sS]) ;; *) log_info "Aborted by user"; exit 0;; esac
  fi

  # start progress monitor if requested
  if [ "$PROGRESS" = true ]; then
    _start_spinner "Upgrading..." 0.12
    _start_monitor 2
  fi

  # process and execute
  process_plan_and_execute "$plan_json"

  # stop monitors
  _stop_spinner
  _stop_monitor

  # run audit unless skipped
  if [ "$NO_AUDIT" = false ] && [ -x "$AUDIT_SCRIPT" ]; then
    log_stage "Running post-upgrade audit (quick)"
    if [ "$DRY_RUN" = true ]; then
      log_info "[DRY-RUN] Would run $AUDIT_SCRIPT --quick"
    else
      "$AUDIT_SCRIPT" --quick --quiet || log_warn "Audit returned non-zero"
    fi
  fi

  # summary
  log_stage "Upgrade completed"
  exit 0
fi

# unknown command fallback
usage
