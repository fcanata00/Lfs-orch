#!/usr/bin/env bash
#
# porg_bootstrap.sh - Bootstrap LFS (ampliado: list/verify/rebuild/crossgen/tui/iso)
# Local: /usr/lib/porg/porg_bootstrap.sh
#
# Uso:
#   sudo porg_bootstrap.sh prepare
#   sudo porg_bootstrap.sh list
#   sudo porg_bootstrap.sh verify
#   sudo porg_bootstrap.sh rebuild <fase>
#   sudo porg_bootstrap.sh crossgen
#   sudo porg_bootstrap.sh full [--tui]
#   sudo porg_bootstrap.sh build [--dry]
#   sudo porg_bootstrap.sh resume
#   sudo porg_bootstrap.sh enter
#   sudo porg_bootstrap.sh iso [--output /path/to.iso] [--label LABEL]
#   sudo porg_bootstrap.sh clean
#
set -euo pipefail
IFS=$'\n\t'

# -------------------- Configuração (carrega /etc/porg/porg.conf se houver) --------------------
PORG_CONF="${PORG_CONF:-/etc/porg/porg.conf}"
[ -f "$PORG_CONF" ] && source "$PORG_CONF" || true

# Padrões
LIBDIR="${LIBDIR:-/usr/lib/porg}"
BUILDER="${PORG_BUILDER:-${LIBDIR}/porg_builder.sh}"
CROSSGEN="${PORG_CROSSGEN:-${LIBDIR}/porg_crossgen.sh}"
ISO_TOOL="${PORG_ISO:-${LIBDIR}/porg_iso.sh}"
BOOTSTRAP_YAML="${BOOTSTRAP_YAML:-/usr/ports/bootstrap.yaml}"
LFS="${LFS:-/mnt/lfs}"
LFS_USER="${LFS_USER:-lfs}"
STATE_BASE="${STATE_DIR:-/var/lib/porg/state}/bootstrap"
LOGDIR="${LOGDIR:-/var/log/porg/bootstrap}"
LOCKFILE="${LOCKFILE:-/var/lock/porg-bootstrap.lock}"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 1)}"

mkdir -p "$STATE_BASE" "$LOGDIR" "$(dirname "$LOCKFILE")"

# -------------------- Utilitários e cores --------------------
_have(){ command -v "$1" >/dev/null 2>&1; }
_timestamp(){ date -u +%Y-%m-%dT%H:%M:%SZ; }

if _have tput && [ -t 1 ]; then
  R=$(tput setaf 1); G=$(tput setaf 2); Y=$(tput setaf 3); C=$(tput setaf 6); B=$(tput bold); N=$(tput sgr0)
else
  R="\e[31m"; G="\e[32m"; Y="\e[33m"; C="\e[36m"; B="\e[1m"; N="\e[0m"
fi

log(){ local lvl="$1"; shift; printf "%s [%s] %b%s%b\n" "$(_timestamp)" "$lvl" "${C}" "$*" "${N}"; printf "%s [%s] %s\n" "$(_timestamp)" "$lvl" "$*" >> "${LOGDIR}/bootstrap-$(date +%Y%m%d).log"; }
log_info(){ log INFO "$*"; }
log_warn(){ log WARN "$*"; }
log_error(){ log ERROR "$*"; }
_die(){ log_error "$*"; exit 2; }

# -------------------- Lock (flock if available) --------------------
_acquire_lock(){
  exec 201>"$LOCKFILE"
  if _have flock; then
    flock -n 201 || { log_error "Another bootstrap is running (lock ${LOCKFILE})."; exit 1; }
  else
    if [ -f "$LOCKFILE" ]; then
      pid=$(cat "$LOCKFILE" 2>/dev/null || true)
      if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        log_error "Another bootstrap seems to be running (pid $pid)."; exit 1
      else
        rm -f "$LOCKFILE"
      fi
    fi
    echo $$ > "$LOCKFILE"
    trap '_release_lock' EXIT
  fi
}
_release_lock(){ if _have flock; then flock -u 201 2>/dev/null || true; fi; [ -f "$LOCKFILE" ] && rm -f "$LOCKFILE" || true; }

