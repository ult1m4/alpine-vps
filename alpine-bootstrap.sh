#!/usr/bin/env bash
set -euo pipefail

#------------------------------------------------------------------------------
# Logging helpers
#------------------------------------------------------------------------------
LOG()   { echo "[$(date +%H:%M:%S)] $*"; }
WARN()  { echo "[$(date +%H:%M:%S)] WARN: $*" >&2; }
ERROR() { echo "[$(date +%H:%M:%S)] ERROR: $*" >&2; exit 1; }

#------------------------------------------------------------------------------
# Defaults & args
#------------------------------------------------------------------------------
ISO_TYPE="virt"       # "virt" or "standard"
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
shift $((OPTIND-1))

[ $# -eq 2 ] || ERROR "Usage: $0 [-t virt|standard] <disk> <ssh-pubkey>"
DISK=$1
PUBKEY_FILE=$2

#------------------------------------------------------------------------------
# Pre-flight (host-side tools)
#------------------------------------------------------------------------------
for cmd in wget sgdisk mkfs.ext4 mount tar extlinux dd partprobe lsblk blockdev gpg; do
  command -v "$cmd" >/dev/null 2>&1 || ERROR "Missing host tool: $cmd"
done

[ -b "$DISK" ]        || ERROR "Block device '$DISK' not found"
[ -f "$PUBKEY_FILE" ] || ERROR "SSH pubkey file '$PUBKEY_FILE' not found"
PUBKEY=$(<"$PUBKEY_FILE")
[ -n "$PUBKEY" ]      || ERROR "SSH pubkey file is empty"

# NVMe partition suffix
PART_PREFIX=""
case "$DISK" in /dev/nvme*) PART_PREFIX="p" ;; esac
PART_BIOS="${DISK}${PART_PREFIX}1"
PART_BOOT="${DISK}${PART_PREFIX}2"
PART_ROOT="${DISK}${PART_PREFIX}3"

