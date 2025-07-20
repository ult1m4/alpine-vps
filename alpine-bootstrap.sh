#!/usr/bin/env bash
#----------------------------------------------------------------------------
# alpine-install.sh – installs Alpine Linux on GPT+BIOS using GRUB
#
# Usage:   ./alpine-install.sh [-t virt|standard] <disk> <ssh-pubkey>
# Example: ./alpine-install.sh -t virt /dev/vda ~/.ssh/id_rsa.pub
#
# Requires host tools: wget, sgdisk, mkfs.ext4, mount, tar, dd,
#                      partprobe, lsblk, blockdev, gpg
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
# Pre-flight checks (host-side tools)
#------------------------------------------------------------------------------
for cmd in wget sgdisk mkfs.ext4 mount tar dd partprobe lsblk blockdev gpg; do
  command -v "$cmd" >/dev/null 2>&1 \
    || ERROR "Missing host tool: $cmd"
done

[ -b "$DISK" ]        || ERROR "Block device '$DISK' not found"
[ -f "$PUBKEY_FILE" ] || ERROR "SSH pubkey file '$PUBKEY_FILE' not found"
PUBKEY=$(<"$PUBKEY_FILE")
[ -n "$PUBKEY" ]      || ERROR "SSH pubkey file is empty"

#------------------------------------------------------------------------------
# Partition naming (NVMe uses 'p')
#------------------------------------------------------------------------------
PART_PREFIX=""
case "$DISK" in /dev/nvme*) PART_PREFIX="p" ;; esac
PART_BIOS="${DISK}${PART_PREFIX}1"
PART_BOOT="${DISK}${PART_PREFIX}2"
PART_ROOT="${DISK}${PART_PREFIX}3"

#------------------------------------------------------------------------------
# 0) Cleanup & RAID/LVM warning
#------------------------------------------------------------------------------
LOG "Cleaning up old mounts"
umount -l "$ISO_MNT" 2>/dev/null || true
umount -l "$CHROOT"/* 2>/dev/null || true

MOUNTS=$(lsblk -n -o MOUNTPOINT \
  "$DISK" "$PART_BIOS" "$PART_BOOT" "$PART_ROOT" \
  | grep -v '^$' || true)
[ -z "$MOUNTS" ] || ERROR "Partitions still mounted; unmount first."

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
  LOG "Reusing existing ISO: $LATEST"
else
  LOG "Downloading ISO, checksums & GPG key (3 attempts)"
  attempts=1
  while [ "$attempts" -le 3 ]; do
    wget --progress=dot:giga \
      "$ISO_URL" \
      "$ISO_URL.sha256" \
      "$ISO_URL.asc" \
      "https://alpinelinux.org/keys/ncopa.asc" && break
    LOG "ISO download attempt $attempts failed, retrying in 5s..."
    sleep 5
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
  LOG "Index fetch attempt $attempts failed, retrying..."
  sleep 5
  attempts=$((attempts + 1))
done

APK_PKG=$(grep -Eo 'apk-tools-static-[0-9.]+(-r[0-9]+)?\.apk' "$IDX" \
           | sort -V | tail -1)
rm -f "$IDX"
[ -n "$APK_PKG" ] \
  || { APK_PKG="apk-tools-static-2.14.4.apk"; WARN "No apk-tools-static found, falling back to $APK_PKG"; }

LOG "Downloading apk-tools-static: $APK_PKG"
attempts=1
while [ "$attempts" -le 3 ]; do
  rm -f "/root/$APK_PKG"
  wget --progress=dot:giga -O "/root/$APK_PKG" \
    "https://dl-cdn.alpinelinux.org/alpine/latest-stable/main/x86_64/$APK_PKG" && break
  LOG "APK download attempt $attempts failed, retrying..."
  sleep 5
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
# 3) Partition & format
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
for p in "$PART_BIOS" "$PART_BOOT" "$PART_ROOT"; do
  [ -b "$p" ] || ERROR "Partition $p missing"
done

LOG "Formatting /boot and /"
mkfs.ext4 -F "$PART_BOOT" || ERROR "mkfs.ext4 $PART_BOOT failed"
mkfs.ext4 -F "$PART_ROOT" || ERROR "mkfs.ext4 $PART_ROOT failed"

#------------------------------------------------------------------------------
# 4) Mount new filesystems
#------------------------------------------------------------------------------
LOG "Mounting root and boot"
mkdir -p "$CHROOT" "$CHROOT/boot"
[ -d "$CHROOT" ]       || ERROR "Failed to create $CHROOT"
[ -d "$CHROOT/boot" ]  || ERROR "Failed to create $CHROOT/boot"

LOG "Checking devices before mount: $PART_ROOT, $PART_BOOT"
[ -b "$PART_ROOT" ]    || ERROR "Partition $PART_ROOT not found"
[ -b "$PART_BOOT" ]    || ERROR "Partition $PART_BOOT not found"

## debug: show mountpoint directories (and save to a log for post-mortem)
ls -ld "$(dirname "$CHROOT")" "$CHROOT" "$CHROOT/boot" \
  | tee /tmp/mount-debug.log

mount "$PART_ROOT" "$CHROOT"       || { \
    echo "Mount-point detail:"; cat /tmp/mount-debug.log >&2; \
    ERROR "Mount $PART_ROOT failed: $(mount)"; }

mount "$PART_BOOT" "$CHROOT/boot"  || { \
    echo "Mount-point detail:"; cat /tmp/mount-debug.log >&2; \
    ERROR "Mount $PART_BOOT failed: $(mount)"; }

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
# 7) In-chroot configure & install GRUB
#------------------------------------------------------------------------------
LOG "Configuring in chroot + installing GRUB"
chroot "$CHROOT" /bin/sh -eux <<'EOF'
# repos
echo -e "https://dl-cdn.alpinelinux.org/alpine/latest-stable/main\n" > /etc/apk/repositories

# fstab
cat > /etc/fstab <<F
$PART_ROOT / ext4 defaults 0 1
$PART_BOOT /boot ext4 defaults 0 2
F

# networking
IF=$(ip -o link show | awk -F': ' '{print $2}' | grep -v lo | head -1)
[ -z "$IF" ] && { echo "WARN: No network interface found, defaulting to eth0" >&2; IF=eth0; }
cat > /etc/network/interfaces <<N
auto lo
iface lo inet loopback

auto $IF
iface $IF inet dhcp
N

# ssh keys
mkdir -p /root/.ssh
cat > /root/.ssh/authorized_keys <<K
$PUBKEY
K
chmod 700 /root/.ssh
chmod 600 /root/.ssh/authorized_keys

# kernel + grub
KERNEL_PKG="linux-virt"
[ "$ISO_TYPE" = "standard" ] && KERNEL_PKG="linux-lts"
apk update
apk add "$KERNEL_PKG" grub grub-bios

# install grub
grub-install "$DISK" > /tmp/grub.log 2>&1 \
  || { cat /tmp/grub.log >&2; exit 1; }
grub-mkconfig -o /boot/grub/grub.cfg \
  || { echo "grub-mkconfig failed" >&2; exit 1; }

# sanity check
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
  WARN "Failed to unmount some filesystems. System may be inconsistent."
  umount -f "$CHROOT"/{sys,proc,dev,boot,''} 2>/dev/null || true
fi

echo
LOG "Installation complete!"
LOG "CRITICAL: Set $DISK as boot device in your panel."
LOG "If you land in PXE/rescue, re-order boot or force $DISK."
LOG "Check /boot/grub/grub.cfg and network inside Alpine if you hit issues."
LOG "Syncing & rebooting in 5s..."
sync; sleep 5
reboot
