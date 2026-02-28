#!/usr/bin/env bash
# install.sh — Deploy snapper-boot scripts and pacman hook
# Usage: sudo ./install.sh [--setup]
#   --setup   Also run snapshot-uki.sh if snapshots exist

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

# ─── Verify uki-secureboot prereqs ──────────────────────────────────────────

CMDLINE="/etc/uki-secureboot/cmdline"
KEY_DIR="/etc/uki-secureboot/keys"

[[ -f "${CMDLINE}" ]]         || die "Kernel cmdline not found at ${CMDLINE} — is uki-secureboot deployed?"
[[ -f "${KEY_DIR}/MOK.key" ]] || die "MOK key not found at ${KEY_DIR}/MOK.key — run uki-secureboot setup first."
[[ -f "${KEY_DIR}/MOK.pem" ]] || die "MOK certificate not found at ${KEY_DIR}/MOK.pem."
log "uki-secureboot prereqs verified."

# ─── Deploy scripts ─────────────────────────────────────────────────────────

log "Deploying scripts to /etc/snapper-boot/..."
mkdir -p /etc/snapper-boot

cp "${SCRIPT_DIR}/snapshot-uki.sh" /etc/snapper-boot/
chmod 700 /etc/snapper-boot/snapshot-uki.sh

# Write default config (non-destructive)
if [[ ! -f /etc/snapper-boot/config ]]; then
    cat > /etc/snapper-boot/config << 'EOF'
# snapper-boot configuration
# Maximum number of snapshot rollback UKI sets to keep on ESP
MAX_SNAPSHOTS=3
EOF
    log "Default config written to /etc/snapper-boot/config"
else
    log "Config already exists at /etc/snapper-boot/config — skipping."
fi

# ─── Deploy pacman hook ─────────────────────────────────────────────────────

log "Deploying pacman hook..."
mkdir -p /etc/pacman.d/hooks
cp "${SCRIPT_DIR}/01-snapshot-uki-pre.hook" /etc/pacman.d/hooks/
log "Hook deployed to /etc/pacman.d/hooks/01-snapshot-uki-pre.hook"

# ─── Optional: run setup immediately ────────────────────────────────────────

if $RUN_SETUP; then
    # Check if any snapshots exist before running
    if snapper -c root list 2>/dev/null | tail -n +4 | grep -qE '\S'; then
        log "Running snapshot-uki.sh (--setup flag passed)..."
        /etc/snapper-boot/snapshot-uki.sh
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
echo "  /etc/snapper-boot/snapshot-uki.sh    — core script"
echo "  /etc/snapper-boot/config             — configuration"
echo "  /etc/pacman.d/hooks/01-snapshot-uki-pre.hook"
echo ""
echo "Rollback UKIs will be built automatically before each pacman transaction."
echo ""
echo "Manual usage:"
echo "  sudo /etc/snapper-boot/snapshot-uki.sh --list       # show rollback UKIs"
echo "  sudo /etc/snapper-boot/snapshot-uki.sh --snapshot N # build for snapshot N"
echo "  sudo /etc/snapper-boot/snapshot-uki.sh --cleanup    # prune old UKIs"
echo ""
echo "To undo: sudo ${SCRIPT_DIR}/remove.sh"
echo ""
