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

COMPLAIN_MODE=0
for arg in "$@"; do
    case "$arg" in
        --complain) COMPLAIN_MODE=1 ;;
        *) error "Unknown argument: $arg"; exit 1 ;;
    esac
done

CMDLINE_FILE="/etc/kernel/cmdline"

# ─── Step 1: Install packages ────────────────────────────────────────────────
info "Step 1: Installing packages..."

pacman -S --needed --noconfirm apparmor audit

if ! pacman -Qi apparmor.d-git &>/dev/null && ! pacman -Qi apparmor.d &>/dev/null; then
    AUR_HELPER=""
    if command -v paru &>/dev/null; then
        AUR_HELPER="paru"
    elif command -v yay &>/dev/null; then
        AUR_HELPER="yay"
    fi

    if [[ -z "$AUR_HELPER" ]]; then
        error "No AUR helper found (paru or yay). Install apparmor.d manually:"
        error "  paru -S apparmor.d-git or apparmor.d or apparmor.d"
        error "  # or: yay -S apparmor.d-git"
        exit 1
    fi

    info "Installing apparmor.d via $AUR_HELPER..."
    "$AUR_HELPER" -S apparmor.d-git || "$AUR_HELPER" -S apparmor.d || "$AUR_HELPER" -S apparmor.d.enforced
fi

# ─── Step 2: Enable kernel parameters (UKI-aware) ────────────────────────────
info "Step 2: Configuring kernel parameters..."

if [[ ! -f "$CMDLINE_FILE" ]]; then
    warn "$CMDLINE_FILE not found — skipping UKI cmdline update."
    warn "Add these parameters manually before rebooting:"
    warn "  apparmor=1  lsm=landlock,lockdown,yama,integrity,apparmor,bpf"
else
    CMDLINE_CHANGED=0

    # apparmor=1
    if ! grep -qw 'apparmor=1' "$CMDLINE_FILE"; then
        # Append with a space separator; strip trailing whitespace first
        sed -i 's/[[:space:]]*$//' "$CMDLINE_FILE"
        echo -n ' apparmor=1' >> "$CMDLINE_FILE"
        info "Added apparmor=1"
        CMDLINE_CHANGED=1
    else
        info "apparmor=1 already present"
    fi

    # security=apparmor
    # NOTE: 'security=' was deprecated in kernel 5.1+ in favour of 'lsm='.
    # It is kept here for compatibility with older kernels; on modern kernels
    # it is a no-op when 'lsm=' includes apparmor.
    if ! grep -qw 'security=apparmor' "$CMDLINE_FILE"; then
        sed -i 's/[[:space:]]*$//' "$CMDLINE_FILE"
        echo -n ' security=apparmor' >> "$CMDLINE_FILE"
        info "Added security=apparmor (legacy compat — harmless on kernels >= 5.1)"
        CMDLINE_CHANGED=1
    else
        info "security=apparmor already present"
    fi

    # lsm= — surgical: append apparmor to existing list, or add full parameter
    if grep -q 'lsm=' "$CMDLINE_FILE"; then
        # Extract only the lsm= value (not the whole line) to avoid false positives
        # from other params like apparmor=1 or security=apparmor on the same line.
        current_lsm=$(grep -oP '(?<=lsm=)\S+' "$CMDLINE_FILE" | head -1)
        if echo "$current_lsm" | tr ',' '\n' | grep -q '^apparmor$'; then
            info "apparmor already present in lsm= list"
        else
            # Append ,apparmor to the existing lsm= value in-place
            sed -i 's/\(lsm=[^ ]*\)/\1,apparmor/' "$CMDLINE_FILE"
            info "Appended apparmor to existing lsm= list"
            CMDLINE_CHANGED=1
        fi
    else
        sed -i 's/[[:space:]]*$//' "$CMDLINE_FILE"
        echo -n ' lsm=landlock,lockdown,yama,integrity,apparmor,bpf' >> "$CMDLINE_FILE"
        info "Added full lsm= parameter"
        CMDLINE_CHANGED=1
    fi

    if [[ $CMDLINE_CHANGED -eq 1 ]]; then
        info "Rebuilding UKI with updated cmdline..."
        mkinitcpio -P || { error "UKI rebuild failed. Check output above."; exit 1; }
        info "UKI rebuilt successfully."
    else
        info "Kernel parameters already up to date — skipping UKI rebuild."
    fi