# -------------------- YAML parsing helper (lista fases) --------------------
get_bootstrap_list(){
  if [ ! -f "$BOOTSTRAP_YAML" ]; then
    log_error "bootstrap.yaml not found at $BOOTSTRAP_YAML"; return 1
  fi
  if _have python3; then
    python3 - <<PY
import yaml,sys,os
p=os.path.expanduser("$BOOTSTRAP_YAML")
try:
    d=yaml.safe_load(open(p,'r',encoding='utf-8')) or {}
    seq=d.get('bootstrap') or d.get('bootstrap_list') or []
    if isinstance(seq, list):
        for it in seq:
            print(it)
    else:
        # fallback printing
        for line in str(seq).splitlines():
            v=line.strip().lstrip('-').strip()
            if v: print(v)
except Exception as e:
    # fallback to grep
    import re
    with open(p,'r',encoding='utf-8') as f:
        for l in f:
            m=re.match(r'^\s*-\s*(.+)',l)
            if m: print(m.group(1).strip())
PY
  else
    # fallback grep/sed
    grep -E '^\s*-\s+' "$BOOTSTRAP_YAML" | sed -E 's/^\s*-\s*//' || true
  fi
}

# -------------------- Checkpoint helpers --------------------
state_file_for(){ local pkg="$1"; echo "${STATE_BASE}/${pkg}.state"; }
save_state(){
  local pkg="$1"; local status="${2:-unknown}"; local extra="${3:-}"
  mkdir -p "$STATE_BASE"
  cat > "$(state_file_for "$pkg")" <<EOF
name: "$pkg"
status: "$status"
extra: "$extra"
ts: "$(_timestamp)"
EOF
}
load_state(){
  local pkg="$1"; if [ -f "$(state_file_for "$pkg")" ]; then cat "$(state_file_for "$pkg")"; else echo ""; fi
}
status_of(){
  local pkg="$1"
  if [ -f "$(state_file_for "$pkg")" ]; then
    awk -F': ' '/status:/{gsub(/"/,"",$2); print $2; exit}' "$(state_file_for "$pkg")"
  else
    echo "PENDING"
  fi
}

# -------------------- Comando: list --------------------
cmd_list(){
  log_info "Listing bootstrap phases from $BOOTSTRAP_YAML"
  local i=0
  mapfile -t arr < <(get_bootstrap_list || true)
  for pkg in "${arr[@]}"; do
    st=$(status_of "$pkg")
    case "$st" in
      success|rebuilt) icon="[${G}✔${N}]" ;;
      building|rebuilding) icon="[${Y}~${N}]" ;;
      failed) icon="[${R}✗${N}]" ;;
      *) icon="[ ]" ;;
    esac
    printf "%3d %s %s\n" $((i+1)) "$icon" "$pkg"
    i=$((i+1))
  done
}

# -------------------- Comando: verify --------------------
cmd_verify(){
  log_info "Verifying bootstrap checkpoints integrity..."
  local ok=0 bad=0
  mapfile -t arr < <(get_bootstrap_list || true)
  for pkg in "${arr[@]}"; do
    sf="$(state_file_for "$pkg")"
    if [ ! -f "$sf" ]; then
      printf "[%s] %s - missing state\n" "MISSING" "$pkg"
      bad=$((bad+1))
      continue
    fi
    st=$(status_of "$pkg")
    if [ "$st" = "success" ] || [ "$st" = "rebuilt" ]; then
      printf "[OK] %s\n" "$pkg"
      ok=$((ok+1))
    else
      printf "[WARN] %s (status=%s)\n" "$pkg" "$st"
      bad=$((bad+1))
    fi
  done
  log_info "Verify: OK=${ok} WARN/ERR=${bad}"
  if [ $bad -gt 0 ]; then return 1; else return 0; fi
}

# -------------------- Comando: rebuild <fase> --------------------
cmd_rebuild(){
  local phase="$1"
  if [ -z "$phase" ]; then _die "Usage: $0 rebuild <fase>"; fi
  if [ ! -x "$BUILDER" ]; then _die "Builder module not found: $BUILDER"; fi
  log_info "Rebuilding phase: $phase"
  save_state "$phase" "rebuilding"
  logfile="${LOGDIR}/${phase}.$(date +%Y%m%d%H%M%S).log"
  mkdir -p "$(dirname "$logfile")"
  if id "$LFS_USER" >/dev/null 2>&1; then
    if ! sudo -E -u "$LFS_USER" "$BUILDER" build "$phase" >>"$logfile" 2>&1; then
      save_state "$phase" "failed" "$logfile"
      log_error "Rebuild failed for $phase. See $logfile"
      return 1
    fi
  else
    if ! "$BUILDER" build "$phase" >>"$logfile" 2>&1; then
      save_state "$phase" "failed" "$logfile"
      log_error "Rebuild failed for $phase. See $logfile"
      return 1
    fi
  fi
  save_state "$phase" "rebuilt" "$logfile"
  log_info "Rebuild succeeded for $phase"
  return 0
}

