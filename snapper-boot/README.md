# snapper-boot — BTRFS Snapshot Rollback UKIs for systemd-boot

Automatically builds signed Unified Kernel Images (UKIs) that boot into BTRFS
snapshots. Designed for systems using UKI + Secure Boot where the kernel cmdline
is embedded and signed inside the UKI.

## Problem

With UKI + Secure Boot, you can't just edit the kernel cmdline at boot time to
point to a different BTRFS subvolume. Tools like grub-btrfs don't work in this
setup. If a system upgrade breaks something, you need a pre-built, signed UKI
that boots into the pre-upgrade snapshot.

## Solution

A pacman hook runs **before** each package transaction (after snap-pac creates a
pre-upgrade snapshot). It builds a signed UKI with a modified cmdline that:

- Points to the snapshot's subvolume (`rootflags=subvolid=NNN`)
- Mounts read-only (`ro` instead of `rw`)
- Strips hibernate resume parameters (not safe from a read-only snapshot)

The rollback UKI appears in the systemd-boot menu as a separate entry.

## Prerequisites

- `uki-secureboot` module deployed (provides MOK keys, cmdline, uki-build.sh)
- BTRFS root filesystem with snapper configured
- systemd-boot as the bootloader

## Installation

```bash
sudo ./install.sh          # deploy scripts and hook
sudo ./install.sh --setup  # also build initial rollback UKI
```

## Usage

Rollback UKIs are built automatically on every pacman transaction. Manual usage:

```bash
# List rollback UKIs on ESP
sudo /etc/snapper-boot/snapshot-uki.sh --list

# Build rollback UKI for a specific snapshot
sudo /etc/snapper-boot/snapshot-uki.sh --snapshot 42

# Prune old rollback UKIs (keeps last 3 by default)
sudo /etc/snapper-boot/snapshot-uki.sh --cleanup
```

## Configuration

Edit `/etc/snapper-boot/config`:

```bash
# Maximum number of snapshot rollback UKI sets to keep on ESP
MAX_SNAPSHOTS=3
```

## How it works

1. snap-pac's `00-snapper-pre.hook` creates a pre-upgrade snapshot
2. `01-snapshot-uki-pre.hook` triggers `snapshot-uki.sh` (PreTransaction)
3. The script finds the latest snapshot, gets its subvolume ID
4. Transforms the kernel cmdline for snapshot booting
5. Builds and signs a UKI for each installed kernel
6. Prunes old rollback UKIs beyond `MAX_SNAPSHOTS`

Output files: `${ESP}/EFI/Linux/snapshot-{N}-{pkgbase}-{kver}.efi`

## Booting a snapshot

1. Reboot and open the systemd-boot menu (hold Space or press a key during boot)
2. Select the snapshot entry (shows "Snapshot #N" in the OS name)
3. The system boots read-only into the snapshot
4. From there, use snapper to rollback or investigate the issue

## Removal

```bash
sudo ./remove.sh
```

This removes rollback UKIs from ESP, the pacman hook, config directory, and
reverts the uki-remove.sh patch.
