#!/usr/bin/env bash
# remove.sh — Undo everything setup.sh configured
# Usage: sudo /etc/arch-scripts/zram-hibernate/remove.sh

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()  { echo -e "${GREEN}[remove]${NC} $*"; }
warn() { echo -e "${YELLOW}[remove]${NC} $*"; }
die()  { echo -e "${RED}[remove] ERROR:${NC} $*" >&2; exit 1; }

SWAP_PATH="/var/swap"
SWAP_FILE="$SWAP_PATH/swapfile"
CMDLINE_FILE="/etc/kernel/cmdline"
APPARMOR_LOCAL="/etc/apparmor.d/local/systemd-sleep"
APPARMOR_PROFILE="/etc/apparmor.d/systemd-sleep"

MKINITCPIO_CONF="/etc/mkinitcpio.conf"

[[ $EUID -eq 0 ]] || die "Must run as root: sudo $0"

warn "This will undo all hibernate configuration. Ctrl-C to cancel."
echo ""
sleep 5

NEED_INITRAMFS=false   # mkinitcpio.conf changed → mkinitcpio -P required
NEED_UKI=false         # cmdline or initramfs changed → uki-build required

# ─── 1. Swapoff ──────────────────────────────────────────────────────────────

if swapon --show 2>/dev/null | grep -qF "$SWAP_FILE"; then
    log "Deactivating swapfile..."
    swapoff "$SWAP_FILE"
else
    log "Swapfile not active — skipping swapoff."
fi

# ─── 2. Remove from /etc/fstab ───────────────────────────────────────────────

if grep -qF "$SWAP_FILE" /etc/fstab; then
    log "Removing swapfile entry from /etc/fstab..."
    sed -i "\|$SWAP_FILE|d" /etc/fstab
else
    log "No swapfile entry in /etc/fstab — skipping."
fi

# ─── 3. Delete swapfile and subvolume ────────────────────────────────────────

if [[ -d "$SWAP_PATH" ]]; then
    log "Deleting $SWAP_PATH..."
    if btrfs subvolume show "$SWAP_PATH" >/dev/null 2>&1; then
        btrfs subvolume delete "$SWAP_PATH" || {
            warn "btrfs subvolume delete failed — falling back to rm -rf"
            rm -rf "$SWAP_PATH"
        }
    else
        rm -rf "$SWAP_PATH"
    fi
    log "Deleted $SWAP_PATH."
else
    log "$SWAP_PATH not found — skipping."
fi

# ─── 4. Remove resume params from cmdline ────────────────────────────────────

if [[ -f "$CMDLINE_FILE" ]]; then
    OLD_CMDLINE=$(cat "$CMDLINE_FILE")
    NEW_CMDLINE=$(printf '%s' "$OLD_CMDLINE" \
        | sed 's/resume=UUID=[^ ]*//g' \
        | sed 's/resume_offset=[^ ]*//g' \
        | sed 's/  */ /g' \
        | sed 's/^ //;s/ $//')

    if [[ "$OLD_CMDLINE" != "$NEW_CMDLINE" ]]; then
        log "Removing resume params from $CMDLINE_FILE:"
        log "  old: $OLD_CMDLINE"
        log "  new: $NEW_CMDLINE"
        _tmp=$(mktemp "${CMDLINE_FILE}.XXXXXX")
        chmod --reference="$CMDLINE_FILE" "$_tmp"
        printf '%s' "$NEW_CMDLINE" > "$_tmp"
        mv "$_tmp" "$CMDLINE_FILE"
        NEED_UKI=true
    else
        log "No resume params found in cmdline — skipping."
    fi
else
    warn "Cmdline file not found: $CMDLINE_FILE — skipping."
fi

# ─── 5. Remove 'resume' hook from mkinitcpio.conf (udev setups only) ─────────

if [[ -f "$MKINITCPIO_CONF" ]]; then
    HOOKS_LINE=$(grep -E '^\s*HOOKS=' "$MKINITCPIO_CONF" | tail -1 || true)
    hooks_content=$(printf '%s\n' "$HOOKS_LINE" | sed 's/.*HOOKS=(\([^)]*\)).*/\1/')
    if printf '%s\n' "$hooks_content" | grep -qw 'udev' && printf '%s\n' "$hooks_content" | grep -qw 'resume'; then
        log "Removing 'resume' hook from $MKINITCPIO_CONF..."
        cp "$MKINITCPIO_CONF" "${MKINITCPIO_CONF}.bak"
        sed -i '/^\s*HOOKS=/ { s/\bresume\b//g; s/  */ /g; s/(  */(/; s/ )/)/; }' "$MKINITCPIO_CONF"
        log "Removed 'resume' hook (backup: ${MKINITCPIO_CONF}.bak)."
        NEED_INITRAMFS=true
        NEED_UKI=true
    else
        log "No 'resume' hook to remove (systemd-based initramfs or already absent)."
    fi
else
    warn "$MKINITCPIO_CONF not found — skipping resume hook removal."
fi

# ─── 6. Rebuild initramfs and UKIs if anything changed ───────────────────────

if [[ "$NEED_INITRAMFS" == true || "$NEED_UKI" == true ]]; then
    log "Rebuilding initramfs and UKIs via mkinitcpio..."
    mkinitcpio -P || warn "mkinitcpio rebuild failed — rebuild manually."
fi

# ─── 7. Remove AppArmor local override ───────────────────────────────────────

if [[ -f "$APPARMOR_LOCAL" ]]; then
    log "Removing AppArmor local override: $APPARMOR_LOCAL"
    rm -f "$APPARMOR_LOCAL"
    if [[ -f "$APPARMOR_PROFILE" ]]; then
        if apparmor_parser -r "$APPARMOR_PROFILE" 2>/dev/null; then
            log "AppArmor profile reloaded."
        else
            warn "AppArmor reload returned non-zero — may need a reboot."
        fi
    fi
else
    log "AppArmor local override not found — skipping."
fi

# ─── 8–9. Remove systemd drop-ins ────────────────────────────────────────────

for f in \
    /etc/systemd/logind.conf.d/hibernate.conf \
    /etc/systemd/sleep.conf.d/hibernate.conf; do
    if [[ -f "$f" ]]; then
        log "Removing $f"
        rm -f "$f"
    else
        log "$f not found — skipping."
    fi
done

# ─── 10. Reload systemd ──────────────────────────────────────────────────────

systemctl daemon-reload
log "systemd daemon reloaded."

# ─── 11. Summary ─────────────────────────────────────────────────────────────

echo ""
echo -e "${GREEN}══════════════════════════════════════════════${NC}"
echo -e "${GREEN}  Hibernate configuration removed!${NC}"
echo -e "${GREEN}══════════════════════════════════════════════${NC}"
echo ""
echo "Removed:"
echo "  - Swapfile ($SWAP_FILE)"
echo "  - /etc/fstab entry"
echo "  - resume params from $CMDLINE_FILE"
echo "  - AppArmor local override ($APPARMOR_LOCAL)"
echo "  - /etc/systemd/logind.conf.d/hibernate.conf"
echo "  - /etc/systemd/sleep.conf.d/hibernate.conf"
echo ""
echo -e "${YELLOW}Action required:${NC}"
echo "  Reboot to activate the restored kernel configuration."
echo ""
