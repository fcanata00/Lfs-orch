#!/usr/bin/env bash
# porg_logger.sh - Logger avançado para Porg (cores, spinner, progresso, perf, JSON)
# Path: /usr/lib/porg/porg_logger.sh
# Load: source /usr/lib/porg/porg_logger.sh
set -euo pipefail
IFS=$'\n\t'

# -------------------- Carregar configuração (respeitar /etc/porg/porg.conf) --------------------
PORG_CONF="${PORG_CONF:-/etc/porg/porg.conf}"
if [ -f "$PORG_CONF" ]; then
  # shellcheck disable=SC1090
  source "$PORG_CONF"
fi

# -------------------- Defaults (podem ser sobrescritos em porg.conf) --------------------
LOG_DIR="${LOG_DIR:-/var/log/porg}"
LOG_LEVEL="${LOG_LEVEL:-INFO}"       # ERROR|WARN|INFO|DEBUG
LOG_COLOR="${LOG_COLOR:-true}"       # true/false
QUIET_MODE_DEFAULT="${QUIET_MODE_DEFAULT:-false}"
LOG_JSON="${LOG_JSON:-false}"        # true -> gera summary JSON por sessão
LOG_JSON_DIR="${LOG_JSON_DIR:-${LOG_DIR}/json}"
LOG_ROTATE_DAYS="${LOG_ROTATE_DAYS:-14}"
SESSION_START_TS="$(date -u +%Y%m%dT%H%M%SZ)"
SESSION_LOG_FILE="${LOG_DIR}/porg-${SESSION_START_TS}.log"
SESSION_JSON_FILE="${LOG_JSON_DIR}/porg-session-${SESSION_START_TS}.json"
mkdir -p "$LOG_DIR" "$LOG_JSON_DIR"

# -------------------- Terminal and color helpers --------------------
_have_tty() { [ -t 1 ]; }
if [ "${LOG_COLOR}" = true ] && _have_tty; then
  # ANSI colors (fallback safe)
  COLOR_RESET="$(tput sgr0 2>/dev/null || printf '\033[0m')"
  COLOR_INFO="$(tput setaf 2 2>/dev/null || printf '\033[0;32m')"
  COLOR_WARN="$(tput setaf 3 2>/dev/null || printf '\033[0;33m')"
  COLOR_ERROR="$(tput setaf 1 2>/dev/null || printf '\033[0;31m')"
  COLOR_DEBUG="$(tput setaf 6 2>/dev/null || printf '\033[0;36m')"
  COLOR_STAGE="$(tput setaf 5 2>/dev/null || printf '\033[0;35m')"
else
  COLOR_RESET=""; COLOR_INFO=""; COLOR_WARN=""; COLOR_ERROR=""; COLOR_DEBUG=""; COLOR_STAGE=""
fi

# -------------------- Internal counters / session metadata --------------------
SESSION_MESSAGES=()
SESSION_COUNTS='{"INFO":0,"WARN":0,"ERROR":0,"DEBUG":0}'
SESSION_START_EPOCH="$(date +%s)"
CURRENT_QUIET="${QUIET_MODE_DEFAULT}"
# allow modules to override QUIET by exporting QUIET=true before sourcing logger

# -------------------- Low-level write (append to session log) --------------------
_log_file_append() {
  local line="$1"
  # atomic append using >> (good enough for simple single-process logging). If concurrent writes expected,
  # consider using flock in future.
  printf "%s\n" "$line" >>"$SESSION_LOG_FILE"
}

# -------------------- Compose standardized timestamped line --------------------
_log_line() {
  local level="$1"; shift
  local msg="$*"
  local ts; ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  printf "%s [%s] %s" "$ts" "$level" "$msg"
}

# -------------------- Public logging functions --------------------
_log_emit() {
  local level="$1"; shift
  local msg="$*"
  # increment counters (shell JSON-ish update)
  SESSION_COUNTS=$(python3 - <<PY
import json,sys
d=json.loads(sys.stdin.read())
lvl=sys.argv[1]
d[lvl]=d.get(lvl,0)+1
print(json.dumps(d))
PY
"$SESSION_COUNTS" "$level" 2>/dev/null || echo "$SESSION_COUNTS")
  local line; line="$(_log_line "$level" "$msg")"
  # store message in session array (for JSON summary)
  SESSION_MESSAGES+=("$line")
  # write to logfile always
  _log_file_append "$line"
  # determine printing to stdout/stderr
  if [ "${CURRENT_QUIET}" = true ] && [ "$level" != "ERROR" ] && [ "$level" != "WARN" ]; then
    return 0
  fi
  case "$level" in
    INFO)  printf "%b%s%b\n" "${COLOR_INFO}" "$line" "${COLOR_RESET}" ;;
    WARN)  printf "%b%s%b\n" "${COLOR_WARN}" "$line" "${COLOR_RESET}" >&2 ;;
    ERROR) printf "%b%s%b\n" "${COLOR_ERROR}" "$line" "${COLOR_RESET}" >&2 ;;
    DEBUG) if [ "${LOG_LEVEL}" = "DEBUG" ]; then printf "%b%s%b\n" "${COLOR_DEBUG}" "$line" "${COLOR_RESET}"; fi ;;
    STAGE) printf "%b%s%b\n" "${COLOR_STAGE}" "$line" "${COLOR_RESET}" ;;
    *) printf "%s\n" "$line" ;;
  esac
  # optional: call db_log_event if provided by porg_db.sh
  if declare -f db_log_event >/dev/null 2>&1; then
    # best-effort, do not break on failure
    db_log_event "$level" "$msg" || true
  fi
}

