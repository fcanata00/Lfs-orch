#!/usr/bin/env bash
#
# porg_logger.sh
# Módulo de logging para Porg — colorido, spinner, barra de progresso, perf measurement, rotação de logs
# Para usar:
#   source /usr/lib/porg/porg_logger.sh
#   log_init            # cria arquivo de sessão em /var/log/porg por padrão
#   log INFO "Mensagem"
#   log_perf make -j4
#
set -euo pipefail
IFS=$'\n\t'

# -------------------- Defaults (overwritten por /etc/porg/porg.conf se presente) --------------------
PORG_CONF="${PORG_CONF:-/etc/porg/porg.conf}"
LOG_DIR="${LOG_DIR:-/var/log/porg}"
LOG_LEVEL="${LOG_LEVEL:-INFO}"        # DEBUG|INFO|WARN|ERROR
LOG_COLOR="${LOG_COLOR:-true}"        # true|false
ROTATE="${ROTATE:-true}"              # rotação on/off
ROTATE_LIMIT="${ROTATE_LIMIT:-10}"    # quantos arquivos manter
KEEP_LOGS_DAYS="${KEEP_LOGS_DAYS:-30}"# dias para limpeza automática
SESSION_LOG=""                        # caminho para o arquivo atual da sessão
SESSION_START_TS=0
ERROR_COUNT=0
WARN_COUNT=0
DEBUG_COUNT=0
INFO_COUNT=0