fi

# ─── Step 3: Enable and start AppArmor service ───────────────────────────────
info "Step 3: Enabling AppArmor service..."
systemctl enable --now apparmor.service

# Detect whether AppArmor is actually active in the *running* kernel.
# It won't be until the new cmdline (apparmor=1, lsm=...) is booted.
if [[ "$(cat /sys/module/apparmor/parameters/enabled 2>/dev/null)" == "Y" ]]; then
    info "AppArmor is active in the running kernel."
else
    warn "AppArmor is NOT active in the current kernel."
    warn "The kernel parameters embedded in the UKI take effect only after reboot."
    warn "Profile operations below will be staged but won't enforce until then."
fi

# ─── Step 4: Enforce (or complain) all loaded profiles ───────────────────────
if [[ $COMPLAIN_MODE -eq 1 ]]; then
    warn "Step 4: Setting all profiles to COMPLAIN mode (--complain flag active)..."
    find /etc/apparmor.d/ -maxdepth 1 -type f -exec aa-complain {} + 2>/dev/null || true
    warn "Profiles are in complain mode — denials are logged but NOT blocked."
    warn "After auditing: sudo /etc/arch-scripts/apparmor-setup/enforce-all.sh"
else
    warn "Step 4: Enforcing all profiles..."
    warn "TIP: Pass --complain to this script to audit first before blocking."
    find /etc/apparmor.d/ -maxdepth 1 -type f -exec aa-enforce {} + 2>/dev/null || true
fi

# Reload profiles (best-effort; AppArmor may not be live yet pre-reboot)
if ! systemctl reload apparmor.service 2>/dev/null; then
    if ! apparmor_parser -r /etc/apparmor.d/ 2>/dev/null; then
        warn "Profile reload skipped — AppArmor not yet active (reboot required)"
    fi
fi

# ─── Step 5: Enable audit logging ────────────────────────────────────────────
info "Step 5: Configuring audit logging..."
systemctl enable --now auditd.service

mkdir -p /etc/audit/rules.d
cat > /etc/audit/rules.d/apparmor.rules <<'EOF'
-w /etc/apparmor/ -p wa -k apparmor
-w /etc/apparmor.d/ -p wa -k apparmor
EOF

augenrules --load 2>/dev/null || true
info "Audit rules written to /etc/audit/rules.d/apparmor.rules"

# ─── Step 6: Preserve local overrides ────────────────────────────────────────
info "Step 6: Reloading local overrides..."

if [[ -d /etc/apparmor.d/local ]] && compgen -G "/etc/apparmor.d/local/*" >/dev/null 2>&1; then
    for f in /etc/apparmor.d/local/*; do
        [[ -f "$f" ]] || continue
        profile=$(basename "$f")
        # apparmor.d convention: the override filename matches the main profile
        # in /etc/apparmor.d/ (e.g. local/system_systemd-sleep →
        # /etc/apparmor.d/system_systemd-sleep).
        if [[ -f "/etc/apparmor.d/${profile}" ]]; then
            apparmor_parser -r "/etc/apparmor.d/${profile}" 2>/dev/null || true
            info "Reloaded profile with local override: ${profile}"
        else
            warn "Main profile not found for local override: ${profile} — skipping"
        fi
    done
else
    info "No local overrides found in /etc/apparmor.d/local/"
fi

# ─── Step 7: Summary ─────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║    AppArmor + apparmor.d setup complete.             ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${YELLOW}REBOOT REQUIRED${NC}: The kernel parameters (apparmor=1 security=apparmor"
echo "lsm=...) are embedded in the UKI and take effect only after reboot."
echo ""
echo "After reboot, verify with:"
echo "  aa-status                                        # loaded + enforced profiles"
echo "  cat /sys/module/apparmor/parameters/enabled      # should print Y"
echo "  journalctl -b | grep apparmor                    # startup messages"
echo "  journalctl -b -g 'apparmor.*DENIED'              # check for denials"
echo "  audit2allow -la                                  # suggest allow rules"
echo ""
echo "If an application breaks:"
echo "  aa-complain /etc/apparmor.d/<profile>            # switch to complain mode"
echo "  # or add overrides in /etc/apparmor.d/local/<profile>"
echo "  apparmor_parser -r /etc/apparmor.d/<profile>     # reload"
