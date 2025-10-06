#!/usr/bin/env bash
# porg_builder_module.sh (no yq, quiet mode with animation)
# Porg Builder Mono Module

set -euo pipefail
IFS=$'\n\t'

# Configuration variables
: "${WORKDIR:=/var/tmp/porg/work}"
: "${CACHE_DIR:=${WORKDIR}/cache}"
: "${LOG_DIR:=${WORKDIR}/logs}"
: "${HOOK_DIR:=/etc/porg/hooks}"
: "${PATCH_DIR:=${WORKDIR}/patches}"
: "${DESTDIR:=${WORKDIR}/destdir}"
: "${JOBS:=$(nproc 2>/dev/null || echo 1)}"
: "${CHROOT_METHOD:=bwrap}"
: "${STRICT_GPG:=false}"
: "${PACKAGE_FORMAT:=tar.zst}"
: "${STRIP:=true}"
: "${VERBOSE:=true}"
: "${QUIET:=false}"

# Progress animation (spinner)
spinner() {
  local pid=$1 delay=0.15 spinstr='|/-\\'
  while kill -0 $pid 2>/dev/null; do
    local temp=${spinstr#?}
    printf " [%c]  " "$spinstr"
    spinstr=$temp${spinstr%$temp}
    sleep $delay
    printf "\b\b\b\b\b\b"
  done
  printf "    \b\b\b\b"
}

# Logging
COLOR_RESET="\e[0m"
COLOR_INFO="\e[32m"
COLOR_ERROR="\e[31m"
LOG_FILE="${LOG_DIR}/porg-$(date +%Y%m%d-%H%M%S).log"
mkdir -p "${LOG_DIR}" "${WORKDIR}" "${CACHE_DIR}" "${DESTDIR}" || true

log(){
  local level="$1"; shift; local msg="$*"
  if [ "$QUIET" = true ]; then echo "[$level] $msg" >> "$LOG_FILE"; return; fi
  case $level in
    INFO) echo -e "${COLOR_INFO}[$level]${COLOR_RESET} $msg" | tee -a "$LOG_FILE";;
    ERROR) echo -e "${COLOR_ERROR}[$level]${COLOR_RESET} $msg" | tee -a "$LOG_FILE";;
    *) echo "[$level] $msg" | tee -a "$LOG_FILE";;
  esac
}

_die(){ log ERROR "$*"; exit 1; }

# Minimal YAML parser (key: value)
parse_yaml(){
  local yaml_file="$1"
  while IFS=: read -r key value; do
    key=$(echo "$key" | tr -d ' \t')
    value=$(echo "$value" | sed 's/^ *//;s/ *$//')
    [ -z "$key" ] && continue
    eval "$key=\"$value\""
  done < "$yaml_file"
}

# Download function
download_source(){
  log INFO "Downloading $SOURCE_URL"
  local file="$CACHE_DIR/$(basename "$SOURCE_URL")"
  if [ -f "$file" ]; then echo "$file"; return; fi
  curl -L --fail -o "$file.part" "$SOURCE_URL" &>/dev/null &
  pid=$!; spinner $pid; wait $pid || _die "Download failed"
  mv "$file.part" "$file"
  echo "$file"
}

# Extract function
extract_archive(){
  local src="$1" dest="$2"; mkdir -p "$dest"
  case "$src" in
    *.tar.zst) tar --use-compress-program=unzstd -xf "$src" -C "$dest";;
    *.tar.xz)  tar -xf "$src" -C "$dest";;
    *.tar.gz)  tar -xf "$src" -C "$dest";;
    *.zip) unzip -qq "$src" -d "$dest";;
    *.7z) 7z x -y -o"$dest" "$src" >/dev/null;;
    *) _die "Unknown archive format: $src";;
  esac
}

# Patch function
apply_patches(){
  [ ! -d "$PATCH_DIR" ] && return
  for p in "$PATCH_DIR"/*.patch; do
    [ -f "$p" ] || continue
    log INFO "Applying patch $p"
    (cd "$1" && patch -p1 < "$p" &>/dev/null)
  done
}

# Build function
build_in_chroot(){
  local srcdir="$1"; shift; local cmds="$@"
  log INFO "Starting build in chroot ($CHROOT_METHOD)"
  if [ "$CHROOT_METHOD" = bwrap ]; then
    bwrap --bind "$srcdir" /src --dev /dev --proc /proc --tmpfs /tmp --ro-bind /usr /usr /bin/sh -c "$cmds" &>/dev/null &
    pid=$!; spinner $pid; wait $pid
  else
    chroot "$srcdir" /bin/sh -c "$cmds"
  fi
}

# Package function
package_build(){
  log INFO "Packaging into tar.$PACKAGE_FORMAT"
  tar -cf "$WORKDIR/${PKG_NAME}-${PKG_VERSION}.tar" -C "$DESTDIR" .
  case "$PACKAGE_FORMAT" in
    tar.zst) zstd -19 "$WORKDIR/${PKG_NAME}-${PKG_VERSION}.tar";;
    tar.xz) xz -9 "$WORKDIR/${PKG_NAME}-${PKG_VERSION}.tar";;
  esac
}

# Main build pipeline
porg_build_full(){
  log INFO "Starting build for $PKG_NAME-$PKG_VERSION"
  local archive=$(download_source)
  extract_archive "$archive" "$WORKDIR/src"
  apply_patches "$WORKDIR/src"
  build_in_chroot "$WORKDIR/src" "$BUILD_CMDS && $INSTALL_CMDS"
  package_build
  log INFO "Build completed for $PKG_NAME-$PKG_VERSION"
}

# CLI
cmd=${1:-build}
case $cmd in
  build) porg_build_full;;
  *) echo "Usage: $0 build";;
esac
