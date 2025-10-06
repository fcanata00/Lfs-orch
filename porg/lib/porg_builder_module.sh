#!/usr/bin/env bash
#
# porg_builder.sh
# Módulo monolítico do Porg — pipeline completo de build LFS-style
# - Leitura de /etc/porg/porg.conf
# - Leitura do metafile YAML em /usr/ports/...
# - download -> verify -> extract -> patch -> hooks -> build (bwrap) -> install (fakeroot) -> strip -> package (.tar.zst) -> optional expand to /
# - Quiet mode com barra estilo Portage (porcentagem, ETA, load, CPU, MEM)
# - Usa somente módulos externos configurados em porg.conf: LOG_MODULE, DEPS_CMD, DB_CMD
#
set -euo pipefail
IFS=$'\n\t'

### -------------------- Config global e defaults --------------------
DEFAULT_CONFIG="/etc/porg/porg.conf"
PORG_CONFIG="${PORG_CONFIG:-$DEFAULT_CONFIG}"
# Valores padrão (podem ser sobrescritos no porg.conf)
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
LOG_MODULE=""   # caminho para script externo de logging (opcional)
DEPS_CMD=""     # caminho para resolvedor de dependências (opcional)
DB_CMD=""       # caminho para registrar pacote (opcional)
QUIET=false
AUTO_YES=false

load_global_config() {
  if [ -f "$PORG_CONFIG" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      # strip comments and CR
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

### -------------------- CLI --------------------
usage() {
  cat <<EOF
Usage: ${0##*/} [options] <command> <metafile.yml>
Commands:
  build <metafile.yml>      Run full pipeline for the given metafile
  package <destdir>         Create package (.tar.zst) from destdir
  expand-root <pkgfile>     Expand package into / (dangerous)
  help                      Show this help
Options:
  -q|--quiet     Quiet progress (Portage-like bar)
  -i|--install   Build and expand into / after packaging (dangerous)
  -c|--clean     Clean workdir/cache before building
  -y|--yes       Auto-confirm destructive operations (expand-root)
  -h|--help      Show help
EOF
}

if [ "$#" -lt 1 ]; then usage; exit 1; fi

CMD="$1"; shift || true
# options that can precede command or after
OPTS_PRE=()
while [[ "$#" -gt 0 && "$1" =~ ^- ]]; do
  case "$1" in
    -q|--quiet) QUIET=true; shift ;;
    -i|--install) EXPORT_INSTALL=true; shift ;; # handled per-command
    -c|--clean) CLEAN_BEFORE=true; shift ;;
    -y|--yes) AUTO_YES=true; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    *) echo "Unknown option: $1"; usage; exit 2 ;;
  esac
done

# load config
load_global_config

### -------------------- Logging helpers --------------------
COLOR_RESET="\e[0m"
COLOR_INFO="\e[32m"
COLOR_WARN="\e[33m"
COLOR_ERROR="\e[31m"
LOG_FILE="${LOG_DIR}/porg-$(date -u +%Y%m%dT%H%M%SZ).log"

log_internal() {
  local level="$1"; shift
  local msg="$*"
  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  # external logger (non-fatal)
  if [ -n "$LOG_MODULE" ] && command -v "$LOG_MODULE" >/dev/null 2>&1; then
    "$LOG_MODULE" "$level" "$ts" "$msg" >/dev/null 2>&1 || true
  fi
  printf '%s [%s] %s\n' "$ts" "$level" "$msg" >> "$LOG_FILE"
  if [ "$QUIET" != true ]; then
    case "$level" in
      INFO)  printf "%b[INFO]%b  %s\n" "$COLOR_INFO" "$COLOR_RESET" "$msg" ;;
      WARN)  printf "%b[WARN]%b  %s\n" "$COLOR_WARN" "$COLOR_RESET" "$msg" ;;
      ERROR) printf "%b[ERROR]%b %s\n" "$COLOR_ERROR" "$COLOR_RESET" "$msg" ;;
      *)     printf "[%s] %s\n" "$level" "$msg" ;;
    esac
  else
    # in quiet mode, only log to file; progress bar handled elsewhere
    :
  fi
}

