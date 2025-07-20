#!/usr/bin/env bash
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
ISO_TYPE="virt"       # "virt" or "standard"
CHROOT="/mnt/alpine"
ISO_MNT="/mnt/iso"

while getopts ":t:" opt; do
  case $opt in
    t) [[ $OPTARG =~ ^(virt|standard)$ ]] \
         || ERROR "Invalid ISO type '$OPTARG', use 'virt' or 'standard'"
       ISO_TYPE=$OPTARG
       ;;
    \?) ERROR "Invalid option -$OPTARG" ;;
  esac
done
shift $((OPTIND-1))

[ $# -eq 2 ] || ERROR "Usage: $0 [-t virt|standard] <disk> <ssh-pubkey>"
DISK=$1
PUBKEY_FILE=$2

#------------------------------------------------------------------------------
# Pre-flight checks
#------------------------------------------------------------------------------
for cmd in wget sgdisk mkfs.ext4 mount tar extlinux dd partprobe lsblk blockdev \
           gpg apk; do
  command -v "$cmd" >/dev/null 2>&1 || ERROR "Missing required tool: $cmd"
done

[ -b "$DISK" ]        || ERROR "Block device '$DISK' not found"
[ -f "$PUBKEY_FILE" ] || ERROR "SSH pubkey file '$PUBKEY_FILE' not found"
PUBKEY=$(<"$PUBKEY_FILE")
[ -n "$PUBKEY" ]      || ERROR "SSH pubkey file is empty"

# NVMe disks use 'p' suffix for partitions
PART_PREFIX=""
case "$DISK" in
  /dev/nvme*) PART_PREFIX="p" ;;
esac
PART_BIOS="${DISK}${PART_PREFIX}1"
PART_BOOT="${DISK}${PART_PREFIX}2"
PART_ROOT="${DISK}${PART_PREFIX}3"

LOG "Ensuring no part of $DISK is mounted"
# Unmount any leftovers
umount -l "$ISO_MNT"           2>/dev/null || true
umount -l "$CHROOT"/*          2>/dev/null || true

# Check via lsblk if any MOUNTPOINT exists on disk or its partitions
MOUNTS=$(lsblk -n -o MOUNTPOINT "$DISK" \
               "$PART_BIOS" \
               "$PART_BOOT" \
               "$PART_ROOT" \
         | grep -v '^$' || true)
[ -z "$MOUNTS" ] || ERROR "Some partitions on $DISK are mounted; unmount them first."

echo
LOG "WARNING: This will ERASE ALL DATA on $DISK and install Alpine Linux."
read -p "Type 'yes' to proceed: " confirm
[ "$confirm" = "yes" ] || ERROR "Aborted by user"

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
  LOG "Downloading ISO, checksums, and GPG key (up to 3 attempts)"
  attempts=1
  while [ "$attempts" -le 3 ]; do
    wget --progress=dot:giga \
      "$ISO_URL" \
      "$ISO_URL.sha256" \
      "$ISO_URL.asc" \
      "https://alpinelinux.org/keys/ncopa.asc" && break

    if [ "$attempts" -lt 3 ]; then
      LOG "Download attempt $attempts failed, retrying in 5s..."
      sleep 5
    else
      ERROR "Download failed after 3 attempts"
    fi
    attempts=$((attempts + 1))
  done
fi

LOG "Verifying ISO integrity"
sha256sum -c "${LATEST}.sha256"   || ERROR "SHA256 check failed"
gpg --import ncopa.asc           &>/dev/null || ERROR "GPG import failed"
gpg --verify "${LATEST}.asc" "$LATEST" &>/dev/null || ERROR "Signature verification failed"

#------------------------------------------------------------------------------
# 2) Mount ISO & extract apk.static
#------------------------------------------------------------------------------
LOG "Mounting ISO at $ISO_MNT"
mkdir -p "$ISO_MNT"
mount -o loop "/root/$LATEST" "$ISO_MNT" || ERROR "ISO mount failed"

LOG "Extracting apk.static from ISO"
APK_BIN="/root/sbin/apk.static"
mkdir -p /root/sbin
tar -xzf "$ISO_MNT"/r*/APKINDEX.tar.gz sbin/apk.static \
  --strip-components=1 -C /root      || ERROR "Failed to extract apk.static"
chmod +x "$APK_BIN"
umount "$ISO_MNT"

