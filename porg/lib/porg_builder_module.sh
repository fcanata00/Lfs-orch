#!/usr/bin/env bash
# porg_builder_module.sh
# Modular builder module for Porg
# Responsibilities:
# - download sources (HTTP/HTTPS/git)
# - extract many archive formats
# - apply patches
# - run hooks at stages
# - build inside a secure chroot (bubblewrap if available)
# - install into DESTDIR using fakeroot
# - package (tar.zst / tar.xz fallback)
# - strip binaries
# - optionally expand package into / (use with caution)
#
# Usage (environment-driven):
#   SOURCE_URL, SRC_ARCHIVE, SRC_DIR, PATCH_DIR, BUILD_CMDS (multiline),
#   INSTALL_CMDS (multiline), DESTDIR, WORKDIR, LOG_DIR, HOOK_DIR
#
# Example minimal usage:
#   SOURCE_URL="https://example.org/pkg-1.0.tar.xz" \
#   BUILD_CMDS=$'./configure --prefix=/usr\nmake -j4' \
#   INSTALL_CMDS=$'make DESTDIR=${DESTDIR} install' \
#   DESTDIR="/tmp/porg-dest" \
#   $(pwd)/porg_builder_module.sh build
#
set -euo pipefail
IFS=$'\n\t'

# ---------------------- Configurable variables (can be exported externally) ----------------------
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

# Source-specific variables (can be passed or read from metafile)
: "${SOURCE_URL:=}"           # e.g. https://.../pkg-1.0.tar.xz or git+https://...
: "${SRC_ARCHIVE:=}"          # optional local archive path
: "${SRC_DIRNAME:=source}"
: "${SRC_EXPANDED_DIR:=${WORKDIR}/${SRC_DIRNAME}}"
: "${BUILD_CMDS:=}"           # multiline commands (string with \n)
: "${INSTALL_CMDS:=}"         # multiline commands expecting DESTDIR env
: "${PKG_NAME:=pkgname}"
: "${PKG_VERSION:=0.0.0}"
: "${GPG_SIG_URL:=}"
: "${SHA256:=}"

# Internal
LOG_FILE="${LOG_DIR}/${PKG_NAME}-${PKG_VERSION}-$(date +%Y%m%d-%H%M%S).log"
mkdir -p "${WORKDIR}" "${CACHE_DIR}" "${LOG_DIR}" "${PATCH_DIR}" "${DESTDIR}"

# ---------------------- Logging ----------------------
COLOR_RESET="\e[0m"
COLOR_DEBUG="\e[36m"   # cyan
COLOR_INFO="\e[32m"    # green
COLOR_WARN="\e[33m"    # yellow
COLOR_ERROR="\e[31m"   # red

log() {
  local level="$1"; shift
  local msg="$*"
  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local color
  case "${level}" in
    DEBUG) color="${COLOR_DEBUG}" ;;
    INFO)  color="${COLOR_INFO}"  ;;
    WARN)  color="${COLOR_WARN}"  ;;
    ERROR) color="${COLOR_ERROR}" ;;
    *)     color="" ;;
  esac
  if [ "${VERBOSE}" = true ]; then
    if [ -n "${color}" ]; then
      printf "%s %b[%s]%b %s\n" "${ts}" "${color}" "${level}" "${COLOR_RESET}" "${msg}"
    else
      printf "%s [%s] %s\n" "${ts}" "${level}" "${msg}"
    fi
  fi
  printf "%s [%s] %s\n" "${ts}" "${level}" "${msg}" >> "${LOG_FILE}"
}

_die() { log ERROR "${*}"; exit 1; }