_die() {
  log_internal ERROR "$*"
  cleanup_and_exit 1
}

### -------------------- Tool checks --------------------
require_tool() {
  for t in "$@"; do
    if ! command -v "$t" >/dev/null 2>&1; then
      _die "Required tool missing: $t"
    fi
  done
}
# check common tools (some used conditionally later)
require_tool bash curl tar zstd fakeroot file find awk sed grep xargs

# If requested bwrap but missing, fallback
if [ "$CHROOT_METHOD" = "bwrap" ] && ! command -v bwrap >/dev/null 2>&1; then
  log_internal WARN "bubblewrap requested but not found; falling back to chroot"
  CHROOT_METHOD="chroot"
fi

### -------------------- YAML parser (simples) --------------------
# Suporta:
# - key: value  (top-level)
# - key: |  (bloco literal preservando \n)
# - key: >  (bloco folded)
# - arrays: - item
# - sources: - url: ... sha256: ... gpg: ...
#
# Variáveis populadas:
# pkg_name, pkg_version, BUILD_CMDS, INSTALL_CMDS
# SOURCES_URLS[], SOURCES_SHA256[], SOURCES_GPG[]
# PATCHES[] and HOOKS["stage"] string with ';;' separators
SOURCES_URLS=()
SOURCES_SHA256=()
SOURCES_GPG=()
PATCHES=()
declare -A HOOKS

