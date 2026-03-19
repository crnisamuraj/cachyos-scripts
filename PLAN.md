# arch-scripts Implementation Plan

## Project Goal

`arch-scripts` is a modular collection of Arch Linux setup scripts.

- Every **folder is a module**
- Modules implement optional scripts: `install`, `uninstall`, `setup`, `configure` (named after the action, `.sh` extension optional)
- A **root-level `install.sh`** discovers all modules and runs their `install` script if present
- Modules are part of the same package, new scripts/modules could be added by maintainer or user by making new folder in source (mintainer before pacakge) or install location (user custom modules)
- Designed to eventually be packaged for AUR (single-package containing all modules, easy module addon by maintainer(source module) or user(custom module in install target))

## Overview

Four workstreams:
1. Root-level orchestrator (`install.sh`) + module script convention
2. Restructure install paths for all modules
3. Migrate `uki-secureboot` to mkinitcpio-native UKI generation
4. Fix and migrate `snapper-boot` to sbctl signing

---

## Current State

### What works
- sbctl enrolled, Secure Boot active, existing UKIs signed
- `zz-sbctl.hook` auto-signs on systemd upgrades
- `zz-sign-bootloader.hook` removed (sbctl handles it)
- `systemd-boot-update.service` masked (prevents unsigned overwrites at boot)

### Known issues
- `uki-secureboot` still uses custom `uki-build.sh` + `99-uki-build.hook` instead of mkinitcpio
- `snapper-boot/snapshot-uki.sh` uses old MOK signing (sbsign/sbverify) — needs sbctl
- `snapper-boot/01-snapshot-uki-pre.hook` runs at priority `01`, **before** snap-pac-pre at `05` — snapshot doesn't exist yet when it runs (bug)
- Install paths not namespaced under repo name
- No AUR packaging

---

## Phase 1 — Root Orchestrator + Module Convention

### Root meta-scripts
Four root-level scripts that discover all modules and delegate to the corresponding module script:

| Root script | Calls per module | Purpose |
|---|---|---|
| `install.sh` | `<module>/install.sh` | Deploy all modules to system |
| `remove.sh` | `<module>/remove.sh` | Remove everything installed by all modules |
| `setup.sh` | `<module>/setup.sh` | Interactive first-time configuration for all modules |
| `reconfigure.sh` | `<module>/reconfigure.sh` | Re-run configuration for all modules |

```bash
# Usage:
sudo ./install.sh              # install all modules
sudo ./remove.sh               # remove all modules
sudo ./setup.sh                # interactive setup all modules
sudo ./reconfigure.sh          # reconfigure all modules
```

Behaviour (same for all four):
- Scans each subdirectory for the corresponding script (`install.sh`, `remove.sh`, etc.)
- Runs it if present, skips silently if not (all module scripts are optional)
- Reports success/failure per module
- Does not abort on individual module failure — continues remaining modules

### Module script convention
Each module folder may contain any combination of:
| Script | Purpose |
|---|---|
| `install.sh` | Deploy scripts, hooks, config to system |
| `remove.sh` | Remove everything installed by the module |
| `setup.sh` | Interactive first-time configuration |
| `reconfigure.sh` | Re-configure without full reinstall |

### Tasks
- [x] Write root `install.sh` orchestrator
- [x] Write root `remove.sh` orchestrator
- [x] Write root `setup.sh` orchestrator
- [x] Write root `reconfigure.sh` orchestrator
- [x] Standardise module script names: `install.sh`, `remove.sh` (rename existing `remove-*.sh`)
- [x] Rename `snapper-boot/remove.sh` → confirm naming matches convention

---

## Phase 2 — Install Path Restructure

### New path convention
```
/etc/{REPO_NAME}/{MODULE_NAME}/
```

| Module | Old path | New path |
|---|---|---|
| uki-secureboot | `/etc/uki-secureboot/` | `/etc/arch-scripts/uki-secureboot/` |
| snapper-boot | `/etc/snapper-boot/` | `/etc/arch-scripts/snapper-boot/` |
| zram-hibernate | `/etc/zram-hibernate/` | `/etc/arch-scripts/zram-hibernate/` |

