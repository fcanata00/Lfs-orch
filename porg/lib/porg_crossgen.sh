#!/usr/bin/env bash
#
# porg_crossgen.sh - Gera scripts automáticos para cross-toolchain inicial
# Local sugerido: /usr/lib/porg/porg_crossgen.sh
#
set -euo pipefail
IFS=$'\n\t'

PORG_CONF="${PORG_CONF:-/etc/porg/porg.conf}"
[ -f "$PORG_CONF" ] && source "$PORG_CONF" || true

LIBDIR="${LIBDIR:-/usr/lib/porg}"
WORKDIR="${WORKDIR:-/var/tmp/porg}"
LFS="${LFS:-/mnt/lfs}"
CROSS_DIR="${WORKDIR}/crossgen"
STATE_DIR="${STATE_DIR:-/var/lib/porg/state}/bootstrap"
LOGDIR="${LOGDIR:-/var/log/porg/bootstrap}"

mkdir -p "$CROSS_DIR" "$(dirname "$STATE_DIR")" "$LOGDIR"

_have(){ command -v "$1" >/dev/null 2>&1; }
log(){ printf "%s [CROSSGEN] %s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" >> "${LOGDIR}/crossgen-$(date +%Y%m%d).log"; }

# Basic cross generation: prepare wrapper scripts for essential bootstrap phases
# It creates small wrapper scripts that call porg_builder.sh with envs suitable for cross builds.
main(){
  log "Starting cross-toolchain generation"
  mkdir -p "$CROSS_DIR/scripts"
  cat > "${CROSS_DIR}/cross-env.sh" <<'ENV'
#!/usr/bin/env bash
export LFS="${LFS:-/mnt/lfs}"
export PATH="/tools/bin:/usr/bin:/bin"
export MAKEFLAGS="-j$(nproc)"
ENV
  chmod +x "${CROSS_DIR}/cross-env.sh"

  # templates for common bootstrap phases (binutils-pass1, gcc-pass1, etc.)
  phases=( "binutils-pass1" "gcc-pass1" "linux-headers" "glibc" "binutils-pass2" "gcc-pass2" )
  for p in "${phases[@]}"; do
    script="${CROSS_DIR}/scripts/${p}.sh"
    cat > "$script" <<SH
#!/usr/bin/env bash
# wrapper to build ${p} using porg_builder
. "${CROSS_DIR}/cross-env.sh"
exec ${LIBDIR}/porg_builder.sh build ${p}
SH
    chmod +x "$script"
    log "Generated cross script for ${p}: ${script}"
  done

  # save state marker
  mkdir -p "$STATE_DIR"
  echo "crossgen: $(date -u +%Y-%m-%dT%H:%M:%SZ)" > "${STATE_DIR}/cross-toolchain.state"
  log "Cross-toolchain scripts generated in ${CROSS_DIR}"
  echo "CROSSGEN_DIR=${CROSS_DIR}"
}

main "$@"
