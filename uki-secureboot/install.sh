#!/usr/bin/env bash
# install.sh — Configure UKI Secure Boot with mkinitcpio-native UKI generation
# Usage: sudo ./install.sh
#
# What this does:
#   1. Installs dependencies (systemd-ukify, sbctl)
#   2. Verifies required system hooks exist
#   3. Migrates/creates kernel cmdline at /etc/kernel/cmdline
#   4. Creates /etc/kernel/uki.conf
#   5. Enables UKI generation in mkinitcpio presets (keeps initramfs active)
#   6. Masks systemd-boot-update.service
#   7. Rebuilds initramfs+UKI via mkinitcpio
#   8. Registers UKI paths with sbctl for automatic re-signing

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_NAME="$(basename "$(cd "${SCRIPT_DIR}/.." && pwd)")"
MODULE_NAME="$(basename "${SCRIPT_DIR}")"
INSTALL_DIR="/etc/${REPO_NAME}/${MODULE_NAME}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[install]${NC} $*"; }
warn() { echo -e "${YELLOW}[install]${NC} $*"; }
die()  { echo -e "${RED}[install] ERROR:${NC} $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Must run as root: sudo ./install.sh"

# ─── Check dependencies ─────────────────────────────────────────────────────
log "Checking dependencies..."
missing=()
for pkg in systemd-ukify sbctl; do
    if ! pacman -Qi "${pkg}" >/dev/null 2>&1; then
        missing+=("${pkg}")
    fi
done

if [[ ${#missing[@]} -gt 0 ]]; then
    log "Installing missing packages: ${missing[*]}"
    pacman -S --needed --noconfirm "${missing[@]}"
fi

# ─── Verify required system hooks are present ───────────────────────────────
log "Checking required system hooks..."
required_hooks=(
    /usr/share/libalpm/hooks/sdboot-systemd-update.hook
    /usr/share/libalpm/hooks/zz-sbctl.hook
)
missing_hooks=()
for hook in "${required_hooks[@]}"; do
    [[ -f "${hook}" ]] || missing_hooks+=("${hook}")
done
if [[ ${#missing_hooks[@]} -gt 0 ]]; then
    die "Required system hooks not found — install the packages that provide them:
$(printf '  %s\n' "${missing_hooks[@]}")
  sdboot-systemd-update.hook → sdboot-manage
  zz-sbctl.hook              → sbctl"
fi
log "Required hooks present."

# ─── Kernel command line ─────────────────────────────────────────────────────
# Check for cmdline in old install locations
OLD_CMDLINE=""
for old_path in "${INSTALL_DIR}/cmdline" "/etc/uki-secureboot/cmdline"; do
    if [[ -f "${old_path}" ]]; then
        OLD_CMDLINE="${old_path}"
        break
    fi
done

if [[ ! -f /etc/kernel/cmdline ]]; then
    mkdir -p /etc/kernel
    if [[ -n "${OLD_CMDLINE}" ]]; then
        log "Migrating cmdline from ${OLD_CMDLINE} → /etc/kernel/cmdline"
        cp "${OLD_CMDLINE}" /etc/kernel/cmdline
    else
        raw_cmdline="$(cat /proc/cmdline)"
        clean_cmdline="$(echo "${raw_cmdline}" \
            | sed 's/BOOT_IMAGE=[^ ]*[[:space:]]*//g' \
            | sed 's/initrd=[^ ]*[[:space:]]*//g' \
            | sed 's/[[:space:]]*$//')"
        log "Writing cmdline: ${clean_cmdline}"
        echo "${clean_cmdline}" > /etc/kernel/cmdline
    fi
    warn "Review /etc/kernel/cmdline and adjust if needed!"
else
    log "Kernel cmdline already exists at /etc/kernel/cmdline."
fi

# ─── UKI configuration ──────────────────────────────────────────────────────
if [[ ! -f /etc/kernel/uki.conf ]]; then
    log "Creating /etc/kernel/uki.conf"
    cat > /etc/kernel/uki.conf << 'EOF'
[UKI]
Cmdline=@/etc/kernel/cmdline
OSRelease=@/etc/os-release
EOF
else
    log "/etc/kernel/uki.conf already exists."
fi

# ─── Detect ESP ──────────────────────────────────────────────────────────────
esp_mount=""
for candidate in /efi /boot/efi /boot; do
    if mountpoint -q "${candidate}" 2>/dev/null; then
        esp_mount="${candidate}"
        break
    fi
done

if [[ -z "${esp_mount}" ]]; then
    die "Could not auto-detect ESP mount point. Mount your ESP and try again."
fi
log "Detected ESP at: ${esp_mount}"
mkdir -p "${esp_mount}/EFI/Linux"

# ─── Enable UKI generation in mkinitcpio presets ─────────────────────────────
log "Configuring mkinitcpio presets for UKI generation..."
for preset in /etc/mkinitcpio.d/*.preset; do
    [[ -f "${preset}" ]] || continue
    preset_name="$(basename "${preset}" .preset)"

    # Check if default_uki is already uncommented/active
    if grep -qE '^\s*default_uki=' "${preset}"; then
        log "  ${preset_name}: default_uki already active."
        continue
    fi

    # Uncomment default_uki if it exists as a comment
    if grep -qE '^\s*#\s*default_uki=' "${preset}"; then
        sed -i 's/^\s*#\s*\(default_uki=.*\)/\1/' "${preset}"
        log "  ${preset_name}: enabled default_uki."
    else
        # Add default_uki line — derive path from preset name
        echo "default_uki=\"${esp_mount}/EFI/Linux/arch-${preset_name}.efi\"" >> "${preset}"
        log "  ${preset_name}: added default_uki."
    fi

    # Ensure default_image is still active (snapper-boot needs initramfs)
    if ! grep -qE '^\s*default_image=' "${preset}"; then
        if grep -qE '^\s*#\s*default_image=' "${preset}"; then
            sed -i 's/^\s*#\s*\(default_image=.*\)/\1/' "${preset}"
            log "  ${preset_name}: re-enabled default_image (needed by snapper-boot)."
        fi
    fi
done

# ─── Mask systemd-boot-update.service ────────────────────────────────────────
log "Masking systemd-boot-update.service..."
systemctl mask systemd-boot-update.service 2>/dev/null || true

# ─── Remove old custom hooks if present ──────────────────────────────────────
for old_hook in /etc/pacman.d/hooks/99-uki-build.hook /etc/pacman.d/hooks/99-uki-remove.hook; do
    if [[ -f "${old_hook}" ]]; then
        rm -f "${old_hook}"
        log "Removed old hook: ${old_hook}"
    fi
done

# ─── Rebuild UKIs via mkinitcpio ─────────────────────────────────────────────
log "Rebuilding initramfs and UKIs via mkinitcpio..."
for preset in /etc/mkinitcpio.d/*.preset; do
    [[ -f "${preset}" ]] || continue
    preset_name="$(basename "${preset}" .preset)"
    log "  Building: ${preset_name}"
    if ! mkinitcpio -p "${preset_name}"; then
        die "mkinitcpio failed for preset ${preset_name}. Check output above."
    fi
done

# ─── Register UKI paths with sbctl ──────────────────────────────────────────
log "Registering UKI paths with sbctl for automatic re-signing..."
if [[ -n "${esp_mount}" ]]; then
    for uki in "${esp_mount}"/EFI/Linux/*.efi; do
        [[ -f "${uki}" ]] || continue
        # Skip snapshot UKIs (managed by snapper-boot)
        [[ "$(basename "${uki}")" == snapshot-* ]] && continue
        log "  Signing and registering: ${uki}"
        sbctl sign -s "${uki}"
    done
fi

# ─── Deploy install dir (for future reference) ──────────────────────────────
mkdir -p "${INSTALL_DIR}"

# ─── Summary ────────────────────────────────────────────────────────────────
echo ""
log "Installation complete!"
echo ""
echo "What was configured:"
echo "  - /etc/kernel/cmdline          — kernel command line"
echo "  - /etc/kernel/uki.conf         — UKI build configuration"
echo "  - mkinitcpio presets           — UKI generation enabled"
echo "  - systemd-boot-update.service  — masked"
echo "  - sbctl                        — UKI paths registered for auto re-signing"
echo ""
echo "UKIs are now built by mkinitcpio on kernel updates."
echo "Signing is handled by zz-sbctl.hook automatically."
echo ""
echo "Verify: sudo sbctl verify"
echo ""
