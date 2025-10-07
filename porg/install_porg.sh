#!/usr/bin/env bash
# install_porg.sh - Installer for Porg system orchestrator

set -euo pipefail
IFS=$'\n\t'

# Define source dirs
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_TARGET="/usr/lib/porg"
BIN_TARGET="/usr/bin/porg"
CONF_TARGET="/etc/porg/porg.conf"
COMP_TARGET="/etc/bash_completion.d/porg_completions.bash"
LOG_DIR="/var/log/porg"
STATE_DIR="/var/lib/porg/state"
DB_DIR="/var/lib/porg/db"
CACHE_DIR="/var/lib/porg/cache"
PORTS_DIR="/usr/ports"

echo "🧱 Installing Porg system orchestrator..."

# ---------------- Verify dependencies ----------------
echo "🔍 Checking required dependencies..."

check_dep() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "❌ Missing dependency: $1"
    MISSING_DEPS+=("$1")
  else
    echo "✅ Found: $1"
  fi
}

MISSING_DEPS=()

# Base
for bin in bash awk grep sed find tar; do check_dep "$bin"; done
# Compression
for bin in xz zstd gzip; do check_dep "$bin"; done
# Networking
(check_dep curl || check_dep wget)
# Build tools
for bin in make fakeroot strip; do check_dep "$bin"; done
# Python
check_dep python3
# Git
check_dep git
# Lock/UI
check_dep flock
check_dep tput || echo "⚠️ tput not found; UI fallback to plain text"
# Sandbox (optional)
if command -v bwrap >/dev/null 2>&1; then
  echo "✅ Found bubblewrap (sandbox enabled)"
else
  echo "⚠️ bubblewrap not found; sandbox disabled"
fi

if [ "${#MISSING_DEPS[@]}" -gt 0 ]; then
  echo "❌ Missing ${#MISSING_DEPS[@]} dependencies. Install them before proceeding:"
  printf '  - %s\n' "${MISSING_DEPS[@]}"
  exit 1
fi

# ---------------- Create directories ----------------
echo "📂 Creating directories..."
mkdir -p "$LIB_TARGET" "$LOG_DIR" "$STATE_DIR" "$DB_DIR" "$CACHE_DIR" "$PORTS_DIR" "$(dirname "$CONF_TARGET")" "$(dirname "$COMP_TARGET")"

# ---------------- Copy files ----------------
echo "📦 Copying files..."

# Copy main binary
if [ -f "${SRC_DIR}/porg" ]; then
  cp -v "${SRC_DIR}/porg" "$BIN_TARGET"
  chmod +x "$BIN_TARGET"
else
  echo "❌ porg executable not found in current directory"
  exit 1
fi

# Copy modules
for mod in "${SRC_DIR}"/porg_*.sh; do
  if [ -f "$mod" ]; then
    echo "→ Installing module: $(basename "$mod")"
    cp -v "$mod" "$LIB_TARGET/"
    chmod +x "$LIB_TARGET/$(basename "$mod")"
  fi
done

# Copy Python deps module if exists
if [ -f "${SRC_DIR}/porg_deps.py" ]; then
  echo "→ Installing porg_deps.py"
  cp -v "${SRC_DIR}/porg_deps.py" "$LIB_TARGET/"
fi

# Copy config
if [ -f "${SRC_DIR}/porg.conf" ]; then
  cp -nv "${SRC_DIR}/porg.conf" "$CONF_TARGET"
else
  echo "⚠️ No porg.conf found, creating default one."
  cat > "$CONF_TARGET" <<'EOF'
# Default porg.conf
LIBDIR=/usr/lib/porg
WORKDIR=/var/tmp/porg
LOGDIR=/var/log/porg
STATE_DIR=/var/lib/porg/state
PORTS_DIR=/usr/ports
PACKAGE_FORMAT=tar.zst
CHROOT_METHOD=bwrap
JOBS=$(nproc)
EOF
fi

# Copy bash completions
if [ -f "${SRC_DIR}/porg_completions.bash" ]; then
  cp -v "${SRC_DIR}/porg_completions.bash" "$COMP_TARGET"
  chmod 644 "$COMP_TARGET"
  echo "✅ Bash completions installed in $COMP_TARGET"
else
  echo "⚠️ No bash completion script found."
fi

# ---------------- Post install checks ----------------
echo "🔍 Post-install checks..."
[ -x "$BIN_TARGET" ] || { echo "❌ porg executable not found at $BIN_TARGET"; exit 1; }
[ -d "$LIB_TARGET" ] || { echo "❌ library directory missing"; exit 1; }

# Verify Python module import
if python3 -c "import yaml,json" 2>/dev/null; then
  echo "✅ Python YAML & JSON support OK"
else
  echo "⚠️ PyYAML not found, install with: pip3 install pyyaml"
fi

# ---------------- Finish ----------------
echo "✅ Installation complete!"
echo
echo "You can now run:"
echo "  porg --init        # create runtime directories"
echo "  porg --status      # check system status"
echo
echo "Reload shell or run: source $COMP_TARGET  to enable autocompletion."
