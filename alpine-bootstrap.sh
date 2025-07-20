#!/usr/bin/env bash
#----------------------------------------------------------------------------
# alpine-bootstrap.sh – installs Alpine Linux on a GPT disk with BIOS/GRUB
#
# Usage:   ./alpine-bootstrap.sh [-t virt|standard] <disk> <ssh-pubkey>
# Example: ./alpine-bootstrap.sh -t virt /dev/vda ~/.ssh/id_rsa.pub
#
# Requires: wget sgdisk mkfs.ext4 mount tar dd partprobe lsblk blockdev gpg
#----------------------------------------------------------------------------

set -euo pipefail

#------------------------------------------------------------------------------
# Logging functions
#------------------------------------------------------------------------------
LOG()   { echo "[$(date +%H:%M:%S)] $*"; }
WARN()  { echo "[$(date +%H:%M:%S)] WARN: $*" >&2; }
ERROR() { echo "[$(date +%H:%M:%S)] ERROR: $*" >&2; exit 1; }

#------------------------------------------------------------------------------
# Defaults & CLI parsing
#------------------------------------------------------------------------------
ISO_TYPE="virt"
CHROOT="/mnt/alpine"
ISO_MNT="/mnt/iso"

while getopts ":t:" opt; do
  case $opt in
    t) [[ $OPTARG =~ ^(virt|standard)$ ]] || ERROR "Invalid ISO type '$OPTARG'"
       ISO_TYPE=$OPTARG ;;
    \?) ERROR "Invalid option -$OPTARG" ;;
  esac
done
shift $((OPTIND - 1))

[ $# -eq 2 ] || ERROR "Usage: $0 [-t virt|standard] <disk> <ssh-pubkey>"
DISK=$1
PUBKEY_FILE=$2

#------------------------------------------------------------------------------
# Pre-flight tool checks
#------------------------------------------------------------------------------
for cmd in wget sgdisk mkfs.ext4 mount tar dd partprobe lsblk blockdev gpg; do
  command -v "$cmd" >/dev/null 2>&1 || ERROR "Missing tool: $cmd"
done

[ -b "$DISK" ]        || ERROR "Block device '$DISK' not found"
[ -f "$PUBKEY_FILE" ] || ERROR "SSH pubkey file '$PUBKEY_FILE' missing"
PUBKEY=$(<"$PUBKEY_FILE")
[ -n "$PUBKEY" ]      || ERROR "SSH pubkey is empty"

#------------------------------------------------------------------------------
# Partition names (NVMe uses 'p')
#------------------------------------------------------------------------------
PART_PREFIX=""
case "$DISK" in /dev/nvme*) PART_PREFIX="p" ;; esac
PART_BIOS="${DISK}${PART_PREFIX}1"
PART_BOOT="${DISK}${PART_PREFIX}2"
PART_ROOT="${DISK}${PART_PREFIX}3"

