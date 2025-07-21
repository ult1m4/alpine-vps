#!/usr/bin/env bash
#----------------------------------------------------------------------------
# alpine-bootstrap.sh – installs Alpine Linux on a GPT disk with BIOS/GRUB
#
# Description: This script automates the installation of Alpine Linux onto a
#              single disk, intended for VPS environments without custom ISO
#              support. It partitions the disk, bootstraps a base system,
#              and configures it to be bootable with GRUB in BIOS mode.
#
# Usage:   ./alpine-bootstrap.sh [-t virt|standard] <disk> <ssh-pubkey>
# Example: ./alpine-bootstrap.sh -t virt /dev/vda ~/.ssh/id_rsa.pub
#
# Requires: wget, sgdisk, mkfs.ext4, mount, tar, dd, partprobe, lsblk, blockdev, gpg
#----------------------------------------------------------------------------

set -euo pipefail

#------------------------------------------------------------------------------
# Logging functions
#------------------------------------------------------------------------------
LOG()   { echo "[$(date +%H:%M:%S)] INFO: $*"; }
WARN()  { echo "[$(date +%H:%M:%S)] WARN: $*" >&2; }
ERROR() { echo "[$(date +%H:%M:%S)] ERROR: $*" >&2; exit 1; }

#------------------------------------------------------------------------------
# Defaults & CLI parsing
#------------------------------------------------------------------------------
ISO_TYPE="virt"
CHROOT="/mnt/alpine"

while getopts ":t:" opt; do
  case $opt in
    t) [[ $OPTARG =~ ^(virt|standard)$ ]] || ERROR "Invalid ISO type '$OPTARG'. Use 'virt' or 'standard'."
       ISO_TYPE=$OPTARG ;;
    \?) ERROR "Invalid option -$OPTARG" ;;
  esac
done
shift $((OPTIND - 1))

[ $# -eq 2 ] || ERROR "Usage: $0 [-t virt|standard] <disk> <ssh-pubkey>"
DISK=$1
PUBKEY_FILE=$2

#------------------------------------------------------------------------------
# Pre-flight tool and input checks
#------------------------------------------------------------------------------
LOG "Performing pre-flight checks..."
for cmd in wget sgdisk mkfs.ext4 mount tar dd partprobe lsblk blockdev gpg; do
  command -v "$cmd" >/dev/null 2>&1 || ERROR "Missing required tool: $cmd"
done

[ -b "$DISK" ]        || ERROR "Block device '$DISK' not found. Please verify the device path."
[ -f "$PUBKEY_FILE" ] || ERROR "SSH public key file '$PUBKEY_FILE' not found."
PUBKEY=$(<"$PUBKEY_FILE")
[ -n "$PUBKEY" ]      || ERROR "SSH public key file is empty."

#------------------------------------------------------------------------------
# Define partition variables based on disk type (SATA/NVMe)
#------------------------------------------------------------------------------
PART_PREFIX=""
case "$DISK" in /dev/nvme*) PART_PREFIX="p" ;; esac
PART_BIOS="${DISK}${PART_PREFIX}1"
PART_BOOT="${DISK}${PART_PREFIX}2"
PART_ROOT="${DISK}${PART_PREFIX}3"

#------------------------------------------------------------------------------
# 0) Clean up previous runs & warn the user
#------------------------------------------------------------------------------
LOG "Cleaning up any old mounts..."
umount -l "$CHROOT/boot" 2>/dev/null || true
umount -l "$CHROOT/dev" 2>/dev/null || true
umount -l "$CHROOT/proc" 2>/dev/null || true
umount -l "$CHROOT/sys" 2>/dev/null || true
umount -l "$CHROOT" 2>/dev/null || true

MOUNTS=$(lsblk -n -o MOUNTPOINT "$DISK" 2>/dev/null | grep -v '^$' || true)
[ -z "$MOUNTS" ] || ERROR "Partitions on $DISK are still mounted. Please unmount first."

