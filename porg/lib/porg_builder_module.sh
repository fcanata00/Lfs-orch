#!/usr/bin/env bash
#
# porg_builder.sh
# Módulo monolítico do Porg — pipeline completo de build LFS-style
# (Português)
#
# Save as porg_builder.sh and chmod +x porg_builder.sh
#
set -euo pipefail
IFS=$'\n\t'

# -------------------- Defaults e Config global --------------------
DEFAULT_CONFIG="/etc/porg/porg.conf"
PORG_CONFIG="${PORG_CONFIG:-$DEFAULT_CONFIG}"

# valores padrão (podem ser sobrescritos em porg.conf)
PORTS_DIR="/usr/ports"
WORKDIR="/var/tmp/porg/work"
CACHE_DIR=""
LOG_DIR=""
HOOK_DIR="/etc/porg/hooks"
PATCH_DIR=""
DESTDIR_BASE=""
JOBS="$(nproc 2>/dev/null || echo 1)"
PACKAGE_FORMAT="tar.zst"
CHROOT_METHOD="bwrap"
STRICT_GPG="false"
STRIP_BINARIES="true"
LOG_MODULE=""   # script externo de logging (opcional)
DEPS_CMD=""     # resolvedor de dependências (opcional)
DB_CMD=""       # registrador/DB (opcional)

QUIET=false
AUTO_YES=false
CLEAN_BEFORE=false
DO_EXPAND=false

load_global_config() {
  if [ -f "$PORG_CONFIG" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      line="${line%%#*}"
      line="${line%$'\r'}"
      [ -z "$line" ] && continue
      if [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
        eval "$line"
      fi
    done < "$PORG_CONFIG"
  fi
  : "${CACHE_DIR:=${WORKDIR}/cache}"
  : "${LOG_DIR:=${WORKDIR}/logs}"
  : "${PATCH_DIR:=${WORKDIR}/patches}"
  : "${DESTDIR_BASE:=${WORKDIR}/destdir}"
  mkdir -p "$WORKDIR" "$CACHE_DIR" "$LOG_DIR" "$PATCH_DIR" "$DESTDIR_BASE"
}

# -------------------- CLI --------------------
usage() {
  cat <<EOF
Usage: ${0##*/} [options] <command> <metafile.yml>
Commands:
  build <metafile.yml>        Run full pipeline for the given metafile
  package <destdir>           Create package (.tar.zst) from destdir
  expand-root <pkgfile>       Expand package into / (dangerous)
  help                        Show help
Options:
  -q|--quiet       Quiet progress (Portage-like bar)
  -i|--install     Build and expand into / after packaging (dangerous)
  -c|--clean       Clean workdir/cache before building
  -y|--yes         Auto-confirm destructive operations (expand-root)
  -h|--help        Show help
EOF
}

if [ "$#" -lt 1 ]; then usage; exit 1; fi

# Parse options that might appear before command
while [[ "$1" =~ ^- ]]; do
  case "$1" in
    -q|--quiet) QUIET=true; shift ;;
    -i|--install) DO_EXPAND=true; shift ;;
    -c|--clean) CLEAN_BEFORE=true; shift ;;
    -y|--yes) AUTO_YES=true; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    *) echo "Unknown option: $1"; usage; exit 2 ;;
  esac
  [ "$#" -gt 0 ] || break
done

CMD="$1"; shift || true
ARG1="$1" || true

# -------------------- Init config & logs --------------------
load_global_config

COLOR_RESET="\e[0m"
COLOR_INFO="\e[32m"
COLOR_WARN="\e[33m"
COLOR_ERROR="\e[31m"
COLOR_STAGE="\e[36m"

LOG_FILE="${LOG_DIR}/porg-$(date -u +%Y%m%dT%H%M%SZ).log"
mkdir -p "$(dirname "$LOG_FILE")"

