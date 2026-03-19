#!/usr/bin/env bash
# install.sh — Deploy zram-hibernate scripts
# Usage: sudo ./install.sh [--setup]
#   --setup   Also run setup.sh immediately after deploying

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_NAME="$(basename "$(cd "${SCRIPT_DIR}/.." && pwd)")"
MODULE_NAME="$(basename "${SCRIPT_DIR}")"
INSTALL_DIR="/etc/${REPO_NAME}/${MODULE_NAME}"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()  { echo -e "${GREEN}[install]${NC} $*"; }
warn() { echo -e "${YELLOW}[install]${NC} $*"; }
die()  { echo -e "${RED}[install] ERROR:${NC} $*" >&2; exit 1; }

RUN_SETUP=false
for arg in "$@"; do
    case "$arg" in
        --setup) RUN_SETUP=true ;;
        *) die "Unknown argument: $arg. Usage: sudo ./install.sh [--setup]" ;;
    esac
done

[[ $EUID -eq 0 ]] || die "Must run as root: sudo $0"

# ─── Check dependencies ───────────────────────────────────────────────────────

log "Checking dependencies..."
if ! pacman -Qi btrfs-progs >/dev/null 2>&1; then
    log "Installing btrfs-progs..."
    pacman -S --needed --noconfirm btrfs-progs
else
    log "btrfs-progs already installed."
fi

# ─── Deploy scripts ───────────────────────────────────────────────────────────

log "Deploying scripts to ${INSTALL_DIR}/..."
mkdir -p "${INSTALL_DIR}"

cp "${SCRIPT_DIR}/setup.sh"  "${INSTALL_DIR}/"
cp "${SCRIPT_DIR}/remove.sh" "${INSTALL_DIR}/"
chmod 700 "${INSTALL_DIR}"/*.sh

log "Scripts deployed."

# ─── Optional: run setup immediately ─────────────────────────────────────────

if $RUN_SETUP; then
    log "Running setup (--setup flag passed)..."
    exec "${INSTALL_DIR}/setup.sh"
fi

# ─── Summary ──────────────────────────────────────────────────────────────────

echo ""
log "Installation complete!"
echo ""
echo "Now run:"
echo "  sudo ${INSTALL_DIR}/setup.sh"
echo ""
echo "To undo everything later:"
echo "  sudo ${INSTALL_DIR}/remove.sh"
echo ""