parse_metafile() {
  local file="$1"
  local last_top=""
  local in_block="" block_key="" block_indent=0
  while IFS= read -r raw || [ -n "$raw" ]; do
    line="${raw%$'\r'}"
    # strip leading and trailing
    ltrim="$(echo "$line" | sed -e 's/^[[:space:]]*//')"
    [ -z "$ltrim" ] && continue
    # comments
    if [[ "$ltrim" =~ ^# ]]; then continue; fi

    # If in block scalar (| or >)
    if [ -n "$in_block" ]; then
      # detect indentation less than block_indent to end block
      leading_len=$(echo "$line" | sed -n 's/^\([[:space:]]*\).*$/\1/p' | awk '{print length}')
      if [ "$leading_len" -lt "$block_indent" ] && [ -n "$(echo "$line" | sed -e 's/^[[:space:]]*//')" ]; then
        in_block=""
        block_key=""
        block_indent=0
        # re-process current line normally
      else
        # append trimmed to variable (preserve newlines)
        val="$(echo "$line" | sed -e "s/^[[:space:]]\\{${block_indent}\\}//")"
        eval "$block_key=\"\${$block_key}\$val\n\""
        continue
      fi
    fi

    # detect array item
    if [[ "$ltrim" =~ ^- ]]; then
      item="${ltrim#- }"
      # if item contains 'key:' it's a map entry (like sources: - url: ...)
      if [[ "$item" =~ ^[A-Za-z0-9_\-]+: ]]; then
        # start a small map capture: this line plus following indented lines
        map_kv=""
        # first kv in this line
        mk="${item%%:*}"
        mv="${item#*: }"
        map_kv="${map_kv}${mk}:::${mv};;"
        # read following lines while indented
        while IFS= read -r next || [ -n "$next" ]; do
          nextline="${next%$'\r'}"
          ntrim="$(echo "$nextline" | sed -e 's/^[[:space:]]*//')"
          # break if not indented (no leading spaces)
          if [[ "$nextline" =~ ^[^[:space:]] ]]; then
            # push back line to input (uses bash trick: use a temporary file)
            REPLY_LINE="$nextline"
            break
          fi
          s="$(echo "$nextline" | sed -e 's/^[[:space:]]*//')"
          if [[ "$s" =~ ^([A-Za-z0-9_\-]+):[[:space:]]*(.*)$ ]]; then
            map_k="${BASH_REMATCH[1]}"; map_v="${BASH_REMATCH[2]}"
            map_kv="${map_kv}${map_k}:::${map_v};;"
          fi
        done
        # parse map_kv for known keys
        url=""; sha=""; gpg=""
        IFS=';;' read -r -a pairs <<< "$map_kv"
        for p in "${pairs[@]}"; do
          [ -z "$p" ] && continue
          k="${p%%:::*}"; v="${p#*:::}"
          case "$k" in
            url) url="$v" ;;
            sha256) sha="$v" ;;
            gpg) gpg="$v" ;;
          esac
        done
        if [ -n "$url" ]; then
          SOURCES_URLS+=("$url")
          SOURCES_SHA256+=("$sha")
          SOURCES_GPG+=("$gpg")
        fi
        # if we broke early with REPLY_LINE, put it back by reading it via a temp file approach
        if [ -n "${REPLY_LINE:-}" ]; then
          # reinsert REPLY_LINE by using a small tmp file prepend hack: create temp with this line + rest of file
          tmpf="$(mktemp)"
          echo "${REPLY_LINE}" > "$tmpf"
          # append remaining input into tmpf by reading the remainder of original file descriptor
          cat >> "$tmpf"
          # replace stdin for outer loop with tmpf
          exec 0< "$tmpf"
          REPLY_LINE=""
        fi
      else
        # scalar array item (likely patches or hooks)
        if [ "$last_top" = "patches" ]; then
          PATCHES+=("$item")
        elif [[ "$last_top" =~ ^hooks(\.|$) ]]; then
          stage="${last_top#hooks.}"
          if [ -z "$stage" ]; then stage="$item"; else
            if [ -n "${HOOKS[$stage]:-}" ]; then
              HOOKS[$stage]="${HOOKS[$stage]};;${item}"
            else
              HOOKS[$stage]="${item}"
            fi
          fi
        fi
      fi
      continue
    fi

    # key: value or key: | or key: >
    if [[ "$ltrim" =~ ^([A-Za-z0-9_.-]+):[[:space:]]*(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"
      val="${BASH_REMATCH[2]}"
      last_top="$key"
      if [[ "$val" =~ ^\|$ ]]; then
        in_block="yes"; block_key="$key"; block_indent=$(echo "$line" | sed -n 's/^\([[:space:]]*\).*$/\1/p' | awk '{print length}')
        eval "$key=\"\""
        continue
      elif [[ "$val" =~ ^\>$ ]]; then
        in_block="yes"; block_key="$key"; block_indent=$(echo "$line" | sed -n 's/^\([[:space:]]*\).*$/\1/p' | awk '{print length}')
        eval "$key=\"\""
        continue
      else
        # scalar
        # strip quotes
        val="$(echo "$val" | sed -e 's/^\"//' -e 's/\"$//' -e \"s/^'//\" -e \"s/'$//\")"
        case "$key" in
          name|pkgname) pkg_name="$val" ;;
          version) pkg_version="$val" ;;
          source|source_url|url) SOURCE_URL="$val" ;;
          sha256) SHA256="$val" ;;
          gpg|gpg_sig|gpg_url) GPG_SIG_URL="$val" ;;
          build) BUILD_CMDS="$val" ;;
          install) INSTALL_CMDS="$val" ;;
          patches) last_top="patches" ;;
          hooks) last_top="hooks" ;;
          stage) META_STAGE="$val" ;;
          *) eval "$key=\"\$val\"" ;; # generic assign
        esac
      fi
    fi
  done < "$file"

  # fallback: if SOURCE_URL set but SOURCES arrays empty, add it
  if [ "${#SOURCES_URLS[@]}" -eq 0 ] && [ -n "${SOURCE_URL:-}" ]; then
    SOURCES_URLS+=("$SOURCE_URL")
    SOURCES_SHA256+=("${SHA256:-}")
    SOURCES_GPG+=("${GPG_SIG_URL:-}")
  fi
}

### -------------------- Utilitários métricas / progresso --------------------
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
  local width=28
  local filled=$((percent * width / 100)); local empty=$((width - filled))
  local bar="$(printf '%0.s█' $(seq 1 $filled))$(printf '%0.s░' $(seq 1 $empty))"
  printf "\r%s  [%s] %3d%% ETA:%s load:%s cpu:%s%% mem:%sMB" "$name" "$bar" "$percent" "$eta" "$loadavg" "$cpu" "$mem"
}
eta_fmt() {
  local s=$1; printf "%02d:%02d:%02d" $((s/3600)) $(((s%3600)/60)) $((s%60))
}