log_internal() {
  local level="$1"; shift
  local msg="$*"
  local ts; ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  # external logger if configured
  if [ -n "$LOG_MODULE" ] && command -v "$LOG_MODULE" >/dev/null 2>&1; then
    "$LOG_MODULE" "$level" "$ts" "$msg" >/dev/null 2>&1 || true
  fi
  printf '%s [%s] %s\n' "$ts" "$level" "$msg" >> "$LOG_FILE"
  if [ "$QUIET" != true ]; then
    case "$level" in
      INFO)  printf "%b[INFO]%b  %s\n" "$COLOR_INFO" "$COLOR_RESET" "$msg" ;;
      WARN)  printf "%b[WARN]%b  %s\n" "$COLOR_WARN" "$COLOR_RESET" "$msg" ;;
      ERROR) printf "%b[ERROR]%b %s\n" "$COLOR_ERROR" "$COLOR_RESET" "$msg" ;;
      STAGE) printf "%b[ >>> ]%b %s\n" "$COLOR_STAGE" "$COLOR_RESET" "$msg" ;;
      OK)    printf "%b[ OK ]%b   %s\n" "$COLOR_INFO" "$COLOR_RESET" "$msg" ;;
      *)     printf "[%s] %s\n" "$level" "$msg" ;;
    esac
  fi
}

_die() {
  log_internal ERROR "$*"
  cleanup_and_exit 1
}

# -------------------- Tool checks --------------------
require_tool() {
  for t in "$@"; do
    if ! command -v "$t" >/dev/null 2>&1; then
      _die "Ferramenta requerida ausente: $t"
    fi
  done
}
# check basic tools
require_tool bash curl tar zstd fakeroot file find awk sed grep xargs

# ensure bwrap if configured
if [ "$CHROOT_METHOD" = "bwrap" ] && ! command -v bwrap >/dev/null 2>&1; then
  log_internal WARN "bubblewrap pedido em CHROOT_METHOD, mas não encontrado — farei fallback para chroot"
  CHROOT_METHOD="chroot"
fi

# -------------------- YAML parser (compatível com nosso esquema) --------------------
# Goals:
# - top-level key: value
# - block scalars with '|' or '>' for build/install (preserve/fold)
# - arrays: '- item' (patches, simple arrays)
# - sources: array of maps:
#   sources:
#     - url: ...
#       sha256: ...
#       gpg: ...
#
SOURCES_URLS=()
SOURCES_SHA256=()
SOURCES_GPG=()
PATCHES=()
declare -A HOOKS
META_STAGE=""
META_EXPAND="false"