# -------------------- Comando: build (sequencial com resume) --------------------
cmd_build(){
  local dry="${1:-false}"
  mapfile -t arr < <(get_bootstrap_list || true)
  local total=${#arr[@]}
  if [ $total -eq 0 ]; then _die "bootstrap list empty"; fi
  # find first not-success (resume)
  local start=0
  for idx in "${!arr[@]}"; do
    pkg="${arr[$idx]}"
    st=$(status_of "$pkg")
    if [ "$st" = "success" ] || [ "$st" = "rebuilt" ]; then
      start=$((start+1))
      continue
    else
      break
    fi
  done
  for ((i=start;i<total;i++)); do
    pkg="${arr[$i]}"
    log_info "[$((i+1))/$total] Building $pkg"
    save_state "$pkg" "building"
    logfile="${LOGDIR}/${pkg}.$(date +%Y%m%d%H%M%S).log"
    mkdir -p "$(dirname "$logfile")"
    if [ "$dry" = "true" ]; then
      log_info "[DRY-RUN] would build $pkg"
      save_state "$pkg" "success" "$logfile"
      continue
    fi
    if [ -x "$BUILDER" ]; then
      if id "$LFS_USER" >/dev/null 2>&1; then
        if ! sudo -E -u "$LFS_USER" "$BUILDER" build "$pkg" >>"$logfile" 2>&1; then
          save_state "$pkg" "failed" "$logfile"
          log_error "Build failed for $pkg (see $logfile)"; return 1
        fi
      else
        if ! "$BUILDER" build "$pkg" >>"$logfile" 2>&1; then
          save_state "$pkg" "failed" "$logfile"
          log_error "Build failed for $pkg (see $logfile)"; return 1
        fi
      fi
      save_state "$pkg" "success" "$logfile"
      log_info "Built $pkg"
    else
      _die "Builder not executable: $BUILDER"
    fi
  done
  log_info "All bootstrap phases completed"
  return 0
}

# -------------------- Comando: crossgen --------------------
cmd_crossgen(){
  if [ ! -x "$CROSSGEN" ]; then _die "crossgen module not found: $CROSSGEN"; fi
  log_info "Running cross-toolchain generator ($CROSSGEN)"
  "$CROSSGEN" || _die "crossgen failed"
  # create marker
  echo "crossgen: $(_timestamp)" > "${STATE_BASE}/cross-toolchain.state"
  log_info "Cross-toolchain generation finished"
}

# -------------------- Comando: iso --------------------
cmd_iso(){
  if [ ! -x "$ISO_TOOL" ]; then _die "iso tool not found: $ISO_TOOL"; fi
  local out="/var/tmp/porg/lfs.iso"
  local label="LFS"
  # parse options
  while [ $# -gt 0 ]; do
    case "$1" in
      --output) out="$2"; shift 2;;
      --label) label="$2"; shift 2;;
      *) shift;;
    esac
  done
  log_info "Generating ISO -> $out (label=$label)"
  "$ISO_TOOL" --output "$out" --label "$label" || _die "ISO generation failed"
  log_info "ISO created at $out"
}

# -------------------- Comando: enter (chroot) --------------------
cmd_enter(){
  if ! mountpoint -q "${LFS}/proc"; then
    log_warn "LFS appears not mounted; run prepare first"
    return 1
  fi
  if [ -f "${LFS}/root/.porg_chroot_env.sh" ]; then
    log_info "Entering chroot $LFS"
    chroot "$LFS" /usr/bin/env -i HOME=/root TERM="$TERM" PATH=/tools/bin:/usr/bin:/bin /bin/bash --login
  else
    log_warn "Chroot env not found; creating minimal env"
    mkdir -p "${LFS}/root"
    cat > "${LFS}/root/.porg_chroot_env.sh" <<EOF
export LFS="$LFS"
export PATH="/tools/bin:/usr/bin:/bin"
EOF
    chroot "$LFS" /usr/bin/env -i HOME=/root TERM="$TERM" PATH=/tools/bin:/usr/bin:/bin /bin/bash --login
  fi
}

