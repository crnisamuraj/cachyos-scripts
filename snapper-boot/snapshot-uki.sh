#!/usr/bin/env bash
# snapshot-uki.sh — Build and sign rollback UKIs for BTRFS snapshots
# Modes:
#   (no args)        Auto: build UKI for latest snapper pre-snapshot, then cleanup
#   --snapshot N     Build UKI for specific snapshot number
#   --cleanup        Just prune old rollback UKIs
#   --list           Show current rollback UKIs on ESP

set -euo pipefail

log()  { echo "[snapshot-uki] $*"; }
warn() { echo "[snapshot-uki] WARNING: $*" >&2; }
die()  { echo "[snapshot-uki] ERROR: $*" >&2; exit 1; }

# ─── Configuration ───────────────────────────────────────────────────────────

CONFIG_FILE="/etc/snapper-boot/config"
MAX_SNAPSHOTS=3

if [[ -f "${CONFIG_FILE}" ]]; then
    # shellcheck source=/dev/null
    source "${CONFIG_FILE}"
fi

# Auto-detect ESP mount point
if [[ -z "${ESP:-}" ]]; then
    for _esp in /efi /boot/efi /boot; do
        if mountpoint -q "${_esp}" 2>/dev/null; then
            ESP="${_esp}"
            break
        fi
    done
fi
[[ -n "${ESP:-}" ]] || die "Cannot detect ESP mount point. Set ESP= in environment."
UKI_DIR="${ESP}/EFI/Linux"

MODULES_DIR="/usr/lib/modules"
CMDLINE="/etc/uki-secureboot/cmdline"
KEY_DIR="/etc/uki-secureboot/keys"
OSRELEASE="/etc/os-release"
UCODE=""

# ─── Parse arguments ─────────────────────────────────────────────────────────

MODE="auto"
SNAPSHOT_NUM=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --snapshot)
            MODE="snapshot"
            SNAPSHOT_NUM="${2:-}"
            [[ -n "${SNAPSHOT_NUM}" ]] || die "--snapshot requires a snapshot number."
            shift 2
            ;;
        --cleanup)
            MODE="cleanup"
            shift
            ;;
        --list)
            MODE="list"
            shift
            ;;
        *)
            die "Unknown argument: $1. Usage: $0 [--snapshot N | --cleanup | --list]"
            ;;
    esac
done

# ─── List mode ───────────────────────────────────────────────────────────────

if [[ "${MODE}" == "list" ]]; then
    if [[ ! -d "${UKI_DIR}" ]]; then
        log "No UKI directory found at ${UKI_DIR}."
        exit 0
    fi
    found=0
    for uki in "${UKI_DIR}"/snapshot-*.efi; do
        [[ -f "${uki}" ]] || continue
        echo "  $(basename "${uki}")"
        found=$((found + 1))
    done
    if [[ ${found} -eq 0 ]]; then
        log "No rollback UKIs found on ESP."
    else
        log "Found ${found} rollback UKI(s)."
    fi
    exit 0
fi

# ─── Cleanup function ────────────────────────────────────────────────────────

