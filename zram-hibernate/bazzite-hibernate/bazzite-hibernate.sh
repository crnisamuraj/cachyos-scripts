#!/bin/bash
# ------------------------------------------------------------------
# Bazzite/Universal Blue Hibernation Enabler
# ------------------------------------------------------------------
# Automates hibernation setup on BTRFS systems with ZRAM support.
#
# What this does:
# 1. Calculates ideal swap size (RAM + 4GB)
# 2. Creates a dedicated BTRFS subvolume & NoCOW swapfile
# 3. Sets swap priority to 0 (so ZRAM remains default for daily use)
# 4. Compiles a custom SELinux policy to fix "Access Denied" errors
# 5. Updates Kernel Arguments (resume UUID) & rebuilds initramfs
# 6. Enables "Suspend-then-Hibernate" behavior
# ------------------------------------------------------------------

set -e # Stop on error

# --- Visuals ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${YELLOW}Starting Bazzite Hibernation Setup...${NC}"

# --- 1. Root Check ---
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}Error: This script must be run as root.${NC}"
   exit 1
fi

# --- 2. Calculate & Create Swap ---
# Get RAM in GB (rounded up)
MEM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
MEM_GB=$(echo "scale=0; ($MEM_KB + 1048576 - 1) / 1024 / 1024" | bc)
SWAP_SIZE_GB=$(($MEM_GB + 4)) # RAM + 4GB Buffer
SWAP_PATH="/var/swap"
SWAP_FILE="$SWAP_PATH/swapfile"

echo -e "System RAM: ${MEM_GB}GB | Target Swap: ${SWAP_SIZE_GB}GB"

if [ -f "$SWAP_FILE" ]; then
    echo -e "${YELLOW}Swapfile already exists. Skipping creation.${NC}"
else
    echo "Creating swapfile structure..."
    # Create subvolume if missing (Best practice for BTRFS snapshots)
    if [ ! -d "$SWAP_PATH" ]; then
        btrfs subvolume create $SWAP_PATH >/dev/null
    fi

    # Disable Copy-on-Write (Required for BTRFS swap)
    chattr +C $SWAP_PATH

    # Create the file
    btrfs filesystem mkswapfile --size ${SWAP_SIZE_GB}G $SWAP_FILE >/dev/null
    chmod 600 $SWAP_FILE
    echo -e "${GREEN}Swapfile created.${NC}"
fi

# --- 3. Configure fstab ---
# We set Priority=0 so it is LOWER than ZRAM (usually 100)
if ! grep -q "$SWAP_FILE" /etc/fstab; then
    echo "$SWAP_FILE none swap defaults,pri=0 0 0" >> /etc/fstab
    echo -e "${GREEN}Added to /etc/fstab.${NC}"
else
    echo -e "${YELLOW}Already in /etc/fstab.${NC}"
fi

# Enable it immediately to ensure it works
swapon $SWAP_FILE 2>/dev/null || true

# --- 4. Fix SELinux (The "All-in-One" Policy) ---
# We manually create a comprehensive policy to avoid the "whack-a-mole" of errors
echo "Applying SELinux fixes for systemd-sleep..."
MOD_NAME="bazzite_hibernate_complete"

cat > ${MOD_NAME}.te <<EOF
module ${MOD_NAME} 1.0;

require {
    type systemd_logind_t;
    type systemd_sleep_t;
    type swapfile_t;
    type unconfined_service_t;
    class dir { search };
    class file { read write open getattr lock ioctl };
    class capability2 { mac_admin };
}

# Allow logind to check space
allow systemd_logind_t swapfile_t:dir search;

# Allow sleep to perform the write
allow systemd_sleep_t swapfile_t:dir search;
allow systemd_sleep_t swapfile_t:file { read write open getattr lock ioctl };

# MAYBE NOT NECCESSARY - Allow chcon/tools if needed
# allow unconfined_service_t unconfined_service_t:capability2 mac_admin;
EOF

# Compile and Install
checkmodule -M -m -o ${MOD_NAME}.mod ${MOD_NAME}.te >/dev/null
semodule_package -o ${MOD_NAME}.pp -m ${MOD_NAME}.mod >/dev/null
semodule -i ${MOD_NAME}.pp
rm ${MOD_NAME}.*
echo -e "${GREEN}SELinux policy installed.${NC}"

# Apply context to file
semanage fcontext -a -t swapfile_t "$SWAP_PATH(/.*)?" 2>/dev/null || true
restorecon -RF $SWAP_PATH

# --- 5. Kernel Arguments ---
echo "Configuring boot arguments..."
# Vital: Find UUID of the FILESYSTEM, not the partition
RESUME_UUID=$(findmnt -no UUID -T $SWAP_FILE)
RESUME_OFFSET=$(btrfs inspect-internal map-swapfile -r $SWAP_FILE)

echo "Resume Device: UUID=$RESUME_UUID"
echo "Resume Offset: $RESUME_OFFSET"

# Update rpm-ostree
rpm-ostree kargs \
    --append-if-missing="resume=UUID=$RESUME_UUID" \
    --append-if-missing="resume_offset=$RESUME_OFFSET" >/dev/null
echo -e "${GREEN}Kernel arguments updated.${NC}"

# --- 6. Initramfs & Dracut ---
echo "Updating initramfs config..."
echo 'add_dracutmodules+=" resume "' > /etc/dracut.conf.d/resume.conf

# Force regeneration on next boot logic
# On atomic, we just ensure the override is enabled
if ! rpm-ostree initramfs --enable --arg="--force" 2>/dev/null; then
     echo -e "${YELLOW}Initramfs already enabled (updates queued).${NC}"
fi

# --- 7. Configure Systemd Sleep ---
echo "Setting up Suspend-then-Hibernate..."

# Update logind.conf to use smart suspend
sed -i 's/#\?HandleLidSwitch=.*/HandleLidSwitch=suspend-then-hibernate/' /etc/systemd/logind.conf
sed -i 's/#\?HandleLidSwitchExternalPower=.*/HandleLidSwitchExternalPower=suspend-then-hibernate/' /etc/systemd/logind.conf

# Update sleep.conf for timing (2 hours)
# If section doesn't exist, append it
if ! grep -q "\[Sleep\]" /etc/systemd/sleep.conf; then
    echo -e "\n[Sleep]\nHibernateDelaySec=2h\nHibernateMode=platform" >> /etc/systemd/sleep.conf
else
    # Else replace existing keys
    sed -i 's/#\?HibernateDelaySec=.*/HibernateDelaySec=2h/' /etc/systemd/sleep.conf
    sed -i 's/#\?HibernateMode=.*/HibernateMode=platform/' /etc/systemd/sleep.conf
fi

# --- 8. Done ---
echo -e "\n${GREEN}==============================================${NC}"
echo -e "${GREEN} SETUP COMPLETE! ${NC}"
echo -e "${GREEN}==============================================${NC}"
echo -e "1. A reboot is required to apply the new Kernel Arguments."
echo -e "2. After reboot, closing your lid will:"
echo -e "   - Sleep immediately (fast)."
echo -e "   - Hibernate after 2 hours (saves battery)."
echo -e "3. You can test manually with: systemctl hibernate"
echo -e "${GREEN}==============================================${NC}"
