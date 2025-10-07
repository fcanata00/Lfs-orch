#!/usr/bin/env bash
# porg_builder.sh - Builder module for Porg (improved)
# Responsibilities: parse metafile, resolve deps, download multi-sources, extract, patch,
# run hooks, build in secure chroot (bwrap), install (fakeroot), package (tar.zst), strip,
# optional expand into /, performance summary, integrated logging and DB registration.
set -euo pipefail
IFS=$'\n\t'

# -------------------- Load config early --------------------
PORG_CONF="${PORG_CONF:-/etc/porg/porg.conf}"
if [ -f "$PORG_CONF" ]; then
  # shellcheck disable=SC1090
  source "$PORG_CONF"
fi

# -------------------- Defaults (can be overridden in porg.conf) --------------------
WORKDIR="${WORKDIR:-/var/tmp/porg/work}"
CACHE_DIR="${CACHE_DIR:-${WORKDIR}/cache}"
LOG_DIR="${LOG_DIR:-${WORKDIR}/logs}"
REPORT_DIR="${REPORT_DIR:-/var/log/porg/reports}"
HOOK_DIR="${HOOK_DIR:-/etc/porg/hooks}"
PATCH_DIR="${PATCH_DIR:-${WORKDIR}/patches}"
DESTDIR_BASE="${DESTDIR_BASE:-/var/tmp/porg/dest}"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 1)}"
CHROOT_METHOD="${CHROOT_METHOD:-bwrap}"
PACKAGE_FORMAT="${PACKAGE_FORMAT:-tar.zst}"
STRIP_BINARIES="${STRIP_BINARIES:-true}"
GPG_KEYRING="${GPG_KEYRING:-/etc/porg/trustedkeys.gpg}"
DEPS_PY="${DEPS_PY:-/usr/lib/porg/porg_deps.py}"
LOGGER_SCRIPT="${LOGGER_MODULE:-/usr/lib/porg/porg_logger.sh}"
DB_SCRIPT="${DB_CMD:-/usr/lib/porg/porg_db.sh}"
BUILDER_NAME="${BUILDER_NAME:-porg}"   # command used by orchestrator to call install, fallback
mkdir -p "$WORKDIR" "$CACHE_DIR" "$LOG_DIR" "$REPORT_DIR" "$HOOK_DIR" "$PATCH_DIR" "$DESTDIR_BASE"

# -------------------- Logger integration --------------------
if [ -f "$LOGGER_SCRIPT" ]; then
  # shellcheck disable=SC1090
  source "$LOGGER_SCRIPT"