# ---------------------- Helpers ----------------------
run_hooks() {
  local stage="$1"
  local hdir
  hdir="${HOOK_DIR}/${stage}"
  log DEBUG "Running hooks for stage=${stage} (dir=${hdir})"
  if [ -d "${hdir}" ]; then
    for hook in "${hdir}"/*; do
      [ -x "${hook}" ] || continue
      log INFO "Executing hook: ${hook}"
      ("${hook}") || { log WARN "Hook ${hook} exited non-zero"; }
    done
  fi
}

detect_archive_type() {
  local file="$1"
  case "${file}" in
    *.tar.gz|*.tgz) echo tar.gz ;;
    *.tar.bz2|*.tbz2) echo tar.bz2 ;;
    *.tar.xz|*.txz) echo tar.xz ;;
    *.tar.zst|*.tzst) echo tar.zst ;;
    *.zip) echo zip ;;
    *.7z) echo 7z ;;
    *.tar) echo tar ;;
    *)
      # fallback to file magic
      file --brief --mime-type "${file}" 2>/dev/null || echo unknown
      ;;
  esac
}

ensure_tool() {
  local tool="$1"
  command -v "${tool}" >/dev/null 2>&1 || _die "Required tool '${tool}' not found in PATH"
}

# ---------------------- Download ----------------------
download_source() {
  log INFO "Download: source_url='${SOURCE_URL}'"
  if [ -n "${SRC_ARCHIVE}" ] && [ -f "${SRC_ARCHIVE}" ]; then
    log INFO "Using provided local archive: ${SRC_ARCHIVE}"
    cp -a "${SRC_ARCHIVE}" "${CACHE_DIR}/"
    echo "${CACHE_DIR}/$(basename "${SRC_ARCHIVE}")"
    return 0
  fi

  if [[ "${SOURCE_URL}" == git+* ]]; then
    ensure_tool git
    local url
    url="${SOURCE_URL#git+}"
    local dest="${CACHE_DIR}/$(basename "${url%.*}")-git"
    if [ -d "${dest}" ]; then
      log INFO "Refreshing git repo ${url}"
      git -C "${dest}" fetch --all --tags --prune || true
    else
      log INFO "Cloning git repo ${url} -> ${dest}"
      git clone --depth 1 "${url}" "${dest}"
    fi
    echo "${dest}"
    return 0
  fi

  if [[ "${SOURCE_URL}" =~ ^https?://|^ftp:// ]]; then
    ensure_tool curl
    local out="${CACHE_DIR}/$(basename "${SOURCE_URL}")"
    if [ -f "${out}" ]; then
      log INFO "Using cached ${out}"
      echo "${out}" && return 0
    fi
    log INFO "Downloading ${SOURCE_URL} -> ${out}"
    curl -L --fail --retry 5 --retry-delay 2 -o "${out}.part" "${SOURCE_URL}" || _die "Download failed"
    mv "${out}.part" "${out}"
    echo "${out}"
    return 0
  fi

  _die "Unsupported SOURCE_URL: ${SOURCE_URL}"
}

# ---------------------- Verify ----------------------
verify_archive() {
  local file="$1"
  if [ -n "${SHA256}" ]; then
    ensure_tool sha256sum
    log INFO "Verifying SHA256 for ${file}"
    echo "${SHA256}  ${file}" | sha256sum -c - || _die "SHA256 mismatch"
  fi
  if [ -n "${GPG_SIG_URL}" ]; then
    ensure_tool gpg
    # download signature to temp
    local sig="${CACHE_DIR}/$(basename "${GPG_SIG_URL}")"
    curl -L --fail -o "${sig}.part" "${GPG_SIG_URL}" && mv "${sig}.part" "${sig}"
    gpg --verify "${sig}" "${file}" || _die "GPG verification failed"
  fi
}

# ---------------------- Extract ----------------------
extract_archive() {
  local archive="$1"
  local destdir="$2"
  mkdir -p "${destdir}"
  local atype
  atype=$(detect_archive_type "${archive}")
  log INFO "Extracting ${archive} (type=${atype}) -> ${destdir}"
  case "${atype}" in
    tar.gz|tar.bz2|tar.xz|tar|tar.zst)
      ensure_tool tar
      if [ "${atype}" = "tar.zst" ]; then
        ensure_tool zstd || true
        tar --use-compress-program=unzstd -xf "${archive}" -C "${destdir}"
      else
        tar -xf "${archive}" -C "${destdir}"
      fi
      ;;
    zip)
      ensure_tool unzip
      unzip -qq "${archive}" -d "${destdir}"
      ;;
    7z)
      ensure_tool 7z
      7z x -y -o"${destdir}" "${archive}" >/dev/null
      ;;
    *)
      _die "Unknown archive type: ${atype}"
      ;;
  esac
}

# ---------------------- Patch ----------------------
apply_patches() {
  local target_src_dir="$1"
  if [ -d "${PATCH_DIR}" ] && [ "$(ls -A "${PATCH_DIR}" 2>/dev/null || true)" ]; then
    ensure_tool patch
    for p in "${PATCH_DIR}"/*; do
      [ -f "${p}" ] || continue
      log INFO "Applying patch ${p}"
      (cd "${target_src_dir}" && patch -p1 < "${p}") || _die "Patch ${p} failed"
    done
  else
    log DEBUG "No patches to apply in ${PATCH_DIR}"
  fi
}

# ---------------------- Chroot wrapper ----------------------
run_in_chroot() {
  local root="$1"; shift
  local cmds=("$@")
  if [ "${CHROOT_METHOD}" = "bwrap" ] && command -v bwrap >/dev/null 2>&1; then
    ensure_tool bwrap
    # Minimal bubblewrap sandbox, bind necessary dirs
    log DEBUG "Using bubblewrap for chroot"
    bwrap \
      --bind "${root}" / \
      --dev /dev \
      --proc /proc \
      --tmpfs /tmp \
      --ro-bind /etc /etc \
      --ro-bind /usr /usr \
      --setenv DESTDIR "${DESTDIR}" \
      --setenv JOBS "${JOBS}" \
      --setenv HOME /root \
      --unshare-net \
      --die-with-parent \
      /bin/sh -c "cd /${SRC_DIRNAME} && ${cmds[*]}"
  else
    # fallback to chroot (requires root)
    ensure_tool chroot
    log WARN "bwrap not available or CHROOT_METHOD != bwrap; falling back to chroot (requires root)"
    chroot "${root}" /bin/sh -c "cd /${SRC_DIRNAME} && ${cmds[*]}"
  fi
}

# ---------------------- Build and install ----------------------
build_and_install() {
  local srcpath="$1"
  log INFO "Preparing build directory"
  mkdir -p "${DESTDIR}"
  # copy source into a dedicated build root under WORKDIR/chroot_root
  local chroot_root="${WORKDIR}/chroot_root"
  rm -rf "${chroot_root}"
  mkdir -p "${chroot_root}/${SRC_DIRNAME}"
  cp -a "${srcpath}/." "${chroot_root}/${SRC_DIRNAME}/"

  # create a simple environment inside chroot: /usr, /bin may be read-only binds by bwrap
  # Build commands are run as a simple sh -c string
  local build_script
  build_script="set -e; export DESTDIR=/${DESTDIR#*/}; export JOBS=${JOBS}; "
  if [ -n "${BUILD_CMDS}" ]; then
    # replace newlines with '&&' to fail fast and preserve sequence
    local bcmds
    bcmds=$(printf "%s" "${BUILD_CMDS}" | awk 'BEGIN{ORS=" && ";} {gsub(/$/,"",$0); print}' )
    build_script+="${bcmds};"
  fi
  if [ -n "${INSTALL_CMDS}" ]; then
    local icmds
    icmds=$(printf "%s" "${INSTALL_CMDS}" | awk 'BEGIN{ORS=" && ";} {gsub(/$/,"",$0); print}' )
    build_script+="fakeroot sh -c '${icmds}';"
  fi

  run_hooks "pre-build"

  log INFO "Running build in chroot (method=${CHROOT_METHOD})"
  run_in_chroot "${chroot_root}" "${build_script}"
  log INFO "Build finished"

  run_hooks "post-build"

  # Copy installed files from DESTDIR (inside chroot) to real DESTDIR path
  # note: if bwrap used a fake DESTDIR path, we must locate installed files
  # Here we assume fakeroot created files under ${chroot_root}${DESTDIR}
  local installed_root="${chroot_root}${DESTDIR}"
  if [ -d "${installed_root}" ]; then
    log INFO "Merging installed files into ${DESTDIR}"
    mkdir -p "$(dirname "${DESTDIR}")"
    cp -a "${installed_root}/." "${DESTDIR}/"
  else
    log WARN "No installed files found at ${installed_root}"
  fi
}

