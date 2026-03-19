#!/usr/bin/env bash
# install.sh — Deploy snapper-boot scripts and pacman hook
# Usage: sudo ./install.sh [--setup]
#   --setup   Also run snapshot-uki.sh if snapshots exist

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

# ─── Timeshift coexistence check ────────────────────────────────────────────

if pacman -Qi timeshift >/dev/null 2>&1; then
    warn "timeshift is installed. snapper-boot uses snapper, which may conflict."
    warn "Consider removing timeshift if unused."
fi

# ─── Check/install dependencies ─────────────────────────────────────────────

log "Checking dependencies..."

for pkg in snapper snap-pac; do
    if ! pacman -Qi "${pkg}" >/dev/null 2>&1; then
        log "Installing ${pkg}..."
        pacman -S --needed --noconfirm "${pkg}"
    else
        log "${pkg} already installed."
    fi
done

# ─── Verify snapper root config ─────────────────────────────────────────────

if ! snapper list-configs 2>/dev/null | grep -q 'root'; then
    die "No snapper root config found.
Create one with: sudo snapper -c root create-config /
Then re-run this script."
fi
log "Snapper root config found."

# ─── Verify signing and cmdline prereqs ────────────────────────────────────

[[ -f /etc/kernel/cmdline ]] || die "Kernel cmdline not found at /etc/kernel/cmdline — create it first."
command -v sbctl >/dev/null   || die "sbctl not installed."
sbctl status 2>/dev/null | grep -q "Installed" || die "sbctl keys not enrolled — run: sudo sbctl create-keys && sudo sbctl enroll-keys --microsoft"
log "Signing prereqs verified."

# ─── Deploy scripts ─────────────────────────────────────────────────────────

log "Deploying scripts to ${INSTALL_DIR}/..."
mkdir -p "${INSTALL_DIR}"

cp "${SCRIPT_DIR}/snapshot-uki.sh" "${INSTALL_DIR}/"
chmod 700 "${INSTALL_DIR}/snapshot-uki.sh"

# Write default config (non-destructive)
if [[ ! -f "${INSTALL_DIR}/config" ]]; then
    cat > "${INSTALL_DIR}/config" << 'EOF'
# snapper-boot configuration
# Maximum number of snapshot rollback UKI sets to keep on ESP
MAX_SNAPSHOTS=3
EOF
    log "Default config written to ${INSTALL_DIR}/config"
else
    log "Config already exists at ${INSTALL_DIR}/config — skipping."
fi

# ─── Deploy pacman hook ─────────────────────────────────────────────────────

log "Deploying pacman hook..."
mkdir -p /etc/pacman.d/hooks

# Remove old priority hook if present (was 01, now 06)
if [[ -f /etc/pacman.d/hooks/01-snapshot-uki-pre.hook ]]; then
    rm -f /etc/pacman.d/hooks/01-snapshot-uki-pre.hook
    log "Removed old hook: 01-snapshot-uki-pre.hook"
fi

# Generate hook with correct Exec path matching INSTALL_DIR
sed "s|^Exec = .*|Exec = ${INSTALL_DIR}/snapshot-uki.sh|" \
    "${SCRIPT_DIR}/06-snapshot-uki-pre.hook" > /etc/pacman.d/hooks/06-snapshot-uki-pre.hook
log "Hook deployed to /etc/pacman.d/hooks/06-snapshot-uki-pre.hook"

# ─── Optional: run setup immediately ────────────────────────────────────────

if $RUN_SETUP; then
    # Check if any snapshots exist before running
    if snapper -c root list 2>/dev/null | tail -n +4 | grep -qE '\S'; then
        log "Running snapshot-uki.sh (--setup flag passed)..."
        "${INSTALL_DIR}/snapshot-uki.sh"
    else
        warn "No snapshots exist yet — skipping initial build."
        warn "Rollback UKIs will be created on the next pacman transaction."
    fi
fi

# ─── Summary ─────────────────────────────────────────────────────────────────

echo ""
log "Installation complete!"
echo ""
echo "Deployed:"
echo "  ${INSTALL_DIR}/snapshot-uki.sh    — core script"
echo "  ${INSTALL_DIR}/config             — configuration"
echo "  /etc/pacman.d/hooks/06-snapshot-uki-pre.hook"
echo ""
echo "Rollback UKIs will be built automatically before each pacman transaction."
echo ""
echo "Manual usage:"
echo "  sudo ${INSTALL_DIR}/snapshot-uki.sh --list       # show rollback UKIs"
echo "  sudo ${INSTALL_DIR}/snapshot-uki.sh --snapshot N # build for snapshot N"
echo "  sudo ${INSTALL_DIR}/snapshot-uki.sh --cleanup    # prune old UKIs"
echo ""
echo "To undo: sudo ${SCRIPT_DIR}/remove.sh"
echo ""