else
  log_info(){ printf "%s [INFO] %s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
  log_warn(){ printf "%s [WARN] %s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
  log_error(){ printf "%s [ERROR] %s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
  log_stage(){ printf "%s [STAGE] %s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
  log_progress(){ printf "%s\n" "$*"; }
fi

# -------------------- Basic helpers --------------------
_die(){ log_error "$*"; exit 1; }
_have_cmd(){ command -v "$1" >/dev/null 2>&1; }
_timestamp(){ date -u +%Y%m%dT%H%M%SZ; }

# -------------------- Args and usage --------------------
usage(){
  cat <<EOF
Usage: $(basename "$0") <command> [options]
Commands:
  build <metafile.yaml>       Run full build pipeline for given metafile
  help                        Show this help

Environment / options can be set in porg.conf. Common env:
  WORKDIR, CACHE_DIR, LOG_DIR, DESTDIR_BASE, PACKAGE_FORMAT, STRIP_BINARIES, CHROOT_METHOD
EOF
  exit 1
}

if [ $# -lt 1 ]; then usage; fi
cmd="$1"; shift || true

# -------------------- YAML/Metafile loader (use PyYAML if available, else fallback) --------------------
_load_metafile_python() {
  local mf="$1"
  python3 - <<PY
import sys,json
try:
    import yaml
    data=yaml.safe_load(open("$mf",'r',encoding='utf-8'))
except Exception:
    # fallback naive parser
    txt=open("$mf",'r',encoding='utf-8').read()
    data={}
    for line in txt.splitlines():
        line=line.strip()
        if not line or line.startswith("#"): continue
        if ":" in line:
            k,v=line.split(":",1)
            data[k.strip()]=v.strip().strip('"').strip("'")
print(json.dumps(data or {}))
PY
}

# -------------------- Metafile fields normalization --------------------
parse_metafile() {
  local metafile="$1"
  if [ ! -f "$metafile" ]; then _die "Metafile not found: $metafile"; fi
  MF_JSON="$(_load_metafile_python "$metafile")"
  # extract important fields into shell vars (defaults if not set)
  PKG_NAME="$(python3 - <<PY
import sys,json
d=json.loads(sys.stdin.read() or "{}")
print(d.get("name","") or d.get("pkg","") or "")
PY
"$MF_JSON")"
  PKG_VERSION="$(python3 - <<PY
import sys,json
d=json.loads(sys.stdin.read() or "{}")
print(d.get("version","") or d.get("ver","") or "")
PY
"$MF_JSON")"
  # list of sources (can be SOURCE_URL or SOURCE_URLS as list)
  SOURCE_URLS=()
  mapfile -t SOURCE_URLS < <(python3 - <<PY
import sys,json
d=json.loads(sys.stdin.read() or "{}")
out=[]
if "source_urls" in d and isinstance(d["source_urls"], list):
    out=d["source_urls"]
elif "source_urls" in d and isinstance(d["source_urls"], str):
    out=[d["source_urls"]]
elif "source_url" in d:
    out=[d["source_url"]]
elif "sources" in d:
    if isinstance(d["sources"], list): out=d["sources"]
    elif isinstance(d["sources"], str): out=[d["sources"]]
print("\\n".join(out))
PY
"$MF_JSON")
  # build and install commands (multiline strings)
  BUILD_CMDS="$(python3 - <<PY
import sys,json
d=json.loads(sys.stdin.read() or "{}")
b=d.get("build_cmds") or d.get("build") or d.get("build_cmd") or ""
if isinstance(b,list):
    print("\\n".join(b))
else:
    print(b or "")
PY
"$MF_JSON")"
  INSTALL_CMDS="$(python3 - <<PY
import sys,json
d=json.loads(sys.stdin.read() or "{}")
i=d.get("install_cmds") or d.get("install") or d.get("install_cmd") or ""
if isinstance(i,list):
    print("\\n".join(i))
else:
    print(i or "")
PY
"$MF_JSON")"
  SHA256="$(python3 - <<PY
import sys,json
d=json.loads(sys.stdin.read() or "{}")
print(d.get("sha256","") or d.get("sha256s","") or "")
PY
"$MF_JSON")"
  GPG_SIG_URL="$(python3 - <<PY
import sys,json
d=json.loads(sys.stdin.read() or "{}")
print(d.get("gpg_sig","") or d.get("gpg_sig_url","") or "")
PY
"$MF_JSON")"
  PATCHES_DIR="$(python3 - <<PY
import sys,json,os
d=json.loads(sys.stdin.read() or "{}")
p=d.get("patches_dir","") or d.get("patch_dir","")
if p:
    print(p)
else:
    print("")
PY
"$MF_JSON")"
  # hooks directory relative or absolute
  META_HOOK_DIR="$(python3 - <<PY
import sys,json
d=json.loads(sys.stdin.read() or "{}")
print(d.get("hooks_dir","") or d.get("hook_dir","") or "")
PY
"$MF_JSON")"
  # package format override
  META_PKG_FORMAT="$(python3 - <<PY
import sys,json
d=json.loads(sys.stdin.read() or "{}")
print(d.get("package_format","") or "")
PY
"$MF_JSON")"
  # patch default
  : "${META_PKG_FORMAT:=${PACKAGE_FORMAT}}"
  # destdir target
  TARGET_PREFIX="$(python3 - <<PY
import sys,json
d=json.loads(sys.stdin.read() or "{}")
print(d.get("prefix","") or d.get("target_prefix","") or "/")
PY
"$MF_JSON")"
  # toolchain/build requirement hints
  TOOLCHAIN_HINT="$(python3 - <<PY
import sys,json
d=json.loads(sys.stdin.read() or "{}")
print(d.get("toolchain","") or "")
PY
"$MF_JSON")"
}