log_info()  { _log_emit "INFO" "$*"; }
log_warn()  { _log_emit "WARN" "$*"; }
log_error() { _log_emit "ERROR" "$*"; }
log_debug() { [ "${LOG_LEVEL}" = "DEBUG" ] && _log_emit "DEBUG" "$*"; }
log_stage() { _log_emit "STAGE" "$*"; }

# -------------------- Spinner (background) --------------------
_SPINNER_PID=""
_spinner_start() {
  local msg="$1"
  # prevent multiple spinners
  if [ -n "$_SPINNER_PID" ] && kill -0 "$_SPINNER_PID" 2>/dev/null; then return 0; fi
  # spinner characters
  local chars=( '⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' )
  # start background spinner
  (
    trap 'exit 0' SIGTERM
    local i=0
    while :; do
      # measure small metrics (loadavg)
      local load; load=$(cut -d' ' -f1 /proc/loadavg 2>/dev/null || echo "0.00")
      printf "\r%s %s (loadavg:%s) " "${chars[i % ${#chars[@]}]}" "$msg" "$load"
      i=$((i+1))
      sleep 0.12
    done
  ) &
  _SPINNER_PID=$!
  disown "$_SPINNER_PID" 2>/dev/null || true
}

_spinner_stop() {
  local rc="${1:-0}"
  if [ -n "$_SPINNER_PID" ]; then
    kill "$_SPINNER_PID" >/dev/null 2>&1 || true
    wait "$_SPINNER_PID" 2>/dev/null || true
    unset _SPINNER_PID
  fi
  # finish line
  if [ "$rc" -eq 0 ]; then
    printf "\r✔\n"
  else
    printf "\r✖\n"
  fi
}

# -------------------- Progress bar helper --------------------
# usage: log_progress current total "Message"
log_progress() {
  local cur="$1"; local total="$2"; local msg="$3"
  if [ "$total" -le 0 ]; then
    printf "\r%s [%d/?] %s" "$(date +%H:%M:%S)" "$cur" "$msg"
    return 0
  fi
  local width=36
  local pct=$(( cur * 100 / total ))
  local fill=$(( pct * width / 100 ))
  local empty=$(( width - fill ))
  local bar
  bar="$(printf '#%.0s' $(seq 1 $fill))$(printf ' %.0s' $(seq 1 $empty))"
  printf "\r%s [%s] %3d%% %s" "$msg" "$bar" "$pct" "$cur/$total"
  if [ "$cur" -ge "$total" ]; then printf "\n"; fi
}