# -------------------- Carregar /etc/porg/porg.conf se existir --------------------
_load_porg_conf() {
  if [ -f "$PORG_CONF" ]; then
    # file expected to contain KEY="value" lines; evaluate safely
    while IFS= read -r line || [ -n "$line" ]; do
      line="${line%%#*}"         # remove comments
      line="${line%$'\r'}"
      [ -z "$line" ] && continue
      if [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
        # shell-eval assignment
        eval "$line"
      fi
    done < "$PORG_CONF"
  fi
}

# -------------------- Colors (with fallback) --------------------
_supports_color() {
  # if LOG_COLOR explicitly false, return 1 (no color)
  if [ "${LOG_COLOR}" = "false" ]; then return 1; fi
  # check tty and tput
  if command -v tput >/dev/null 2>&1 && [ -t 1 ]; then
    ncolors=$(tput colors 2>/dev/null || echo 0)
    [ "$ncolors" -ge 8 ] && return 0 || return 1
  fi
  return 1
}

if _supports_color; then
  C_DEBUG="$(tput setaf 6)"  # ciano
  C_INFO="$(tput setaf 2)"   # verde
  C_WARN="$(tput setaf 3)"   # amarelo
  C_ERROR="$(tput setaf 1)"  # vermelho
  C_STAGE="$(tput setaf 4)"  # azul
  C_RESET="$(tput sgr0)"
else
  C_DEBUG=""; C_INFO=""; C_WARN=""; C_ERROR=""; C_STAGE=""; C_RESET=""
fi

# -------------------- Init / rotate --------------------
_rotate_if_needed() {
  # keep only ROTATE_LIMIT most recent logs
  [ "${ROTATE}" = "true" ] || return 0
  mkdir -p "$LOG_DIR"
  # list session logs sorted by mtime (oldest first)
  logs=( $(ls -1t "${LOG_DIR}" 2>/dev/null || true) )
  if [ "${#logs[@]}" -le "$ROTATE_LIMIT" ]; then return 0; fi
  # remove older beyond rotate limit
  idx=0
  for f in "${logs[@]}"; do
    idx=$((idx+1))
    if [ "$idx" -gt "$ROTATE_LIMIT" ]; then
      rm -f "${LOG_DIR}/${f}" 2>/dev/null || true
    fi
  done
}

# limpa logs mais antigos que N dias
clean_old_logs() {
  local days="${1:-$KEEP_LOGS_DAYS}"
  if [ -z "$days" ] || ! [[ "$days" =~ ^[0-9]+$ ]]; then
    echo "Uso: clean_old_logs <days>  (ex: clean_old_logs 30)"
    return 2
  fi
  if [ -d "$LOG_DIR" ]; then
    find "$LOG_DIR" -type f -mtime +"$days" -print0 | xargs -0r rm -f --
    return 0
  fi
  return 0
}

# inicilizar logger: log_init [log_dir_or_file]
# se argumento for diretório => cria sessão em <dir>/porg-YYYYmmdd-HHMMSS.log
# se argumento for arquivo => usa exatamente esse arquivo
log_init() {
  _load_porg_conf
  local target="${1:-${LOG_DIR}}"
  if [ -d "$target" ]; then
    mkdir -p "$target"
    SESSION_LOG="${target%/}/porg-$(date -u +%Y%m%dT%H%M%SZ).log"
  else
    # if parent dir doesn't exist create it
    mkdir -p "$(dirname "$target")"
    SESSION_LOG="$target"
  fi
  mkdir -p "$(dirname "$SESSION_LOG")"
  touch "$SESSION_LOG"
  SESSION_START_TS=$(date +%s)
  ERROR_COUNT=0; WARN_COUNT=0; DEBUG_COUNT=0; INFO_COUNT=0
  # rotate old logs if requested
  _rotate_if_needed
  # header
  echo "=== Porg log session started at $(date -u +%Y-%m-%dT%H:%M:%SZ) ===" >> "$SESSION_LOG"
  # also echo to stdout
  log "INFO" "Log iniciado: $SESSION_LOG"
}

# -------------------- Basic logging function --------------------
# log LEVEL MESSAGE
# LEVEL: DEBUG|INFO|WARN|ERROR|OK|STAGE
log() {
  local level="${1:-INFO}"
  shift || true
  local msg="$*"
  local ts; ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  [ -n "$SESSION_LOG" ] || log_init

  # Update counters
  case "$level" in
    DEBUG) DEBUG_COUNT=$((DEBUG_COUNT+1));;
    INFO) INFO_COUNT=$((INFO_COUNT+1));;
    WARN) WARN_COUNT=$((WARN_COUNT+1));;
    ERROR) ERROR_COUNT=$((ERROR_COUNT+1));;
  esac

  # format line
  local line="[$ts] [$level] $msg"
  printf '%s\n' "$line" >> "$SESSION_LOG"

  # decide to print to stdout based on LOG_LEVEL
  # order: DEBUG < INFO < WARN < ERROR
  declare -A lvlmap=( ["DEBUG"]=0 ["INFO"]=1 ["WARN"]=2 ["ERROR"]=3 )
  local cur=${lvlmap[$LOG_LEVEL]:-1}
  local want=${lvlmap[$level]:-1}
  if [ "$want" -lt "$cur" ]; then
    # lower-than-config level: skip printing to stdout
    return 0
  fi

  # print colored
  case "$level" in
    DEBUG)
      printf "%b[DEBUG]%b %s\n" "$C_DEBUG" "$C_RESET" "$msg"
      ;;
    INFO)
      printf "%b[INFO]%b  %s\n" "$C_INFO" "$C_RESET" "$msg"
      ;;
    WARN)
      printf "%b[WARN]%b  %s\n" "$C_WARN" "$C_RESET" "$msg"
      ;;
    ERROR)
      printf "%b[ERROR]%b %s\n" "$C_ERROR" "$C_RESET" "$msg"
      ;;
    OK)
      printf "%b[ OK ]%b   %s\n" "$C_INFO" "$C_RESET" "$msg"
      ;;
    STAGE)
      printf "%b[ >>> ]%b %s\n" "$C_STAGE" "$C_RESET" "$msg"
      ;;
    *)
      printf "[%s] %s\n" "$level" "$msg"
      ;;
  esac
}

# imprime seção
log_section() {
  local title="$*"
  [ -n "$title" ] || return 1
  [ -n "$SESSION_LOG" ] || log_init
  local ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  printf '\n%s\n' "=== $title ===" | tee -a "$SESSION_LOG"
  log "STAGE" "$title"
}