### -------------------- Cleanup / traps --------------------
TMP_DIRS=()
cleanup_and_exit() {
  local code=${1:-0}
  # cleanup temporários
  for d in "${TMP_DIRS[@]:-}"; do
    [ -n "$d" ] && rm -rf "$d" 2>/dev/null || true
  done
  if [ "$QUIET" = true ]; then printf "\n"; fi
  log_internal INFO "Exiting with code $code"
  exit "$code"
}
trap 'log_internal WARN "Interrupted by user"; cleanup_and_exit 130' INT
trap 'cleanup_and_exit $?' EXIT

### -------------------- Orquestra pipeline --------------------
# parse metafile
METAFILE_PATH="$2"
# In case user called: porg_builder.sh build /path/to/metafile
# Accept also: porg_builder.sh build <metafile>
if [ "$CMD" = "build" ]; then
  if [ -z "${METAFILE_PATH:-}" ]; then METAFILE_PATH="$1"; fi
fi
if [ ! -f "$METAFILE_PATH" ]; then _die "Metafile not found: $METAFILE_PATH"; fi

parse_metafile "$METAFILE_PATH"

# set defaults and LFS bootstrap support
: "${pkg_name:=${pkg_name:-unnamed}}"
: "${pkg_version:=${pkg_version:-0.0.0}}"
: "${BUILD_CMDS:=${BUILD_CMDS:-}}"
: "${INSTALL_CMDS:=${INSTALL_CMDS:-}}"
# If metafile declares stage: bootstrap, set DESTDIR_BASE to /mnt/lfs by default (unless overridden)
if [ "${META_STAGE:-}" = "bootstrap" ]; then
  : "${DESTDIR_BASE:=/mnt/lfs}"
fi

PKG_ID="${pkg_name}-${pkg_version}"
WORK_PKG_DIR="${WORKDIR}/${PKG_ID}"
DESTDIR="${DESTDIR_BASE}/${PKG_ID}"
mkdir -p "$WORK_PKG_DIR" "$DESTDIR"
TMP_DIRS+=("$WORK_PKG_DIR")

log_internal INFO "Parsed metafile: ${METAFILE_PATH}"
log_internal INFO "Package: ${PKG_ID}; workdir: ${WORK_PKG_DIR}; destdir: ${DESTDIR}"