# ---------------------- Strip and package ----------------------
strip_and_package() {
  local destdir="$1"
  local outdir="${WORKDIR}/packages"
  mkdir -p "${outdir}"
  local pkgfile
  pkgfile="${outdir}/${PKG_NAME}-${PKG_VERSION}.tar"

  if [ "${STRIP}" = true ]; then
    # find ELF files and strip
    ensure_tool file
    ensure_tool strip
    log INFO "Stripping binaries in ${destdir}"
    while IFS= read -r -d '' f; do
      if file "$f" | grep -q ELF; then
        strip --strip-unneeded "$f" || log WARN "strip failed for $f"
      fi
    done < <(find "${destdir}" -type f -print0)
  fi

  log INFO "Packaging ${destdir} -> ${pkgfile}"
  (cd "${destdir}" && tar -cf "${pkgfile}" .)
  case "${PACKAGE_FORMAT}" in
    tar.zst)
      if command -v zstd >/dev/null 2>&1; then
        zstd -T0 -19 "${pkgfile}" -o "${pkgfile}.zst"
        pkgfile="${pkgfile}.zst"
      else
        xz -9 "${pkgfile}" && pkgfile="${pkgfile}.xz"
      fi
      ;;
    tar.xz)
      xz -9 "${pkgfile}" && pkgfile="${pkgfile}.xz"
      ;;
    tar.gz)
      gzip -9 "${pkgfile}" && pkgfile="${pkgfile}.gz"
      ;;
    *)
      log WARN "Unknown PACKAGE_FORMAT ${PACKAGE_FORMAT}; leaving uncompressed"
      ;;
  esac
  log INFO "Package created: ${pkgfile}"
  echo "${pkgfile}"
}