### Dynamic path resolution in install scripts
```bash
REPO_NAME="$(basename "$(cd "${SCRIPT_DIR}/.." && pwd)")"
MODULE_NAME="$(basename "${SCRIPT_DIR}")"
INSTALL_DIR="/etc/${REPO_NAME}/${MODULE_NAME}"
```
Renaming the repo folder automatically updates install paths — required for AUR packaging.

### Paths that stay fixed regardless of REPO_NAME
- Pacman hooks: `/etc/pacman.d/hooks/`
- Kernel cmdline: `/etc/kernel/cmdline` (systemd standard location)

### Tasks
- [x] Update `uki-secureboot/install.sh` — dynamic `INSTALL_DIR`
- [x] Update `snapper-boot/install.sh` — dynamic `INSTALL_DIR`
- [x] Update all hardcoded `/etc/uki-secureboot/` and `/etc/snapper-boot/` references in scripts
- [ ] Add migration notice in install scripts: detect old path, warn user to remove manually

---

## Phase 3 — uki-secureboot: Switch to mkinitcpio UKI Generation

### Why
- mkinitcpio with `default_uki=` is distro-native, zero maintenance
- Fixed UKI path per kernel package — sbctl registers once, `zz-sbctl.hook` re-signs forever
- Removes need for custom hook and build script

### New build chain
```
90-mkinitcpio-install.hook  →  mkinitcpio  →  ukify  →  fixed UKI path
zz-sbctl.hook               →  sbctl sign-all          →  signs it
```

### mkinitcpio preset changes
Uncomment `default_uki=` in each preset. Keep `default_image=` active too — snapper-boot
reads the initramfs directly to build snapshot UKIs:
```ini
# /etc/mkinitcpio.d/linux-cachyos.preset
default_uki="/efi/EFI/Linux/arch-linux-cachyos.efi"
default_image="/boot/initramfs-linux-cachyos.img"   # keep — snapper-boot needs this
```

### /etc/kernel/uki.conf
```ini
[UKI]
Cmdline=@/etc/kernel/cmdline
OSRelease=@/etc/os-release
```
Microcode is handled automatically by mkinitcpio initrd hooks.

### Cmdline migration
Move `/etc/uki-secureboot/cmdline` → `/etc/kernel/cmdline` (systemd standard).
`install.sh` copies existing cmdline if not already present.

### Register fixed UKI paths with sbctl
`install.sh` triggers mkinitcpio rebuild and registers the output paths:
```bash
mkinitcpio -p linux-cachyos
sbctl sign -s /efi/EFI/Linux/arch-linux-cachyos.efi
```

### What gets removed
- `uki-secureboot/uki-build.sh`
- `uki-secureboot/99-uki-build.hook`
- `uki-secureboot/99-uki-remove.hook`

### What remains in uki-secureboot
- `install.sh` — automates: preset editing, uki.conf, cmdline, sbctl registration, service masking
- `cmdline` — shipped as template, installed to `/etc/kernel/cmdline`
- `README.md`

### install.sh safeguards
Before making any changes, verify required system hooks exist:
- `/usr/share/libalpm/hooks/sdboot-systemd-update.hook` (updates bootloader on systemd upgrade)
- `/usr/share/libalpm/hooks/zz-sbctl.hook` (sbctl auto-signing)

### Tasks
- [x] Update mkinitcpio presets (keep `default_image=` active alongside `default_uki=`)
- [x] Create `/etc/kernel/uki.conf`
- [x] Migrate cmdline to `/etc/kernel/cmdline`
- [x] Remove `uki-build.sh`, `99-uki-build.hook`, `99-uki-remove.hook`
- [x] Rewrite `install.sh` — preset editing, uki.conf, cmdline, sbctl registration, service masking, hook existence checks
- [ ] Update `README.md`

---

## Phase 4 — snapper-boot: Fix and Migrate to sbctl

### Bug: hook priority
`01-snapshot-uki-pre.hook` runs before snap-pac-pre (`05`). Snapper hasn't created the
snapshot yet, so the hook references a snapshot that doesn't exist.

