#!/usr/bin/env bash
#
# porg_bootstrap.sh - Bootstrap LFS via Porg
# Local sugerido: /usr/lib/porg/porg_bootstrap.sh
# Uso: sudo porg_bootstrap.sh <prepare|build|enter|resume|clean|full> [opts]
#
set -euo pipefail
IFS=$'\n\t'

# -------------------- Configuração e caminhos --------------------
PORG_CONF="${PORG_CONF:-/etc/porg/porg.conf}"
[ -f "$PORG_CONF" ] && source "$PORG_CONF"

# Variáveis padrão (podem ser sobrescritas em porg.conf)
LFS="${LFS:-/mnt/lfs}"
LFS_SOURCES_DIR="${LFS_SOURCES_DIR:-${LFS}/sources}"
LFS_TOOLS_DIR="${LFS_TOOLS_DIR:-${LFS}/tools}"
LFS_USER="${LFS_USER:-lfs}"
LFS_TGT="${LFS_TGT:-x86_64-lfs-linux-gnu}"
LFS_JOBS="${LFS_JOBS:-$(nproc 2>/dev/null || echo 1)}"

LIBDIR="${LIBDIR:-/usr/lib/porg}"
BUILDER="${BUILDER:-${LIBDIR}/porg_builder.sh}"
STATE_DIR="${STATE_DIR:-/var/lib/porg/state}"
BOOTSTRAP_STATE="${STATE_DIR}/bootstrap.state"
LOGDIR="${LOGDIR:-/var/log/porg/bootstrap}"
LOCKFILE="${LOCKFILE:-/var/lock/porg-bootstrap.lock}"
BOOTSTRAP_YAML="${BOOTSTRAP_YAML:-/usr/ports/bootstrap.yaml}"

mkdir -p "$STATE_DIR" "$LOGDIR" "$(dirname "$LOCKFILE")"

# -------------------- UI / logger fallback --------------------
if [ -f "${LIBDIR}/porg_logger.sh" ]; then
  # shellcheck disable=SC1090
  source "${LIBDIR}/porg_logger.sh" || true
