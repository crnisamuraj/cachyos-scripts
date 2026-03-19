#!/bin/bash
set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

[[ $EUID -ne 0 ]] && { error "Must run as root"; exit 1; }

CMDLINE_FILE="/etc/kernel/cmdline"

# ─── Helper: remove 'apparmor' from lsm= list ────────────────────────────────
# Handles all positions: only item, start, middle, end.
# If apparmor was the only item the entire lsm= parameter is removed.
remove_apparmor_from_lsm() {
    local file="$1"

    if ! grep -q 'lsm=' "$file"; then
        return
    fi

    local current_lsm
    current_lsm=$(grep -oP 'lsm=\S+' "$file" | head -1 | sed 's/^lsm=//')

    local new_lsm
    new_lsm=$(echo "$current_lsm" | tr ',' '\n' | grep -v '^apparmor$' | tr '\n' ',' | sed 's/,$//')

    if [[ -z "$new_lsm" ]]; then
        # apparmor was the only LSM — remove the entire parameter.
        # Note: [^ \t] in GNU sed bracket expressions does NOT interpret \t as tab;
        # use [^ ] (space only) since cmdline params are space-separated.
        sed -i 's/ lsm=[^ ]*//g' "$file"
        # Also handle the case where lsm= is at the start of the file
        sed -i 's/^lsm=[^ ]*//' "$file"
        sed -i 's/^[[:space:]]*//' "$file"
        info "Removed entire lsm= parameter (apparmor was the only entry)"
    else
        sed -i "s/lsm=[^ ]*/lsm=${new_lsm}/" "$file"
        info "Removed apparmor from lsm= list (remaining: ${new_lsm})"
    fi
}

# ─── Step 1: Set all profiles to complain mode ───────────────────────────────
info "Step 1: Setting all profiles to complain mode..."
aa-complain /etc/apparmor.d/* 2>/dev/null || true

# ─── Step 2: Stop and disable services ───────────────────────────────────────
info "Step 2: Disabling AppArmor service..."
systemctl disable --now apparmor.service || true

# ─── Step 3: Remove kernel parameters ────────────────────────────────────────
info "Step 3: Removing AppArmor kernel parameters..."

if [[ ! -f "$CMDLINE_FILE" ]]; then
    warn "$CMDLINE_FILE not found — skipping cmdline update."
else
    CMDLINE_CHANGED=0

    if grep -qw 'apparmor=1' "$CMDLINE_FILE"; then
        # Use word-boundary removal to handle all positions: start, middle, end, alone.
        # [[:space:]]* before \b consumes the preceding separator so no double-spaces
        # are left; leading whitespace is stripped separately for the start-of-line case.
        sed -i -E 's/[[:space:]]*\bapparmor=1\b//' "$CMDLINE_FILE"
        sed -i 's/^[[:space:]]*//' "$CMDLINE_FILE"
        info "Removed apparmor=1"
        CMDLINE_CHANGED=1
    fi

    if grep -qw 'security=apparmor' "$CMDLINE_FILE"; then
        sed -i -E 's/[[:space:]]*\bsecurity=apparmor\b//' "$CMDLINE_FILE"
        sed -i 's/^[[:space:]]*//' "$CMDLINE_FILE"
        info "Removed security=apparmor"
        CMDLINE_CHANGED=1
    fi

    if grep -q 'apparmor' <(grep 'lsm=' "$CMDLINE_FILE" 2>/dev/null) 2>/dev/null; then
        remove_apparmor_from_lsm "$CMDLINE_FILE"
        CMDLINE_CHANGED=1
    fi

    if [[ $CMDLINE_CHANGED -eq 1 ]]; then
        info "Rebuilding UKI with updated cmdline..."
        mkinitcpio -P || { error "UKI rebuild failed. Check output above."; exit 1; }
        info "UKI rebuilt successfully."
    else
        info "No AppArmor kernel parameters found — skipping UKI rebuild."
    fi
fi

# ─── Step 4: Remove audit rules ──────────────────────────────────────────────
info "Step 4: Removing AppArmor audit rules..."

if [[ -f /etc/audit/rules.d/apparmor.rules ]]; then
    rm -f /etc/audit/rules.d/apparmor.rules
    augenrules --load 2>/dev/null || true
    info "Removed /etc/audit/rules.d/apparmor.rules"
else
    info "No AppArmor audit rules file found — skipping."
fi

# Offer to disable auditd if it was enabled solely for AppArmor
if systemctl is-enabled auditd.service &>/dev/null; then
    warn "auditd.service is still enabled."
    warn "If it was enabled solely for AppArmor, disable it with:"
    warn "  sudo systemctl disable --now auditd.service"
fi

# ─── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}Reboot to complete removal.${NC}"
echo ""
echo "The new UKI (without AppArmor kernel parameters) will be active after reboot."
echo "Packages (apparmor, apparmor.d) were NOT removed — do that manually if desired:"
echo "  sudo pacman -Rns apparmor"
echo "  sudo pacman -Rns apparmor.d.enforced  # or apparmor.d-git"