# Optional cleaning
if [ "${CLEAN_BEFORE:-false}" = true ]; then
  log_internal INFO "Cleaning requested: cleaning workdir and cache"
  rm -rf "$WORK_PKG_DIR" "$CACHE_DIR"/* 2>/dev/null || true
  mkdir -p "$WORK_PKG_DIR"
fi

# Determine active steps
ACT_STEPS=()
ACT_STEPS+=(download verify extract)
if [ "${#PATCHES[@]}" -gt 0 ]; then ACT_STEPS+=(patch); fi
ACT_STEPS+=(build install)
if [ "$STRIP_BINARIES" = "true" ]; then ACT_STEPS+=(strip); fi
ACT_STEPS+=(package)
# expand if requested via -i or metafile EXPAND_TO_ROOT or variable DO_EXPAND
DO_EXPAND="${EXPORT_INSTALL:-false}"
if [ "${DO_EXPAND}" = true ] || [ "${META_EXPAND:-false}" = "true" ]; then ACT_STEPS+=(expand); fi

TOTAL=${#ACT_STEPS[@]}; IDX=0

start_step() { IDX=$((IDX+1)); STNAME="$1"; ST_START=$(date +%s); log_internal INFO "STEP [$IDX/$TOTAL] ${STNAME} started"; }
end_step() { local rc=${1:-0}; ST_END=$(date +%s); log_internal INFO "STEP [$IDX/$TOTAL] ${STNAME} finished (duration $((ST_END-ST_START))s)"; }

### 1) DOWNLOAD
start_step "download"
downloaded=""
for i in "${!SOURCES_URLS[@]}"; do
  url="${SOURCES_URLS[$i]}"
  sha="${SOURCES_SHA256[$i]:-}"
  gpg="${SOURCES_GPG[$i]:-}"
  if [[ "$url" =~ ^git\+ ]]; then
    require_tool git
    repo="${url#git+}"
    dest="${CACHE_DIR}/git-$(basename "$repo" .git)"
    if [ -d "$dest/.git" ]; then
      log_internal INFO "Refreshing git ${repo}"
      git -C "$dest" fetch --all --tags --prune || true
    else
      log_internal INFO "Cloning ${repo} -> $dest"
      git clone --depth 1 "$repo" "$dest" || { log_internal WARN "git clone failed: $repo"; continue; }
    fi
    downloaded="$dest"
    break
  else
    fname="$(basename "$url")"
    out="$CACHE_DIR/$fname"
    mkdir -p "$CACHE_DIR"
    if [ -f "$out" ]; then
      log_internal INFO "Using cached $out"
      downloaded="$out"
    else
      log_internal INFO "Downloading $url -> $out"
      # attempt to get content-length
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
            if [ "$pct" -gt 0 ]; then
              est_total=$((elapsed * 100 / pct)); left=$((est_total - elapsed)); eta=$(eta_fmt $left)
            else eta="??:??:??"; fi
            progress_draw "$PKG_ID" "$pct" "$eta"
          else
            # spinner fallback
            printf "\r%s  [ downloading... ]" "$PKG_ID"
          fi
          sleep 0.6
        done
        wait $cpid || { rm -f "$out.part"; log_internal WARN "curl failed for $url"; continue; }
        printf "\n"
      else
        wait $cpid || { rm -f "$out.part"; log_internal WARN "curl failed for $url"; continue; }
      fi
      mv "$out.part" "$out"
      downloaded="$out"
    fi
  fi

  # verify if sha/gpg present
  if [ -n "$sha" ]; then
    require_tool sha256sum
    if ! echo "$sha  $downloaded" | sha256sum -c - >/dev/null 2>&1; then
      log_internal WARN "sha256 mismatch for $downloaded; trying next source"
      rm -f "$downloaded"
      downloaded=""
      continue
    fi
  fi
  if [ -n "$gpg" ]; then
    require_tool gpg curl
    sigf="$CACHE_DIR/$(basename "$gpg")"
    curl -L --fail -o "$sigf.part" "$gpg" && mv "$sigf.part" "$sigf"
    if ! gpg --verify "$sigf" "$downloaded" >/dev/null 2>&1; then
      log_internal WARN "GPG verify failed; trying next source"
      rm -f "$downloaded"; downloaded=""; continue
    fi
  fi
  break
done
[ -n "$downloaded" ] || _die "Nenhuma fonte válida foi baixada/verificada"
end_step 0

### 2) EXTRACT
start_step "extract"
EXDIR="${WORK_PKG_DIR}/src"
rm -rf "$EXDIR"; mkdir -p "$EXDIR"
if [ -d "$downloaded" ]; then
  log_internal INFO "Fonte é diretório (git); copiando"
  cp -a "$downloaded"/. "$EXDIR"/
else
  fn="$downloaded"
  case "$fn" in
    *.tar.zst|*.tzst)
      require_tool tar zstd
      if [ "$QUIET" = true ]; then
        (tar --use-compress-program=unzstd -xf "$fn" -C "$EXDIR") & pid=$!
        while kill -0 $pid 2>/dev/null; do progress_draw "$PKG_ID" 0 "??:??:??"; sleep 0.6; done; printf "\n"; wait $pid
      else
        tar --use-compress-program=unzstd -xf "$fn" -C "$EXDIR"
      fi
      ;;
    *.tar.xz|*.txz) require_tool tar xz; tar -xf "$fn" -C "$EXDIR" ;;
    *.tar.gz|*.tgz) require_tool tar gzip; tar -xf "$fn" -C "$EXDIR" ;;
    *.zip) require_tool unzip; unzip -qq "$fn" -d "$EXDIR" ;;
    *.7z) require_tool 7z; 7z x -y -o"$EXDIR" "$fn" >/dev/null ;;
    *) _die "Formato de arquivo não suportado: $fn" ;;
  esac
fi
# pick top-level dir
topd=$(find "$EXDIR" -mindepth 1 -maxdepth 1 -type d | head -n1 || true)
if [ -n "$topd" ]; then SRC_DIR="$topd"; else SRC_DIR="$EXDIR"; fi
end_step 0

### 3) PATCH
if [ "${#PATCHES[@]}" -gt 0 ]; then
  start_step "patch"
  require_tool patch
  for p in "${PATCHES[@]}"; do
    if [ -f "$p" ]; then ppath="$p"; else ppath="$(dirname "$METAFILE_PATH")/$p"; fi
    [ -f "$ppath" ] || _die "Patch não encontrado: $ppath"
    log_internal INFO "Aplicando patch $ppath"
    (cd "$SRC_DIR" && patch -p1 < "$ppath") || _die "Falha ao aplicar patch $ppath"
  done
  # also check for patches in /usr/ports/<pkg>/patches
  pkg_par_dir="$(dirname "$METAFILE_PATH")"
  if [ -d "$pkg_par_dir/patches" ]; then
    for p in "$pkg_par_dir/patches"/*.patch; do
      [ -f "$p" ] || continue
      log_internal INFO "Aplicando patch local $p"
      (cd "$SRC_DIR" && patch -p1 < "$p") || _die "Falha ao aplicar patch $p"
    done
  fi
  end_step 0
fi

### Hooks pre/post-download/extract handled where appropriate
run_hooks() {
  local stage="$1"
  log_internal INFO "Executing hooks: $stage"
  # package-local hooks parsed into HOOKS associative array
  if [ -n "${HOOKS[$stage]:-}" ]; then
    IFS=';;' read -r -a cmds <<< "${HOOKS[$stage]}"
    for c in "${cmds[@]}"; do
      [ -z "$c" ] && continue
      log_internal INFO "pkg-hook: $c"
      bash -c "$c" || log_internal WARN "pkg-hook falhou: $c"
    done
  fi
  # global hooks
  hd="$HOOK_DIR/$stage"
  if [ -d "$hd" ]; then
    for h in "$hd"/*; do
      [ -x "$h" ] || continue
      log_internal INFO "global-hook: $h"
      "$h" || log_internal WARN "global hook falhou: $h"
    done
  fi
}

run_hooks "pre-build"

### 4) BUILD (bwrap)
start_step "build"
CHROOT_ROOT="${WORK_PKG_DIR}/chroot_root"
rm -rf "$CHROOT_ROOT" || true
mkdir -p "$CHROOT_ROOT/$pkg_name"
cp -a "$SRC_DIR"/. "$CHROOT_ROOT/$pkg_name"/
DESTDIR_REL="${DESTDIR#/}"

# prepare build script
# ensure build/install commands preserve newlines
BUILD_SCRIPT=""
if [ -n "${BUILD_CMDS:-}" ]; then BUILD_SCRIPT+="${BUILD_CMDS};"; fi
if [ -n "${INSTALL_CMDS:-}" ]; then
  safe_install_cmds="${INSTALL_CMDS//\'/\'\\\'\'}"
  BUILD_SCRIPT+="fakeroot sh -c '${safe_install_cmds}';"
fi

# execute
if [ "$CHROOT_METHOD" = "bwrap" ] && command -v bwrap >/dev/null 2>&1; then
  inner="set -euo pipefail; export JOBS=${JOBS}; export DESTDIR=/${DESTDIR_REL}; cd /${pkg_name}; ${BUILD_SCRIPT}"
  if [ "$QUIET" = true ]; then
    bwrap --ro-bind "$CHROOT_ROOT" / --dev /dev --proc /proc --tmpfs /tmp --ro-bind /usr /usr --ro-bind /bin /bin --ro-bind /lib /lib --ro-bind /lib64 /lib64 --unshare-net /bin/sh -c "$inner" &
    bp=$!
    # show CPU/MEM while building
    while kill -0 $bp 2>/dev/null; do
      cpu=$(cpu_percent); mem=$(mem_used_mb)
      printf "\rBuilding %s ... CPU:%s%% MEM:%sMB" "$PKG_ID" "$cpu" "$mem"
      sleep 0.6
    done
    wait $bp || _die "Erro no build dentro do bwrap"
    printf "\n"
  else
    bwrap --ro-bind "$CHROOT_ROOT" / --dev /dev --proc /proc --tmpfs /tmp --ro-bind /usr /usr --ro-bind /bin /bin --ro-bind /lib /lib --ro-bind /lib64 /lib64 --unshare-net /bin/sh -c "$inner"
  fi
else
  # fallback chroot
  if [ "$(id -u)" -ne 0 ]; then
    log_internal WARN "Fallback chroot pode exigir root; prosseguindo com privilégios atuais"
  fi
  chroot "$CHROOT_ROOT" /bin/sh -c "set -euo pipefail; export JOBS=${JOBS}; export DESTDIR=/${DESTDIR_REL}; cd /${pkg_name}; ${BUILD_SCRIPT}"
fi
run_hooks "post-build"
end_step 0

### 5) INSTALL (merge from chroot's DESTDIR)
start_step "install"
INST_ROOT="${CHROOT_ROOT}/${DESTDIR_REL}"
if [ -d "$INST_ROOT" ]; then
  mkdir -p "$DESTDIR"
  cp -a "$INST_ROOT"/. "$DESTDIR"/
  log_internal INFO "Arquivos instalados mesclados em $DESTDIR"
else
  log_internal WARN "Nenhum arquivo instalado em $INST_ROOT (verifique INSTALL_CMDS)"
fi
run_hooks "post-install"
end_step 0

### 6) STRIP (opcional)
if [ "$STRIP_BINARIES" = "true" ]; then
  start_step "strip"
  if command -v strip >/dev/null 2>&1 && command -v file >/dev/null 2>&1; then
    while IFS= read -r -d '' f; do
      if file "$f" | grep -q "ELF"; then
        strip --strip-unneeded "$f" || log_internal WARN "strip falhou: $f"
      fi
    done < <(find "$DESTDIR" -type f -print0)
  else
    log_internal WARN "strip/file não disponíveis; pulando strip"
  fi
  end_step 0
fi

### 7) PACKAGE (.tar.zst)
start_step "package"
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
log_internal INFO "Pacote criado: $pkg_file"
run_hooks "post-package"
end_step 0

### 8) EXPAND into / (opcional / perigoso)
if [ "${DO_EXPAND:-false}" = true ] || [ "${META_EXPAND:-false}" = "true" ]; then
  start_step "expand"
  if [ "$AUTO_YES" != true ]; then
    printf "\nATENÇÃO: vai extrair '%s' em / (root). Isso sobrescreverá arquivos.\nDigite 'yes' para confirmar: " "$pkg_file" >&2
    read -r ans
    if [ "$ans" != "yes" ]; then
      log_internal WARN "Usuário cancelou expand-root"
      end_step 1
    fi
  fi
  run_hooks "pre-expand-root"
  case "$pkg_file" in
    *.zst) zstd -d "$pkg_file" -c | tar -xf - -C / ;;
    *.tar) tar -xf "$pkg_file" -C / ;;
    *.xz) xz -d "$pkg_file" -c | tar -xf - -C / ;;
    *) _die "Tipo de pacote não suportado para expand: $pkg_file" ;;
  esac
  run_hooks "post-expand-root"
  log_internal INFO "Pacote expandido em /"
  end_step 0
fi

### final summary and optional hooks to deps/db managers
log_internal INFO "Build finalizado: ${PKG_ID}"
log_internal INFO "Pacote disponível em: $pkg_file"

# notify dependency manager / registro if configured
if [ -n "$DEPS_CMD" ] && command -v "$DEPS_CMD" >/dev/null 2>&1; then
  log_internal INFO "Chamando resolvedor de dependências: $DEPS_CMD"
  "$DEPS_CMD" --register "$PKG_ID" --manifest "$pkg_file" || log_internal WARN "DEPS_CMD retornou código não-zero"
fi
if [ -n "$DB_CMD" ] && command -v "$DB_CMD" >/dev/null 2>&1; then
  log_internal INFO "Registrando pacote no DB: $DB_CMD"
  "$DB_CMD" add --name "$pkg_name" --version "$pkg_version" --file "$pkg_file" || log_internal WARN "DB_CMD retornou código não-zero"
fi

exit 0
