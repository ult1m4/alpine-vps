#!/usr/bin/env bash
#----------------------------------------------------------------------------
# alpine-install.sh: installs Alpine Linux on a GPT disk with BIOS-GRUB
# Overrides PXE/rescue boot on most VPS providers (e.g., IONOS).
#
# Usage:   ./alpine-install.sh [-t virt|standard] <disk> <ssh-pubkey>
# Example: ./alpine-install.sh -t virt /dev/vda ~/.ssh/id_rsa.pub
# Requires: wget, sgdisk, mkfs.ext4, mount, tar, dd,
#           partprobe, lsblk, blockdev, gpg.
#----------------------------------------------------------------------------

set -euo pipefail

#------------------------------------------------------------------------------
# Logging helpers
#------------------------------------------------------------------------------
LOG()   { echo "[$(date +%H:%M:%S)] $*"; }
WARN()  { echo "[$(date +%H:%M:%S)] WARN: $*" >&2; }
ERROR() { echo "[$(date +%H:%M:%S)] ERROR: $*" >&2; exit 1; }

#------------------------------------------------------------------------------
# Defaults & arg parsing
#------------------------------------------------------------------------------
ISO_TYPE="virt"
CHROOT="/mnt/alpine"
ISO_MNT="/mnt/iso"

while getopts ":t:" opt; do
  case $opt in
    t) [[ $OPTARG =~ ^(virt|standard)$ ]] \
         || ERROR "Invalid ISO type '$OPTARG', use 'virt' or 'standard'"
       ISO_TYPE=$OPTARG ;;
    \?) ERROR "Invalid option -$OPTARG" ;;
  esac
done
shift $((OPTIND - 1))

[ $# -eq 2 ] || ERROR "Usage: $0 [-t virt|standard] <disk> <ssh-pubkey>"
DISK=$1
PUBKEY_FILE=$2

#------------------------------------------------------------------------------
# Pre-flight tools
#------------------------------------------------------------------------------
for cmd in wget sgdisk mkfs.ext4 mount tar dd partprobe lsblk blockdev gpg; do
  command -v "$cmd" >/dev/null 2>&1 \
    || ERROR "Missing required host tool: $cmd"
done

[ -b "$DISK" ]        || ERROR "Block device '$DISK' not found"
[ -f "$PUBKEY_FILE" ] || ERROR "SSH pubkey file '$PUBKEY_FILE' not found"
PUBKEY=$(<"$PUBKEY_FILE")
[ -n "$PUBKEY" ]      || ERROR "SSH pubkey file is empty"

#------------------------------------------------------------------------------
# Partition names (NVMe uses 'p')
#------------------------------------------------------------------------------
PART_PREFIX=""
case "$DISK" in /dev/nvme*) PART_PREFIX="p";; esac
PART_BIOS="${DISK}${PART_PREFIX}1"
PART_BOOT="${DISK}${PART_PREFIX}2"
PART_ROOT="${DISK}${PART_PREFIX}3"

