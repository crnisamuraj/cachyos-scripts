#!/usr/bin/env bash
# setup-hibernate.sh — Configure hibernate-to-swapfile on BTRFS with ZRAM coexistence
# Usage: sudo /etc/zram-hibernate/setup-hibernate.sh

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()  { echo -e "${GREEN}[setup]${NC} $*"; }
warn() { echo -e "${YELLOW}[setup]${NC} $*"; }
die()  { echo -e "${RED}[setup] ERROR:${NC} $*" >&2; exit 1; }

SWAP_PATH="/var/swap"
SWAP_FILE="$SWAP_PATH/swapfile"
CMDLINE_FILE="/etc/uki-secureboot/cmdline"
MKINITCPIO_CONF="/etc/mkinitcpio.conf"

# ─── Pre-flight checks ───────────────────────────────────────────────────────

[[ $EUID -eq 0 ]] || die "Must run as root: sudo $0"

log "Running pre-flight checks..."

for cmd in btrfs findmnt mkinitcpio; do
    command -v "$cmd" >/dev/null 2>&1 || die "Required command not found: $cmd"
done

[[ -f "$CMDLINE_FILE" ]]     || die "Kernel cmdline file not found: $CMDLINE_FILE — is uki-secureboot set up?"
[[ -f "$MKINITCPIO_CONF" ]]  || die "mkinitcpio config not found: $MKINITCPIO_CONF"

# Verify 'resume' hook presence and ordering in mkinitcpio.conf
HOOKS_LINE=$(grep -E '^\s*HOOKS=' "$MKINITCPIO_CONF" | tail -1 || true)
[[ -n "$HOOKS_LINE" ]] || die "Could not find HOOKS= line in $MKINITCPIO_CONF"

hooks_content=$(echo "$HOOKS_LINE" | sed 's/.*HOOKS=(\([^)]*\)).*/\1/')
[[ "$hooks_content" != "$HOOKS_LINE" ]] \
    || die "Could not parse HOOKS array from $MKINITCPIO_CONF — unexpected format: $HOOKS_LINE"

if ! echo "$hooks_content" | grep -qw 'resume'; then
    die "'resume' hook not found in $MKINITCPIO_CONF HOOKS.

Add 'resume' after 'filesystems' in the HOOKS line, e.g.:
  HOOKS=(base udev autodetect modconf kms keyboard keymap consolefont block filesystems resume fsck)

Then re-run this script."
fi

# Check that resume comes after filesystems
fs_pos=0
resume_pos=0
i=0
for hook in $hooks_content; do
    i=$((i + 1))
    if [[ "$hook" == "filesystems" ]]; then fs_pos=$i; fi
    if [[ "$hook" == "resume" ]];      then resume_pos=$i; fi
done

if [[ $fs_pos -gt 0 && $resume_pos -le $fs_pos ]]; then
    die "'resume' hook must come AFTER 'filesystems' in $MKINITCPIO_CONF HOOKS.

Current order: filesystems=$fs_pos, resume=$resume_pos
Fix: move 'resume' to after 'filesystems', e.g.:
  HOOKS=(base udev autodetect ... filesystems resume fsck)

Then re-run this script."
fi

log "Pre-flight OK: 'resume' hook present and correctly ordered."

if grep -qw 'noresume' "$CMDLINE_FILE"; then
    warn "'noresume' found in $CMDLINE_FILE — hibernate will not restore state until it is removed!"
fi

# ─── 1. Calculate swap size ──────────────────────────────────────────────────

MEM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
MEM_GB=$(( (MEM_KB + 1048575) / 1048576 ))
SWAP_SIZE_GB=$((MEM_GB + 4))

log "System RAM: ${MEM_GB}GB | Target swapfile size: ${SWAP_SIZE_GB}GB"

# ─── 2. Create BTRFS swapfile ────────────────────────────────────────────────

if [[ -f "$SWAP_FILE" ]]; then
    log "Swapfile already exists at $SWAP_FILE — skipping creation."
else
    if [[ -d "$SWAP_PATH" ]]; then
        if ! btrfs subvolume show "$SWAP_PATH" >/dev/null 2>&1; then
            die "$SWAP_PATH exists as a regular directory (not a BTRFS subvolume).
Investigate and remove it manually, then re-run this script."
        fi
        log "$SWAP_PATH is already a BTRFS subvolume."
    else
        log "Creating BTRFS subvolume: $SWAP_PATH"
        btrfs subvolume create "$SWAP_PATH"
    fi

    log "Disabling CoW on $SWAP_PATH (chattr +C)..."
    chattr +C "$SWAP_PATH"

    log "Creating swapfile (${SWAP_SIZE_GB}G)..."
    btrfs filesystem mkswapfile --size "${SWAP_SIZE_GB}G" "$SWAP_FILE"
    chmod 600 "$SWAP_FILE"
    log "Swapfile created: $SWAP_FILE"
fi

# ─── 3. Configure /etc/fstab ─────────────────────────────────────────────────

if grep -qF "$SWAP_FILE" /etc/fstab; then
    log "Swapfile already in /etc/fstab — skipping."
else
    echo "$SWAP_FILE none swap defaults,pri=0 0 0" >> /etc/fstab
    log "Added to /etc/fstab (pri=0, below ZRAM priority of 100)"
fi

if swapon --show 2>/dev/null | grep -qF "$SWAP_FILE"; then
    log "Swapfile already active."
else
    swapon "$SWAP_FILE"
    log "Swapfile activated."
fi

# ─── 4. Get resume parameters ────────────────────────────────────────────────

