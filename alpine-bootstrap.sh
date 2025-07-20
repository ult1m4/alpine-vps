#!/usr/bin/env bash
set -euo pipefail

# Logging functions
LOG()   { echo "[$(date +%H:%M:%S)] $*" >&1; }
WARN()  { echo "[$(date +%H:%M:%S)] WARN: $*" >&2; }
ERROR() { echo "[$(date +%H:%M:%S)] ERROR: $*" >&2; exit 1; }

# Defaults
ISO_TYPE="virt"       # "virt" or "standard"
CHROOT="/mnt/alpine"
ISO_MNT="/mnt/iso"

# Parse options
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

# Usage
[ $# -eq 2 ] || ERROR "Usage: $0 [-t virt|standard] <disk> <ssh-pubkey-file>
Example: $0 -t virt /dev/vda /root/id_ed25519.pub"
DISK=$1
PUBKEY_FILE=$2

# Check dependencies
for cmd in wget sgdisk mkfs.ext4 mount tar extlinux dd partprobe lsblk blockdev gpg; do
  command -v "$cmd" >/dev/null 2>&1 || ERROR "Missing required tool: $cmd"
done

# Validate inputs
[ -b "$DISK" ]        || ERROR "Block device '$DISK' not found"
[ -f "$PUBKEY_FILE" ] || ERROR "SSH pubkey file '$PUBKEY_FILE' not found"
PUBKEY=$(<"$PUBKEY_FILE")
[ -n "$PUBKEY" ]      || ERROR "SSH pubkey file is empty"

# Determine partition suffix (nvme uses 'p')
PART_PREFIX=""
[[ $DISK =~ nvme ]] && PART_PREFIX="p"
PART1="${DISK}${PART_PREFIX}1"
PART2="${DISK}${PART_PREFIX}2"

# Verify unmounted
LOG "Ensuring $DISK and partitions are unmounted"
if lsblk -n -o MOUNTPOINT "$DISK" | grep -q .; then
  ERROR "$DISK is mounted"
fi
for p in "${DISK}${PART_PREFIX}"*; do
  [ -b "$p" ] || continue
  if lsblk -n -o MOUNTPOINT "$p" | grep -q .; then
    ERROR "Partition $p is mounted"
  fi
done

# Cleanup old mounts/data
LOG "Cleaning up previous mounts and data"
umount -l "$ISO_MNT"           2>/dev/null || true
umount -l "$CHROOT/dev"        2>/dev/null || true
umount -l "$CHROOT/proc"       2>/dev/null || true
umount -l "$CHROOT/sys"        2>/dev/null || true
umount -l "$CHROOT/boot"       2>/dev/null || true
rm -rf "$CHROOT" "$ISO_MNT"

# Confirm destructive action
echo
LOG "WARNING: This will ERASE ALL DATA on $DISK and install Alpine Linux."
read -p "Type 'yes' to proceed: " confirm
[ "$confirm" = "yes" ] || ERROR "Aborted by user"

# -------------------------------------------------------------------
# 1) Download & verify ISO
# -------------------------------------------------------------------
LOG "Selecting Alpine $ISO_TYPE ISO"
BASE="https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/x86_64/"
PATTERN="alpine-${ISO_TYPE}-[0-9.]+-x86_64.iso"

LATEST=$(wget --progress=dot:giga -qO- "$BASE" \
  | grep -Eo "$PATTERN" \
  | grep -v rc \
  | sort -V \
  | tail -1)
[ -n "$LATEST" ] || ERROR "Could not find Alpine $ISO_TYPE ISO"
ISO_URL="${BASE}${LATEST}"

LOG "ISO: $LATEST"
cd /root
if [ -f "$LATEST" ]; then
  LOG "Reusing existing /root/$LATEST"
else
  LOG "Downloading ISO, checksums, and GPG key"
  wget --progress=dot:giga \
    "$ISO_URL" \
    "$ISO_URL.sha256" \
    "$ISO_URL.asc" \
    "https://alpinelinux.org/keys/ncopa.asc" \
    || ERROR "Download failed"
fi

LOG "Verifying ISO integrity"
sha256sum -c "${LATEST}.sha256"   || ERROR "SHA256 check failed"
gpg --import ncopa.asc           &>/dev/null || ERROR "GPG import failed"
gpg --verify "${LATEST}.asc" "$LATEST" &>/dev/null || ERROR "Signature verification failed"

# -------------------------------------------------------------------
# 2) Mount ISO & extract apk.static
# -------------------------------------------------------------------
LOG "Mounting ISO at $ISO_MNT"
mkdir -p "$ISO_MNT"
mount -o loop "/root/$LATEST" "$ISO_MNT" || ERROR "ISO mount failed"

LOG "Fetching apk-tools-static index"
IDX="/tmp/alpine-index.html"
wget --progress=dot:giga -O "$IDX" \
  "https://dl-cdn.alpinelinux.org/alpine/latest-stable/main/x86_64/" \
  || ERROR "Failed to fetch package index"

APK_PKG=$(grep -Eo 'apk-tools-static-[0-9.]+(-r[0-9]+)?\.apk' "$IDX" \
  | sort -V \
  | tail -1)
rm -f "$IDX"
[ -n "$APK_PKG" ] || ERROR "apk-tools-static not found"

LOG "Downloading $APK_PKG"
wget --progress=dot:giga -O "/root/$APK_PKG" \
  "https://dl-cdn.alpinelinux.org/alpine/latest-stable/main/x86_64/$APK_PKG" \
  || ERROR "Failed to download apk-tools-static"

LOG "Extracting apk.static"
mkdir -p /root/sbin
tar -C /root -xzf "/root/$APK_PKG" sbin/apk.static || ERROR "Extract failed"
APK_BIN="/root/sbin/apk.static"
[ -x "$APK_BIN" ] || ERROR "apk.static is not executable"
rm -f "/root/$APK_PKG"
umount "$ISO_MNT" || WARN "ISO unmount failed"

# -------------------------------------------------------------------
# 3) Partition & format disk
# -------------------------------------------------------------------
LOG "Partitioning $DISK"
DISK_MB=$(( $(blockdev --getsize64 "$DISK") / 1024 / 1024 ))
[ $DISK_MB -ge 512 ] || ERROR "Disk too small (${DISK_MB} MB)"

BOOT_MB=256
if [ $DISK_MB -gt 10240 ]; then
  BOOT_MB=$(( DISK_MB/20 ))
  [ $BOOT_MB -gt 512 ] && BOOT_MB=512
fi
LOG "Disk ${DISK_MB}MB: /boot=${BOOT_MB}MB, root=$(($DISK_MB-BOOT_MB))MB"

sgdisk --zap-all "$DISK"                                &&
sgdisk -n1:0:+${BOOT_MB}M -t1:8300 "$DISK"              &&
sgdisk -n2:0:0          -t2:8300 "$DISK"                &&
partprobe "$DISK"                                       ||
  ERROR "Partitioning failed"

LOG "Formatting partitions"
mkfs.ext4 -F "$PART1" || ERROR "Format $PART1 failed"
mkfs.ext4 -F "$PART2" || ERROR "Format $PART2 failed"

# -------------------------------------------------------------------
# 4) Mount new partitions
# -------------------------------------------------------------------
LOG "Mounting root and boot"
mkdir -p "$CHROOT"
mount "$PART2" "$CHROOT"   || ERROR "Mount root failed"
mkdir -p "$CHROOT/boot"
mount "$PART1" "$CHROOT/boot" || ERROR "Mount boot failed"

# -------------------------------------------------------------------
# 5) Bootstrap Alpine
# -------------------------------------------------------------------
LOG "Bootstrapping Alpine"
"$APK_BIN" \
  --repository "https://dl-cdn.alpinelinux.org/alpine/latest-stable/main" \
  --allow-untrusted -U --root "$CHROOT" --initdb \
  add alpine-base || ERROR "Failed to install alpine-base"

# -------------------------------------------------------------------
# 6) Bind mounts & resolv
# -------------------------------------------------------------------
LOG "Setting up bind mounts"
for d in dev proc sys; do
  mount --bind "/$d" "$CHROOT/$d" || ERROR "Bind mount $d failed"
done
cp /etc/resolv.conf "$CHROOT/etc/" || ERROR "Copy resolv.conf failed"

# -------------------------------------------------------------------
# 7) Configure in chroot & install bootloader
# -------------------------------------------------------------------
LOG "Entering chroot for final configuration"
chroot "$CHROOT" /bin/sh -eux <<EOF
# Repositories
echo "https://dl-cdn.alpinelinux.org/alpine/latest-stable/main" > /etc/apk/repositories

# fstab
cat > /etc/fstab <<FSTAB
$PART2 /      ext4 defaults 0 1
$PART1 /boot  ext4 defaults 0 2
FSTAB

# Networking
IF=\$(ip -o link show | awk -F': ' '{print \$2}' | grep -v lo | head -1)
[ -z "\$IF" ] && IF=eth0
cat > /etc/network/interfaces <<NETCFG
auto lo
iface lo inet loopback

auto \$IF
iface \$IF inet dhcp
NETCFG

# SSH
mkdir -p /root/.ssh
cat > /root/.ssh/authorized_keys <<KEY
$PUBKEY
KEY
chmod 700 /root/.ssh
chmod 600 /root/.ssh/authorized_keys

# Install kernel & syslinux
apk update
apk add linux-virt syslinux

# Install extlinux bootloader
extlinux --install /boot

# Write MBR from discovered path
MBR=""
for p in /usr/lib/syslinux/mbr/mbr.bin /usr/share/syslinux/mbr.bin \
         /usr/lib/extlinux/mbr.bin /usr/lib/syslinux/mbr.bin; do
  [ -f "\$p" ] && { MBR="\$p"; break; }
done
[ -n "\$MBR" ] || { echo "MBR binary not found" >&2; exit 1; }
dd if="\$MBR" of="$DISK" bs=440 count=1 conv=notrunc

# extlinux.conf
cat > /boot/extlinux.conf <<CFG
default alpine
prompt 1
timeout 5

label alpine
  kernel /boot/vmlinuz-virt
  append initrd=/boot/initramfs-virt modloop=/modloop \
    modules=loop,squashfs,sd-mod,usb-storage,ext4 root=$PART2 rw console=ttyS0
CFG
EOF

# -------------------------------------------------------------------
# 8) Cleanup & reboot
# -------------------------------------------------------------------
LOG "Cleaning up mounts"
for d in dev proc sys; do
  umount "$CHROOT/$d" 2>/dev/null || true
done
umount "$CHROOT/boot" 2>/dev/null || true
umount "$CHROOT"      2>/dev/null || true

LOG "Syncing and rebooting in 5s"
sync
sleep 5
reboot