parse_metafile() {
  local file="$1"
  local in_block="" block_key="" block_indent=0
  local last_top=""
  while IFS= read -r raw || [ -n "$raw" ]; do
    line="${raw%$'\r'}"
    # trim leading
    ltrim="$(echo "$line" | sed -e 's/^[[:space:]]*//')"
    # skip empty or comment-only
    [ -z "$ltrim" ] && continue
    [[ "$ltrim" =~ ^# ]] && continue

    # if inside a block scalar, collect lines
    if [ -n "$in_block" ]; then
      leading_len=$(echo "$line" | sed -n 's/^\([[:space:]]*\).*$/\1/p' | awk '{print length}')
      if [ "$leading_len" -lt "$block_indent" ] && [ -n "$(echo "$line" | sed -e 's/^[[:space:]]*//')" ]; then
        in_block=""
        block_key=""
        block_indent=0
        # fall through to parse current line as normal
      else
        # append content without the block indent
        content="$(echo "$line" | sed -e "s/^[[:space:]]\\{${block_indent}\\}//")"
        # preserve newlines
        # append to variable
        eval "$block_key=\"\${$block_key}\$content\n\""
        continue
      fi
    fi

    # arrays items
    if [[ "$ltrim" =~ ^- ]]; then
      item="${ltrim#- }"
      # map entry inline? e.g., "- url: https://..."
      if [[ "$item" =~ ^[A-Za-z0-9_\-]+:[[:space:]]*.*$ ]]; then
        # start capture of map: first pair plus following indented pairs
        map_kv=""
        # first pair
        mk="${item%%:*}"
        mv="$(echo "${item#*:}" | sed -e 's/^[[:space:]]*//')"
        map_kv="${map_kv}${mk}:::${mv};;"
        # read subsequent indented lines (peek)
        while IFS= read -r cont || [ -n "$cont" ]; do
          cont="${cont%$'\r'}"
          # stop if not indented
          if [[ "$cont" =~ ^[^[:space:]] ]]; then
            # put it back in a temp file so outer loop will see it: write rest to tmp and reset stdin
            printf '%s\n' "$cont" > /tmp/.porg_remainder.$$ || true
            cat >> /tmp/.porg_remainder.$$ <<'__END__'
__END__
            # append remaining stdin to file
            while IFS= read -r rem || [ -n "$rem" ]; do
              printf '%s\n' "$rem" >> /tmp/.porg_remainder.$$
            done
            # reset stdin to tmp file
            exec 0< /tmp/.porg_remainder.$$
            break
          fi
          # if indented, parse key: val
          s="$(echo "$cont" | sed -e 's/^[[:space:]]*//')"
          if [[ "$s" =~ ^([A-Za-z0-9_\-]+):[[:space:]]*(.*)$ ]]; then
            kk="${BASH_REMATCH[1]}"; vv="${BASH_REMATCH[2]}"
            map_kv="${map_kv}${kk}:::${vv};;"
          fi
        done
        # interpret map_kv
        url=""; sha=""; gpg=""
        IFS=';;' read -r -a pairs <<< "$map_kv"
        for p in "${pairs[@]}"; do
          [ -z "$p" ] && continue
          k="${p%%:::*}"; v="${p#*:::}"
          case "$k" in
            url) url="$v" ;;
            sha256) sha="$v" ;;
            gpg|gpg_sig) gpg="$v" ;;
          esac
        done
        if [ -n "$url" ]; then
          SOURCES_URLS+=("$url")
          SOURCES_SHA256+=("$sha")
          SOURCES_GPG+=("$gpg")
        fi
      else
        # scalar array item
        if [ "$last_top" = "patches" ]; then
          PATCHES+=("$item")
        elif [[ "$last_top" =~ ^hooks\. ]]; then
          stage="${last_top#hooks.}"
          if [ -n "${HOOKS[$stage]:-}" ]; then
            HOOKS[$stage]="${HOOKS[$stage]};;${item}"
          else
            HOOKS[$stage]="${item}"
          fi
        else
          # fallback: ignore or log
          :
        fi
      fi
      continue
    fi

    # key: value or key: | or key: >
    if [[ "$ltrim" =~ ^([A-Za-z0-9_.-]+):[[:space:]]*(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"
      val="${BASH_REMATCH[2]}"
      last_top="$key"
      if [[ "$val" =~ ^\|$ || "$val" =~ ^\>$ ]]; then
        in_block="yes"; block_key="$key"; block_indent=$(echo "$line" | sed -n 's/^\([[:space:]]*\).*$/\1/p' | awk '{print length}')
        eval "$key=\"\""
        continue
      else
        # strip surrounding quotes
        val="$(echo "$val" | sed -e 's/^"//' -e 's/"$//' -e \"s/^'//\" -e \"s/'$//\")"
        case "$key" in
          name|pkgname) pkg_name="$val" ;;
          version) pkg_version="$val" ;;
          stage) META_STAGE="$val" ;;
          expand_to_root) META_EXPAND="$val" ;;
          build) BUILD_CMDS="$val" ;;
          install) INSTALL_CMDS="$val" ;;
          source|sources|url) # if single-line source url
            if [[ "$val" =~ ^http|git\+ ]]; then
              SOURCES_URLS+=("$val")
              # associated sha/gpg may be elsewhere; leave empty
              SOURCES_SHA256+=("")
              SOURCES_GPG+=("")
            fi
            ;;
          sha256) SHA256="$val" ;;
          gpg|gpg_sig|gpg_url) GPG_SIG_URL="$val" ;;
          patches) last_top="patches" ;;
          hooks) last_top="hooks" ;;
          *) eval "$key=\"\$val\"" ;;
        esac
      fi
    fi
  done < "$file"

  # fallback: if SOURCES arrays empty but global SOURCE_URL set, add it
  if [ "${#SOURCES_URLS[@]}" -eq 0 ] && [ -n "${SOURCE_URL:-}" ]; then
    SOURCES_URLS+=("$SOURCE_URL")
    SOURCES_SHA256+=("${SHA256:-}")
    SOURCES_GPG+=("${GPG_SIG_URL:-}")
  fi
}