log "Getting resume parameters..."
RESUME_UUID=$(findmnt -no UUID -T "$SWAP_FILE")
RESUME_OFFSET=$(btrfs inspect-internal map-swapfile -r "$SWAP_FILE")

[[ -n "$RESUME_UUID" ]]   || die "Could not determine filesystem UUID for $SWAP_FILE (findmnt returned empty)"
[[ -n "$RESUME_OFFSET" ]] || die "Could not determine swapfile offset (btrfs map-swapfile returned empty)"

log "  resume UUID   : $RESUME_UUID"
log "  resume offset : $RESUME_OFFSET"

# ─── 5. Update kernel cmdline (strip-and-replace) ────────────────────────────

OLD_CMDLINE=$(cat "$CMDLINE_FILE")

# Strip any existing resume tokens (handles re-runs with updated values)
NEW_CMDLINE=$(echo "$OLD_CMDLINE" \
    | sed 's/resume=UUID=[^ ]*//g' \
    | sed 's/resume_offset=[^ ]*//g' \
    | sed 's/  */ /g' \
    | sed 's/^ //;s/ $//')
NEW_CMDLINE="$NEW_CMDLINE resume=UUID=$RESUME_UUID resume_offset=$RESUME_OFFSET"

if [[ "$OLD_CMDLINE" == "$NEW_CMDLINE" ]]; then
    log "Cmdline already up to date — skipping."
else
    log "Updating $CMDLINE_FILE:"
    log "  old: $OLD_CMDLINE"
    log "  new: $NEW_CMDLINE"
    _tmp=$(mktemp "${CMDLINE_FILE}.XXXXXX")
    echo "$NEW_CMDLINE" > "$_tmp"
    mv "$_tmp" "$CMDLINE_FILE"
fi

# ─── 6. Rebuild initramfs ────────────────────────────────────────────────────

log "Rebuilding initramfs (mkinitcpio -P)..."
mkinitcpio -P

# ─── 7. Rebuild and re-sign UKIs ─────────────────────────────────────────────
# Must run AFTER mkinitcpio so the UKI embeds the new initramfs + updated cmdline.
# The pacman hook (99-uki-build.hook) only fires on package updates, not here.

log "Rebuilding and signing UKIs..."
[[ -x "/etc/uki-secureboot/uki-build.sh" ]] || die "uki-build.sh not found — is uki-secureboot deployed to /etc/uki-secureboot/?"
/etc/uki-secureboot/uki-build.sh

# ─── 8. AppArmor local override ──────────────────────────────────────────────
# /etc/apparmor.d/systemd-sleep already contains:
#   include if exists <local/systemd-sleep>
# so this file is automatically picked up on profile reload.

APPARMOR_LOCAL="/etc/apparmor.d/local/systemd-sleep"
APPARMOR_PROFILE="/etc/apparmor.d/systemd-sleep"

log "Writing AppArmor local override: $APPARMOR_LOCAL"
mkdir -p /etc/apparmor.d/local

cat > "$APPARMOR_LOCAL" << 'EOF'
# zram-hibernate: allow systemd-sleep to write hibernate resume parameters

# Allow hibernate to write resume parameters to sysfs
/sys/power/ r,
/sys/power/disk rw,
/sys/power/resume rw,
/sys/power/resume_offset rw,
/sys/power/image_size rw,

# Allow access to swapfile
/var/swap/ r,
/var/swap/swapfile rw,
EOF

if [[ -f "$APPARMOR_PROFILE" ]]; then
    apparmor_parser -r "$APPARMOR_PROFILE" 2>/dev/null \
        && log "AppArmor profile reloaded." \
        || warn "AppArmor reload returned non-zero — profile may not be active yet (OK on first boot)."
else
    warn "AppArmor profile not found at $APPARMOR_PROFILE — local override written but not loaded."
fi

# ─── 9. Configure systemd sleep ──────────────────────────────────────────────

log "Writing systemd drop-ins..."

mkdir -p /etc/systemd/logind.conf.d
cat > /etc/systemd/logind.conf.d/hibernate.conf << 'EOF'
[Login]
HandleLidSwitch=suspend-then-hibernate
HandleLidSwitchExternalPower=suspend-then-hibernate
EOF
log "Written: /etc/systemd/logind.conf.d/hibernate.conf"

mkdir -p /etc/systemd/sleep.conf.d
cat > /etc/systemd/sleep.conf.d/hibernate.conf << 'EOF'
[Sleep]
HibernateDelaySec=2h
HibernateMode=platform
EOF
log "Written: /etc/systemd/sleep.conf.d/hibernate.conf"

systemctl daemon-reload
log "systemd daemon reloaded."

# ─── 10. Summary ─────────────────────────────────────────────────────────────

echo ""
echo -e "${GREEN}══════════════════════════════════════════════${NC}"
echo -e "${GREEN}  Hibernate setup complete!${NC}"
echo -e "${GREEN}══════════════════════════════════════════════${NC}"
echo ""
echo "  Swapfile     : $SWAP_FILE (${SWAP_SIZE_GB}G, pri=0)"
echo "  Resume UUID  : $RESUME_UUID"
echo "  Resume offset: $RESUME_OFFSET"
echo ""
echo "Next steps:"
echo "  1. Reboot to activate the new UKI (resume params in cmdline)"
echo "  2. Verify after reboot:"
echo "       cat /sys/power/resume          # major:minor of resume device"
echo "       cat /sys/power/resume_offset   # should match: $RESUME_OFFSET"
echo "       swapon --show                  # swapfile pri=0, zram pri=100"
echo "  3. Test: systemctl hibernate"
echo ""
