#!/usr/bin/env bash
# install.sh — Deploy UKI + Secure Boot setup to the system
# Usage: sudo ./install.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
for pkg in systemd-ukify sbsigntools mokutil openssl; do
    if ! pacman -Qi "${pkg}" >/dev/null 2>&1; then
        missing+=("${pkg}")
    fi
done

if [[ ${#missing[@]} -gt 0 ]]; then
    log "Installing missing packages: ${missing[*]}"
    pacman -S --needed --noconfirm "${missing[@]}"
fi

# ─── Deploy scripts ─────────────────────────────────────────────────────────
log "Deploying scripts to /etc/uki-secureboot/..."
mkdir -p /etc/uki-secureboot/keys

cp "${SCRIPT_DIR}/generate-mok.sh"    /etc/uki-secureboot/
cp "${SCRIPT_DIR}/uki-build.sh"       /etc/uki-secureboot/
cp "${SCRIPT_DIR}/uki-remove.sh"      /etc/uki-secureboot/
cp "${SCRIPT_DIR}/sign-bootloader.sh" /etc/uki-secureboot/

chmod 700 /etc/uki-secureboot/*.sh
chmod 700 /etc/uki-secureboot/keys

# ─── Kernel command line ─────────────────────────────────────────────────────
if [[ ! -f /etc/uki-secureboot/cmdline ]]; then
    # Strip bootloader-specific tokens that must not be embedded in a UKI:
    #   BOOT_IMAGE=  — set by the bootloader, meaningless inside UKI
    #   initrd=      — the initramfs is embedded; an extra initrd= causes conflicts
    raw_cmdline="$(cat /proc/cmdline)"
    clean_cmdline="$(echo "${raw_cmdline}" \
        | sed 's/BOOT_IMAGE=[^ ]*[[:space:]]*//g' \
        | sed 's/initrd=[^ ]*[[:space:]]*//g' \
        | sed 's/[[:space:]]*$//')"
    log "Writing cmdline: ${clean_cmdline}"
    echo "${clean_cmdline}" > /etc/uki-secureboot/cmdline
    warn "Review /etc/uki-secureboot/cmdline and adjust if needed!"
else
    log "Kernel cmdline already exists, not overwriting."
fi

# ─── Deploy pacman hooks ────────────────────────────────────────────────────
log "Installing pacman hooks..."
mkdir -p /etc/pacman.d/hooks

cp "${SCRIPT_DIR}/99-uki-build.hook"       /etc/pacman.d/hooks/
cp "${SCRIPT_DIR}/99-uki-remove.hook"      /etc/pacman.d/hooks/
cp "${SCRIPT_DIR}/99-sign-bootloader.hook" /etc/pacman.d/hooks/

# ─── Disable mkinitcpio's default UKI/copying hooks if present ──────────────
# CachyOS may ship hooks that copy vmlinuz/initramfs to ESP — we handle that now
if [[ -f /etc/pacman.d/hooks/90-mkinitcpio-install.hook ]]; then
    warn "Found existing mkinitcpio install hook — you may want to review"
    warn "  /etc/pacman.d/hooks/90-mkinitcpio-install.hook"
    warn "to avoid duplicate ESP entries."
fi

# ─── Detect ESP and create UKI output dir ───────────────────────────────────
esp_mount=""
for candidate in /efi /boot/efi /boot; do
    if mountpoint -q "${candidate}" 2>/dev/null; then
        esp_mount="${candidate}"
        break
    fi
done

if [[ -z "${esp_mount}" ]]; then
    warn "Could not auto-detect ESP mount point — scripts will detect it at runtime."
else
    log "Detected ESP at: ${esp_mount}"
    mkdir -p "${esp_mount}/EFI/Linux"
fi

# ─── Summary ────────────────────────────────────────────────────────────────
echo ""
log "Installation complete!"
echo ""
echo "Next steps:"
echo "  1. Review /etc/uki-secureboot/cmdline (auto-detected from current boot)"
echo "  2. Generate MOK keys:"
echo "       sudo /etc/uki-secureboot/generate-mok.sh"
echo "  3. Enroll MOK in firmware:"
echo "       sudo mokutil --import /etc/uki-secureboot/keys/MOK.cer"
echo "       (reboot and confirm in MOK Manager)"
echo "  4. Build initial UKIs:"
echo "       sudo /etc/uki-secureboot/uki-build.sh"
echo "  5. Sign systemd-boot bootloader:"
echo "       sudo /etc/uki-secureboot/sign-bootloader.sh"
echo "  6. Test boot with the UKI entry in systemd-boot"
echo "  7. Once confirmed working, enable Secure Boot in UEFI settings"
echo ""
warn "IMPORTANT: Keep a USB recovery drive ready before enabling Secure Boot!"
