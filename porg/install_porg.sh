#!/usr/bin/env bash
# install_porg.sh
# Instalador/Provisionador do Porg: verifica e instala dependências para funcionamento TOTAL
# (LFS bootstrap, BLFS, Xorg, KDE, TUI, chroot seguro com bubblewrap, PyYAML, etc.)
#
# Uso:
#   sudo ./install_porg.sh        # interativo (requer confirmação)
#   sudo ./install_porg.sh --yes  # assume "sim" para prompts
#   ./install_porg.sh --check     # só verifica e mostra o que falta (sem instalar)
#   ./install_porg.sh --dry-run   # imprime ações sem executar instalações
#
set -euo pipefail
IFS=$'\n\t'

# ----------------------------
# Configuráveis (edite se necessário)
# ----------------------------
SRC_DIR="$(pwd)"                  # onde os módulos do porg estão (padrão: diretório atual)
MODULES_DEST="/usr/lib/porg"
BIN_DEST="/usr/bin"
CONF_DIR="/etc/porg"
WORKDIR="/var/tmp/porg"
CACHE_DIR="${WORKDIR}/cache"
LOG_DIR="/var/log/porg"
STATE_DIR="/var/lib/porg"
SESSION_LOG_BASE="${LOG_DIR}/session"
KEEP_FILES_DIR="/var/cache/porg/sources"

# ----------------------------
# Flags
# ----------------------------
ASSUME_YES=false
DRY_RUN=false
CHECK_ONLY=false

# ----------------------------
# Helpers de UI (cores)
# ----------------------------
_have() { command -v "$1" >/dev/null 2>&1; }

if _have tput && [ -t 1 ]; then
  C_GREEN="$(tput setaf 2)"; C_RED="$(tput setaf 1)"; C_YELLOW="$(tput setaf 3)"
  C_BLUE="$(tput setaf 4)"; C_RESET="$(tput sgr0)"; C_BOLD="$(tput bold)"
else
  C_GREEN="\e[32m"; C_RED="\e[31m"; C_YELLOW="\e[33m"; C_BLUE="\e[34m"
  C_RESET="\e[0m"; C_BOLD="\e[1m"
fi

info(){ printf "%b[INFO] %b%s%b\n" "${C_BLUE}" "${C_RESET}" "$*" "${C_RESET}"; }
ok(){ printf "%b[ OK ]%b %s\n" "${C_GREEN}" "${C_RESET}" "$*"; }
warn(){ printf "%b[WARN]%b %s\n" "${C_YELLOW}" "${C_RESET}" "$*"; }
err(){ printf "%b[ERR ]%b %s\n" "${C_RED}" "${C_RESET}" "$*"; }
die(){ err "$*"; exit 1; }

# ----------------------------
# Parse args
# ----------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --yes|-y) ASSUME_YES=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --check) CHECK_ONLY=true; shift ;;
    --src-dir) SRC_DIR="$2"; shift 2 ;;
    --help|-h) cat <<EOF
Uso: $0 [--yes] [--check] [--dry-run] [--src-dir DIR]
  --yes       assume "yes" to prompts
  --check     apenas verificar dependências (não instala)
  --dry-run   simula as ações sem executar instalações
  --src-dir   diretório com os módulos porg (padrão: diretório atual)
EOF
      exit 0 ;;
    *) shift ;;
  esac
done

# ----------------------------
# Requisitos mínimos do script
# ----------------------------
if [ "$(id -u)" -ne 0 ]; then
  die "Este script precisa ser executado como root (use sudo)."
fi

if [ "$DRY_RUN" = true ]; then
  info "Modo DRY-RUN: nenhuma ação será executada, apenas simulada."
fi
if [ "$CHECK_ONLY" = true ]; then
  info "Modo CHECK-ONLY: listando dependências, nenhuma instalação será feita."
fi

# ----------------------------
# Detectar gerenciador de pacotes
# ----------------------------
PKG_MGR=""
PKG_INSTALL=""
PKG_UPDATE=""
PKG_DEPS_QUERY=""

if _have apt-get; then
  PKG_MGR="apt"
  PKG_INSTALL="apt-get install -y"
  PKG_UPDATE="apt-get update -y"
  PKG_DEPS_QUERY="dpkg -s"
elif _have dnf; then
  PKG_MGR="dnf"
  PKG_INSTALL="dnf install -y"
  PKG_UPDATE="dnf makecache"
  PKG_DEPS_QUERY="rpm -q"
