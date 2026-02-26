#!/usr/bin/env bash
# sign-bootloader.sh — Sign systemd-boot EFI binaries with MOK for Secure Boot
# Run manually: sudo /etc/uki-secureboot/sign-bootloader.sh
# Also triggered by pacman hook on systemd upgrades

set -euo pipefail

log()  { echo "[sign-bootloader] $*"; }
warn() { echo "[sign-bootloader] WARNING: $*" >&2; }
die()  { echo "[sign-bootloader] ERROR: $*" >&2; exit 1; }

# Auto-detect ESP mount point (override by setting ESP= in environment)
if [[ -z "${ESP:-}" ]]; then
    for _esp in /efi /boot/efi /boot; do
        if mountpoint -q "${_esp}" 2>/dev/null; then
            ESP="${_esp}"
            break
        fi
    done
fi
[[ -n "${ESP:-}" ]] || die "Cannot detect ESP mount point. Run: ESP=/your/esp $0"

KEY_DIR="/etc/uki-secureboot/keys"

[[ $EUID -eq 0 ]] || die "Must run as root."
command -v sbsign   >/dev/null 2>&1 || die "sbsign not found. Install sbsigntools."
command -v sbverify >/dev/null 2>&1 || die "sbverify not found. Install sbsigntools."
[[ -f "${KEY_DIR}/MOK.key" ]] || die "MOK key not found. Run generate-mok.sh first."
[[ -f "${KEY_DIR}/MOK.pem" ]] || die "MOK certificate not found."

found=0
signed=0
for efi_file in \
    "${ESP}/EFI/systemd/systemd-bootx64.efi" \
    "${ESP}/EFI/BOOT/BOOTX64.EFI"; do

    [[ -f "${efi_file}" ]] || { warn "${efi_file} not found, skipping."; continue; }
    found=$((found + 1))

    # Skip if already correctly signed with our certificate
    if sbverify --cert "${KEY_DIR}/MOK.pem" "${efi_file}" >/dev/null 2>&1; then
        log "Already signed, skipping: ${efi_file}"
        signed=$((signed + 1))
        continue
    fi

    log "Signing: ${efi_file}"

    # Sign to a temp file on the same filesystem for atomic replacement
    tmp="$(mktemp "${efi_file}.XXXXXX")"
    trap 'rm -f "${tmp}"' EXIT

    sbsign \
        --key "${KEY_DIR}/MOK.key" \
        --cert "${KEY_DIR}/MOK.pem" \
        --output "${tmp}" \
        "${efi_file}" || { warn "sbsign failed for ${efi_file}"; rm -f "${tmp}"; trap - EXIT; continue; }

    # Verify before replacing the live bootloader binary
    if ! sbverify --cert "${KEY_DIR}/MOK.pem" "${tmp}" >/dev/null 2>&1; then
        warn "Verification FAILED — not replacing ${efi_file}"
        rm -f "${tmp}"
        trap - EXIT
        continue
    fi

    cp "${efi_file}" "${efi_file}.old"
    mv "${tmp}" "${efi_file}"
    trap - EXIT
    log "Signed and verified: ${efi_file}"
    signed=$((signed + 1))
done

if [[ ${found} -eq 0 ]]; then
    warn "No systemd-boot EFI files found on ESP — is systemd-boot installed?"
    exit 0
fi

if [[ ${signed} -lt ${found} ]]; then
    warn "Signing failed for $((found - signed)) of ${found} file(s)."
    exit 1
fi

log "Done. ${signed}/${found} bootloader file(s) signed/verified."
log "If Secure Boot rejects a binary, ensure MOK.cer is in UEFI db: efi-readvar -v db"