# -------------------- Comando: prepare (mounts, user, resolv.conf) --------------------
cmd_prepare(){
  if [ "$(id -u)" -ne 0 ]; then _die "prepare requires root"; fi
  log_info "Preparing LFS at $LFS (mounts, user, dirs)"
  mkdir -p "${LFS}" "${LFS}/dev" "${LFS}/proc" "${LFS}/sys" "${LFS}/run" "${LFS}/tools" "${LFS}/sources" "${LFS}/etc"
  if mountpoint -q "$LFS"; then log_warn "$LFS may already be mounted"; fi
  mount --bind /dev "${LFS}/dev" || true
  mount --bind /run "${LFS}/run" || true
  mount -t proc proc "${LFS}/proc" || true
  mount -t sysfs sysfs "${LFS}/sys" || true
  mount -t devpts devpts "${LFS}/dev/pts" -o gid=5,mode=620 || true
  if [ -f /etc/resolv.conf ]; then cp -a /etc/resolv.conf "${LFS}/etc/resolv.conf"; log_info "Copied resolv.conf into chroot"; fi
  if ! id "$LFS_USER" >/dev/null 2>&1; then useradd -m -s /bin/bash "$LFS_USER" || log_warn "useradd failed"; fi
  chown -R "$LFS_USER":"$LFS_USER" "${LFS}/sources" "${LFS}/tools" || true
  # optionally run crossgen if tools absent
  if [ ! -d "${LFS}/tools/bin" ]; then
    log_info "No /tools found in LFS; invoking crossgen"
    cmd_crossgen
  fi
  log_info "Prepare complete"
}

# -------------------- Comando: clean (umount safe) --------------------
cmd_clean(){
  if [ "$(id -u)" -ne 0 ]; then _die "clean requires root"; fi
  log_info "Unmounting LFS (safe reverse order)"
  targets=( "${LFS}/dev/pts" "${LFS}/dev" "${LFS}/proc" "${LFS}/sys" "${LFS}/run" )
  for t in "${targets[@]}"; do
    if mountpoint -q "$t"; then
      log_info "Unmount $t"
      umount -l "$t" 2>/dev/null || umount -f "$t" 2>/dev/null || log_warn "Failed to unmount $t"
    fi
  done
  log_info "Clean complete"
}

# -------------------- Comando: tui (dialog simple) --------------------
cmd_tui(){
  if ! _have dialog; then log_warn "dialog not installed; install 'dialog' to use TUI"; return 1; fi
  log_info "Starting TUI (interactive) - press ESC/Ctrl-C to quit"
  tmp="$(mktemp)"
  trap 'rm -f "$tmp"' EXIT
  # run build in background and stream logs to dialog tailbox
  ( cmd_build "false" ) &> "$tmp" &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    dialog --title "Porg Bootstrap (TUI)" --tailbox "$tmp" 30 100
    sleep 1
  done
  dialog --msgbox "Bootstrap finished (TUI)" 8 40
}

# -------------------- Dispatcher / CLI --------------------
usage(){
  cat <<EOF
porg_bootstrap.sh - uso:
  prepare                - montar LFS, criar usuário, copiar resolv.conf
  list                   - listar fases do bootstrap e status
  verify                 - verificar integridade dos checkpoints
  rebuild <fase>         - reconstruir apenas a fase indicada
  crossgen               - gerar cross-toolchain scripts (chamar porg_crossgen.sh)
  build [--dry]          - executar o bootstrap completo (resume automático)
  resume                 - continuar do último checkpoint
  full [--tui]           - prepare -> build (se --tui usa interface)
  enter                  - entrar no chroot
  iso [--output file]    - gerar ISO a partir do LFS
  clean                  - desmontar LFS
EOF
  exit 1
}

if [ $# -lt 1 ]; then usage; fi
_cmd="$1"; shift || true

_acquire_lock
case "$_cmd" in
  list) cmd_list ;;
  verify) cmd_verify ;;
  rebuild) cmd_rebuild "${1:-}" ;;
  crossgen) cmd_crossgen ;;
  build) cmd_build "${1:-false}" ;;
  resume) cmd_build "false" ;;
  prepare) cmd_prepare ;;
  enter) cmd_enter ;;
  clean) cmd_clean ;;
  full)
    tui=false
    if [ "${1:-}" = "--tui" ]; then tui=true; fi
    cmd_prepare
    if [ "$tui" = true ]; then cmd_tui; else cmd_build "false"; fi
    ;;
  iso) cmd_iso "$@" ;;
  tui) cmd_tui ;;
  help|--help|-h) usage ;;
  *) usage ;;
esac
_release_lock
exit 0
