# UKI + Secure Boot Setup for CachyOS (systemd-boot)

## Overview

This setup creates **Unified Kernel Images (UKI)** using `ukify`, signs them with
your **Machine Owner Key (MOK)**, and automates everything via **pacman hooks** so
that kernel/initramfs updates are handled automatically.

## Directory Structure

```
/etc/uki-secureboot/
├── keys/
│   ├── MOK.key          # Private key (keep safe!)
│   ├── MOK.cer          # DER certificate (for enrollment)
│   └── MOK.pem          # PEM certificate (for signing)
├── cmdline              # Kernel command line
├── uki-build.sh         # Main build + sign script
├── uki-remove.sh        # Cleanup script for removed kernels
├── sign-bootloader.sh   # Sign systemd-boot EFI binaries
└── generate-mok.sh      # One-time MOK key generation
```

## Setup Steps

### 1. Run the Installer (Recommended)

The easiest way to set everything up:

```bash
sudo ./install.sh
```

This installs dependencies, deploys scripts, installs pacman hooks, and
auto-populates `/etc/uki-secureboot/cmdline` from your current boot
(stripping bootloader-specific tokens like `BOOT_IMAGE=` and `initrd=`
that must not be embedded in a UKI).

Then skip to [Step 2](#2-generate-mok-keys).

---

### Manual Install (Alternative)

#### 1a. Install Dependencies

```bash
sudo pacman -S systemd-ukify sbsigntools mokutil openssl
```

#### 1b. Copy Files

```bash
sudo mkdir -p /etc/uki-secureboot/keys
sudo chmod 700 /etc/uki-secureboot/keys
sudo cp uki-build.sh uki-remove.sh generate-mok.sh /etc/uki-secureboot/
sudo chmod 700 /etc/uki-secureboot/*.sh

# Install pacman hooks
sudo mkdir -p /etc/pacman.d/hooks
sudo cp 99-uki-build.hook /etc/pacman.d/hooks/
sudo cp 99-uki-remove.hook /etc/pacman.d/hooks/
```

#### 1c. Configure Kernel Command Line

```bash
# Auto-populate from current boot, stripping bootloader-specific tokens:
cat /proc/cmdline \
  | sed 's/BOOT_IMAGE=[^ ]*[[:space:]]*//g' \
  | sed 's/initrd=[^ ]*[[:space:]]*//g' \
  | sed 's/[[:space:]]*$//' \
  | sudo tee /etc/uki-secureboot/cmdline
```

Review and edit `/etc/uki-secureboot/cmdline` to confirm it looks correct:

```
root=UUID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx rw quiet splash loglevel=3
```

Find your root UUID with: `blkid | grep ' / '`.

### 2. Generate MOK Keys

```bash
sudo /etc/uki-secureboot/generate-mok.sh
```

### 3. Enroll MOK Certificate in UEFI Firmware

> **Critical**: `mokutil --import` only works if **shim** is your bootloader.
> This setup uses **systemd-boot directly** — shim is not in the chain.
> The firmware validates EFI binaries against its own **Signature Database (`db`)**,
> not against MokList. You must enroll `MOK.cer` into the UEFI `db`.

#### Method 1: BIOS UI (Recommended)

1. Copy `/etc/uki-secureboot/keys/MOK.cer` to a FAT32 USB drive
2. Enter UEFI firmware settings
3. Navigate to **Secure Boot → Key Management** (may be under "Advanced")
4. Look for one of: **"Append Certificate"**, **"db Management"**,
   **"Enroll Certificate"**, or **"Authorized Signatures (db)"**
   - MSI boards: Secure Boot → Key Management → works in User Mode (no Setup Mode needed)
   - ASUS boards: Secure Boot → Key Management → Authorized Signatures (db)
5. Select `MOK.cer` and confirm

#### Method 2: Setup Mode + efi-updatevar (Fallback)

If your BIOS has no certificate append option:

```bash
# 1. In BIOS: reset/clear Secure Boot keys — this enters Setup Mode (PK is cleared)
# 2. Boot Linux:
efi-updatevar -a -c /etc/uki-secureboot/keys/MOK.cer db
# 3. In BIOS: restore factory Secure Boot keys (re-adds MS/OEM certs)
#    The -a flag appended your cert, so it survives the restore
# 4. Re-enable Secure Boot
```

#### Verify enrollment

```bash
efi-readvar -v db   # Your cert appears as a new X509 entry at the end
```

> **Note**: `mokutil --list-enrolled` shows **MokList** (shim's database), not UEFI `db`.
> If you enrolled via the methods above, `mokutil --list-enrolled` will be empty — that is normal.

### 4. Build Initial UKI

```bash
sudo /etc/uki-secureboot/uki-build.sh
```

### 5. Sign systemd-boot

systemd-boot itself must also be signed — it is the first EFI binary the
firmware loads, so Secure Boot will reject it if unsigned.

```bash
sudo /etc/uki-secureboot/sign-bootloader.sh
```

A pacman hook (`99-sign-bootloader.hook`) re-signs it automatically whenever
the `systemd` package is upgraded.

### 6. Enable Secure Boot

After confirming the UKI boots correctly, enable Secure Boot in your UEFI
firmware settings.

### 7. Verify

```bash
# Check Secure Boot status
mokutil --sb-state

# Check that your MOK cert is in UEFI db (not MokList)
efi-readvar -v db   # look for your CN= entry near the bottom

# Check UKI signature
sbverify --cert /etc/uki-secureboot/keys/MOK.pem <ESP>/EFI/Linux/*.efi

# Check bootloader signature
sbverify --cert /etc/uki-secureboot/keys/MOK.pem <ESP>/EFI/systemd/systemd-bootx64.efi
```

## How It Works

- **On kernel install/update**: The `99-uki-build.hook` triggers `uki-build.sh`,
  which builds a UKI for each installed kernel and signs it with your MOK.
- **On kernel removal**: The `99-uki-remove.hook` triggers `uki-remove.sh`,
  which cleans up orphaned UKI files.
- **On systemd upgrade**: The `99-sign-bootloader.hook` triggers `sign-bootloader.sh`,
  which re-signs the updated systemd-boot binaries on the ESP.
- systemd-boot auto-discovers UKI files in `<ESP>/EFI/Linux/` (Type #2 entries).

## Troubleshooting

### Firmware rejects signed EFI binary ("signature not in db" / "Security Violation")

This is the most common issue. The cause is almost always that `MOK.cer` is
in **MokList** (shim's variable) instead of the UEFI **Signature Database (`db`)**.

These are completely different things:

| | MokList | UEFI db |
|---|---|---|
| Managed by | `mokutil` / MokManager (shim) | UEFI firmware / `efi-updatevar` |
| Checked by | shim (if in boot chain) | UEFI firmware directly |
| Used by this setup | **No** (no shim) | **Yes** |

**Diagnose:**
```bash
# If your cert appears here but NOT in efi-readvar, that's the problem:
mokutil --list-enrolled

# Your cert must appear here as an X509 entry:
efi-readvar -v db
```

**Fix:** Follow [Step 3](#3-enroll-mok-certificate-in-uefi-firmware) — enroll via
BIOS UI or Setup Mode + `efi-updatevar`.

---

### "Enroll EFI image" worked once but broke after an update

Your firmware enrolled the **SHA-256 hash** of a specific binary — not the signing
certificate. Every update produces a new binary with a new hash, invalidating the
old enrollment. This is not sustainable.

Fix: Enroll `MOK.cer` as a certificate (see Step 3). Certificate-based trust
covers all binaries signed with that key, regardless of their hash.

---

### systemd-boot binary rejected but UKI accepted (or vice versa)

Both must be signed and the signing certificate must be in UEFI `db`. Verify both:
```bash
sbverify --cert /etc/uki-secureboot/keys/MOK.pem <ESP>/EFI/systemd/systemd-bootx64.efi
sbverify --cert /etc/uki-secureboot/keys/MOK.pem <ESP>/EFI/Linux/*.efi
```

If either fails, re-run the relevant signing script:
```bash
sudo /etc/uki-secureboot/sign-bootloader.sh
sudo /etc/uki-secureboot/uki-build.sh
```

---

### Boot fails after enabling Secure Boot

Disable Secure Boot in BIOS, boot normally, then diagnose with `sbverify` above.

---

### MOK.cer vs MOK.pem — what's the difference?

- `MOK.pem` — PEM format, used by `sbsign`/`sbverify` for signing and verification
- `MOK.cer` — DER format (binary), used for enrolling into UEFI firmware

They are the same certificate in different encodings. Convert with:
```bash
# PEM → DER
openssl x509 -in MOK.pem -outform DER -out MOK.cer
# DER → PEM
openssl x509 -inform DER -in MOK.cer -out MOK.pem
```

---

### initramfs not found

Ensure mkinitcpio runs before ukify. The hook ordering handles this automatically.
