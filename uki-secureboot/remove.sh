#!/usr/bin/env bash
# remove.sh — Undo uki-secureboot configuration
# Usage: sudo ./remove.sh
#
# This does NOT uninstall sbctl or systemd-ukify — only reverts config changes.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_NAME="$(basename "$(cd "${SCRIPT_DIR}/.." && pwd)")"
MODULE_NAME="$(basename "${SCRIPT_DIR}")"
INSTALL_DIR="/etc/${REPO_NAME}/${MODULE_NAME}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[remove]${NC} $*"; }
warn() { echo -e "${YELLOW}[remove]${NC} $*"; }
die()  { echo -e "${RED}[remove] ERROR:${NC} $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Must run as root: sudo $0"

# ─── Re-comment default_uki in mkinitcpio presets ────────────────────────────
log "Disabling UKI generation in mkinitcpio presets..."
for preset in /etc/mkinitcpio.d/*.preset; do
    [[ -f "${preset}" ]] || continue
    preset_name="$(basename "${preset}" .preset)"
    if grep -qE '^\s*default_uki=' "${preset}"; then
        sed -i 's/^\(\s*default_uki=\)/#\1/' "${preset}"
        log "  ${preset_name}: commented out default_uki."
    fi
done

# ─── Unmask systemd-boot-update.service ──────────────────────────────────────
log "Unmasking systemd-boot-update.service..."
systemctl unmask systemd-boot-update.service 2>/dev/null || true

# ─── Deregister UKIs from sbctl ─────────────────────────────────────────────
log "Deregistering UKIs from sbctl..."
for esp_candidate in /efi /boot/efi /boot; do
    if mountpoint -q "${esp_candidate}" 2>/dev/null; then
        for uki in "${esp_candidate}"/EFI/Linux/*.efi; do
            [[ -f "${uki}" ]] || continue
            [[ "$(basename "${uki}")" == snapshot-* ]] && continue
            sbctl remove-file "${uki}" 2>/dev/null || true
            rm -f "${uki}"
            log "  Removed: ${uki}"
        done
        break
    fi
done

# ─── Remove old custom hooks if present ──────────────────────────────────────
for old_hook in /etc/pacman.d/hooks/99-uki-build.hook /etc/pacman.d/hooks/99-uki-remove.hook; do
    if [[ -f "${old_hook}" ]]; then
        rm -f "${old_hook}"
        log "Removed old hook: ${old_hook}"
    fi
done

# ─── Remove install dirs (current and legacy) ───────────────────────────────
for dir in "${INSTALL_DIR}" "/etc/uki-secureboot"; do
    if [[ -d "${dir}" ]]; then
        rm -rf "${dir}"
        log "Removed ${dir}/"
    fi
done

# ─── Summary ────────────────────────────────────────────────────────────────
echo ""
log "Removal complete!"
echo ""
echo "Not removed (manual cleanup if desired):"
echo "  /etc/kernel/cmdline   — may be used by other tools"
echo "  /etc/kernel/uki.conf  — may be used by other tools"
echo "  sbctl keys            — use 'sbctl reset' to remove"
echo ""