LOG "Ensuring $DISK isn't in use"
umount -l "$ISO_MNT" 2>/dev/null || true
umount -l "$CHROOT"/* 2>/dev/null   || true
MOUNTS=$(lsblk -n -o MOUNTPOINT "$DISK" "$PART_BIOS" "$PART_BOOT" "$PART_ROOT" \
         | grep -v '^$' || true)
[ -z "$MOUNTS" ] || ERROR "Some partitions on $DISK are still mounted"

echo
LOG "WARNING: This will ERASE ALL DATA on $DISK and install Alpine Linux."
read -p "Type 'yes' to proceed: " confirm
[ "$confirm" = "yes" ] || ERROR "Aborted by user"

#------------------------------------------------------------------------------
# 1) Download & verify ISO
#------------------------------------------------------------------------------
LOG "Picking Alpine $ISO_TYPE ISO"
BASE="https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/x86_64/"
PATTERN="alpine-${ISO_TYPE}-[0-9.]+-x86_64.iso"
LATEST=$(wget -qO- "$BASE" \
         | grep -Eo "$PATTERN" \
         | grep -v rc \
         | sort -V \
         | tail -1)
[ -n "$LATEST" ] || ERROR "Could not find Alpine $ISO_TYPE ISO"
ISO_URL="$BASE$LATEST"

cd /root
if [ -f "$LATEST" ]; then
  LOG "Reusing ISO: $LATEST"
else
  LOG "Downloading ISO + checksums + GPG key (up to 3 tries)"
  attempts=1
  while [ "$attempts" -le 3 ]; do
    wget --progress=dot:giga \
      "$ISO_URL" \
      "$ISO_URL.sha256" \
      "$ISO_URL.asc" \
      "https://alpinelinux.org/keys/ncopa.asc" && break

    [ "$attempts" -lt 3 ] \
      && { LOG "Attempt $attempts failed, retrying in 5s…"; sleep 5; } \
      || ERROR "Download failed after 3 attempts"
    attempts=$((attempts+1))
  done
fi

LOG "Verifying ISO"
sha256sum -c "${LATEST}.sha256"   || ERROR "SHA256 mismatch"
gpg --import ncopa.asc           &>/dev/null || ERROR "GPG import failed"
gpg --verify "${LATEST}.asc" "$LATEST" &>/dev/null \
                                 || ERROR "GPG signature failed"

#------------------------------------------------------------------------------
# 2) Mount ISO & grab apk.static
#------------------------------------------------------------------------------
LOG "Mounting ISO at $ISO_MNT"
mkdir -p "$ISO_MNT"
mount -o loop "/root/$LATEST" "$ISO_MNT" || ERROR "ISO mount failed"

LOG "Copying apk.static from ISO"
APK_BIN="/root/sbin/apk.static"
mkdir -p /root/sbin

# Try the standard path, else find it
if [ -f "$ISO_MNT/sbin/apk.static" ]; then
  cp "$ISO_MNT"/sbin/apk.static "$APK_BIN"
else
  FOUND=$(find "$ISO_MNT" -type f -name apk.static | head -1 || true)
  [ -n "$FOUND" ] && cp "$FOUND" "$APK_BIN" \
    || ERROR "apk.static not found on ISO"
fi
chmod +x "$APK_BIN"
umount "$ISO_MNT"

#------------------------------------------------------------------------------
# 3) Partition & format disk
#------------------------------------------------------------------------------
LOG "Partitioning $DISK (GPT + BIOS-GRUB + /boot + /)"
sgdisk --zap-all "$DISK"
sgdisk --mbrtogpt "$DISK"
# BIOS-GRUB slice: 1 MiB EF02
sgdisk -n1:1MiB:+1MiB   -t1:EF02 -c1:"BIOS-GRUB" "$DISK"
# /boot: 256 MiB ext4
sgdisk -n2:0:+256MiB    -t2:8300 -c2:"alpine-boot" "$DISK"
# rest: rootfs ext4
sgdisk -n3:0:0          -t3:8300 -c3:"alpine-root" "$DISK"
partprobe "$DISK"

LOG "Formatting partitions"
mkfs.ext4 -F "$PART_BOOT" || ERROR "mkfs.ext4 $PART_BOOT failed"
mkfs.ext4 -F "$PART_ROOT" || ERROR "mkfs.ext4 $PART_ROOT failed"

#------------------------------------------------------------------------------
# 4) Mount new filesystems
#------------------------------------------------------------------------------
LOG "Mounting root & boot"
mkdir -p "$CHROOT" "$CHROOT/boot"
mount "$PART_ROOT" "$CHROOT"     || ERROR "Mount $PART_ROOT failed"
mount "$PART_BOOT" "$CHROOT/boot" || ERROR "Mount $PART_BOOT failed"

#------------------------------------------------------------------------------
# 5) Bootstrap Alpine base
#------------------------------------------------------------------------------
LOG "Bootstrapping alpine-base"
"$APK_BIN" \
  --repository "https://dl-cdn.alpinelinux.org/alpine/latest-stable/main" \
  --allow-untrusted -U --root "$CHROOT" --initdb \
  add alpine-base || ERROR "alpine-base bootstrap failed"

#------------------------------------------------------------------------------
# 6) Prepare chroot env
#------------------------------------------------------------------------------
LOG "Bind-mounting and DNS"
for d in dev proc sys; do
  mount --bind "/$d" "$CHROOT/$d" || ERROR "Bind $d failed"
done
cp /etc/resolv.conf "$CHROOT/etc/resolv.conf" || ERROR "Copy resolv.conf failed"

#------------------------------------------------------------------------------
# 7) Chroot: config & GRUB
#------------------------------------------------------------------------------
LOG "Chroot: configure Alpine + install GRUB"
chroot "$CHROOT" /bin/sh -eux <<EOF
# Repos
cat > /etc/apk/repositories <<REPOS
https://dl-cdn.alpinelinux.org/alpine/latest-stable/main
https://dl-cdn.alpinelinux.org/alpine/latest-stable/community
REPOS

# fstab
cat > /etc/fstab <<FSTAB
$PART_ROOT /      ext4 defaults 0 1
$PART_BOOT /boot  ext4 defaults 0 2
FSTAB

# Networking
IF=\$(ip -o link show | awk -F': ' '{print \$2}' | grep -v lo | head -1)
[ -z "\$IF" ] && { WARN "No network interface found, defaulting to eth0"; IF=eth0; }
cat > /etc/network/interfaces <<NETCFG
auto lo
iface lo inet loopback

auto \$IF
iface \$IF inet dhcp
NETCFG

# SSH key
mkdir -p /root/.ssh
cat > /root/.ssh/authorized_keys <<KEY
$PUBKEY
KEY
chmod 700 /root/.ssh
chmod 600 /root/.ssh/authorized_keys

# Kernel package
KPKG="linux-virt"
[ "\$ISO_TYPE" = "standard" ] && KPKG="linux-lts"

# Install kernel + GRUB
apk update
apk add "\$KPKG" grub grub-bios

# Install GRUB & generate cfg
grub-install "$DISK"
grub-mkconfig -o /boot/grub/grub.cfg
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
  WARN "Forcing leftover unmounts"
  umount -f "$CHROOT/sys" "$CHROOT/proc" "$CHROOT/dev" \
        "$CHROOT/boot" "$CHROOT" 2>/dev/null || true
fi

LOG "Install complete. Ensure your VPS boots from $DISK (not PXE)."
LOG "Syncing & rebooting in 5s…"
sync; sleep 5
reboot