# -------------------- Métricas / progresso --------------------
_prev_idle=0; _prev_total=0
cpu_percent() {
  read -r cpu user nice system idle iowait irq softirq steal guest < /proc/stat
  idle_now=$((idle + iowait))
  total_now=$((user + nice + system + idle + iowait + irq + softirq + steal))
  if [ "$_prev_total" -eq 0 ]; then _prev_idle=$idle_now; _prev_total=$total_now; echo "0"; return; fi
  diff_idle=$((idle_now - _prev_idle)); diff_total=$((total_now - _prev_total))
  _prev_idle=$idle_now; _prev_total=$total_now
  if [ "$diff_total" -le 0 ]; then echo "0"; return; fi
  usage=$((100 * (diff_total - diff_idle) / diff_total))
  echo "$usage"
}
mem_used_mb() {
  awk '/MemTotal:/ {t=$2} /MemAvailable:/ {a=$2} END {printf "%d", (t-a)/1024}' /proc/meminfo 2>/dev/null || echo "0"
}
progress_draw() {
  local name="$1" percent="$2" eta="$3"
  local loadavg="$(cut -d' ' -f1 /proc/loadavg 2>/dev/null || echo 0.00)"
  local cpu=$(cpu_percent)
  local mem=$(mem_used_mb)
  local width=30
  local filled=$((percent * width / 100)); local empty=$((width - filled))
  local bar="$(printf '%0.s█' $(seq 1 $filled))$(printf '%0.s░' $(seq 1 $empty))"
  printf "\r%s  [%s] %3d%% ETA:%s load:%s cpu:%s%% mem:%sMB" "$name" "$bar" "$percent" "$eta" "$loadavg" "$cpu" "$mem"
}

eta_fmt() {
  local s=$1; printf "%02d:%02d:%02d" $((s/3600)) $(((s%3600)/60)) $((s%60))
}

# -------------------- cleanup / traps --------------------
TMP_DIRS=()
cleanup_and_exit() {
  local code=${1:-0}
  for d in "${TMP_DIRS[@]:-}"; do
    [ -n "$d" ] && rm -rf "$d" 2>/dev/null || true
  done
  if [ "$QUIET" = true ]; then printf "\n"; fi
  log_internal INFO "Saindo com código $code"
  exit "$code"
}
trap 'log_internal WARN "Interrompido pelo usuário"; cleanup_and_exit 130' INT
trap 'cleanup_and_exit $?' EXIT

# -------------------- Funções de pipeline --------------------
# download_sources: tenta as SOURCES_URLS em ordem até uma válida
download_sources() {
  local out=""
  mkdir -p "$CACHE_DIR"
  for i in "${!SOURCES_URLS[@]}"; do
    url="${SOURCES_URLS[$i]}"
    sha="${SOURCES_SHA256[$i]:-}"
    gpg="${SOURCES_GPG[$i]:-}"
    if [[ "$url" =~ ^git\+ ]]; then
      require_tool git
      repo="${url#git+}"
      dest="${CACHE_DIR}/git-$(basename "$repo" .git)"
      if [ -d "$dest/.git" ]; then
        log_internal INFO "Atualizando git ${repo}"
        git -C "$dest" fetch --all --tags --prune || true
      else
        log_internal INFO "Clonando ${repo} -> $dest"
        git clone --depth 1 "$repo" "$dest" || { log_internal WARN "git clone falhou: $repo"; continue; }
      fi
      out="$dest"
      # no verify for git (we assume tag/commit used); break
      break
    else
      fname="$(basename "$url")"
      out="$CACHE_DIR/$fname"
      if [ -f "$out" ]; then
        log_internal INFO "Usando cache $out"
      else
        log_internal INFO "Download: $url -> $out"
        # try to get content-length
        cl=$(curl -sI "$url" | awk -F': ' '/^Content-Length:/ {print $2}' | tr -d '\r\n' || echo "")
        curl -L --fail --output "$out.part" "$url" &
        cpid=$!
        if [ "$QUIET" = true ]; then
          start_ts=$(date +%s)
          while kill -0 $cpid 2>/dev/null; do
            if [ -n "$cl" ] && [ "$cl" -gt 0 ]; then
              cur=$(stat -c%s "$out.part" 2>/dev/null || echo 0)
              pct=$((cur * 100 / cl))
              elapsed=$(( $(date +%s) - start_ts ))
              if [ "$pct" -gt 0 ]; then est_total=$((elapsed * 100 / pct)); left=$((est_total - elapsed)); eta=$(eta_fmt $left); else eta="??:??:??"; fi
              progress_draw "$PKG_ID" "$pct" "$eta"
            else
              printf "\r%s  [ downloading... ]" "$PKG_ID"
            fi
            sleep 0.6
          done
          wait $cpid || { rm -f "$out.part"; log_internal WARN "curl falhou para $url"; out=""; continue; }
          printf "\n"
        else
          wait $cpid || { rm -f "$out.part"; log_internal WARN "curl falhou para $url"; out=""; continue; }
        fi
        mv "$out.part" "$out"
      fi
    fi

    # verify if sha/gpg provided
    if [ -n "$sha" ]; then
      require_tool sha256sum
      log_internal INFO "Verificando sha256 para $out"
      if ! echo "$sha  $out" | sha256sum -c - >/dev/null 2>&1; then
        log_internal WARN "sha256 mismatch $out; tentando próxima fonte"
        rm -f "$out"; out=""
        continue
      fi
    fi
    if [ -n "$gpg" ]; then
      require_tool gpg curl
      sigf="$CACHE_DIR/$(basename "$gpg")"
      curl -L --fail -o "$sigf.part" "$gpg" && mv "$sigf.part" "$sigf"
      if ! gpg --verify "$sigf" "$out" >/dev/null 2>&1; then
        log_internal WARN "GPG verify falhou para $out; tentando próxima fonte"
        rm -f "$out"; out=""
        continue
      fi
    fi
    # success
    break
  done
  [ -n "$out" ] || return 1
  echo "$out"
}

