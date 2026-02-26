#!/usr/bin/env bash
# generate-mok.sh — Generate Machine Owner Key pair for Secure Boot signing
# Run once: sudo /etc/uki-secureboot/generate-mok.sh

set -euo pipefail

KEY_DIR="/etc/uki-secureboot/keys"
CN="CachyOS Secure Boot MOK"
DAYS=3650  # 10 years

if [[ $EUID -ne 0 ]]; then
    echo "Error: Must run as root." >&2
    exit 1
fi

if [[ -f "${KEY_DIR}/MOK.key" ]]; then
    echo "MOK key already exists at ${KEY_DIR}/MOK.key"
    echo "Delete it manually if you want to regenerate."
    exit 1
fi

command -v openssl >/dev/null 2>&1 || { echo "Error: openssl not found. Install openssl." >&2; exit 1; }

mkdir -p "${KEY_DIR}"
chmod 700 "${KEY_DIR}"

# Clean up partial output files if interrupted mid-generation
trap 'rm -f "${KEY_DIR}/MOK.key" "${KEY_DIR}/MOK.pem" "${KEY_DIR}/MOK.cer"' INT TERM EXIT

echo "Generating MOK key pair..."

# Generate private key + PEM certificate
openssl req -new -x509 \
    -newkey rsa:2048 \
    -keyout "${KEY_DIR}/MOK.key" \
    -out "${KEY_DIR}/MOK.pem" \
    -nodes \
    -days "${DAYS}" \
    -subj "/CN=${CN}/" \
    -addext "extendedKeyUsage=codeSigning" \
    -addext "keyUsage=digitalSignature"

# Convert PEM to DER for mokutil enrollment
openssl x509 -in "${KEY_DIR}/MOK.pem" -outform DER -out "${KEY_DIR}/MOK.cer"

trap - INT TERM EXIT

# Lock down permissions
chmod 600 "${KEY_DIR}/MOK.key"
chmod 644 "${KEY_DIR}/MOK.pem" "${KEY_DIR}/MOK.cer"

echo ""
echo "Keys generated:"
echo "  Private key : ${KEY_DIR}/MOK.key"
echo "  Certificate : ${KEY_DIR}/MOK.pem (PEM) / ${KEY_DIR}/MOK.cer (DER)"
echo ""
echo "Next step — enroll MOK.cer in your UEFI firmware's Signature Database (db):"
echo ""
echo "  Option A — BIOS UI (recommended):"
echo "    Copy ${KEY_DIR}/MOK.cer to a FAT32 USB drive, then in UEFI settings:"
echo "    Secure Boot → Key Management → Append Certificate (or 'db Management')"
echo ""
echo "  Option B — efi-updatevar (requires Setup Mode):"
echo "    1. In BIOS: reset/clear Secure Boot keys (enters Setup Mode)"
echo "    2. Run:  efi-updatevar -a -c ${KEY_DIR}/MOK.cer db"
echo "    3. In BIOS: restore factory keys, re-enable Secure Boot"
echo ""
echo "  WARNING: Do NOT use 'mokutil --import' — that only works with shim."
echo "  This setup uses systemd-boot directly; the firmware checks UEFI db, not MokList."
echo ""
echo "  Verify after enrollment:  efi-readvar -v db"
