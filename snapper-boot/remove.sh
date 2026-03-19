#!/usr/bin/env bash
# remove.sh — Remove snapper-boot: rollback UKIs, hook, and config
# Usage: sudo ./remove.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_NAME="$(basename "$(cd "${SCRIPT_DIR}/.." && pwd)")"
MODULE_NAME="$(basename "${SCRIPT_DIR}")"
INSTALL_DIR="/etc/${REPO_NAME}/${MODULE_NAME}"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()  { echo -e "${GREEN}[remove]${NC} $*"; }
warn() { echo -e "${YELLOW}[remove]${NC} $*"; }
die()  { echo -e "${RED}[remove] ERROR:${NC} $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Must run as root: sudo $0"

# ─── Remove rollback UKIs from ESP ──────────────────────────────────────────

# Auto-detect ESP mount point
if [[ -z "${ESP:-}" ]]; then
    for _esp in /efi /boot/efi /boot; do
        if mountpoint -q "${_esp}" 2>/dev/null; then
            ESP="${_esp}"
            break
        fi
    done
fi

if [[ -n "${ESP:-}" ]]; then
    UKI_DIR="${ESP}/EFI/Linux"
    removed=0
    for uki in "${UKI_DIR}"/snapshot-*.efi; do
        [[ -f "${uki}" ]] || continue
        log "Removing: ${uki}"
        sbctl remove-file "${uki}" 2>/dev/null || true
        rm -f "${uki}"
        removed=$((removed + 1))
    done
    if [[ ${removed} -gt 0 ]]; then
        log "Removed ${removed} rollback UKI(s) from ESP."
    else
        log "No rollback UKIs found on ESP."
    fi
else
    warn "Cannot detect ESP mount point — skipping UKI removal."
    warn "Manually remove snapshot-*.efi from your ESP's EFI/Linux/ directory."
fi

# ─── Remove pacman hook ─────────────────────────────────────────────────────

# Remove current and legacy hook names
for hook_name in 06-snapshot-uki-pre.hook 01-snapshot-uki-pre.hook; do
    hook_path="/etc/pacman.d/hooks/${hook_name}"
    if [[ -f "${hook_path}" ]]; then
        rm -f "${hook_path}"
        log "Removed pacman hook: ${hook_path}"
    fi
done

# ─── Remove config directory ────────────────────────────────────────────────

# Remove current and legacy config directories
for dir in "${INSTALL_DIR}" "/etc/snapper-boot"; do
    if [[ -d "${dir}" ]]; then
        rm -rf "${dir}"
        log "Removed ${dir}/"
    fi
done

# ─── Summary ─────────────────────────────────────────────────────────────────

echo ""
log "Removal complete!"
echo ""
echo "Optional manual cleanup:"
echo "  sudo pacman -R snap-pac    # if no longer needed"
echo "  sudo pacman -R snapper     # if no longer needed"
echo ""
