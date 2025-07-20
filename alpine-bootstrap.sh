#!/usr/bin/env bash
set -euo pipefail

# Logging
LOG()   { echo "[$(date +%H:%M:%S)] $*"; }
WARN()  { echo "[$(date +%H:%M:%S)] WARN: $*" >&2; }
ERROR() { echo "[$(date +%H:%M:%S)] ERROR: $*" >&2; exit 1; }

# Defaults
ISO_TYPE="virt"   # "virt" or "standard"
CHROOT="/mnt/alpine"
ISO_MNT="/mnt/iso"

# Parse options
while getopts ":t:" opt; do
  case $opt in
    t)
      case "${OPTARG}" in
        virt|standard) ISO_TYPE=${OPTARG} ;;
        *)
          ERROR "Invalid ISO type: ${OPTARG}. Use 'virt' or 'standard'."
          ;;
      esac
      ;;
    \?)
      ERROR "Invalid option: -$OPTARG"
      ;;
  esac
done
shift $((OPTIND-1))

# Usage
if [ $# -ne 2 ]; then
  ERROR "Usage: $0 [-t virt|standard] <disk> <ssh-pubkey-file>\nExample: $0 -t virt /dev/vda /root/id_ed25519.pub"
fi

DISK="$1"
PUBKEY_FILE="$2"

# Dependencies
for cmd in wget sgdisk mkfs.ext4 mount tar extlinux dd partprobe lsblk gpg; do
  command -v "$cmd" >/dev/null || ERROR "Missing required tool: $cmd"
done

# Validate inputs
[ -b "$DISK" ] || ERROR "Block device $DISK not found. Check with 'lsblk'."
[ -f "$PUBKEY_FILE" ] || ERROR "SSH pubkey file $PUBKEY_FILE not found."
PUBKEY=$(cat "$PUBKEY_FILE")
[ -n "$PUBKEY" ] || ERROR "SSH pubkey file is empty."

# Check mounts
LOG "Checking if $DISK is mounted..."
if lsblk -n -o MOUNTPOINT "$DISK" | grep -q .; then
  ERROR "$DISK is mounted. Unmount first."
fi
for part in "${DISK}"[0-9]*; do
  if [ -e "$part" ] && lsblk -n -o MOUNTPOINT "$part" | grep -q .; then
    ERROR "Partition $part is mounted. Unmount it."
  fi
done

# Cleanup old mounts/data
umount -l "$ISO_MNT" 2>/dev/null || true
umount -l "$CHROOT"/{dev,proc,sys,boot,} 2>/dev/null || true
rm -rf "$CHROOT" "$ISO_MNT"

# Confirm
LOG "Target disk: $DISK"
LOG "SSH pubkey: $PUBKEY"
echo "WARNING: This erases ALL DATA on $DISK and installs Alpine."
echo "Type 'yes' to proceed:"
read -r confirm
[ "$confirm" != "yes" ] && ERROR "Aborted."

# -------------------------------------------------------------------
# 1) Determine ISO filename/pattern
# -------------------------------------------------------------------
LOG "Selecting Alpine ${ISO_TYPE} ISO..."
LISTING="https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/x86_64/"
if [ "$ISO_TYPE" = "virt" ]; then
  PATTERN='alpine-virt-[0-9.]\+-x86_64.iso'
else
  PATTERN='alpine-standard-[0-9.]\+-x86_64.iso'
fi

LATEST=$(wget --progress=dot:giga -qO- "$LISTING" 2>/tmp/wget_err \
  | grep -o "${PATTERN}" \
  | grep -v '_rc' \
  | sort -V \
  | tail -n1)
[ -n "$LATEST" ] || { cat /tmp/wget_err >&2; ERROR "Could not find Alpine ${ISO_TYPE} ISO."; }

VERSION=${LATEST#alpine-}
VERSION=${VERSION%-x86_64.iso}
ISO_URL="$LISTING$LATEST"

LOG "Alpine version: $VERSION"
LOG "ISO file: $LATEST"

# -------------------------------------------------------------------
# 2) Download & verify ISO (with caching)
# -------------------------------------------------------------------
cd /root
if [ -f "$LATEST" ]; then
  LOG "Found existing ISO /root/$LATEST — skipping download."
else
  LOG "Downloading $LATEST..."
  wget --progress=dot:giga \
    "$ISO_URL" "$ISO_URL.sha256" "$ISO_URL.asc" \
    "https://alpinelinux.org/keys/ncopa.asc" \
    || ERROR "Download failed"
fi

LOG "Verifying ISO..."
sha256sum -c "${LATEST}.sha256" || ERROR "Checksum failed"
gpg --import ncopa.asc 2>/dev/null || ERROR "GPG import failed"
gpg --verify "${LATEST}.asc" "$LATEST" 2>/dev/null || ERROR "Signature failed"

# -------------------------------------------------------------------
# 3) Mount ISO & extract apk-tools-static (~2 MB)
# -------------------------------------------------------------------
mkdir -p "$ISO_MNT"
mount -o loop "/root/$LATEST" "$ISO_MNT" || ERROR "Mount failed"

LOG "Fetching apk-tools-static from repo..."
APK_PKG=$(wget --progress=dot:giga -qO- \
  https://dl-cdn.alpinelinux.org/alpine/latest-stable/main/x86_64/ \
  | grep -m1 'apk-tools-static-[0-9.]\+\.apk')
[ -n "$APK_PKG" ] || ERROR "Could not find apk-tools-static package name"

wget --progress=dot:giga \
  "https://dl-cdn.alpinelinux.org/alpine/latest-stable/main/x86_64/${APK_PKG}" \
  -O "/root/${APK_PKG}" \
  || ERROR "Failed to download apk-tools-static"

mkdir -p /root/sbin
LOG "Extracting apk.static..."
tar -C /root -xzf "/root/${APK_PKG}" sbin/apk.static || ERROR "Extract failed"
APK_STATIC="/root/sbin/apk.static"
[ -x "$APK_STATIC" ] || ERROR "apk.static not extracted"

umount "$ISO_MNT"

# -------------------------------------------------------------------
# 4) Bootstrap Alpine into chroot
# -------------------------------------------------------------------
LOG "Bootstrapping Alpine into $CHROOT..."
mkdir -p "$CHROOT"
"$APK_STATIC" \
  --repository "https://dl-cdn.alpinelinux.org/alpine/latest-stable/main" \
  --allow-untrusted -U --root "$CHROOT" --initdb \
  add alpine-base linux-virt syslinux e2fsprogs openssh \
  || ERROR "Bootstrap failed"

# -------------------------------------------------------------------
# 5) Bind mounts + resolv
# -------------------------------------------------------------------
LOG "Mounting dev, proc, sys..."
for d in dev proc sys; do
  mount --bind "/$d" "$CHROOT/$d" || ERROR "Mount /$d failed"
done
cp /etc/resolv.conf "$CHROOT/etc/" || ERROR "resolv.conf copy failed"

# -------------------------------------------------------------------
# 6) Partition, format, mount
# -------------------------------------------------------------------
LOG "Wiping & partitioning $DISK..."
sgdisk --zap-all "$DISK" \
  && sgdisk -n1:0:+256M -t1:8300 "$DISK" \
  && sgdisk -n2:0:0 -t2:8300 "$DISK" \
  && partprobe "$DISK" \
  || ERROR "Partitioning failed"

LOG "Formatting partitions..."
mkfs.ext4 -F "${DISK}1" || ERROR "/boot format failed"
mkfs.ext4 -F "${DISK}2" || ERROR "root format failed"

LOG "Mounting partitions..."
mkdir -p "$CHROOT/boot"
mount "${DISK}2" "$CHROOT" || ERROR "Mount root failed"
mount "${DISK}1" "$CHROOT/boot" || ERROR "Mount boot failed"

# -------------------------------------------------------------------
# 7) Chroot & configure
# -------------------------------------------------------------------
LOG "Configuring in chroot..."
chroot "$CHROOT" /bin/sh -eux << 'EOF'
# Repos
echo "https://dl-cdn.alpinelinux.org/alpine/latest-stable/main" > /etc/apk/repositories

# fstab
cat > /etc/fstab << F
/dev/vda2 /      ext4 defaults 0 1
/dev/vda1 /boot  ext4 defaults 0 2
F

# Networking
NET_IFACE=$(ip -o link show | awk -F': ' '{print $2}' | grep -v lo | head -n1)
[ -z "$NET_IFACE" ] && NET_IFACE="eth0"
cat > /etc/network/interfaces << N
auto lo
iface lo inet loopback

auto $NET_IFACE
iface $NET_IFACE inet dhcp
N

# SSH key
mkdir -p /root/.ssh
cat > /root/.ssh/authorized_keys << KEY
$PUBKEY
KEY
chmod 700 /root/.ssh
chmod 600 /root/.ssh/authorized_keys

# Install bootloader
extlinux --install /boot
dd if=/usr/lib/syslinux/mbr/mbr.bin of=/dev/vda bs=440 count=1 conv=notrunc

# extlinux.conf
cat > /boot/extlinux.conf << C
default alpine
prompt 1
timeout 5

label alpine
  kernel /boot/vmlinuz-virt
  append initrd=/boot/initramfs-virt modloop=/modloop \
    modules=loop,squashfs,sd-mod,usb-storage,ext4 root=/dev/vda2 rw console=ttyS0
C

# Install kernel
apk update
apk add linux-virt
cp /usr/lib/syslinux/mbr/mbr.bin /boot/
EOF

# -------------------------------------------------------------------
# 8) Cleanup & reboot
# -------------------------------------------------------------------
LOG "Cleaning up mounts..."
for d in dev proc sys; do
  umount "$CHROOT/$d" 2>/dev/null || WARN "Unmount $d failed"
done
umount "$CHROOT/boot" 2>/dev/null || WARN "Unmount boot failed"
umount "$CHROOT" 2>/dev/null || WARN "Unmount root failed"

LOG "Syncing and rebooting in 5s..."
sync
sleep 5
reboot