**Fix:** rename to `06-snapshot-uki-pre.hook`. Correct pre-transaction order:
```
05-snap-pac-pre.hook      →  snapper creates pre-snapshot N  (old kernel still on disk)
06-snapshot-uki-pre.hook  →  build snapshot UKI for N        (old kernel still on disk)
...pacman transaction runs — kernel may be upgraded/removed...
zz-snap-pac-post.hook     →  snapper creates post-snapshot
zz-sbctl.hook             →  sbctl sign-all (signs snapshot UKIs in database)
```
The snapshot UKI must be built pre-transaction while the old kernel is still on disk.

### Bug: MOK signing
Replace `sbsign`/`sbverify` with `sbctl sign -s`. The `-s` flag registers the UKI in
sbctl's database so `zz-sbctl.hook` can re-sign it automatically in future.

### Cleanup: remove stale sbctl database entries
When pruning old snapshot UKIs, also deregister from sbctl:
```bash
sbctl remove-file "${uki_path}" 2>/dev/null || true
rm -f "${uki_path}"
```

### Cmdline path
Update default from `/etc/uki-secureboot/cmdline` → `/etc/kernel/cmdline`.

### Snapshot boot approach
Boot snapshot as `rw`. No overlayfs needed — the CachyOS btrfs layout already
isolates all noisy writable paths as separate subvolumes (`@log`, `@cache`, `@tmp`,
`@home`). The `@` snapshot only captures `/usr`, `/etc`, `/var/lib`. Fstab in the
snapshot still correctly references other subvolumes by their absolute names.

Snapshot cmdline transformation:
```
rootflags=subvol=@ rw  →  rootflags=subvolid={SUBVOLID} rw
```
Using `subvolid` is more robust than subvolume path for read-only snapshots.
`resume=` and `resume_offset=` are stripped (no hibernation from snapshots).

### Dependency on uki-secureboot
Removed. `snapper-boot` now only needs:
- `/etc/kernel/cmdline` — base cmdline to transform
- `sbctl` — signing
- `systemd-ukify` — UKI assembly
- `snapper`, `snap-pac` — snapshot management

### install.sh safeguards
Before making any changes verify:
- `snap-pac` is installed (provides `05-snap-pac-pre.hook`)
- `sbctl` is installed and enrolled (`sbctl status`)
- `/etc/kernel/cmdline` exists

### Tasks
- [x] Rename `01-snapshot-uki-pre.hook` → `06-snapshot-uki-pre.hook`
- [x] Replace sbsign/sbverify with `sbctl sign -s` in `snapshot-uki.sh`
- [x] Add `sbctl remove-file` to cleanup function
- [x] Update cmdline path → `/etc/kernel/cmdline`
- [x] Rewrite `install.sh` — new path, remove MOK checks, add sbctl/cmdline checks
- [ ] Test: verify snapshot UKI appears in systemd-boot menu after pacman transaction
- [ ] Test: boot snapshot, verify correct kernel version boots correct rootfs

---

## Phase 5 — AUR Packaging (Future)

Single AUR package shipping the entire repo as-is:
```
pkgname=arch-scripts
```

### What gets packaged
The full repo is installed to a fixed location (e.g. `/usr/share/arch-scripts/` or `/opt/arch-scripts/`).
The root meta-scripts (`install.sh`, `remove.sh` etc.) are the user-facing entry points.
Users can add their own modules by dropping folders into the install location — out of scope for this package.

### PKGBUILD behaviour
- Ships all files to the package install location
- `post_install()` in the `.install` file does NOT auto-run modules — user runs `install.sh` manually to choose what to deploy
- `pre_remove()` runs `remove.sh` to clean up deployed system files before package is uninstalled

### Tasks
- [ ] Write PKGBUILD
- [ ] Write `arch-scripts.install` (post_install hint, pre_remove cleanup)
- [ ] Decide install location: `/usr/share/arch-scripts/` vs `/opt/arch-scripts/`
- [ ] Submit to AUR

---

## Execution Order

```
Phase 1 (orchestrator)  →  Phase 2 (paths)  →  Phase 3 (uki-secureboot)  →  Phase 5 (AUR)
                                                Phase 4 (snapper-boot)    ↗
```
Phases 3 and 4 are independent of each other after Phase 2.