verify_archive() {
  local file="$1" sha="$2" gpg="$3"
  if [ -n "$sha" ]; then
    require_tool sha256sum
    log_internal INFO "Verificando SHA256: $file"
    if ! echo "$sha  $file" | sha256sum -c - >/dev/null 2>&1; then
      return 1
    fi
  fi
  if [ -n "$gpg" ]; then
    require_tool gpg curl
    sigf="$CACHE_DIR/$(basename "$gpg")"
    curl -L --fail -o "$sigf.part" "$gpg" && mv "$sigf.part" "$sigf"
    if ! gpg --verify "$sigf" "$file" >/dev/null 2>&1; then
      return 1
    fi
  fi
  return 0
}

extract_archive() {
  local archive="$1" dest="$2"
  mkdir -p "$dest"
  case "$archive" in
    *.tar.zst|*.tzst)
      require_tool tar zstd
      if [ "$QUIET" = true ]; then
        (tar --use-compress-program=unzstd -xf "$archive" -C "$dest") & pid=$!
        while kill -0 $pid 2>/dev/null; do progress_draw "$PKG_ID" 0 "??:??:??"; sleep 0.6; done; printf "\n"; wait $pid
      else
        tar --use-compress-program=unzstd -xf "$archive" -C "$dest"
      fi
      ;;
    *.tar.xz|*.txz)
      require_tool tar xz
      tar -xf "$archive" -C "$dest"
      ;;
    *.tar.gz|*.tgz)
      require_tool tar gzip
      tar -xf "$archive" -C "$dest"
      ;;
    *.zip)
      require_tool unzip
      unzip -qq "$archive" -d "$dest"
      ;;
    *.7z)
      require_tool 7z
      7z x -y -o"$dest" "$archive" >/dev/null
      ;;
    *)
      _die "Formato de arquivo não suportado: $archive"
      ;;
  esac
}