else
  log_info(){ printf "%s [INFO] %s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
  log_warn(){ printf "%s [WARN] %s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
  log_error(){ printf "%s [ERROR] %s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
  log_stage(){ printf "%s [STAGE] %s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
fi

# -------------------- Helpers --------------------
_have(){ command -v "$1" >/dev/null 2>&1; }
_timestamp(){ date -u +%Y%m%dT%H%M%SZ; }
_die(){ log_error "$*"; exit 2; }

# Acquire lock (flock if available) to avoid concurrent bootstraps
_acquire_lock(){
  exec 201>"$LOCKFILE"
  if _have flock; then
    flock -n 201 || { log_error "Another bootstrap is running (lockfile $LOCKFILE)."; exit 1; }
  else
    if [ -f "$LOCKFILE" ]; then
      pid=$(cat "$LOCKFILE" 2>/dev/null || true)
      if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        log_error "Another bootstrap (pid $pid) is running. Aborting."
        exit 1
      else
        log_warn "Stale lockfile found; removing."
        rm -f "$LOCKFILE"
      fi
    fi
    echo $$ > "$LOCKFILE"
    trap '_release_lock' EXIT
  fi
  # register cleanup
  trap 'umount_lfs_on_exit' INT TERM EXIT
}

_release_lock(){
  if _have flock; then
    flock -u 201 2>/dev/null || true
  fi
  [ -f "$LOCKFILE" ] && rm -f "$LOCKFILE" || true
}

# ensure we are root for mount/umount/useradd operations
_require_root(){
  if [ "$(id -u)" -ne 0 ]; then
    _die "This script must be run as root (sudo)."
  fi
}

# -------------------- Mount /mnt/lfs safely --------------------
is_mounted(){
  local target="$1"
  mountpoint -q "$target"
}

mount_lfs(){
  _require_root
  log_stage "Preparando montagem em ${LFS}"
  mkdir -p "${LFS}" "${LFS_SOURCES_DIR}" "${LFS_TOOLS_DIR}" "${LFS}/dev" "${LFS}/proc" "${LFS}/sys" "${LFS}/run" "${LFS}/root" "${LFS}/etc"
  if is_mounted "$LFS"; then
    log_warn "${LFS} já está montado."
    return 0
  fi

  log_info "Bind /dev -> ${LFS}/dev"
  mount --bind /dev "${LFS}/dev"
  log_info "Bind /run -> ${LFS}/run"
  mount --bind /run "${LFS}/run"
  log_info "Mount proc -> ${LFS}/proc"
  mount -t proc proc "${LFS}/proc"
  log_info "Mount sysfs -> ${LFS}/sys"
  mount -t sysfs sysfs "${LFS}/sys"
  log_info "Mount devpts -> ${LFS}/dev/pts"
  mount -t devpts devpts "${LFS}/dev/pts" -o gid=5,mode=620

  # Ensure /etc exists inside chroot and copy resolv.conf for network inside chroot
  mkdir -p "${LFS}/etc"
  if [ -f /etc/resolv.conf ]; then
    cp -a /etc/resolv.conf "${LFS}/etc/resolv.conf"
    log_info "Cópia de /etc/resolv.conf para ${LFS}/etc/resolv.conf"
  fi

  log_info "Montagem concluída."
}

# Unmount in safe reverse order; ignore failures but warn
umount_lfs(){
  _require_root
  log_stage "Desmontando ${LFS} (ordem reversa segura)"
  local targets=( "${LFS}/dev/pts" "${LFS}/dev" "${LFS}/proc" "${LFS}/sys" "${LFS}/run" )
  for t in "${targets[@]}"; do
    if mountpoint -q "$t"; then
      log_info "Umount $t"
      if ! umount -l "$t" 2>/dev/null; then
        log_warn "umount -l falhou para $t; tentando forçar depois"
        umount -f "$t" 2>/dev/null || log_warn "Falha ao desmontar $t"
      fi
    fi
  done
  log_info "Desmontagem concluída (se não houver processos presos)."
}

# helper used in trap to ensure unmount attempt
umount_lfs_on_exit(){
  # only when script exits do we try to unmount if we mounted
  if is_mounted "${LFS}/proc" || is_mounted "${LFS}/dev"; then
    log_warn "Tentando desmontar LFS na saída..."
    umount_lfs || true
  fi
}

# -------------------- Create LFS user and permissions --------------------
create_lfs_user(){
  _require_root
  if id "${LFS_USER}" >/dev/null 2>&1; then
    log_info "Usuário ${LFS_USER} já existe"
  else
    log_info "Criando usuário ${LFS_USER}"
    useradd -m -s /bin/bash "${LFS_USER}" || _die "Falha ao criar usuário ${LFS_USER}"
  fi
  mkdir -p "${LFS_SOURCES_DIR}" "${LFS_TOOLS_DIR}"
  chown -R "${LFS_USER}:${LFS_USER}" "${LFS_SOURCES_DIR}" "${LFS_TOOLS_DIR}"
  chmod a+wt "${LFS_SOURCES_DIR}" || true
  log_info "Permissões ajustadas em ${LFS_SOURCES_DIR} e ${LFS_TOOLS_DIR}"
}

# -------------------- Bootstrap list parser --------------------
get_bootstrap_list(){
  # Return list via stdout, one per line
  if [ -f "$BOOTSTRAP_YAML" ]; then
    if _have python3; then
      # prefer PyYAML; fallback to naive parsing in python
      python3 - <<PY
import sys,os
p=os.path.expanduser("$BOOTSTRAP_YAML")
try:
    import yaml
    d=yaml.safe_load(open(p,'r',encoding='utf-8'))
    seq=d.get('bootstrap') or d.get('bootstrap_list') or []
    if isinstance(seq, list):
        for item in seq:
            print(item)
    else:
        # fallback string lines
        for line in str(seq).splitlines():
            line=line.strip().lstrip('-').strip()
            if line: print(line)
except Exception:
    # naive parser: find lines after 'bootstrap:' with '- item'
    out=[]
    with open(p,'r',encoding='utf-8') as f:
        started=False
        for l in f:
            if not started and l.strip().startswith('bootstrap'):
                started=True
                continue
            if started:
                s=l.strip()
                if not s: break
                if s.startswith('-'):
                    print(s.lstrip('-').strip())
PY
      return 0
    else
      # fallback to grep-based parse
      grep -E '^\s*-\s+' "$BOOTSTRAP_YAML" | sed -E 's/^\s*-\s*//' || true
    fi
  else
    log_warn "bootstrap.yaml não encontrado em $BOOTSTRAP_YAML"
    return 1
  fi
}

# -------------------- State (checkpoints/resume) --------------------
save_bootstrap_state(){
  # accepts index and current package name
  local idx="$1"; local pkg="$2"
  cat > "$BOOTSTRAP_STATE" <<JSON
{"index": ${idx}, "package":"${pkg}", "ts":"$(_timestamp)"}
JSON
  log_info "Checkpoint salvo: index=${idx} package=${pkg}"
}

load_bootstrap_state(){
  if [ -f "$BOOTSTRAP_STATE" ]; then
    cat "$BOOTSTRAP_STATE"
  else
    echo "{}"
  fi
}

clear_bootstrap_state(){
  [ -f "$BOOTSTRAP_STATE" ] && rm -f "$BOOTSTRAP_STATE"
  log_info "Checkpoint removido"
}

# -------------------- Build toolchain (usa porg_builder.sh) --------------------
build_toolchain(){
  _require_root
  local dry="${1:-false}"
  local idx=0
  # read array of packages
  mapfile -t pkgs < <(get_bootstrap_list || true)
  if [ "${#pkgs[@]}" -eq 0 ]; then
    _die "Lista bootstrap vazia; verifique $BOOTSTRAP_YAML"
  fi

  # resume if state exists
  if [ -f "$BOOTSTRAP_STATE" ]; then
    cur_json="$(load_bootstrap_state)"
    idx=$(python3 - <<PY
import json,sys
try:
  d=json.load(open("$BOOTSTRAP_STATE",'r'))
  print(int(d.get('index',0)))
except:
  print(0)
PY
)
    log_info "Resuming from index $idx"
  fi

  local total=${#pkgs[@]}
  for (( i=idx; i<total; i++ )); do
    pkg="${pkgs[i]}"
    save_bootstrap_state "$i" "$pkg"
    log_stage "[$((i+1))/$total] Construindo toolchain: $pkg"
    # invoke builder as LFS user, with env vars so builder knows we're bootstrapping
    export LFS DESTDIR LFS_TGT LFS_JOBS
    DESTDIR="${LFS}" # builder may respect DESTDIR env
    if [ "$dry" = "true" ]; then
      log_info "[DRY-RUN] sudo -u ${LFS_USER} ${BUILDER} build ${pkg}"
    else
      if id "${LFS_USER}" >/dev/null 2>&1; then
        # Prefer to run as lfs user to reduce permission problems inside build
        log_info "Chamando builder para $pkg (como ${LFS_USER})"
        if ! sudo -E -u "${LFS_USER}" "${BUILDER}" build "${pkg}"; then
          log_error "Builder falhou para ${pkg}. Verifique logs em ${LOGDIR}."
          return 1
        fi
      else
        # fallback to running as root (menos seguro)
        if ! "${BUILDER}" build "${pkg}"; then
          log_error "Builder falhou para ${pkg}. Verifique logs em ${LOGDIR}."
          return 1
        fi
      fi
    fi
    # small sync + sleep to stabilize mounts & disk
    sync
    sleep 1
  done

  log_stage "Toolchain bootstrap concluído"
  clear_bootstrap_state
}

# -------------------- Enter chroot (/mnt/lfs) with resolv.conf copied --------------------
enter_chroot(){
  _require_root
  if ! is_mounted "${LFS}/proc"; then
    log_warn "LFS não está montado; monte primeiro com 'prepare' ou 'mount'"
    return 1
  fi
  # ensure resolv.conf present
  if [ -f /etc/resolv.conf ]; then
    cp -a /etc/resolv.conf "${LFS}/etc/resolv.conf"
    log_info "resolv.conf copiado para chroot"
  fi

  # write a helper environment file inside chroot
  cat > "${LFS}/root/.porg_chroot_env.sh" <<EOF
export LFS="${LFS}"
export LFS_TGT="${LFS_TGT}"
export PATH="/tools/bin:/bin:/usr/bin"
export HOME="/root"
EOF

  log_info "Entrando no chroot ${LFS} (execute 'exit' para sair)"
  # enter chroot with a clean environment
  chroot "${LFS}" /usr/bin/env -i HOME=/root TERM="$TERM" PS1='(lfs chroot)\u:\w\$ ' PATH=/usr/bin:/bin:/tools/bin /bin/bash --login
}

# -------------------- Clean / Umount and optional cleanup --------------------
clean_all(){
  _require_root
  log_stage "Executando limpeza completa e desmontagem"
  umount_lfs
  # optional: remove LFS user? we won't remove it automatically
  log_info "Limpeza concluída"
}

# -------------------- CLI / Dispatcher --------------------
usage(){
  cat <<EOF
porg_bootstrap.sh - gerenciador bootstrap LFS

Uso: sudo porg_bootstrap.sh <comando> [opções]

Comandos:
  prepare         - monta /mnt/lfs, cria usuário lfs e prepara diretórios
  build [--dry]   - compila toolchain conforme ${BOOTSTRAP_YAML}
  enter           - entra no chroot LFS (copia resolv.conf)
  resume <pkg|idx>- retoma bootstrap do pacote (ou index) salvo em checkpoint
  clean           - desmonta /mnt/lfs de forma segura
  full            - executa: prepare -> build -> enter
  help

Exemplos:
  sudo porg_bootstrap.sh prepare
  sudo porg_bootstrap.sh build
  sudo porg_bootstrap.sh build --dry
  sudo porg_bootstrap.sh enter
  sudo porg_bootstrap.sh resume
  sudo porg_bootstrap.sh full
EOF
  exit 1
}

if [ $# -lt 1 ]; then usage; fi

cmd="$1"; shift || true

# Acquire global lock for bootstrap operations
_acquire_lock

case "$cmd" in
  prepare)
    _require_root
    mount_lfs
    create_lfs_user
    log_info "Prepare concluído"
    ;;

  build)
    _require_root
    dry="false"
    if [ "${1:-}" = "--dry" ]; then dry="true"; fi
    build_toolchain "$dry"
    ;;

  enter)
    enter_chroot
    ;;

  resume)
    # resume uses saved bootstrap state; if argument provided, attempt to set index accordingly
    arg="${1:-}"
    if [ -n "$arg" ]; then
      # if numeric, set index, else try to find index of package in bootstrap list
      if [[ "$arg" =~ ^[0-9]+$ ]]; then
        # set state index
        idx="$arg"
        # try to find package name for logging
        pkg="$(get_bootstrap_list | sed -n "$((idx+1))p" 2>/dev/null || echo "")"
        save_bootstrap_state "$idx" "$pkg"
      else
        # find index of package name in list
        mapfile -t arr < <(get_bootstrap_list || true)
        for i in "${!arr[@]}"; do
          if [ "${arr[$i]}" = "$arg" ]; then
            save_bootstrap_state "$i" "${arr[$i]}"
            break
          fi
        done
      fi
    fi
    # call build which will resume from checkpoint
    build_toolchain "false"
    ;;

  clean)
    _require_root
    clean_all
    ;;

  full)
    _require_root
    mount_lfs
    create_lfs_user
    build_toolchain "false"
    log_info "Bootstrap completo; você pode executar 'enter' para entrar no chroot"
    ;;

  help|*)
    usage
    ;;
esac

_release_lock
exit 0