# ---------------------- Expand package into / (dangerous) ----------------------
expand_into_root() {
  local package_path="$1"
  log WARN "Expanding package ${package_path} into / — this will overwrite files. Be sure you know what you're doing."
  run_hooks "pre-expand-root"
  case "${package_path}" in
    *.tar|*.tar.*|*.tar.zst|*.tar.xz|*.tar.gz)
      if [[ "${package_path}" == *.zst ]]; then
        ensure_tool zstd
        mkdir -p /tmp/porg_expand
        zstd -d "${package_path}" -c | tar -xf - -C /
      elif [[ "${package_path}" == *.xz ]]; then
        xz -d "${package_path}" -c | tar -xf - -C /
      else
        tar -xf "${package_path}" -C /
      fi
      ;;
    *)
      _die "Unsupported package type for expand: ${package_path}"
      ;;
  esac
  run_hooks "post-expand-root"
}

# ---------------------- High level build entrypoint ----------------------
porg_build_full() {
  # Sequence: download -> verify -> extract -> patch -> chroot build/install -> package -> optional expand
  run_hooks "pre-download"
  local src
  src=$(download_source) || _die "download failed"
  run_hooks "post-download"

  if [ -d "${src}" ]; then
    # git or directory
    local srcpath="${src}"
  else
    verify_archive "${src}"
    local extract_to="${WORKDIR}/src_extracted"
    rm -rf "${extract_to}" && mkdir -p "${extract_to}"
    extract_archive "${src}" "${extract_to}"
    # find top-level dir
    local maybe_dir
    maybe_dir=$(find "${extract_to}" -maxdepth 1 -mindepth 1 -type d | head -n1 || true)
    if [ -n "${maybe_dir}" ]; then
      srcpath="${maybe_dir}"
    else
      srcpath="${extract_to}"
    fi
  fi

  run_hooks "pre-patch"
  apply_patches "${srcpath}"
  run_hooks "post-patch"

  run_hooks "pre-build"
  build_and_install "${srcpath}"
  run_hooks "post-build"

  local pkgpath
  pkgpath=$(strip_and_package "${DESTDIR}")

  log INFO "Build pipeline finished for ${PKG_NAME}-${PKG_VERSION}. Package at ${pkgpath}"

  # optional: expand into / if user asked via env variable EXPAND_TO_ROOT=true
  if [ "${EXPAND_TO_ROOT:-false}" = true ]; then
    expand_into_root "${pkgpath}"
  fi
}

# ---------------------- CLI ----------------------
usage() {
  cat <<EOF
Usage: ${0##*/} <command>
Commands:
  build       Run full build pipeline (reads env variables described at top)
  package     Package an existing DESTDIR into archive
  expand-root Expand generated package into /
  help        Show this help

Environment variables accepted (examples):
  SOURCE_URL, SRC_ARCHIVE, BUILD_CMDS, INSTALL_CMDS, DESTDIR, WORKDIR, PATCH_DIR, HOOK_DIR,
  PKG_NAME, PKG_VERSION, PACKAGE_FORMAT, STRIP, EXPAND_TO_ROOT
EOF
}

cmd="$1" || cmd=help
case "${cmd}" in
  build)
    porg_build_full
    ;;
  package)
    strip_and_package "${DESTDIR}"
    ;;
  expand-root)
    if [ -z "${2:-}" ]; then _die "expand-root requires package path argument"; fi
    expand_into_root "${2}";
    ;;
  help|*)
    usage;;
esac