# -------------------- Helpers para performance (proc) --------------------
# retorna: cpu_percent instantâneo (0-100)
_cpu_percent_instant() {
  # read /proc/stat and compute delta since last call
  # static local prev values
  local cur user nice system idle iowait irq softirq steal guest
  read -r _cpu user nice system idle iowait irq softirq steal guest < /proc/stat
  local idle_now=$((idle + iowait))
  local total_now=$((user + nice + system + idle + iowait + irq + softirq + steal))
  # use temp file to persist previous measurement
  local tmpf="/tmp/.porg_cpu_prev"
  if [ -f "$tmpf" ]; then
    read -r prev_idle prev_total < "$tmpf"
  else
    prev_idle=$idle_now; prev_total=$total_now
    printf '%s %s' "$prev_idle" "$prev_total" > "$tmpf"
    echo 0; return
  fi
  diff_idle=$((idle_now - prev_idle))
  diff_total=$((total_now - prev_total))
  printf '%s %s' "$idle_now" "$total_now" > "$tmpf"
  if [ "$diff_total" -le 0 ]; then echo 0; return; fi
  local usage=$((100 * (diff_total - diff_idle) / diff_total))
  echo "$usage"
}

# retorna mem em MB usada (approx)
_mem_used_mb() {
  awk '/MemTotal:/ {t=$2} /MemAvailable:/ {a=$2} END {printf "%d", (t-a)/1024}' /proc/meminfo 2>/dev/null || echo 0
}

_loadavg() {
  awk '{printf "%.2f", $1}' /proc/loadavg 2>/dev/null || echo "0.00"
}

# -------------------- Spinner (monitor PID) --------------------
# log_spinner <mensagem> <pid>
# mostra spinner até pid morrer. grava resumo no log ao finalizar.
log_spinner() {
  local msg="$1"; local pid="$2"
  [ -n "$SESSION_LOG" ] || log_init
  if ! kill -0 "$pid" 2>/dev/null; then
    log "WARN" "PID $pid não está em execução para spinner"
    return 1
  fi
  local spin='|/-\\'
  local i=0
  local start_ts=$(date +%s)
  # header
  printf "%s " "$msg"
  while kill -0 "$pid" 2>/dev/null; do
    i=$(( (i + 1) % 4 ))
    printf "\b%c" "${spin:$i:1}"
    # show small perf snapshot
    local cpu=$(_cpu_percent_instant)
    local mem=$(_mem_used_mb)
    local load=$(_loadavg)
    printf " cpu:%s%% mem:%sMB load:%s\r" "$cpu" "$mem" "$load"
    sleep 0.6
  done
  wait "$pid" 2>/dev/null || true
  local rc=$?
  local end_ts=$(date +%s); local dura=$((end_ts - start_ts))
  printf "\n"
  log "INFO" "$msg finished (rc=$rc, duration=${dura}s)"
  return "$rc"
}

# -------------------- Progress bar (Portage-like) --------------------
# log_progress <percent> <mensagem> <eta_seconds_or_string>
# percent: 0..100
log_progress() {
  local percent="${1:-0}"
  local msg="${2:-}"
  local eta="${3:-}"
  local load=$( _loadavg )
  local cpu=$( _cpu_percent_instant )
  local mem=$( _mem_used_mb )
  local width=28
  # ensure percent numeric
  if ! [[ "$percent" =~ ^[0-9]+$ ]]; then percent=0; fi
  if [ "$percent" -lt 0 ]; then percent=0; fi
  if [ "$percent" -gt 100 ]; then percent=100; fi
  local filled=$((percent * width / 100)); local empty=$((width - filled))
  local bar="$(printf '%0.s█' $(seq 1 $filled) 2>/dev/null)$(printf '%0.s░' $(seq 1 $empty) 2>/dev/null)"
  # format ETA
  local eta_s=""
  if [[ "$eta" =~ ^[0-9]+$ ]]; then eta_s="$(eta_fmt "$eta")"; else eta_s="$eta"; fi
  printf "\r%s  [%s] %3d%% ETA:%s load:%s cpu:%s%% mem:%sMB  %s" "$msg" "$bar" "$percent" "$eta_s" "$load" "$cpu" "$mem" " "
  # also log snapshot line into session log (once every call)
  printf '%s [%s] %3d%% ETA:%s load:%s cpu:%s%% mem:%sMB %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$msg" "$percent" "$eta_s" "$load" "$cpu" "$mem" "" >> "$SESSION_LOG"
}

# helper to format seconds to hh:mm:ss
eta_fmt() {
  local s="$1"
  printf "%02d:%02d:%02d" $((s/3600)) $(((s%3600)/60)) $((s%60))
}