elif _have pacman; then
  PKG_MGR="pacman"
  PKG_INSTALL="pacman -S --noconfirm --needed"
  PKG_UPDATE="pacman -Sy"
  PKG_DEPS_QUERY="pacman -Qi"
elif _have zypper; then
  PKG_MGR="zypper"
  PKG_INSTALL="zypper install -y"
  PKG_UPDATE="zypper refresh"
  PKG_DEPS_QUERY="rpm -q"
elif _have emerge; then
  PKG_MGR="emerge"
  PKG_INSTALL="emerge --ask=n"
  PKG_UPDATE="emerge --sync"
  PKG_DEPS_QUERY="qlist -I"
elif _have xbps-install; then
  PKG_MGR="xbps"
  PKG_INSTALL="xbps-install -Sy"
  PKG_UPDATE="xbps-install -S"
  PKG_DEPS_QUERY="xbps-query -l"
else
  PKG_MGR=""
fi

info "Gerenciador de pacotes detectado: ${PKG_MGR:-nenhum encontrado}"

# ----------------------------
# Listas de pacotes por papel (nomes por distro aproximados)
# Nota: nomes podem variar entre distros; script tenta instalar melhores correspondências.
# ----------------------------
read -r -d '' CORE_PKGS_DEB <<'PKGS' || true
build-essential curl wget git tar xz-utils zstd gzip make patch fakeroot file dpkg-dev gnupg \
python3 python3-pip python3-venv python3-distutils pkg-config bzip2
PKGS

read -r -d '' CORE_PKGS_RPM <<'PKGS' || true
gcc gcc-c++ curl wget git tar xz zstd gzip make patch fakeroot file python3 python3-pip \
python3-virtualenv python3-devel pkgconfig bzip2
PKGS

read -r -d '' CORE_PKGS_PACMAN <<'PKGS' || true
base-devel curl wget git tar xz zstd gzip make patch fakeroot file python python-pip \
pkgconf bzip2
PKGS

read -r -d '' TOOLCHAIN_PKGS_DEB <<'PKGS' || true
g++ autoconf automake libtool pkg-config meson ninja-build bison flex gettext \
libncurses-dev libcap-dev
PKGS

read -r -d '' TOOLCHAIN_PKGS_RPM <<'PKGS' || true
gcc-c++ autoconf automake libtool pkgconfig meson ninja-build bison flex gettext \
ncurses-devel libcap-devel
PKGS

read -r -d '' UI_PKGS_DEB <<'PKGS' || true
dialog whiptail ncurses-bin pv procps
PKGS

read -r -d '' UI_PKGS_RPM <<'PKGS' || true
dialog ncurses pv procps-ng
PKGS

# paquetes extras para pacman
read -r -d '' TOOLCHAIN_PKGS_PACMAN <<'PKGS' || true
gcc autoconf automake libtool pkgconf meson ninja bison flex gettext ncurses
PKGS

read -r -d '' UI_PKGS_PACMAN <<'PKGS' || true
dialog ncurses pv procps
PKGS

# packages for systems using emerge/xbps - best-effort names
read -r -d '' EXTRA_EMERGE <<'PKGS' || true
sys-devel/gcc dev-vcs/git app-arch/xz app-arch/zstd dev-util/cmake dev-util/meson dev-util/ninja \
dev-lang/python:3.9 dev-lang/python:3.10 sys-apps/findutils sys-devel/binutils dev-util/pkgconfig
PKGS

# ----------------------------
# Funções utilitárias
# ----------------------------
confirm() {
  if [ "$ASSUME_YES" = true ]; then return 0; fi
  read -r -p "$1 [y/N]: " ans
  case "$ans" in [Yy]*) return 0;; *) return 1;; esac
}

run_cmd() {
  if [ "$DRY_RUN" = true ]; then
    info "[DRY-RUN] $*"
    return 0
  fi
  eval "$*"
}