#------------------------------------------------------------------------------
# 3) Partition & format disk (GPT + BIOS-boot + /boot + /)
#------------------------------------------------------------------------------
LOG "Partitioning $DISK (GPT + BIOS-boot(1MiB) + 256MiB /boot + rest /)"
sgdisk --zap-all        "$DISK"
sgdisk --mbrtogpt       "$DISK"
# 1MiB BIOS-GRUB slice (EF02)
sgdisk -n1:1MiB:+1MiB   -t1:EF02 -c1:"BIOS-GRUB" "$DISK"
# 256MiB /boot
sgdisk -n2:0:+256MiB    -t2:8300 -c2:"alpine-boot" "$DISK"
# Remaining / 
sgdisk -n3:0:0          -t3:8300 -c3:"alpine-root" "$DISK"
partprobe "$DISK"

LOG "Formatting partitions"
mkfs.ext4 -F "$PART_BOOT" || ERROR "mkfs.ext4 on $PART_BOOT failed"
mkfs.ext4 -F "$PART_ROOT" || ERROR "mkfs.ext4 on $PART_ROOT failed"

#------------------------------------------------------------------------------
# 4) Mount target filesystems
#------------------------------------------------------------------------------
LOG "Mounting root and boot"
mkdir -p "$CHROOT" "$CHROOT/boot"
mount "$PART_ROOT" "$CHROOT"     || ERROR "Mount $PART_ROOT failed"
mount "$PART_BOOT" "$CHROOT/boot" || ERROR "Mount $PART_BOOT failed"

#------------------------------------------------------------------------------
# 5) Bootstrap Alpine base
#------------------------------------------------------------------------------
LOG "Bootstrapping Alpine base"
"$APK_BIN" \
  --repository "https://dl-cdn.alpinelinux.org/alpine/latest-stable/main" \
  --allow-untrusted -U --root "$CHROOT" --initdb \
  add alpine-base || ERROR "alpine-base bootstrap failed"

#------------------------------------------------------------------------------
# 6) Prepare chroot env
#------------------------------------------------------------------------------
LOG "Bind-mounting /dev, /proc, /sys and copying DNS"
for d in dev proc sys; do
  mount --bind "/$d" "$CHROOT/$d" || ERROR "Bind mount $d failed"
done
cp /etc/resolv.conf "$CHROOT/etc/resolv.conf" || ERROR "Copy resolv.conf failed"

#------------------------------------------------------------------------------
# 7) Chroot: configure system & install GRUB
#------------------------------------------------------------------------------
LOG "Configuring Alpine in chroot and installing GRUB"
chroot "$CHROOT" /bin/sh -eux <<EOF
# 7.1) Repositories
cat > /etc/apk/repositories <<REPOS
https://dl-cdn.alpinelinux.org/alpine/latest-stable/main
https://dl-cdn.alpinelinux.org/alpine/latest-stable/community
REPOS

# 7.2) fstab
cat > /etc/fstab <<FSTAB
$PART_ROOT /      ext4 defaults 0 1
$PART_BOOT /boot  ext4 defaults 0 2
FSTAB

# 7.3) Networking (DHCP)
IF=\$(ip -o link show | awk -F': ' '{print \$2}' | grep -v lo | head -1)
[ -z "\$IF" ] && IF=eth0
cat > /etc/network/interfaces <<NETCFG
auto lo
iface lo inet loopback

auto \$IF
iface \$IF inet dhcp
NETCFG

# 7.4) SSH authorized_keys
mkdir -p /root/.ssh
cat > /root/.ssh/authorized_keys <<KEY
$PUBKEY
KEY
chmod 700 /root/.ssh
chmod 600 /root/.ssh/authorized_keys

# 7.5) Select kernel package
KERNEL_PKG="linux-virt"
[ "\$ISO_TYPE" = "standard" ] && KERNEL_PKG="linux-lts"

# 7.6) Install kernel + GRUB
apk update
apk add "\$KERNEL_PKG" grub grub-bios

# 7.7) Install GRUB to MBR and generate config
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

# Force unmount leftovers in reverse order
if mount | grep -q "$CHROOT"; then
  WARN "Some mounts remained; forcing unmount"
  umount -f "$CHROOT/sys" "$CHROOT/proc" "$CHROOT/dev" \
        "$CHROOT/boot" "$CHROOT" 2>/dev/null || true
fi

LOG "Alpine Linux installation completed successfully!"
LOG "Make sure your VPS is set to boot from $DISK (not PXE or rescue)."

LOG "Syncing and rebooting in 5 seconds..."
sync; sleep 5
reboot