# -------------------- log_perf: executar comando e medir perf --------------------
# log_perf <cmd...>
# Retorna o exit code do comando
log_perf() {
  [ "$#" -gt 0 ] || return 2
  [ -n "$SESSION_LOG" ] || log_init
  local cmd=( "$@" )
  local start_ts=$(date +%s)
  local start_uptime=$(cat /proc/uptime 2>/dev/null | awk '{print int($1)}' || echo 0)
  # capture /proc/stat baseline for CPU delta
  local stat_prev="$(cat /proc/stat | head -n1)"
  # run command in background with its own pid
  "${cmd[@]}" &
  local pid=$!
  log "INFO" "Executando: ${cmd[*]}  (pid=$pid)"
  # monitor: sample mem and cpu for this pid while running
  local peak_mem=0
  local samples=0
  local cpu_acc=0
  while kill -0 "$pid" 2>/dev/null; do
    # per-process mem (RSS in KB) and cpu% approximation (not exact)
    if [ -r "/proc/${pid}/status" ]; then
      rss_kb=$(awk '/VmRSS:/ {print $2}' /proc/${pid}/status 2>/dev/null || echo 0)
      [ -z "$rss_kb" ] && rss_kb=0
      rss_mb=$((rss_kb/1024))
      [ "$rss_mb" -gt "$peak_mem" ] && peak_mem="$rss_mb"
    fi
    # approximate cpu% via system instant cpu (cheap)
    cpu_now=$(_cpu_percent_instant)
    cpu_acc=$((cpu_acc + cpu_now))
    samples=$((samples + 1))
    sleep 1
  done
  wait "$pid"
  local rc=$?
  local end_ts=$(date +%s)
  local duration=$((end_ts - start_ts))
  local avg_cpu=0
  if [ "$samples" -gt 0 ]; then avg_cpu=$((cpu_acc / samples)); fi
  local load=$( _loadavg )
  printf "Comando finalizado: rc=%d, duracao=%ds, avg_cpu=%s%%, peak_mem=%sMB, load=%s\n" "$rc" "$duration" "$avg_cpu" "$peak_mem" "$load" >> "$SESSION_LOG"
  log "INFO" "Comando finalizado: rc=$rc, duracao=${duration}s, avg_cpu=${avg_cpu}%, peak_mem=${peak_mem}MB, load=${load}"
  return "$rc"
}

# -------------------- log_summary (final) --------------------
log_summary() {
  [ -n "$SESSION_LOG" ] || log_init
  local end_ts=$(date +%s)
  local total=$((end_ts - SESSION_START_TS))
  log "INFO" "Resumo da sessão: duração=${total}s, errors=${ERROR_COUNT}, warnings=${WARN_COUNT}, info=${INFO_COUNT}, debug=${DEBUG_COUNT}"
  printf '{"time":"%s","duration_s":%d,"errors":%d,"warnings":%d,"info":%d,"debug":%d}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$total" "$ERROR_COUNT" "$WARN_COUNT" "$INFO_COUNT" "$DEBUG_COUNT" >> "$SESSION_LOG"
}

# -------------------- Export functions for sourcing scripts --------------------
# When sourced, these names are available to caller script
# Provide a small CLI for direct invocation (clean logs)
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  # invoked directly as script
  case "$1" in
    --clean-old)
      d="${2:-$KEEP_LOGS_DAYS}"
      clean_old_logs "$d"
      ;;
    --rotate)
      _rotate_if_needed
      ;;
    --init)
      log_init "${2:-}"
      ;;
    --help|*)
      cat <<EOF
porg_logger.sh - helper
Usage:
  source /usr/lib/porg/porg_logger.sh    # to use functions in shell
  ./porg_logger.sh --init [dir|file]     # create new session log
  ./porg_logger.sh --clean-old <days>    # delete logs older than <days>
  ./porg_logger.sh --rotate              # perform rotation check
EOF
      ;;
  esac
  exit 0
fi

# exported names (bash sourcing doesn't require "export", just define)
# functions available: log_init, log, log_section, log_spinner, log_progress, log_perf, log_summary, clean_old_logs

# end of porg_logger.sh