install_pkg_list() {
  local list="$1"
  if [ -z "$PKG_MGR" ]; then
    warn "Nenhum gerenciador de pacotes suportado detectado; instale os pacotes manualmente:"
    printf '%s\n' "$list"
    return 2
  fi

  info "Instalando pacotes via $PKG_MGR..."
  case "$PKG_MGR" in
    apt)
      run_cmd "DEBIAN_FRONTEND=noninteractive $PKG_UPDATE"
      run_cmd "$PKG_INSTALL $list"
      ;;
    dnf)
      run_cmd "$PKG_UPDATE"
      run_cmd "$PKG_INSTALL $list"
      ;;
    pacman)
      run_cmd "$PKG_UPDATE"
      run_cmd "$PKG_INSTALL $list"
      ;;
    zypper)
      run_cmd "$PKG_UPDATE"
      run_cmd "$PKG_INSTALL $list"
      ;;
    emerge)
      run_cmd "$PKG_UPDATE"
      run_cmd "$PKG_INSTALL $list"
      ;;
    xbps)
      run_cmd "$PKG_UPDATE"
      run_cmd "$PKG_INSTALL $list"
      ;;
    *)
      warn "Gerenciador $PKG_MGR não tratado explicitamente; tente instalar manualmente: $list"
      ;;
  esac
}

check_cmd() {
  if _have "$1"; then
    ok "$1 encontrado"
    return 0
  else
    warn "$1 ausente"
    return 1
  fi
}

# ----------------------------
# Checagem pré-instalação: quais comandos essenciais faltam?
# ----------------------------
info "Verificando pré-requisitos essenciais..."
MISSING_CMDS=()
for cmd in bash tar xz tar gzip zstd make patch fakeroot file git python3 pip3 curl sha256sum gpg; do
  if ! _have "$cmd"; then
    MISSING_CMDS+=("$cmd")
  fi
done

# show what is missing
if [ "${#MISSING_CMDS[@]}" -gt 0 ]; then
  warn "Comandos ausentes: ${MISSING_CMDS[*]}"
else
  ok "Todos os comandos essenciais parecem presentes."
fi

# ----------------------------
# If check-only, print recommendations and exit
# ----------------------------
if [ "$CHECK_ONLY" = true ]; then
  echo
  info "Modo somente-verificação: listagem de dependências recomendadas"
  echo "- Core packages (recommended):"
  case "$PKG_MGR" in
    apt) printf "%s\n" "$CORE_PKGS_DEB" ;;
    dnf|zypper) printf "%s\n" "$CORE_PKGS_RPM" ;;
    pacman) printf "%s\n" "$CORE_PKGS_PACMAN" ;;
    emerge) printf "%s\n" "$EXTRA_EMERGE" ;;
    *) printf "%s\n" "$CORE_PKGS_DEB" ;;
  esac
  echo
  info "Instalação automática desabilitada (modo --check). Saindo."
  exit 0
fi

# ----------------------------
# Instalar pacotes core + toolchain + ui
# ----------------------------
if [ "${#MISSING_CMDS[@]}" -gt 0 ] || ! _have python3 || ! python3 -c "import yaml" &>/dev/null; then
  info "Tentando instalar pacotes essenciais e dependências de build via gerenciador ($PKG_MGR)..."

  case "$PKG_MGR" in
    apt)
      install_pkg_list "$CORE_PKGS_DEB"
      install_pkg_list "$TOOLCHAIN_PKGS_DEB"
      install_pkg_list "$UI_PKGS_DEB"
      ;;
    dnf)
      install_pkg_list "$CORE_PKGS_RPM"
      install_pkg_list "$TOOLCHAIN_PKGS_RPM"
      install_pkg_list "$UI_PKGS_RPM"
      ;;
    pacman)
      install_pkg_list "$CORE_PKGS_PACMAN"
      install_pkg_list "$TOOLCHAIN_PKGS_PACMAN"
      install_pkg_list "$UI_PKGS_PACMAN"
      ;;
    zypper)
      install_pkg_list "$CORE_PKGS_RPM"
      install_pkg_list "$TOOLCHAIN_PKGS_RPM"
      install_pkg_list "$UI_PKGS_RPM"
      ;;
    emerge)
      info "Sistema Gentoo detectado: instalar manualmente (emerge) os pacotes listados."
      warn "$EXTRA_EMERGE"
      ;;
    xbps)
      install_pkg_list "$CORE_PKGS_RPM"
      install_pkg_list "$TOOLCHAIN_PKGS_RPM"
      install_pkg_list "$UI_PKGS_RPM"
      ;;
    "")
      warn "Nenhum gerenciador de pacotes detectado. Instale manualmente os pacotes listados no topo do script."
      ;;
  esac
else
  ok "Dependências essenciais já instaladas (python3 + ferramentas básicas)."
fi

# ----------------------------
# Verificar/install PyYAML
# ----------------------------
if python3 -c "import yaml" &>/dev/null; then
  ok "PyYAML disponível"