if blkid -s TYPE -o value "$DISK" 2>/dev/null | grep -Eq '^(LVM|LVM2_member|linux_raid)'; then
  WARN "Disk appears to have existing LVM/RAID metadata—this will be overwritten."
fi

echo
LOG "!!! WARNING: This script will ERASE ALL DATA on $DISK !!!"
read -p "Type 'yes' to confirm and continue: " confirm
[ "$confirm" = "yes" ] || ERROR "Operation aborted by user."

#------------------------------------------------------------------------------
# 1) Download & verify Alpine ISO
#------------------------------------------------------------------------------
LOG "Finding latest Alpine $ISO_TYPE ISO..."
BASE_URL="https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/x86_64/"
PATTERN="alpine-${ISO_TYPE}-[0-9.]+-x86_64.iso"
LATEST_ISO=$(wget -qO- "$BASE_URL" | grep -Eo "$PATTERN" | grep -v 'rc' | sort -V | tail -1)
[ -n "$LATEST_ISO" ] || ERROR "Could not find the latest Alpine $ISO_TYPE ISO."
ISO_URL="${BASE_URL}${LATEST_ISO}"

cd /root
if [ -f "$LATEST_ISO" ]; then
  LOG "Reusing existing ISO: $LATEST_ISO"
else
  LOG "Downloading ISO, checksum, and signature..."
  wget --progress=dot:giga "$ISO_URL" "$ISO_URL.sha256" "$ISO_URL.asc" "https://alpinelinux.org/keys/ncopa.asc" \
    || ERROR "Download failed. Please check network and try again."
fi

LOG "Verifying ISO integrity and signature..."
sha256sum -c "${LATEST_ISO}.sha256" || ERROR "SHA256 checksum verification failed."
gpg --import ncopa.asc &>/dev/null || WARN "Could not import GPG key (ncopa.asc)."
gpg --verify "${LATEST_ISO}.asc" "$LATEST_ISO" || ERROR "GPG signature verification failed."

#------------------------------------------------------------------------------
# 2) Fetch apk-tools-static for bootstrapping
#------------------------------------------------------------------------------
LOG "Fetching apk-tools-static..."
APK_TOOLS_URL="https://dl-cdn.alpinelinux.org/alpine/latest-stable/main/x86_64/"
APK_TOOLS_PKG=$(wget -qO- "$APK_TOOLS_URL" | grep -Eo 'apk-tools-static-[0-9.]+(-r[0-9]+)?\.apk' | sort -V | tail -1)
[ -n "$APK_TOOLS_PKG" ] || { APK_TOOLS_PKG="apk-tools-static-2.14.4.apk"; WARN "Could not find latest apk-tools-static, falling back to $APK_TOOLS_PKG"; }

LOG "Downloading $APK_TOOLS_PKG..."
wget --progress=dot:giga -O "/root/$APK_TOOLS_PKG" "${APK_TOOLS_URL}${APK_TOOLS_PKG}" \
  || ERROR "Failed to download apk-tools-static."

LOG "Extracting apk.static binary..."
mkdir -p /root/sbin
tar -C /root -xzf "/root/$APK_TOOLS_PKG" sbin/apk.static || ERROR "Failed to extract apk.static."
chmod +x /root/sbin/apk.static
APK_BIN="/root/sbin/apk.static"
rm -f "/root/$APK_TOOLS_PKG"

#------------------------------------------------------------------------------
# 3) Partition & format the disk
#------------------------------------------------------------------------------
LOG "Wiping and partitioning $DISK..."
sgdisk --zap-all     "$DISK"
sgdisk --mbrtogpt    "$DISK"
sgdisk -n1:0:+1MiB   -t1:EF02 -c1:"BIOS-GRUB"  "$DISK"
sgdisk -n2:0:+256MiB -t2:8300 -c2:"alpine-boot" "$DISK"
sgdisk -n3:0:0       -t3:8300 -c3:"alpine-root" "$DISK"
partprobe "$DISK"
sleep 2 # Give the kernel a moment to see the new partitions

