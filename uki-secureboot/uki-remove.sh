#!/usr/bin/env bash
# uki-remove.sh — Remove orphaned UKI files for uninstalled kernels
# Triggered by pacman hook or run manually: sudo /etc/uki-secureboot/uki-remove.sh

set -euo pipefail

# Auto-detect ESP mount point (override by setting ESP= in environment)
if [[ -z "${ESP:-}" ]]; then
    for _esp in /efi /boot/efi /boot; do
        if mountpoint -q "${_esp}" 2>/dev/null; then
            ESP="${_esp}"
            break
        fi
    done
fi
[[ -n "${ESP:-}" ]] || { echo "[uki-remove] ERROR: Cannot detect ESP mount point." >&2; exit 1; }
UKI_DIR="${ESP}/EFI/Linux"
MODULES_DIR="/usr/lib/modules"

log()  { echo "[uki-remove] $*"; }
warn() { echo "[uki-remove] WARNING: $*" >&2; }

[[ $EUID -eq 0 ]] || { echo "Error: Must run as root." >&2; exit 1; }
[[ -d "${UKI_DIR}" ]] || exit 0

# Collect currently installed kernel versions
declare -A installed_kvers
for kdir in "${MODULES_DIR}"/*/; do
    [[ -d "${kdir}" ]] || continue
    kver="$(basename "${kdir}")"
    installed_kvers["${kver}"]=1
done

# Safety check: refuse to run if no kernels found — avoids wiping all UKIs
# on a broken or transitional system state
if [[ ${#installed_kvers[@]} -eq 0 ]]; then
    warn "No kernels found in ${MODULES_DIR} — refusing to remove any UKIs."
    exit 0
fi

# Check each UKI file
removed=0
for uki in "${UKI_DIR}"/*.efi; do
    [[ -f "${uki}" ]] || continue
    filename="$(basename "${uki}" .efi)"

    # Skip snapshot rollback UKIs (managed by snapper-boot)
    [[ "${filename}" == snapshot-* ]] && continue

    # Match against the exact expected filename using the same naming logic as uki-build.sh
    # (pkgbase-kver or linux-kver) — avoids false positives from substring matches
    # when one kver is a substring of another (e.g. 6.19.3-2-cachyos inside
    # linux-cachyos-lts-6.19.3-2-cachyos-lts)
    found=0
    for kver in "${!installed_kvers[@]}"; do
        if [[ -f "${MODULES_DIR}/${kver}/pkgbase" ]]; then
            pkgbase="$(< "${MODULES_DIR}/${kver}/pkgbase")"
            expected="${pkgbase}-${kver}"
        else
            expected="linux-${kver}"
        fi
        if [[ "${filename}" == "${expected}" ]]; then
            found=1
            break
        fi
    done

    if [[ ${found} -eq 0 ]]; then
        log "Removing orphaned UKI: ${uki}"
        rm -f "${uki}"
        removed=$((removed + 1))
    fi
done

if [[ ${removed} -gt 0 ]]; then
    log "Removed ${removed} orphaned UKI(s)."
else
    log "No orphaned UKIs found."
fi