cleanup_old_snapshots() {
    [[ -d "${UKI_DIR}" ]] || return 0

    # Collect unique snapshot numbers from rollback UKIs
    local -a snap_nums=()
    for uki in "${UKI_DIR}"/snapshot-*.efi; do
        [[ -f "${uki}" ]] || continue
        local fname
        fname="$(basename "${uki}" .efi)"
        # Extract snapshot number: snapshot-{N}-{pkgbase}-{kver}
        local num
        num="$(echo "${fname}" | sed 's/^snapshot-\([0-9]*\)-.*/\1/')"
        [[ -n "${num}" ]] || continue
        # Add to array if not already present
        local already=0
        for existing in "${snap_nums[@]+"${snap_nums[@]}"}"; do
            if [[ "${existing}" == "${num}" ]]; then
                already=1
                break
            fi
        done
        [[ ${already} -eq 1 ]] || snap_nums+=("${num}")
    done

    # Sort numerically (descending) and remove oldest beyond MAX_SNAPSHOTS
    if [[ ${#snap_nums[@]} -le ${MAX_SNAPSHOTS} ]]; then
        return 0
    fi

    local sorted
    sorted="$(printf '%s\n' "${snap_nums[@]}" | sort -rn)"
    local keep_count=0
    while IFS= read -r num; do
        keep_count=$((keep_count + 1))
        if [[ ${keep_count} -gt ${MAX_SNAPSHOTS} ]]; then
            log "Pruning rollback UKIs for snapshot #${num}..."
            rm -f "${UKI_DIR}"/snapshot-"${num}"-*.efi
        fi
    done <<< "${sorted}"
}

# ─── Cleanup-only mode ───────────────────────────────────────────────────────

if [[ "${MODE}" == "cleanup" ]]; then
    [[ $EUID -eq 0 ]] || die "Must run as root."
    log "Running cleanup..."
    cleanup_old_snapshots
    log "Cleanup complete."
    exit 0
fi

# ─── Prereq checks ──────────────────────────────────────────────────────────

[[ $EUID -eq 0 ]] || die "Must run as root."

command -v ukify   >/dev/null 2>&1 || die "ukify not found. Install systemd-ukify."
command -v sbsign  >/dev/null 2>&1 || die "sbsign not found. Install sbsigntools."
command -v snapper >/dev/null 2>&1 || die "snapper not found. Install snapper."
command -v btrfs   >/dev/null 2>&1 || die "btrfs not found. Install btrfs-progs."

[[ -f "${KEY_DIR}/MOK.key" ]] || die "MOK key not found at ${KEY_DIR}/MOK.key."
[[ -f "${KEY_DIR}/MOK.pem" ]] || die "MOK certificate not found at ${KEY_DIR}/MOK.pem."
[[ -f "${CMDLINE}" ]]         || die "Kernel cmdline not found at ${CMDLINE}."
[[ -f "${OSRELEASE}" ]]       || die "os-release not found at ${OSRELEASE}."

# Verify snapper root config exists
if ! snapper list-configs 2>/dev/null | grep -q 'root'; then
    die "No snapper root config found. Run: sudo snapper -c root create-config /"
fi

mkdir -p "${UKI_DIR}"

# ─── Determine snapshot number ───────────────────────────────────────────────

if [[ "${MODE}" == "auto" ]]; then
    # Find the latest pre or single snapshot
    # snapper list outputs: number | type | pre-number | date | user | cleanup | description | userdata
    SNAPSHOT_NUM="$(snapper -c root list --columns number,type,description \
        | tail -n +3 \
        | awk -F'|' '
            {
                gsub(/^[ \t]+|[ \t]+$/, "", $1)
                gsub(/^[ \t]+|[ \t]+$/, "", $2)
                if ($2 == "pre" || $2 == "single") num = $1
            }
            END { if (num) print num }
        ')"

    if [[ -z "${SNAPSHOT_NUM}" ]]; then
        warn "No snapshots found yet (fresh install?). Nothing to do."
        exit 0
    fi
    log "Auto-detected latest snapshot: #${SNAPSHOT_NUM}"
fi

# Validate snapshot exists
SNAPSHOT_PATH="/.snapshots/${SNAPSHOT_NUM}/snapshot"
if [[ ! -d "${SNAPSHOT_PATH}" ]]; then
    die "Snapshot path not found: ${SNAPSHOT_PATH}"
fi

# ─── Get subvolume ID ────────────────────────────────────────────────────────

SUBVOLID="$(btrfs subvolume show "${SNAPSHOT_PATH}" 2>/dev/null \
    | grep -E '^\s*Subvolume ID:' \
    | awk '{print $NF}')"

[[ -n "${SUBVOLID}" ]] || die "Could not determine subvolume ID for ${SNAPSHOT_PATH}"
log "Snapshot #${SNAPSHOT_NUM} subvolid: ${SUBVOLID}"

# ─── Cmdline transformation ─────────────────────────────────────────────────

ORIG_CMDLINE="$(cat "${CMDLINE}")"

SNAP_CMDLINE="$(echo "${ORIG_CMDLINE}" \
    | sed 's/rootflags=[^ ]*//g' \
    | sed 's/resume=[^ ]*//g' \
    | sed 's/resume_offset=[^ ]*//g' \
    | sed 's/ rw / ro /g; s/^rw /ro /; s/ rw$/ ro/' \
    | sed 's/  */ /g' \
    | sed 's/^ //;s/ $//')"

SNAP_CMDLINE="${SNAP_CMDLINE} rootflags=subvolid=${SUBVOLID}"

log "Snapshot cmdline: ${SNAP_CMDLINE}"

# ─── Temp files ──────────────────────────────────────────────────────────────

TMPDIR_WORK="$(mktemp -d /tmp/snapshot-uki-XXXXXX)"
trap 'rm -rf "${TMPDIR_WORK}"' EXIT

# Write temp cmdline
SNAP_CMDLINE_FILE="${TMPDIR_WORK}/cmdline"
echo "${SNAP_CMDLINE}" > "${SNAP_CMDLINE_FILE}"

# Write temp os-release with modified PRETTY_NAME
SNAP_OSRELEASE="${TMPDIR_WORK}/os-release"
sed "s/^PRETTY_NAME=\"\(.*\)\"/PRETTY_NAME=\"\1 (Snapshot #${SNAPSHOT_NUM})\"/" \
    "${OSRELEASE}" > "${SNAP_OSRELEASE}"

# ─── Auto-detect CPU microcode ───────────────────────────────────────────────

for ucode_candidate in \
    "/boot/intel-ucode.img" \
    "/boot/amd-ucode.img" \
    "/efi/intel-ucode.img" \
    "/efi/amd-ucode.img" \
    "/usr/lib/firmware/intel-ucode.img" \
    "/usr/lib/firmware/amd-ucode.img"; do
    if [[ -f "${ucode_candidate}" ]]; then
        UCODE="${ucode_candidate}"
        log "Detected microcode: ${UCODE}"
        break
    fi
done

# ─── Build UKI for each installed kernel ─────────────────────────────────────

built=0
for kdir in "${MODULES_DIR}"/*/; do
    [[ -d "${kdir}" ]] || continue

    kver="$(basename "${kdir}")"
    vmlinuz="${kdir}vmlinuz"
    initrd="/boot/initramfs-${kver}.img"

    # CachyOS fallback naming
    if [[ ! -f "${initrd}" ]]; then
        for candidate in /boot/initramfs-*.img; do
            if [[ -f "${candidate}" ]] && [[ "${candidate}" != *"-fallback"* ]]; then
                preset_name="$(basename "${candidate}" .img)"
                preset_name="${preset_name#initramfs-}"
                if [[ -f "/usr/lib/modules/${kver}/pkgbase" ]]; then
                    pkgbase="$(< "/usr/lib/modules/${kver}/pkgbase")"
                    if [[ "${preset_name}" == "${pkgbase}" ]]; then
                        initrd="${candidate}"
                        break
                    fi
                fi
            fi
        done
    fi

    if [[ ! -f "${vmlinuz}" ]]; then
        warn "No vmlinuz for ${kver}, skipping."
        continue
    fi

    if [[ ! -f "${initrd}" ]]; then
        warn "No initramfs for ${kver}, skipping."
        continue
    fi

    # Determine output filename: snapshot-{N}-{pkgbase}-{kver}.efi
    if [[ -f "${MODULES_DIR}/${kver}/pkgbase" ]]; then
        pkgbase="$(< "${MODULES_DIR}/${kver}/pkgbase")"
    else
        pkgbase="linux"
    fi
    uki_name="snapshot-${SNAPSHOT_NUM}-${pkgbase}-${kver}.efi"
    uki_path="${UKI_DIR}/${uki_name}"
    uki_tmp="${TMPDIR_WORK}/uki-${kver}.efi"

    log "Building rollback UKI: ${uki_name}"
    log "  Kernel  : ${vmlinuz}"
    log "  Initrd  : ${initrd}"
    [[ -n "${UCODE}" ]] && log "  Microcode: ${UCODE}"

    # Assemble ukify arguments
    ukify_args=(
        build
        --linux="${vmlinuz}"
        --cmdline="@${SNAP_CMDLINE_FILE}"
        --os-release="@${SNAP_OSRELEASE}"
        --uname="${kver}"
        --output="${uki_tmp}"
    )

    # Microcode first, then main initrd
    if [[ -n "${UCODE}" ]]; then
        ukify_args+=(--initrd="${UCODE}")
    fi
    ukify_args+=(--initrd="${initrd}")

    # Build the UKI
    if ! ukify "${ukify_args[@]}"; then
        warn "ukify failed for ${kver}"
        rm -f "${uki_tmp}"
        continue
    fi

    # Sign with MOK
    log "Signing rollback UKI with MOK..."
    if ! sbsign \
        --key "${KEY_DIR}/MOK.key" \
        --cert "${KEY_DIR}/MOK.pem" \
        --output "${uki_path}" \
        "${uki_tmp}"; then
        warn "sbsign failed for ${kver}"
        rm -f "${uki_tmp}"
        continue
    fi

    rm -f "${uki_tmp}"

    # Verify signature
    if sbverify --cert "${KEY_DIR}/MOK.pem" "${uki_path}" >/dev/null 2>&1; then
        log "Signature verified: ${uki_path}"
    else
        warn "Signature verification FAILED for ${uki_path} — removing"
        rm -f "${uki_path}"
        continue
    fi

    built=$((built + 1))
done

if [[ ${built} -eq 0 ]]; then
    warn "No rollback UKIs were built. Check kernel installations."
    exit 1
fi

log "Built and signed ${built} rollback UKI(s) for snapshot #${SNAPSHOT_NUM}."

# ─── Cleanup old rollback UKIs ───────────────────────────────────────────────

cleanup_old_snapshots
log "Done."