LOG "Verifying partitions were created..."
for p in "$PART_BIOS" "$PART_BOOT" "$PART_ROOT"; do
  [ -b "$p" ] || ERROR "Partition $p was not created successfully."
done

LOG "Formatting filesystems..."
mkfs.ext4 -F -L "alpine-boot" "$PART_BOOT" || ERROR "Formatting /boot partition failed."
mkfs.ext4 -F -L "alpine-root" "$PART_ROOT" || ERROR "Formatting / (root) partition failed."

#------------------------------------------------------------------------------
# 4) Mount filesystems and bootstrap the base system
#------------------------------------------------------------------------------
LOG "Mounting new filesystems at $CHROOT..."
mkdir -p "$CHROOT"
mount "$PART_ROOT" "$CHROOT" || ERROR "Mounting root filesystem failed."
mkdir -p "$CHROOT/boot"
mount "$PART_BOOT" "$CHROOT/boot" || ERROR "Mounting boot filesystem failed."

LOG "Bootstrapping Alpine base system..."
"$APK_BIN" \
  --repository "https://dl-cdn.alpinelinux.org/alpine/latest-stable/main" \
  --allow-untrusted -U --root "$CHROOT" --initdb \
  add alpine-base || ERROR "Bootstrap with apk-tools-static failed."

#------------------------------------------------------------------------------
# 5) Prepare and enter the chroot environment
#------------------------------------------------------------------------------
LOG "Preparing chroot environment (binding mounts, copying DNS config)..."
for d in dev proc sys; do
  mount --bind "/$d" "$CHROOT/$d" || ERROR "Binding /$d failed."
done
cp /etc/resolv.conf "$CHROOT/etc/resolv.conf"

#------------------------------------------------------------------------------
# 6) Configure the system from within the chroot
#------------------------------------------------------------------------------
# Define kernel‐specific variables based on ISO_TYPE
KERNEL_SUFFIX="virt"
[ "$ISO_TYPE" = "standard" ] && KERNEL_SUFFIX="lts"
KERNEL_PKG="linux-$KERNEL_SUFFIX"
VMLINUZ_NAME="vmlinuz-$KERNEL_SUFFIX"
INITRAMFS_NAME="initramfs-$KERNEL_SUFFIX"

# Host‐side: grab PARTUUIDs and FS UUID
ROOT_PARTUUID=$(blkid -s PARTUUID -o value "$PART_ROOT")
BOOT_PARTUUID=$(blkid -s PARTUUID -o value "$PART_BOOT")
BOOT_FS_UUID=$(blkid -s UUID     -o value "$PART_BOOT")
[ -n "$ROOT_PARTUUID" ] || ERROR "Can't determine root PARTUUID"
[ -n "$BOOT_PARTUUID" ] || ERROR "Can't determine boot PARTUUID"
[ -n "$BOOT_FS_UUID"   ] || ERROR "Can't determine boot FS UUID"

LOG "Entering chroot to install kernel, initramfs & GRUB"

chroot "$CHROOT" /bin/sh -eux <<EOF
  # 1) Setup APK repos
  cat > /etc/apk/repositories <<REPOS
https://dl-cdn.alpinelinux.org/alpine/latest-stable/main
https://dl-cdn.alpinelinux.org/alpine/latest-stable/community
REPOS
  apk update

  # 2) Write /etc/fstab with PARTUUIDs
  cat > /etc/fstab <<FSTAB
PARTUUID=$ROOT_PARTUUID /      ext4 defaults,noatime 0 1
PARTUUID=$BOOT_PARTUUID /boot  ext4 defaults,noatime 0 2
FSTAB

  # 3) Networking (DHCP)
  IFACE=\$(ip -o link show | awk -F': ' '{print \$2}' | grep -v lo | head -1)
  IFACE=\${IFACE:-eth0}
  cat > /etc/network/interfaces <<NETCFG
auto lo
iface lo inet loopback