#------------------------------------------------------------------------------
# 0) Cleanup old mounts & check for LVM/RAID
#------------------------------------------------------------------------------
LOG "Cleaning up any old mounts"
umount -l "$ISO_MNT"       2>/dev/null || true
umount -l "$CHROOT"/*      2>/dev/null || true

MOUNTS=$(lsblk -n -o MOUNTPOINT \
  "$DISK" "$PART_BIOS" "$PART_BOOT" "$PART_ROOT" \
  | grep -v '^$' || true)
[ -z "$MOUNTS" ] || ERROR "Some partitions on $DISK are mounted; unmount first."

if blkid -s TYPE -o value "$DISK" | grep -Eq '^(LVM|LVM2_member|linux_raid)'; then
  WARN "Disk $DISK carries LVM/RAID metadata—this install will overwrite it!"
fi

echo
LOG "WARNING: This will ERASE ALL DATA on $DISK and install Alpine Linux."
read -p "Type 'yes' to proceed: " confirm
[ "$confirm" = "yes" ] || ERROR "Aborted by user."

#------------------------------------------------------------------------------
# 1) Download & verify Alpine ISO
#------------------------------------------------------------------------------
LOG "Selecting Alpine $ISO_TYPE ISO"
BASE="https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/x86_64/"
PATTERN="alpine-${ISO_TYPE}-[0-9.]+-x86_64.iso"

LATEST=$(wget -qO- "$BASE" \
  | grep -Eo "$PATTERN" \
  | grep -v rc \
  | sort -V \
  | tail -1)
[ -n "$LATEST" ] || ERROR "Could not find Alpine $ISO_TYPE ISO"
ISO_URL="${BASE}${LATEST}"

cd /root
if [ -f "$LATEST" ]; then
  LOG "Reusing existing ISO: /root/$LATEST"
else
  LOG "Downloading ISO, checksums & GPG key (3 attempts)"
  attempts=1
  while [ "$attempts" -le 3 ]; do
    wget --progress=dot:giga \
      "$ISO_URL" \
      "$ISO_URL.sha256" \
      "$ISO_URL.asc" \
      "https://alpinelinux.org/keys/ncopa.asc" && break

    if [ "$attempts" -lt 3 ]; then
      LOG "ISO download attempt $attempts failed, retrying in 5s..."
      sleep 5
    else
      ERROR "ISO download failed after 3 attempts"
    fi
    attempts=$((attempts + 1))
  done
fi

LOG "Verifying ISO integrity"
sha256sum -c "${LATEST}.sha256"   || ERROR "SHA256 check failed"
gpg --import ncopa.asc           &>/dev/null || ERROR "GPG import failed"
gpg --verify "${LATEST}.asc" "$LATEST" &>/dev/null \
                                 || ERROR "Signature verification failed"

#------------------------------------------------------------------------------
# 2) Mount ISO & fetch apk-tools-static
#------------------------------------------------------------------------------
LOG "Mounting ISO at $ISO_MNT"
mkdir -p "$ISO_MNT"
mount -o loop "/root/$LATEST" "$ISO_MNT" || ERROR "ISO mount failed"

LOG "Fetching apk-tools-static index"
IDX="/tmp/alpine-index.html"
attempts=1
while [ "$attempts" -le 3 ]; do
  rm -f "$IDX"
  wget --progress=dot:giga -O "$IDX" \
    "https://dl-cdn.alpinelinux.org/alpine/latest-stable/main/x86_64/" && break

  if [ "$attempts" -lt 3 ]; then
    LOG "Index fetch attempt $attempts failed, retrying..."
    sleep 5
  else
    ERROR "Failed to fetch APK index after 3 attempts"
  fi
  attempts=$((attempts + 1))
done

APK_PKG=$(grep -Eo 'apk-tools-static-[0-9.]+(-r[0-9]+)?\.apk' "$IDX" \
           | sort -V \
           | tail -1)
rm -f "$IDX"
[ -n "$APK_PKG" ] || { APK_PKG="apk-tools-static-2.14.4.apk"; WARN "No apk-tools-static found, falling back to $APK_PKG"; }

LOG "Downloading apk-tools-static: $APK_PKG"
attempts=1
while [ "$attempts" -le 3 ]; do
  rm -f "/root/$APK_PKG"
  wget --progress=dot:giga -O "/root/$APK_PKG" \
    "https://dl-cdn.alpinelinux.org/alpine/latest-stable/main/x86_64/$APK_PKG" && break

  if [ "$attempts" -lt 3 ]; then
    LOG "APK download attempt $attempts failed, retrying..."
    sleep 5
  else
    ERROR "Failed to download apk-tools-static after 3 attempts"
  fi
  attempts=$((attempts + 1))
done

LOG "Extracting apk.static"
mkdir -p /root/sbin
tar -C /root -xzf "/root/$APK_PKG" sbin/apk.static \
  || ERROR "Failed to extract apk.static"
chmod +x /root/sbin/apk.static
APK_BIN="/root/sbin/apk.static"
rm -f "/root/$APK_PKG"
umount "$ISO_MNT"

#------------------------------------------------------------------------------
# 3) Partition & format disk (GPT + BIOS-GRUB + /boot + /)
#------------------------------------------------------------------------------
LOG "Partitioning $DISK"
sgdisk --zap-all     "$DISK"
sgdisk --mbrtogpt    "$DISK"
sgdisk -n1:1MiB:+1MiB -t1:EF02 -c1:"BIOS-GRUB"  "$DISK"
sgdisk -n2:0:+256MiB  -t2:8300 -c2:"alpine-boot" "$DISK"
sgdisk -n3:0:0       -t3:8300 -c3:"alpine-root" "$DISK"
partprobe "$DISK"
sleep 2

LOG "Verifying partitions"
for part in "$PART_BIOS" "$PART_BOOT" "$PART_ROOT"; do
  [ -b "$part" ] || ERROR "Partition $part not found"
done

LOG "Formatting partitions"
mkfs.ext4 -F "$PART_BOOT" || ERROR "mkfs.ext4 on $PART_BOOT failed"
mkfs.ext4 -F "$PART_ROOT" || ERROR "mkfs.ext4 on $PART_ROOT failed"

#------------------------------------------------------------------------------
# 4) Mount new filesystems
#------------------------------------------------------------------------------
LOG "Mounting root and boot"
mkdir -p "$CHROOT" "$CHROOT/boot"
[ -d "$CHROOT" ]       || ERROR "Failed to create $CHROOT"
[ -d "$CHROOT/boot" ]  || ERROR "Failed to create $CHROOT/boot"

LOG "Verifying partitions before mount: $PART_ROOT, $PART_BOOT"
[ -b "$PART_ROOT" ]    || ERROR "Partition $PART_ROOT not found"
[ -b "$PART_BOOT" ]    || ERROR "Partition $PART_BOOT not found"

mount "$PART_ROOT" "$CHROOT"       || ERROR "Mount $PART_ROOT failed"
mount "$PART_BOOT" "$CHROOT/boot"  || ERROR "Mount $PART_BOOT failed"

#------------------------------------------------------------------------------
# 5) Bootstrap Alpine base
#------------------------------------------------------------------------------
LOG "Bootstrapping Alpine base"
"$APK_BIN" \
  --repository "https://dl-cdn.alpinelinux.org/alpine/latest-stable/main" \
  --allow-untrusted -U --root "$CHROOT" --initdb \
  add alpine-base || ERROR "alpine-base bootstrap failed"

#------------------------------------------------------------------------------
# 6) Prepare chroot environment
#------------------------------------------------------------------------------
LOG "Binding dev/proc/sys and copying DNS"
for d in dev proc sys; do
  mount --bind "/$d" "$CHROOT/$d" || ERROR "Bind mount $d failed"
done
cp /etc/resolv.conf "$CHROOT/etc/resolv.conf" || ERROR "Copy resolv.conf failed"

#------------------------------------------------------------------------------
# 7) Chroot: configure system & install GRUB
#------------------------------------------------------------------------------
LOG "Configuring Alpine in chroot and installing GRUB"
chroot "$CHROOT" /bin/sh -eux <<EOF
# Repositories
echo "https://dl-cdn.alpinelinux.org/alpine/latest-stable/main" > /etc/apk/repositories

# fstab
cat > /etc/fstab <<FSTAB
$PART_ROOT /      ext4 defaults 0 1
$PART_BOOT /boot  ext4 defaults 0 2
FSTAB

# Networking
IF=\$(ip -o link show | awk -F': ' '{print \$2}' | grep -v lo | head -1)
[ -z "\$IF" ] && { echo "WARN: No network interface found, defaulting to eth0" >&2; IF=eth0; }
cat > /etc/network/interfaces <<NETCFG
auto lo
iface lo inet loopback

auto \$IF
iface \$IF inet dhcp
NETCFG

# SSH keys
mkdir -p /root/.ssh
cat > /root/.ssh/authorized_keys <<KEY
$PUBKEY
KEY
chmod 700 /root/.ssh
chmod 600 /root/.ssh/authorized_keys

# Kernel + GRUB
KERNEL_PKG="linux-virt"
[ "\$ISO_TYPE" = "standard" ] && KERNEL_PKG="linux-lts"
apk update
apk add "\$KERNEL_PKG" grub grub-bios

# Install GRUB & generate config
grub-install "$DISK" > /tmp/grub-install.log 2>&1 \
  || { echo "GRUB installation failed" >&2; cat /tmp/grub-install.log >&2; exit 1; }
grub-mkconfig -o /boot/grub/grub.cfg

# Sanity check
[ -s /boot/grub/grub.cfg ] || { echo "GRUB config is empty or missing" >&2; exit 1; }
EOF

#------------------------------------------------------------------------------
# 8) Cleanup & reboot
#------------------------------------------------------------------------------
LOG "Cleaning up mounts"
for d in dev proc sys; do
  umount "$CHROOT/$d" 2>/dev/null || true
done
umount "$CHROOT/boot" 2>/dev/null || true
umount "$CHROOT"      2>/dev/null || true

if mount | grep -q "$CHROOT"; then
  WARN "Failed to unmount some filesystems. Reboot may leave system in an inconsistent state."
  umount -f "$CHROOT/sys" "$CHROOT/proc" "$CHROOT/dev" \
        "$CHROOT/boot" "$CHROOT" 2>/dev/null || true
fi

echo
LOG "Alpine Linux installation completed successfully!"
LOG "CRITICAL: After reboot, configure your provider to boot from $DISK."
LOG "If you return to PXE/rescue, double-check boot order or force $DISK."
LOG "Debug info & grub.cfg live in /boot/grub/grub.cfg on the new system."
LOG "After reboot, verify networking. If interface ($IF) fails, run 'ip link' and edit /etc/network/interfaces."

LOG "Syncing & rebooting in 5 seconds..."
sync; sleep 5
reboot
