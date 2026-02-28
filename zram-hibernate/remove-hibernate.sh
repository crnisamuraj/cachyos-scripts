#!/usr/bin/env bash
# remove-hibernate.sh — Undo everything setup-hibernate.sh configured
# Usage: sudo /etc/zram-hibernate/remove-hibernate.sh

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
CMDLINE_FILE="/etc/uki-secureboot/cmdline"
APPARMOR_LOCAL="/etc/apparmor.d/local/systemd-sleep"
APPARMOR_PROFILE="/etc/apparmor.d/systemd-sleep"

[[ $EUID -eq 0 ]] || die "Must run as root: sudo $0"

echo -e "${YELLOW}[remove]${NC} This will undo all hibernate configuration. Ctrl-C to cancel."
echo ""

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

# ─── 4. Remove resume params from cmdline and rebuild UKIs ───────────────────

if [[ -f "$CMDLINE_FILE" ]]; then
    OLD_CMDLINE=$(cat "$CMDLINE_FILE")
    NEW_CMDLINE=$(echo "$OLD_CMDLINE" \
        | sed 's/resume=UUID=[^ ]*//g' \
        | sed 's/resume_offset=[^ ]*//g' \
        | sed 's/  */ /g' \
        | sed 's/^ //;s/ $//')

    if [[ "$OLD_CMDLINE" != "$NEW_CMDLINE" ]]; then
        log "Removing resume params from $CMDLINE_FILE:"
        log "  old: $OLD_CMDLINE"
        log "  new: $NEW_CMDLINE"
        _tmp=$(mktemp "${CMDLINE_FILE}.XXXXXX")
        echo "$NEW_CMDLINE" > "$_tmp"
        mv "$_tmp" "$CMDLINE_FILE"

        if [[ -x "/etc/uki-secureboot/uki-build.sh" ]]; then
            log "Rebuilding and re-signing UKIs..."
            /etc/uki-secureboot/uki-build.sh
        else
            warn "uki-build.sh not found — UKIs not rebuilt. Run manually when available."
        fi
    else
        log "No resume params found in cmdline — skipping."
    fi
else
    warn "Cmdline file not found: $CMDLINE_FILE — skipping."
fi

# ─── 5. mkinitcpio warning ───────────────────────────────────────────────────

warn "ACTION REQUIRED: Manually remove 'resume' from HOOKS in /etc/mkinitcpio.conf"
warn "  Then run: mkinitcpio -P && /etc/uki-secureboot/uki-build.sh"

# ─── 6. Remove AppArmor local override ───────────────────────────────────────

if [[ -f "$APPARMOR_LOCAL" ]]; then
    log "Removing AppArmor local override: $APPARMOR_LOCAL"
    rm -f "$APPARMOR_LOCAL"
    if [[ -f "$APPARMOR_PROFILE" ]]; then
        apparmor_parser -r "$APPARMOR_PROFILE" 2>/dev/null \
            && log "AppArmor profile reloaded." \
            || warn "AppArmor reload returned non-zero — may need a reboot."
    fi
else
    log "AppArmor local override not found — skipping."
fi

# ─── 7–8. Remove systemd drop-ins ────────────────────────────────────────────

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

# ─── 9. Reload systemd ───────────────────────────────────────────────────────

systemctl daemon-reload
log "systemd daemon reloaded."

# ─── 10. Summary ─────────────────────────────────────────────────────────────

echo ""
echo -e "${GREEN}══════════════════════════════════════════════${NC}"
echo -e "${GREEN}  Hibernate configuration removed!${NC}"
echo -e "${GREEN}══════════════════════════════════════════════${NC}"
echo ""
echo "Removed:"
echo "  - Swapfile ($SWAP_FILE)"
echo "  - /etc/fstab entry"
echo "  - resume params from $CMDLINE_FILE (UKIs rebuilt)"
echo "  - AppArmor local override ($APPARMOR_LOCAL)"
echo "  - /etc/systemd/logind.conf.d/hibernate.conf"
echo "  - /etc/systemd/sleep.conf.d/hibernate.conf"
echo ""
echo -e "${YELLOW}Still required manually:${NC}"
echo "  1. Remove 'resume' from HOOKS in /etc/mkinitcpio.conf"
echo "  2. Run: mkinitcpio -P"
echo "  3. Run: /etc/uki-secureboot/uki-build.sh"
echo "  4. Reboot"
echo ""