apply_patches() {
  local srcdir="$1"
  # patches list from metafile
  for p in "${PATCHES[@]}"; do
    if [ -f "$p" ]; then ppath="$p"; else ppath="$(dirname "$METAFILE_PATH")/$p"; fi
    [ -f "$ppath" ] || _die "Patch não encontrado: $ppath"
    log_internal INFO "Aplicando patch $ppath"
    (cd "$srcdir" && patch -p1 < "$ppath") || _die "Patch falhou: $ppath"
  done
  # local patches dir near metafile: /usr/ports/.../patches
  pkgdir="$(dirname "$METAFILE_PATH")"
  if [ -d "$pkgdir/patches" ]; then
    for p in "$pkgdir/patches"/*.patch; do [ -f "$p" ] || continue; log_internal INFO "Aplicando patch local $p"; (cd "$srcdir" && patch -p1 < "$p") || _die "Patch local falhou: $p"; done
  fi
}

run_hooks() {
  local stage="$1"
  log_internal STAGE "hooks: $stage"
  if [ -n "${HOOKS[$stage]:-}" ]; then
    IFS=';;' read -r -a cmds <<< "${HOOKS[$stage]}"
    for c in "${cmds[@]}"; do
      [ -z "$c" ] && continue
      log_internal INFO "pkg-hook: $c"
      bash -c "$c" || log_internal WARN "pkg-hook retornou não-zero: $c"
    done
  fi
  # hooks locais e globais
  pkgdir="$(dirname "$METAFILE_PATH")"
  if [ -d "$pkgdir/hooks/$stage" ]; then
    for h in "$pkgdir/hooks/$stage"/*; do [ -x "$h" ] || continue; log_internal INFO "pkg-dir-hook: $h"; "$h" || log_internal WARN "hook falhou: $h"; done
  fi
  if [ -d "$HOOK_DIR/$stage" ]; then
    for h in "$HOOK_DIR/$stage"/*; do [ -x "$h" ] || continue; log_internal INFO "global-hook: $h"; "$h" || log_internal WARN "global hook falhou: $h"; done
  fi
}

build_in_bwrap() {
  local chroot_root="$1" inner_cmd="$2"
  if [ "$CHROOT_METHOD" = "bwrap" ] && command -v bwrap >/dev/null 2>&1; then
    if [ "$QUIET" = true ]; then
      bwrap --ro-bind "$chroot_root" / --dev /dev --proc /proc --tmpfs /tmp --ro-bind /usr /usr --ro-bind /bin /bin --ro-bind /lib /lib --ro-bind /lib64 /lib64 --unshare-net /bin/sh -c "$inner_cmd" &
      bp=$!
      while kill -0 $bp 2>/dev/null; do cpu=$(cpu_percent); mem=$(mem_used_mb); printf "\rBuilding %s ... CPU:%s%% MEM:%sMB" "$PKG_ID" "$cpu" "$mem"; sleep 0.6; done
      wait $bp || _die "Build falhou dentro do bwrap"
      printf "\n"
    else
      bwrap --ro-bind "$chroot_root" / --dev /dev --proc /proc --tmpfs /tmp --ro-bind /usr /usr --ro-bind /bin /bin --ro-bind /lib /lib --ro-bind /lib64 /lib64 --unshare-net /bin/sh -c "$inner_cmd"
    fi
  else
    if [ "$(id -u)" -ne 0 ]; then log_internal WARN "Fallback chroot pode exigir root"; fi
    chroot "$chroot_root" /bin/sh -c "$inner_cmd"
  fi
}

strip_binaries() {
  if [ "$STRIP_BINARIES" != "true" ]; then return; fi
  if ! command -v strip >/dev/null 2>&1 || ! command -v file >/dev/null 2>&1; then log_internal WARN "strip/file não disponível; skip strip"; return; fi
  while IFS= read -r -d '' f; do
    if file "$f" | grep -q "ELF"; then
      strip --strip-unneeded "$f" || log_internal WARN "strip falhou: $f"
    fi
  done < <(find "$DESTDIR" -type f -print0)
}

package_destdir() {
  mkdir -p "${WORK_PKG_DIR}/packages"
  pkg_base="${WORK_PKG_DIR}/packages/${PKG_ID}.tar"
  tar -C "$DESTDIR" -cf "$pkg_base" .
  pkg_file="$pkg_base"
  if [ "$PACKAGE_FORMAT" = "tar.zst" ] && command -v zstd >/dev/null 2>&1; then
    zstd -T0 -19 "$pkg_base" -o "${pkg_base}.zst"
    pkg_file="${pkg_base}.zst"
  elif [ "$PACKAGE_FORMAT" = "tar.xz" ] && command -v xz >/dev/null 2>&1; then
    xz -9 "$pkg_base"
    pkg_file="${pkg_base}.xz"
  fi
  echo "$pkg_file"
}

expand_into_root() {
  local pkgfile="$1"
  log_internal WARN "Expandindo pacote $pkgfile em / (perigoso)"
  if [ "$AUTO_YES" != true ]; then
    printf "CONFIRMA: extrair %s em / ? digite 'yes' para confirmar: " "$pkgfile" >&2
    read -r ans
    [ "$ans" = "yes" ] || { log_internal WARN "Usuário cancelou expand-root"; return 1; }
  fi
  run_hooks "pre-expand-root"
  case "$pkgfile" in
    *.zst) zstd -d "$pkgfile" -c | tar -xf - -C / ;;
    *.tar) tar -xf "$pkgfile" -C / ;;
    *.xz) xz -d "$pkgfile" -c | tar -xf - -C / ;;
    *) _die "Tipo não suportado: $pkgfile" ;;
  esac
  run_hooks "post-expand-root"
  log_internal INFO "Expand-root concluído"
}

# -------------------- Orquestração principal --------------------
porg_build_full() {
  METAFILE_PATH="$1"
  parse_metafile "$METAFILE_PATH"
  : "${pkg_name:=${pkg_name:-unnamed}}"
  : "${pkg_version:=${pkg_version:-0.0.0}}"
  : "${BUILD_CMDS:=${BUILD_CMDS:-}}"
  : "${INSTALL_CMDS:=${INSTALL_CMDS:-}}"

  # bootstrap stage handling
  if [ "${META_STAGE:-}" = "bootstrap" ] || [ "${META_STAGE:-}" = "toolchain" ]; then
    : "${DESTDIR_BASE:=/mnt/lfs}"
    log_internal INFO "Stage bootstrap/toolchain detectado; DESTDIR_BASE definido como $DESTDIR_BASE"
  fi

  PKG_ID="${pkg_name}-${pkg_version}"
  WORK_PKG_DIR="${WORKDIR}/${PKG_ID}"
  DESTDIR="${DESTDIR_BASE}/${PKG_ID}"
  mkdir -p "$WORK_PKG_DIR" "$DESTDIR"
  TMP_DIRS+=("$WORK_PKG_DIR")

  log_internal STAGE "Iniciando build: $PKG_ID"
  log_internal INFO "Workdir: $WORK_PKG_DIR, Destdir: $DESTDIR"

  if [ "$CLEAN_BEFORE" = true ]; then
    log_internal INFO "Cleaning requested: removing workdir/cache"
    rm -rf "$WORK_PKG_DIR" "$CACHE_DIR"/* 2>/dev/null || true
    mkdir -p "$WORK_PKG_DIR"
  fi

  # STEPS dynamic
  STEPS=(download verify extract patch build install strip package expand)
  ACTIVE=()
  ACTIVE+=(download verify extract)
  if [ "${#PATCHES[@]}" -gt 0 ]; then ACTIVE+=(patch); fi
  ACTIVE+=(build install)
  if [ "$STRIP_BINARIES" = "true" ]; then ACTIVE+=(strip); fi
  ACTIVE+=(package)
  if [ "$DO_EXPAND" = true ] || [ "${META_EXPAND:-false}" = "true" ]; then ACTIVE+=(expand); fi

  TOTAL=${#ACTIVE[@]}; IDX=0

  start_step() { IDX=$((IDX+1)); STNAME="$1"; ST_S=$(date +%s); log_internal STAGE "STEP [$IDX/$TOTAL] $STNAME start"; }
  end_step() { rc=${1:-0}; ST_E=$(date +%s); log_internal OK "STEP [$IDX/$TOTAL] $STNAME done (duration $((ST_E-ST_S))s)"; }

  # DOWNLOAD
  start_step download
  downloaded="$(download_sources)" || _die "Falha no download/verify de fontes"
  end_step 0

  # VERIFY (already done per-source in download_sources), but record
  start_step verify
  log_internal INFO "Verify step completed (see download step for details)"
  end_step 0

  # EXTRACT
  start_step extract
  EXDIR="${WORK_PKG_DIR}/src"
  rm -rf "$EXDIR"; mkdir -p "$EXDIR"
  if [ -d "$downloaded" ]; then
    log_internal INFO "Fonte é diretório (git), copiando..."
    cp -a "$downloaded"/. "$EXDIR"/
  else
    extract_archive "$downloaded" "$EXDIR"
  fi
  # pick top-level dir
  topd=$(find "$EXDIR" -mindepth 1 -maxdepth 1 -type d | head -n1 || true)
  if [ -n "$topd" ]; then SRC_DIR="$topd"; else SRC_DIR="$EXDIR"; fi
  # run post-extract hooks
  run_hooks "post-extract"
  end_step 0

  # PATCH
  if [ "${#PATCHES[@]}" -gt 0 ]; then
    start_step patch
    apply_patches "$SRC_DIR"
    end_step 0
  fi

  # pre-build hooks
  run_hooks "pre-build"

  # BUILD
  start_step build
  CHROOT_ROOT="${WORK_PKG_DIR}/chroot_root"
  rm -rf "$CHROOT_ROOT" || true
  mkdir -p "$CHROOT_ROOT/$pkg_name"
  cp -a "$SRC_DIR"/. "$CHROOT_ROOT/$pkg_name"/

  DESTDIR_REL="${DESTDIR#/}"
  BUILD_SCRIPT=""
  if [ -n "${BUILD_CMDS:-}" ]; then
    # convert newlines to semicolon; ensure safe quoting of single quotes later
    BUILD_SCRIPT+="${BUILD_CMDS};"
  fi
  if [ -n "${INSTALL_CMDS:-}" ]; then
    # escape single quotes (for safe embedding)
    esc_install="${INSTALL_CMDS//\'/\'\\\'\'}"
    BUILD_SCRIPT+="fakeroot sh -c '${esc_install}';"
  fi

  inner_cmd="set -euo pipefail; export JOBS=${JOBS}; export DESTDIR=/${DESTDIR_REL}; cd /${pkg_name}; ${BUILD_SCRIPT}"

  build_in_bwrap "$CHROOT_ROOT" "$inner_cmd"
  run_hooks "post-build"
  end_step 0

  # INSTALL (merge)
  start_step install
  INST_ROOT="${CHROOT_ROOT}/${DESTDIR_REL}"
  if [ -d "$INST_ROOT" ]; then
    mkdir -p "$DESTDIR"
    cp -a "$INST_ROOT"/. "$DESTDIR"/
    log_internal INFO "Arquivos instalados mesclados em $DESTDIR"
  else
    log_internal WARN "Nenhum arquivo instalado em $INST_ROOT; verifique INSTALL_CMDS"
  fi
  run_hooks "post-install"
  end_step 0

  # STRIP
  if [ "$STRIP_BINARIES" = "true" ]; then
    start_step strip
    strip_binaries
    end_step 0
  fi

  # PACKAGE
  start_step package
  pkg_file="$(package_destdir)"
  log_internal INFO "Pacote criado: $pkg_file"
  run_hooks "post-package"
  end_step 0

  # EXPAND (opcional)
  if [ "${DO_EXPAND}" = true ] || [ "${META_EXPAND:-false}" = "true" ]; then
    start_step expand
    expand_into_root "$pkg_file"
    end_step 0
  fi

  # final actions: call deps/db managers if configured
  log_internal INFO "Build finalizado: $PKG_ID"
  log_internal INFO "Pacote em: $pkg_file"

  # log progress snapshot to file (summary)
  echo "{\"pkg\":\"$PKG_ID\",\"package\":\"$pkg_file\",\"time\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" >> "${LOG_FILE}"

  if [ -n "$DEPS_CMD" ] && command -v "$DEPS_CMD" >/dev/null 2>&1; then
    log_internal INFO "Chamando DEPS_CMD: $DEPS_CMD"
    "$DEPS_CMD" --register "$PKG_ID" --manifest "$pkg_file" || log_internal WARN "DEPS_CMD retornou não-zero"
  fi
  if [ -n "$DB_CMD" ] && command -v "$DB_CMD" >/dev/null 2>&1; then
    log_internal INFO "Registrando pacote no DB: $DB_CMD"
    "$DB_CMD" add --name "$pkg_name" --version "$pkg_version" --file "$pkg_file" || log_internal WARN "DB_CMD retornou não-zero"
  fi

  # success
  return 0
}

# -------------------- Entrypoint CLI dispatch --------------------
case "$CMD" in
  build)
    if [ -z "${ARG1:-}" ]; then echo "metafile required"; usage; exit 2; fi
    METAFILE_PATH="$ARG1"
    [ -f "$METAFILE_PATH" ] || _die "metafile não encontrado: $METAFILE_PATH"
    porg_build_full "$METAFILE_PATH"
    ;;
  package)
    if [ -z "${ARG1:-}" ]; then echo "destdir required"; usage; exit 2; fi
    DESTDIR="$ARG1"
    [ -d "$DESTDIR" ] || _die "destdir não existe: $DESTDIR"
    PKG_ID="$(basename "$DESTDIR")"
    WORK_PKG_DIR="${WORKDIR}/${PKG_ID}"
    mkdir -p "$WORK_PKG_DIR"
    pkg="$(package_destdir)"
    echo "Package created: $pkg"
    ;;
  expand-root)
    if [ -z "${ARG1:-}" ]; then echo "pkgfile required"; usage; exit 2; fi
    expand_into_root "$ARG1"
    ;;
  help|*)
    usage; exit 0 ;;
esac

exit 0