# -------------------- Resolve dependencies before build --------------------
resolve_dependencies_prebuild() {
  if [ -x "$DEPS_PY" ]; then
    log_stage "Resolving dependencies for ${PKG_NAME} via $DEPS_PY"
    if [ "${DRY_RUN:-false}" = true ]; then
      log_info "[DRY-RUN] Would call $DEPS_PY for ${PKG_NAME}"
      return 0
    fi
    "$DEPS_PY" resolve "$PKG_NAME" > "${TMPDIR}/deps-resolve.json" 2>/dev/null || log_warn "deps.py resolve returned non-zero"
    # optional: builder can act on this file externally
  else
    log_debug "No deps resolver found at $DEPS_PY; skipping prebuild resolve"
  fi
}

# -------------------- Download helpers --------------------
download_http() {
  local url="$1"; local outdir="$2"
  mkdir -p "$outdir"
  local fname
  fname="$(basename "$url")"
  local out="$outdir/$fname"
  if [ -f "$out" ]; then
    log_info "Using cached $out"
    echo "$out" && return 0
  fi
  if _have_cmd curl; then
    log_info "Downloading $url -> $out"
    curl -L --fail --retry 5 --retry-delay 2 -o "${out}.part" "$url" || { rm -f "${out}.part"; return 1; }
    mv "${out}.part" "${out}"
    echo "$out"
    return 0
  elif _have_cmd wget; then
    log_info "Downloading $url -> $out (wget)"
    wget -O "${out}.part" "$url" || { rm -f "${out}.part"; return 1; }
    mv "${out}.part" "${out}"
    echo "$out"
    return 0
  else
    log_warn "No HTTP downloader available (curl/wget)"
    return 1
  fi
}

download_sources() {
  log_stage "download_sources"
  mkdir -p "${CACHE_DIR}"
  DOWNLOADS=()
  for url in "${SOURCE_URLS[@]}"; do
    [ -z "$url" ] && continue
    if [[ "$url" == git+* ]]; then
      url_git="${url#git+}"
      dest="${CACHE_DIR}/git-$(basename "${url_git%.*}")"
      if [ -d "$dest/.git" ]; then
        log_info "Refreshing git repo $url_git -> $dest"
        git -C "$dest" fetch --all --tags --prune || true
      else
        log_info "Cloning $url_git -> $dest"
        git clone --depth 1 "$url_git" "$dest"
      fi
      DOWNLOADS+=("$dest")
      continue
    fi
    # http/ftp/file
    file="$(download_http "$url" "$CACHE_DIR")" || { log_warn "Failed to download $url"; continue; }
    DOWNLOADS+=("$file")
  done
  # verify sha256 if provided (simple: only if single sha provided)
  if [ -n "${SHA256:-}" ] && [ "${#DOWNLOADS[@]}" -gt 0 ]; then
    log_info "Verifying SHA256 if provided"
    if _have_cmd sha256sum; then
      for f in "${DOWNLOADS[@]}"; do
        if [ -f "$f" ]; then
          echo "${SHA256}  ${f}" | sha256sum -c - >/dev/null 2>&1 || _die "SHA256 mismatch for ${f}"
        fi
      done
    fi
  fi
  # verify gpg sig if specified
  if [ -n "${GPG_SIG_URL:-}" ]; then
    if _have_cmd gpg; then
      sig="${CACHE_DIR}/$(basename "${GPG_SIG_URL}")"
      download_http "${GPG_SIG_URL}" "$CACHE_DIR" >/dev/null 2>&1 || true
      for f in "${DOWNLOADS[@]}"; do
        if [ -f "$f" ] && [ -f "$sig" ]; then
          gpg --no-default-keyring --keyring "${GPG_KEYRING}" --verify "$sig" "$f" || _die "GPG verify failed for $f"
        fi
      done
    fi
  fi
  # return array in DOWNLOADS var
}

# -------------------- Extract helpers --------------------
detect_archive_type() {
  local file="$1"
  case "$file" in
    *.tar.gz|*.tgz) echo tar.gz ;;
    *.tar.bz2|*.tbz2) echo tar.bz2 ;;
    *.tar.xz|*.txz) echo tar.xz ;;
    *.tar.zst|*.tzst) echo tar.zst ;;
    *.zip) echo zip ;;
    *.7z) echo 7z ;;
    *.tar) echo tar ;;
    *) file --brief --mime-type "$file" 2>/dev/null || echo "unknown" ;;
  esac
}