else
  warn "PyYAML não encontrado (python3 yaml). Vou tentar instalar via gerenciador/pip."
  if [ "$DRY_RUN" = true ]; then
    info "[DRY-RUN] pip3 install pyyaml"
  else
    if [ -n "$PKG_MGR" ]; then
      case "$PKG_MGR" in
        apt) run_cmd "apt-get install -y python3-yaml || pip3 install pyyaml" ;;
        dnf) run_cmd "dnf install -y python3-PyYAML || pip3 install pyyaml" ;;
        pacman) run_cmd "pacman -S --noconfirm python-yaml || pip3 install pyyaml" ;;
        zypper) run_cmd "zypper install -y python3-PyYAML || pip3 install pyyaml" ;;
        xbps) run_cmd "xbps-install -Sy python3-pyyaml || pip3 install pyyaml" ;;
        *) run_cmd "pip3 install pyyaml" ;;
      esac
    else
      run_cmd "pip3 install pyyaml"
    fi
  fi
fi

# ----------------------------
# Verificar bubblewrap (bwrap)
# ----------------------------
if _have bwrap; then
  ok "bubblewrap (bwrap) disponível"
else
  warn "bubblewrap não encontrado. É altamente recomendado para chroot seguro."
  if [ -n "$PKG_MGR" ]; then
    case "$PKG_MGR" in
      apt) run_cmd "$PKG_INSTALL bubblewrap" ;;
      dnf) run_cmd "$PKG_INSTALL bubblewrap" ;;
      pacman) run_cmd "$PKG_INSTALL bubblewrap" ;;
      zypper) run_cmd "$PKG_INSTALL bubblewrap" ;;
    esac
  else
    warn "Instale bubblewrap manualmente (ex: apt install bubblewrap)"
  fi
fi

# ----------------------------
# Criar diretórios padrão e permissões
# ----------------------------
info "Criando estrutura de diretórios do Porg..."
dirs=( "$MODULES_DEST" "$BIN_DEST" "$CONF_DIR" "$WORKDIR" "$CACHE_DIR" "$LOG_DIR" "$STATE_DIR" "$KEEP_FILES_DIR" )
for d in "${dirs[@]}"; do
  if [ "$DRY_RUN" = true ]; then
    info "[DRY-RUN] mkdir -p $d"
  else
    mkdir -p "$d"
    chmod 755 "$d" || true
  fi
done
ok "Diretórios criados/garantidos."

# ----------------------------
# Copiar módulos para /usr/lib/porg (se houverem no SRC_DIR)
# ----------------------------
info "Instalando módulos Porg em ${MODULES_DEST} (copiando de ${SRC_DIR})..."
if [ "$DRY_RUN" = true ]; then
  info "[DRY-RUN] cp -a ${SRC_DIR}/porg_* ${MODULES_DEST}/"
else
  shopt -s nullglob
  files=( "${SRC_DIR}/porg_"* )
  if [ "${#files[@]}" -eq 0 ]; then
    warn "Nenhum arquivo 'porg_*' encontrado em ${SRC_DIR}. Verifique se os módulos estão no diretório correto."
  else
    cp -av "${SRC_DIR}/porg_"* "$MODULES_DEST"/ || warn "Alguns módulos não puderam ser copiados"
    chmod -R 755 "$MODULES_DEST"
    ok "Módulos copiados para ${MODULES_DEST}."
  fi
fi

# ----------------------------
# Instalar o binário wrapper /usr/bin/porg (se existir)
# ----------------------------
if [ -f "${SRC_DIR}/porg" ]; then
  info "Instalando executável wrapper em ${BIN_DEST}/porg"
  if [ "$DRY_RUN" = true ]; then
    info "[DRY-RUN] cp ${SRC_DIR}/porg ${BIN_DEST}/porg && chmod +x ${BIN_DEST}/porg"
  else
    cp -av "${SRC_DIR}/porg" "${BIN_DEST}/porg"
    chmod +x "${BIN_DEST}/porg"
    ok "Executável /usr/bin/porg instalado"
  fi
else
  warn "Executável 'porg' não encontrado em ${SRC_DIR}. Você pode criar um wrapper em /usr/bin/porg que invoque /usr/lib/porg/porg (opcional)."
fi

