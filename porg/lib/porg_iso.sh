#!/usr/bin/env bash
#
# porg_iso.sh - Gera uma ISO mínima a partir do LFS finalizado
# Local sugerido: /usr/lib/porg/porg_iso.sh
#
# Uso: porg_iso.sh [--output /path/to/lfs.iso] [--label LFS]
#
set -euo pipefail
IFS=$'\n\t'

PORG_CONF="${PORG_CONF:-/etc/porg/porg.conf}"
[ -f "$PORG_CONF" ] && source "$PORG_CONF" || true

LFS="${LFS:-/mnt/lfs}"
OUT="${1:-/var/tmp/porg/lfs.iso}"
LABEL="${2:-LFS}"
WORKDIR="${WORKDIR:-/var/tmp/porg}"
ISO_ROOT="${WORKDIR}/iso-root"
SQUASH="${WORKDIR}/iso-root.sqsh"
KERNEL_BIN="${LFS}/boot/vmlinuz"   # best-effort
INITRAMFS="${WORKDIR}/initramfs.cpio.gz"
LOGDIR="${LOGDIR:-/var/log/porg/bootstrap}"

_have(){ command -v "$1" >/dev/null 2>&1; }
log(){ printf "%s [ISO] %s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; mkdir -p "$LOGDIR"; echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" >> "${LOGDIR}/iso-$(date +%Y%m%d).log"; }

if [ "$(id -u)" -ne 0 ]; then log "Você deve rodar como root para gerar ISO"; fi

main(){
  log "Preparing ISO root in $ISO_ROOT"
  rm -rf "$ISO_ROOT" "$SQUASH" "$OUT"
  mkdir -p "$ISO_ROOT"/{boot,live}
  # Use rsync to copy minimal root (avoid proc/sys/dev)
  if _have rsync; then
    rsync -aHAX --exclude=/proc --exclude=/sys --exclude=/dev --exclude=/run "${LFS}/" "$ISO_ROOT/"
  else
    cp -a "${LFS}/." "$ISO_ROOT/"
  fi

  # create squashfs of root
  if _have mksquashfs; then
    log "Creating squashfs..."
    mksquashfs "$ISO_ROOT" "$SQUASH" -noappend -comp xz
  else
    log "mksquashfs not found; creating plain tar.xz as fallback"
    (cd "$ISO_ROOT" && tar -cJf "${SQUASH}.tar.xz" .)
    SQUASH="${SQUASH}.tar.xz"
  fi

  # prepare boot files: copy kernel if available
  if [ -f "$KERNEL_BIN" ]; then
    mkdir -p "$ISO_ROOT/boot"
    cp -a "$KERNEL_BIN" "$ISO_ROOT/boot/vmlinuz" || true
  fi

  # create basic initramfs (busybox minimal) if not present
  if ! [ -f "$INITRAMFS" ]; then
    log "Creating simple initramfs (busybox required)"
    if _have busybox; then
      tmpdir=$(mktemp -d)
      mkdir -p "$tmpdir"/{bin,sbin,etc,proc,sys,usr/bin}
      busybox --install -s "$tmpdir/bin"
      (cd "$tmpdir" && find . | cpio -H newc -o > "${WORKDIR}/initramfs.cpio")
      gzip -f "${WORKDIR}/initramfs.cpio"
      mv "${WORKDIR}/initramfs.cpio.gz" "$INITRAMFS"
      rm -rf "$tmpdir"
      log "Initramfs created at $INITRAMFS"
    else
      log "busybox not found; skipping initramfs creation"
    fi
  fi

  # add squashfs to ISO tree
  mkdir -p "$ISO_ROOT/live"
  cp -a "$SQUASH" "$ISO_ROOT/live/root.sqsh"

  # create grub-based ISO (requires grub-mkrescue or xorriso)
  if _have grub-mkrescue; then
    log "Creating ISO with grub-mkrescue -> $OUT"
    grub-mkrescue -o "$OUT" "$ISO_ROOT" 2>/dev/null || true
    log "ISO created: $OUT"
  elif _have xorriso; then
    log "Creating ISO with xorriso -> $OUT"
    xorriso -as mkisofs -o "$OUT" -J -R -V "$LABEL" "$ISO_ROOT" || true
    log "ISO created: $OUT"
  else
    log "Neither grub-mkrescue nor xorriso found; cannot create ISO"
    return 2
  fi

  log "ISO generation done: $OUT"
}

main "$@"