#------------------------------------------------------------------------------
# 0) Clean up & warn LVM/RAID
#------------------------------------------------------------------------------
LOG "Cleaning old mounts"
umount -l "$ISO_MNT"  2>/dev/null || true
umount -l "$CHROOT"/* 2>/dev/null || true

MOUNTS=$(lsblk -n -o MOUNTPOINT "$DISK" "$PART_BIOS" "$PART_BOOT" "$PART_ROOT" \
         | grep -v '^$' || true)
[ -z "$MOUNTS" ] || ERROR "Partitions still mounted; please unmount first"

if blkid -s TYPE -o value "$DISK" | grep -Eq '^(LVM|LVM2_member|linux_raid)'; then
  WARN "Disk has existing LVM/RAID metadata—will be overwritten"
fi

echo
LOG "WARNING: This will ERASE ALL DATA on $DISK"
read -p "Type 'yes' to continue: " confirm
[ "$confirm" = "yes" ] || ERROR "Aborted"

#------------------------------------------------------------------------------
# 1) Download & verify Alpine ISO
#------------------------------------------------------------------------------
LOG "Finding latest Alpine $ISO_TYPE ISO"
BASE="https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/x86_64/"
PATTERN="alpine-${ISO_TYPE}-[0-9.]+-x86_64.iso"
LATEST=$(wget -qO- "$BASE" | grep -Eo "$PATTERN" | grep -v rc | sort -V | tail -1)
[ -n "$LATEST" ] || ERROR "No Alpine ISO found"
ISO_URL="$BASE$LATEST"

cd /root
if [ -f "$LATEST" ]; then
  LOG "Reusing ISO $LATEST"
else
  LOG "Downloading ISO, checksums & GPG key"
  attempts=1
  while [ $attempts -le 3 ]; do
    wget --progress=dot:giga \
      "$ISO_URL" "$ISO_URL.sha256" "$ISO_URL.asc" \
      "https://alpinelinux.org/keys/ncopa.asc" && break
    LOG "Attempt $attempts failed, retrying..."
    sleep 5
    attempts=$((attempts+1))
  done
fi

LOG "Verifying ISO"
sha256sum -c "${LATEST}.sha256"   || ERROR "SHA256 failed"
gpg --import ncopa.asc           &>/dev/null || ERROR "GPG import failed"
gpg --verify "${LATEST}.asc" "$LATEST" &>/dev/null || ERROR "GPG signature failed"

#------------------------------------------------------------------------------
# 2) Mount ISO & fetch apk-tools-static
#------------------------------------------------------------------------------
LOG "Mounting ISO"
mkdir -p "$ISO_MNT"
mount -o loop "/root/$LATEST" "$ISO_MNT" || ERROR "ISO mount failed"

LOG "Fetching apk-tools-static index"
IDX="/tmp/alpine-index.html"
attempts=1
while [ $attempts -le 3 ]; do
  rm -f "$IDX"
  wget --progress=dot:giga -O "$IDX" \
    "https://dl-cdn.alpinelinux.org/alpine/latest-stable/main/x86_64/" && break
  LOG "Index fetch attempt $attempts failed"
  sleep 5
  attempts=$((attempts+1))
done

APK_PKG=$(grep -Eo 'apk-tools-static-[0-9.]+(-r[0-9]+)?\.apk' "$IDX" | sort -V | tail -1)
rm -f "$IDX"
[ -n "$APK_PKG" ] || { APK_PKG="apk-tools-static-2.14.4.apk"; WARN "Falling back: $APK_PKG"; }

LOG "Downloading $APK_PKG"
attempts=1
while [ $attempts -le 3 ]; do
  rm -f "/root/$APK_PKG"
  wget --progress=dot:giga -O "/root/$APK_PKG" \
    "https://dl-cdn.alpinelinux.org/alpine/latest-stable/main/x86_64/$APK_PKG" && break
  LOG "APK fetch attempt $attempts failed"
  sleep 5
  attempts=$((attempts+1))
done

LOG "Extract apk.static"
mkdir -p /root/sbin
tar -C /root -xzf "/root/$APK_PKG" sbin/apk.static || ERROR "Extract failed"
chmod +x /root/sbin/apk.static
APK_BIN="/root/sbin/apk.static"
rm -f "/root/$APK_PKG"
umount "$ISO_MNT"

#------------------------------------------------------------------------------
# 3) Partition & format disk
#------------------------------------------------------------------------------
LOG "Partitioning $DISK"
sgdisk --zap-all     "$DISK"
sgdisk --mbrtogpt    "$DISK"
sgdisk -n1:1MiB:+1MiB -t1:EF02 -c1:"BIOS-GRUB"  "$DISK"
sgdisk -n2:0:+256MiB  -t2:8300 -c2:"alpine-boot" "$DISK"
sgdisk -n3:0:0        -t3:8300 -c3:"alpine-root" "$DISK"
partprobe "$DISK"
sleep 2

LOG "Verifying partitions"
for p in "$PART_BIOS" "$PART_BOOT" "$PART_ROOT"; do
  [ -b "$p" ] || ERROR "Missing partition $p"
done

LOG "Formatting filesystems"
mkfs.ext4 -F "$PART_BOOT" || ERROR "/boot format failed"
mkfs.ext4 -F "$PART_ROOT" || ERROR "/ format failed"

#------------------------------------------------------------------------------
# 4) Mount root & boot
#------------------------------------------------------------------------------
LOG "Mounting root"
mkdir -p "$CHROOT"
mount "$PART_ROOT" "$CHROOT" || ERROR "Mount root failed"

LOG "Mounting /boot"
mkdir -p "$CHROOT/boot"
mount "$PART_BOOT" "$CHROOT/boot" || ERROR "Mount /boot failed"

#------------------------------------------------------------------------------
# 5) Bootstrap Alpine base
#------------------------------------------------------------------------------
LOG "Bootstrapping alpine-base"
"$APK_BIN" \
  --repository "https://dl-cdn.alpinelinux.org/alpine/latest-stable/main" \
  --allow-untrusted -U --root "$CHROOT" --initdb \
  add alpine-base || ERROR "Bootstrap failed"

#------------------------------------------------------------------------------
# 6) Prepare chroot
#------------------------------------------------------------------------------
LOG "Bind-mount /dev /proc /sys & DNS"
for d in dev proc sys; do
  mount --bind "/$d" "$CHROOT/$d" || ERROR "Bind $d failed"
done
cp /etc/resolv.conf "$CHROOT/etc/resolv.conf"

#------------------------------------------------------------------------------
# 7) In-chroot config & GRUB
#------------------------------------------------------------------------------
# Pre-calc kernel package on host so no $ISO_TYPE in chroot
KERNEL_PKG="linux-virt"
[ "$ISO_TYPE" = "standard" ] && KERNEL_PKG="linux-lts"

LOG "Configuring in chroot and installing GRUB"
chroot "$CHROOT" /bin/sh -eux <<EOF
# /etc/apk/repositories
echo "https://dl-cdn.alpinelinux.org/alpine/latest-stable/main" > /etc/apk/repositories

# /etc/fstab
cat > /etc/fstab <<FSTAB
$PART_ROOT /      ext4 defaults 0 1
$PART_BOOT /boot  ext4 defaults 0 2
FSTAB

# Networking
IF=\$(ip -o link show 2>/dev/null | awk -F': ' '{print \$2}' | grep -v lo | head -1)
IF=\${IF:-eth0}
echo "INFO: Using interface '\$IF'" >&2
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

# Install kernel + GRUB
apk update
apk add "$KERNEL_PKG" grub grub-bios

# Install GRUB
grub-install "$DISK" > /tmp/grub-install.log 2>&1 || { cat /tmp/grub-install.log >&2; exit 1; }
grub-mkconfig -o /boot/grub/grub.cfg || { echo "grub-mkconfig failed" >&2; exit 1; }

# Sanity check
[ -s /boot/grub/grub.cfg ] || { echo "GRUB config missing!" >&2; exit 1; }
EOF

#------------------------------------------------------------------------------
# 8) Cleanup & reboot
#------------------------------------------------------------------------------
LOG "Cleaning up mounts"
for d in dev proc sys; do
  umount "$CHROOT/$d" 2>/dev/null || true
done
umount "$CHROOT/boot" 2>/dev/null || true
umount "$CHROOT" >/dev/null 2>&1 || true

if mount | grep -q "$CHROOT"; then
  WARN "Leftover mounts remain; system may be inconsistent."
  umount -f "$CHROOT"/{sys,proc,dev,boot} 2>/dev/null || true
fi

echo
LOG "INSTALL COMPLETE!"
LOG "Set $DISK as the boot device in your provider panel."
LOG "If you drop to rescue/PXE, re-order boot or force $DISK."
LOG "Check /boot/grub/grub.cfg and network inside Alpine if needed."
LOG "Sync & reboot in 5s..."
sync; sleep 5
reboot