# ----------------------------
# Criar /etc/porg/porg.conf se não existir (arquivo exemplo)
# ----------------------------
if [ ! -f "${CONF_DIR}/porg.conf" ]; then
  info "Criando arquivo de configuração padrão em ${CONF_DIR}/porg.conf"
  if [ "$DRY_RUN" = true ]; then
    info "[DRY-RUN] criar ${CONF_DIR}/porg.conf"
  else
    cat > "${CONF_DIR}/porg.conf" <<'CONF'
# porg.conf gerado pelo install_porg.sh
WORKDIR="/var/tmp/porg/work"
CACHE_DIR="${WORKDIR}/cache"
LOG_DIR="/var/log/porg"
PATCH_DIR="${WORKDIR}/patches"
DESTDIR_BASE="${WORKDIR}/destdir"
PKG_OUTPUT_DIR="${WORKDIR}/packages"
PORTS_DIR="/usr/ports"
MODULES_DIR="/usr/lib/porg"
DB_DIR="/var/lib/porg"
STATE_DIR="/var/lib/porg/state"
LOCKFILE="/var/lock/porg.lock"
HOOK_DIR="/etc/porg/hooks"
LFS="/mnt/lfs"

USE_CHROOT=true
CHROOT_METHOD="bwrap"
COPY_RESOLV_CONF=true
JOBS="$(nproc 2>/dev/null || echo 1)"
PKG_FORMAT="tar.zst"
USE_FAKEROOT=true
STRIP_BINARIES=true
LOG_LEVEL="INFO"
LOG_COLOR=true
CLEAN_OLD_LOGS_DAYS=10
TUI_ENABLED=false
SESSION_LOG_BASE="${SESSION_LOG_BASE}"
CONF
    ok "Arquivo de configuração padrão criado em ${CONF_DIR}/porg.conf"
  fi
else
  ok "Arquivo de configuração ${CONF_DIR}/porg.conf já existe; preservado."
fi

# ----------------------------
# Instalar bash completion (opcional, se houver em SRC_DIR)
# ----------------------------
if [ -f "${SRC_DIR}/por_completions.bash" ]; then
  info "Instalando bash completion..."
  if [ "$DRY_RUN" = true ]; then
    info "[DRY-RUN] cp ${SRC_DIR}/por_completions.bash /etc/bash_completion.d/porg"
  else
    mkdir -p /etc/bash_completion.d
    cp -av "${SRC_DIR}/por_completions.bash" /etc/bash_completion.d/porg
    ok "Bash completion instalado em /etc/bash_completion.d/porg"
  fi
fi

# ----------------------------
# Verificações finais: comandos essenciais
# ----------------------------
info "Verificando comandos essenciais pós-instalação..."
essential_check=( bash tar xz gzip zstd make patch fakeroot file git python3 pip3 curl sha256sum gpg bwrap )
MISSING_AFTER=()
for c in "${essential_check[@]}"; do
  if ! _have "$c"; then
    MISSING_AFTER+=("$c")
  fi
done

if [ "${#MISSING_AFTER[@]}" -gt 0 ]; then
  warn "Ainda faltam os seguintes comandos (instale-os manualmente ou reveja a saída): ${MISSING_AFTER[*]}"
else
  ok "Todas as dependências essenciais estão agora disponíveis."
fi

# ----------------------------
# Final: instruções pós-instalação e resumo
# ----------------------------
info "Instalação/Provisionamento do Porg concluído (ou simulado em dry-run)."
echo
echo -e "${C_BOLD}Resumo de locais importantes:${C_RESET}"
echo "  Módulos:   ${MODULES_DEST}"
echo "  Executável: ${BIN_DEST}/porg"
echo "  Config:    ${CONF_DIR}/porg.conf"
echo "  Workdir:   ${WORKDIR}"
echo "  Cache:     ${CACHE_DIR}"
echo "  Logs:      ${LOG_DIR}"
echo "  State:     ${STATE_DIR}"
echo
if [ "${#MISSING_AFTER[@]}" -gt 0 ]; then
  warn "Atenção: ainda faltam comandos listados acima. O Porg pode funcionar parcialmente sem alguns extras."
fi

echo
info "Próximos passos recomendados:"
echo "  1) Verifique/Preencha checksums nos metafiles (sha256) e coloque fontes em ${KEEP_FILES_DIR} se preferir."
echo "  2) Edite ${CONF_DIR}/porg.conf conforme sua preferência."
echo "  3) Execute: porg --init"
echo "  4) Teste o bootstrap em modo dry-run: porg --bootstrap build --dry"
echo
ok "Instalação finalizada."

exit 0