extract_archive() {
  local archive="$1"; local dest="$2"
  mkdir -p "$dest"
  local atype
  atype="$(detect_archive_type "$archive")"
  log_info "Extracting $archive -> $dest (type=$atype)"
  case "$atype" in
    tar.gz|tar.bz2|tar.xz|tar)
      tar -xf "$archive" -C "$dest" ;;
    tar.zst)
      if _have_cmd zstd; then
        tar --use-compress-program=unzstd -xf "$archive" -C "$dest"
      else
        _die "zstd required to extract .zst archives"
      fi ;;
    zip) unzip -qq "$archive" -d "$dest" ;; 
    7z) 7z x -y -o"$dest" "$archive" >/dev/null ;; 
    *) _die "Unknown archive type: $archive" ;;
  esac
}

# -------------------- Patches --------------------
apply_patches_to_src() {
  local srcdir="$1"
  # patches may be in PATCHES_DIR or in package-specific path
  local pdirs=()
  [ -n "$PATCHES_DIR" ] && pdirs+=("$PATCHES_DIR")
  [ -n "$PATCH_DIR" ] && pdirs+=("$PATCH_DIR")
  for pdir in "${pdirs[@]}"; do
    [ -d "$pdir" ] || continue
    for p in "$pdir"/*; do
      [ -f "$p" ] || continue
      log_info "Applying patch $p in $srcdir"
      (cd "$srcdir" && patch -p1 < "$p") || _die "Patch failed: $p"
    done
  done
}

# -------------------- Hooks runner --------------------
run_hooks() {
  local stage="$1"
  local hooks=()
  # global hooks dir
  [ -d "$HOOK_DIR/$stage" ] && for h in "$HOOK_DIR/$stage"/*; do [ -x "$h" ] && hooks+=("$h"); done
  # metafile-specific hooks dir (if set)
  if [ -n "$META_HOOK_DIR" ] && [ -d "$META_HOOK_DIR/$stage" ]; then
    for h in "$META_HOOK_DIR/$stage"/*; do [ -x "$h" ] && hooks+=("$h"); done
  fi
  for h in "${hooks[@]}"; do
    log_info "Running hook $h (stage=$stage)"
    if [ "$DRY_RUN" = true ]; then
      log_info "[DRY-RUN] Would run $h"
    else
      ("$h") || log_warn "Hook $h exited non-zero"
    fi
  done
}

# -------------------- Build inside chroot (bubblewrap) --------------------
run_in_chroot() {
  local chroot_root="$1"
  shift
  local cmd="$*"
  if [ "$CHROOT_METHOD" = "bwrap" ] && _have_cmd bwrap; then
    log_debug "Running in bwrap: $cmd"
    bwrap --bind "$chroot_root" / \
      --ro-bind /usr /usr \
      --dev /dev \
      --proc /proc \
      --tmpfs /tmp \
      --setenv DESTDIR "$DESTDIR_INSIDE" \
      --setenv JOBS "$JOBS" \
      --unshare-net --die-with-parent /bin/sh -c "cd /${SRC_BASENAME} && $cmd"
  else
    if [ "$(id -u)" -ne 0 ]; then
      _die "Chroot build requires bubblewrap or root privileges for chroot"
    fi
    log_warn "Using system chroot (requires root)"
    chroot "$chroot_root" /bin/sh -c "cd /${SRC_BASENAME} && $cmd"
  fi
}

# -------------------- Build & install flow --------------------
build_from_source() {
  local srcpath="$1"
  # prepare chroot root (copy source)
  CHROOT_ROOT="${WORKDIR}/chroot_${PKG_NAME}_${PKG_VERSION}"
  rm -rf "$CHROOT_ROOT"
  mkdir -p "$CHROOT_ROOT/${SRC_BASENAME}"
  # copy all source content
  cp -a "${srcpath}/." "$CHROOT_ROOT/${SRC_BASENAME}/"
  DESTDIR_INSIDE="/${DESTDIR#"/"}" # but builder will use faket dest
  # construct combined build command
  local cmds="set -e; export JOBS=${JOBS};"
  if [ -n "$BUILD_CMDS" ]; then
    # convert newlines to '&&'
    local bcmd
    bcmd="$(printf "%s" "$BUILD_CMDS" | awk 'BEGIN{ORS=" && ";} {gsub(/$|\\n/,""); print}')"
    cmds+="$bcmd;"
  fi
  if [ -n "$INSTALL_CMDS" ]; then
    local icmd
    icmd="$(printf "%s" "$INSTALL_CMDS" | awk 'BEGIN{ORS=" && ";} {gsub(/$|\\n/,""); print}')"
    # run install under fakeroot in chroot, so DESTDIR observed
    cmds+="fakeroot sh -c '${icmd}';"
  fi

  run_hooks "pre-build"
  log_stage "Building package ${PKG_NAME}-${PKG_VERSION}"
  if [ "$DRY_RUN" = true ]; then
    log_info "[DRY-RUN] Would build with commands: $BUILD_CMDS"
  else
    run_in_chroot "$CHROOT_ROOT" "$cmds" || _die "Build failed for ${PKG_NAME}"
    log_info "Build completed for ${PKG_NAME}"
  fi
  run_hooks "post-build"

  # copy installed files from chroot DESTDIR to real DESTDIR
  if [ -d "${CHROOT_ROOT}${DESTDIR}" ]; then
    mkdir -p "$DESTDIR"
    cp -a "${CHROOT_ROOT}${DESTDIR}/." "${DESTDIR}/"
    log_info "Installed files merged into ${DESTDIR}"
  else
    log_warn "No files found in chroot DESTDIR (${CHROOT_ROOT}${DESTDIR})"
  fi
}

# -------------------- Strip & Package --------------------
strip_and_package() {
  local dest="$1"
  local outdir="${WORKDIR}/packages"
  mkdir -p "$outdir"
  local pkgfile="${outdir}/${PKG_NAME}-${PKG_VERSION}.tar"
  if [ "$STRIP_BINARIES" = true ]; then
    if _have_cmd strip; then
      log_info "Stripping ELF binaries in $dest"
      while IFS= read -r -d '' f; do
        if file "$f" 2>/dev/null | grep -q ELF; then
          strip --strip-unneeded "$f" || log_warn "strip failed for $f"
        fi
      done < <(find "$dest" -type f -print0)
    else
      log_warn "strip not available"
    fi
  fi
  (cd "$dest" && tar -cf "$pkgfile" .)
  case "$META_PKG_FORMAT" in
    tar.zst|tar.zstd|tar.zst)
      if _have_cmd zstd; then
        zstd -T0 -19 "$pkgfile" -o "${pkgfile}.zst" && pkgfile="${pkgfile}.zst"
      else
        xz -9 "$pkgfile" && pkgfile="${pkgfile}.xz"
      fi ;;
    tar.xz)
      xz -9 "$pkgfile" && pkgfile="${pkgfile}.xz" ;;
    tar.gz)
      gzip -9 "$pkgfile" && pkgfile="${pkgfile}.gz" ;;
    *)
      log_warn "Unknown package format: $META_PKG_FORMAT; leaving uncompressed"
  esac
  log_info "Package created: $pkgfile"
  echo "$pkgfile"
}

# -------------------- Optional expand to root --------------------
expand_into_root() {
  local package_path="$1"
  log_warn "Expanding $package_path into / (dangerous)"
  [ "$DRY_RUN" = true ] && { log_info "[DRY-RUN] Would expand $package_path into /"; return 0; }
  case "$package_path" in
    *.tar|*.tar.*|*.tar.zst|*.tar.xz|*.tar.gz)
      if [[ "$package_path" == *.zst ]]; then
        zstd -d "$package_path" -c | sudo tar -xf - -C /
      elif [[ "$package_path" == *.xz ]]; then
        xz -d "$package_path" -c | sudo tar -xf - -C /
      else
        sudo tar -xf "$package_path" -C /
      fi ;;
    *) _die "Unsupported package type for expand: $package_path" ;;
  esac
}

# -------------------- Register to DB --------------------
register_pkg_in_db() {
  if [ -x "$DB_SCRIPT" ]; then
    if [ "$DRY_RUN" = true ]; then
      log_info "[DRY-RUN] Would register ${PKG_NAME}-${PKG_VERSION} in DB"
    else
      "$DB_SCRIPT" register "$PKG_NAME" "$PKG_VERSION" "$TARGET_PREFIX" '{"source":"metafile"}' || log_warn "DB register returned non-zero"
    fi
  else
    log_warn "DB script not present; skipping register"
  fi
}

# -------------------- Performance summary --------------------
emit_performance_summary() {
  local start_ts="$1"; local end_ts="$2"
  local elapsed=$((end_ts - start_ts))
  local load="$(awk '{print $1" "$2" "$3}' /proc/loadavg 2>/dev/null || echo "0.00 0.00 0.00")"
  local mem_free="$(awk '/MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
  log_info "BUILD SUMMARY: package=${PKG_NAME}-${PKG_VERSION} duration=${elapsed}s loadavg=${load} mem_avail_kb=${mem_free} log=${LOG_FILE}"
  # also write JSON summary
  python3 - <<PY > "${REPORT_DIR}/build-summary-${PKG_NAME}-${PKG_VERSION}-${_timestamp}.json"
import json,time
print(json.dumps({"package": "${PKG_NAME}-${PKG_VERSION}", "duration_s": ${elapsed}, "loadavg": "${load}", "mem_avail_kb": ${mem_free}, "log":"${LOG_FILE}"}, indent=2))
PY
}

# -------------------- Main build entrypoint --------------------
build_pipeline() {
  local metafile="$1"
  parse_metafile "$metafile"
  # defaults
  : "${PKG_NAME:=$(basename "$metafile" | sed 's/\.ya\?ml$//')}"
  : "${PKG_VERSION:=0.0.0}"
  : "${META_PKG_FORMAT:=${PACKAGE_FORMAT}}"
  # logs
  LOG_FILE="${LOG_DIR}/${PKG_NAME}-${PKG_VERSION}-$(date -u +%Y%m%dT%H%M%SZ).log"
  mkdir -p "$(dirname "$LOG_FILE")"
  log_stage "Starting build pipeline for ${PKG_NAME}-${PKG_VERSION}"
  start_epoch="$(date +%s)"
  # create TMPDIR
  TMPDIR="$(mktemp -d "${WORKDIR}/porg-build.XXXX")"
  trap 'rm -rf "$TMPDIR"' EXIT

  # resolve deps first
  resolve_dependencies_prebuild

  run_hooks "pre-download"
  download_sources
  run_hooks "post-download"

  # extract each download (if directories from git, treat as source)
  EXTRACT_DIR="${TMPDIR}/src"
  mkdir -p "$EXTRACT_DIR"
  for s in "${DOWNLOADS[@]}"; do
    if [ -d "$s" ]; then
      # git dir
      cp -a "$s/." "$EXTRACT_DIR/"
    else
      extract_archive "$s" "$EXTRACT_DIR"
    fi
  done

  # find top-level source dir
  SRC_BASENAME="$(find "$EXTRACT_DIR" -maxdepth 1 -mindepth 1 -type d | head -n1 | xargs -r basename || true)"
  SRC_DIR="${EXTRACT_DIR}/${SRC_BASENAME}"
  [ -d "$SRC_DIR" ] || SRC_DIR="$EXTRACT_DIR"  # fallback

  run_hooks "pre-patch"
  # copy patches into TMP patchdir if metafile set
  if [ -n "$PATCHES_DIR" ] && [ -d "$PATCHES_DIR" ]; then
    cp -a "$PATCHES_DIR"/* "$TMPDIR/" 2>/dev/null || true
  fi
  apply_patches_to_src "$SRC_DIR"
  run_hooks "post-patch"

  # prepare DESTDIR
  DESTDIR="${DESTDIR_BASE}/${PKG_NAME}-${PKG_VERSION}"
  rm -rf "$DESTDIR"
  mkdir -p "$DESTDIR"

  # build & install
  build_from_source "$SRC_DIR"

  # package
  PKG_PATH="$(strip_and_package "$DESTDIR")"

  # register in DB if successful
  register_pkg_in_db

  # optional expand into root if requested
  if [ "${EXPAND_TO_ROOT:-false}" = true ]; then
    expand_into_root "$PKG_PATH"
  fi

  end_epoch="$(date +%s)"
  emit_performance_summary "$start_epoch" "$end_epoch"
  log_stage "Build pipeline finished for ${PKG_NAME}-${PKG_VERSION}"
  echo "$PKG_PATH"
}

# -------------------- CLI dispatcher --------------------
case "$cmd" in
  build)
    if [ $# -lt 1 ]; then usage; fi
    MF="$1"
    # allow env overrides for dry-run, quiet
    DRY_RUN="${DRY_RUN:-false}"
    # run build
    build_pipeline "$MF"
    ;;
  help|*)
    usage;;
esac