# -------------------- Performance wrapper: run command and sample peak RSS --------------------
# usage: log_perf "label" -- command args...
# collects: elapsed_s, exit_code, peak_rss_kb, start_load, end_load
log_perf() {
  local label="$1"
  shift
  if [ $# -lt 1 ]; then log_error "log_perf requires -- command"; return 2; fi
  # expect "--" delimiter optional
  if [ "$1" = "--" ]; then shift; fi
  local cmd=( "$@" )
  log_stage "PERF START: $label -> ${cmd[*]}"
  local start_epoch_ns; start_epoch_ns=$(date +%s%N)
  local start_load; start_load=$(cut -d' ' -f1 /proc/loadavg 2>/dev/null || echo "0.00")
  local pid
  local peak_rss=0
  # run command in background, sample RSS
  "${cmd[@]}" &
  pid=$!
  # sample loop
  while kill -0 "$pid" 2>/dev/null; do
    # try reading /proc/<pid>/status VmRSS
    if [ -r "/proc/$pid/status" ]; then
      local rss_kb; rss_kb=$(awk '/VmRSS:/ {print $2}' /proc/"$pid"/status 2>/dev/null || echo 0)
      rss_kb=${rss_kb:-0}
      if [ "$rss_kb" -gt "$peak_rss" ] 2>/dev/null; then peak_rss=$rss_kb; fi
    fi
    sleep 0.12
  done
  wait "$pid" || true
  local exit_code=$?
  local end_epoch_ns; end_epoch_ns=$(date +%s%N)
  local elapsed_ns=$((end_epoch_ns - start_epoch_ns))
  local elapsed_s; elapsed_s=$(awk "BEGIN {printf \"%.3f\", $elapsed_ns/1000000000}")
  local end_load; end_load=$(cut -d' ' -f1 /proc/loadavg 2>/dev/null || echo "0.00")
  log_info "PERF: $label exit=$exit_code elapsed=${elapsed_s}s peak_rss=${peak_rss}KB load_before=${start_load} load_after=${end_load}"
  # append to session messages as structured line for later JSON export
  SESSION_MESSAGES+=("PERF|$label|exit=$exit_code|elapsed_s=${elapsed_s}|peak_rss_kb=${peak_rss}|load_before=${start_load}|load_after=${end_load}")
  return "$exit_code"
}

# -------------------- Session summary -> text and JSON --------------------
log_summary() {
  local end_epoch; end_epoch=$(date +%s)
  local elapsed=$(( end_epoch - SESSION_START_EPOCH ))
  local info_count; info_count=$(python3 - <<PY
import json,sys
d=json.loads('''$SESSION_COUNTS''')
print(d.get('INFO',0))
PY
)
  local warn_count; warn_count=$(python3 - <<PY
import json,sys
d=json.loads('''$SESSION_COUNTS''')
print(d.get('WARN',0))
PY
)
  local err_count; err_count=$(python3 - <<PY
import json,sys
d=json.loads('''$SESSION_COUNTS''')
print(d.get('ERROR',0))
PY
)
  local dbg_count; dbg_count=$(python3 - <<PY
import json,sys
d=json.loads('''$SESSION_COUNTS''')
print(d.get('DEBUG',0))
PY
)
  log_info "SESSION SUMMARY: duration=${elapsed}s INFO=${info_count} WARN=${warn_count} ERROR=${err_count} DEBUG=${dbg_count}"
  # JSON output if requested
  if [ "${LOG_JSON}" = true ]; then
    mkdir -p "$(dirname "$SESSION_JSON_FILE")"
    # build JSON using python for safety
    python3 - <<PY > "$SESSION_JSON_FILE"
import json,sys,time
summary={}
summary["session_start"]="${SESSION_START_TS}"
summary["session_end"]="$(date -u +%Y%m%dT%H%M%SZ)"
summary["duration_s"]=${elapsed}
summary["counts"]=${SESSION_COUNTS}
summary["messages"]=${MSG_JSON}
# flatten messages
mes=[]
for m in ${SESSION_MESSAGES[@]+"${SESSION_MESSAGES[@]}"}:
    pass
# we'll reconstruct differently: read log file lines
try:
    with open("${SESSION_LOG_FILE}","r",encoding='utf-8') as f:
        lines=f.read().splitlines()
except:
    lines=[]
summary["log_lines"]=lines
print(json.dumps(summary,indent=2,ensure_ascii=False))
PY
    log_info "Session JSON exported to $SESSION_JSON_FILE"
  fi
}

# -------------------- Log rotation / cleanup --------------------
rotate_logs() {
  find "$LOG_DIR" -maxdepth 1 -type f -name "porg-*.log" -mtime +"$LOG_ROTATE_DAYS" -print -exec gzip -9 {} \; || true
  log_info "rotate_logs: compressed logs older than ${LOG_ROTATE_DAYS} days in $LOG_DIR"
}

clean_old_logs() {
  local days="${1:-$LOG_ROTATE_DAYS}"
  find "$LOG_DIR" -type f -name "porg-*.log*.gz" -mtime +"$days" -print -delete || true
  log_info "clean_old_logs: removed archived logs older than ${days} days"
}

# -------------------- CLI for logger utility --------------------
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  # executed as script
  cmd="${1:-help}"
  case "$cmd" in
    --clean-old)
      clean_old_logs "${2:-$LOG_ROTATE_DAYS}"
      exit 0
      ;;
    --rotate)
      rotate_logs
      exit 0
      ;;
    --summary)
      log_summary
      exit 0
      ;;
    --help|help)
      cat <<EOF
porg_logger.sh - helper/CLI
Usage: $0 [--clean-old [days]] [--rotate] [--summary] [--help]
  --clean-old [days]  Remove archived logs older than 'days'
  --rotate            Compress older logs (older than LOG_ROTATE_DAYS)
  --summary           Print session summary (and export JSON if LOG_JSON=true)
EOF
      exit 0
      ;;
    *)
      echo "Unknown logger CLI command: $cmd" >&2
      exit 2
      ;;
  esac
fi

# -------------------- Expose small API for other modules --------------------
# Functions available for modules that source this file:
# log_info, log_warn, log_error, log_debug, log_stage, _spinner_start, _spinner_stop,
# log_progress, log_perf, log_summary, rotate_logs, clean_old_logs
export -f log_info log_warn log_error log_debug log_stage _spinner_start _spinner_stop log_progress log_perf log_summary rotate_logs clean_old_logs

# init: write first header line
printf "%s\n" "=== Porg log session started at $(date -u +%Y-%m-%dT%H:%M:%SZ) ===" >> "$SESSION_LOG_FILE"
_log_emit "INFO" "Logger initialized (logfile=$SESSION_LOG_FILE)"
# end of file