auto \$IFACE
iface \$IFACE inet dhcp
NETCFG

  # 4) SSH access
  mkdir -p /root/.ssh && chmod 700 /root/.ssh
  cat > /root/.ssh/authorized_keys <<KEY
$PUBKEY
KEY
  chmod 600 /root/.ssh/authorized_keys
  apk add openssh-server
  rc-update add sshd default

  # 5) Install kernel & GRUB
  apk add "$KERNEL_PKG" grub grub-bios

  # 6) Detect kernel version (avoid unset errors)
  echo "INFO: detecting kernel version for $KERNEL_PKG" >&2
  KERNEL_VERSION=""
  if [ -L "/boot/vmlinuz-$KERNEL_SUFFIX" ]; then
    TARGET=\$(readlink -f "/boot/vmlinuz-$KERNEL_SUFFIX")
    KERNEL_VERSION="\${TARGET##*/vmlinuz-}"
  else
    KERNEL_VERSION="\$(ls /lib/modules | sort -V | tail -n1)"
  fi
  [ -n "\$KERNEL_VERSION" ] || { echo "ERROR: kernel version not found" >&2; exit 1; }

  # 7) Build initramfs (sysroot + ext4 + virtio drivers)
  mkinitfs \
    -o "/boot/$INITRAMFS_NAME" \
    -k "\$KERNEL_VERSION" \
    -f "base modules ext4" \
    -t "virtio_blk virtio_scsi virtio_net" \
    || { echo "ERROR: mkinitfs failed" >&2; exit 1; }

  # 8) Install GRUB with explicit module path
  grub-install \
    --target=i386-pc \
    --boot-directory=/boot \
    --modules-path=/usr/lib/grub/i386-pc \
    --modules=part_gpt ext4 search_fs_uuid \
    "$DISK" \
    || { echo "ERROR: grub-install failed" >&2; exit 1; }

  # 9) Write a static grub.cfg (single‐line linux stanza)
  mkdir -p /boot/grub
  cat > /boot/grub/grub.cfg <<GRUBCFG
set default=0
set timeout=2

menuentry "Alpine Linux" {
    insmod part_gpt
    insmod ext4
    insmod search_fs_uuid
    search --no-floppy --fs-uuid --set=root $BOOT_FS_UUID
    linux /$VMLINUZ_NAME root=PARTUUID=$ROOT_PARTUUID ro rootfstype=ext4 modules=ext4 rootdelay=30 quiet
    initrd /$INITRAMFS_NAME
}
GRUBCFG

  # 10) Sanity checks
  test -s "/boot/$VMLINUZ_NAME"    || { echo "ERROR: kernel missing" >&2; exit 1; }
  test -s "/boot/$INITRAMFS_NAME"  || { echo "ERROR: initramfs missing" >&2; exit 1; }
  grep -q "$BOOT_FS_UUID" /boot/grub/grub.cfg \
      || { echo "ERROR: FS UUID mismatch in grub.cfg" >&2; exit 1; }
  grep -q "root=PARTUUID=$ROOT_PARTUUID" /boot/grub/grub.cfg \
      || { echo "ERROR: root PARTUUID mismatch in grub.cfg" >&2; exit 1; }

  echo "INFO: Chroot configuration complete." >&2
EOF

#------------------------------------------------------------------------------
# 7) Final cleanup and reboot instructions
#------------------------------------------------------------------------------
LOG "Unmounting all filesystems..."
umount "$CHROOT/boot"
umount "$CHROOT/dev"
umount "$CHROOT/proc"
umount "$CHROOT/sys"
umount "$CHROOT"

echo
LOG "*********************************************************************"
LOG "                         INSTALL COMPLETE!                           "
LOG "*********************************************************************"
LOG "The script has finished. Please ensure your VPS is configured to"
LOG "boot from disk '$DISK' in its control panel."
LOG
LOG "System will sync and reboot in 10 seconds..."
LOG "*********************************************************************"
sync
sleep 10
reboot
