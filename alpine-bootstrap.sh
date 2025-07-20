#!/usr/bin/env bash
set -euo pipefail

# Logging
LOG()   { echo "[$(date +%H:%M:%S)] $*"; }
WARN()  { echo "[$(date +%H:%M:%S)] WARN: $*" >&2; }
ERROR() { echo "[$(date +%H:%M:%S)] ERROR: $*" >&2; exit 1; }

# Dependencies
for cmd in wget sgdisk mkfs.ext4 mount tar extlinux dd partprobe lsblk gpg; do
  command -v "$cmd" >/dev/null || ERROR "Missing required tool: $cmd"
done

# Usage
if [ $# -ne 2 ]; then
  ERROR "Usage: $0 <disk> <ssh-pubkey-file>\nExample: $0 /dev/vda /root/id_ed25519.pub"
fi

DISK="$1"
PUBKEY_FILE="$2"
CHROOT="/mnt/alpine"
ISO_MNT="/mnt/iso"

# Validate inputs
[ -b "$DISK" ] || ERROR "Block device $DISK not found. Check with 'lsblk'."
[ -f "$PUBKEY_FILE" ] || ERROR "SSH pubkey file $PUBKEY_FILE not found."
PUBKEY=$(cat "$PUBKEY_FILE")
[ -n "$PUBKEY" ] || ERROR "SSH pubkey file is empty."

# Check if disk or partitions are mounted
LOG "Checking if $DISK is mounted..."
if lsblk -n -o MOUNTPOINT "$DISK" | grep -q .; then
  ERROR "$DISK is mounted. Unmount all partitions (e.g., 'umount /dev/vda1') or contact IONOS support to reset to a fresh Debian 12 image."
fi
for part in "${DISK}"[0-9]*; do
  if [ -e "$part" ] && lsblk -n -o MOUNTPOINT "$part" | grep -q .; then
    ERROR "Partition $part is mounted. Unmount it (e.g., 'umount $part') or contact IONOS support to reset the VPS."
  fi
done

# Clean up any old mounts
umount -l "$ISO_MNT" 2>/dev/null || true
umount -l "$CHROOT"/{dev,proc,sys,boot,} 2>/dev/null || true
rm -rf "$CHROOT" "$ISO_MNT"

# Confirmation
LOG "Target disk: $DISK"
LOG "SSH public key: $PUBKEY"
echo "WARNING: This will ERASE ALL DATA on $DISK and install Alpine Linux."
echo "Type 'yes' to proceed, anything else to abort."
read -r confirm
[ "$confirm" != "yes" ] && ERROR "Aborted by user."

# Fetch latest Alpine extended ISO
LOG "Fetching latest Alpine extended ISO name..."
LISTING="https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/x86_64/"
LATEST=$(wget -qO- "$LISTING" 2>/tmp/wget_err \
  | grep -o 'alpine-extended-[0-9.]\+-x86_64.iso' \
  | grep -v '_rc' \
  | sort -V \
  | tail -n1)
if [ -z "$LATEST" ]; then
  WARN "Failed to find latest extended ISO in directory listing."
  cat /tmp/wget_err >&2
  ERROR "Could not fetch latest Alpine ISO. Check network or CDN."
fi
VERSION=$(echo "$LATEST" | sed 's/alpine-extended-\([0-9.]\+\)-x86_64.iso/\1/')
ISO_URL="$LISTING$LATEST"
SHA256_URL="$LISTING${LATEST}.sha256"
ASC_URL="$LISTING${LATEST}.asc"
LOG "Alpine version: $VERSION"
LOG "Downloading $ISO_URL..."

# Download and verify ISO
cd /root
wget -q "$ISO_URL" "$SHA256_URL" "$ASC_URL" "https://alpinelinux.org/keys/ncopa.asc" || ERROR "Download failed"
[ -f "$LATEST" ] || ERROR "ISO file missing after download"
LOG "Verifying ISO..."
sha256sum -c "${LATEST}.sha256" || ERROR "Checksum verification failed"
gpg --import ncopa.asc 2>/dev/null || ERROR "GPG key import failed"
gpg --verify "${LATEST}.asc" "$LATEST" 2>/dev/null || ERROR "Signature verification failed"

# Mount ISO and extract apk.static
mkdir -p "$ISO_MNT"
mount -o loop "/root/$LATEST" "$ISO_MNT" || ERROR "Failed to mount ISO"
LOG "Extracting apk.static..."
[ -f "$ISO_MNT/apks/x86_64/apk-tools-static-"*.apk ] || ERROR "apk-tools-static not found in ISO"
tar -C "$ISO_MNT/apks/x86_64" -xzf "$ISO_MNT/apks/x86_64/apk-tools-static-"*.apk sbin/apk.static || ERROR "Failed to extract apk.static"
umount "$ISO_MNT"

# Bootstrap Alpine into chroot
LOG "Bootstrapping Alpine into $CHROOT..."
mkdir -p "$CHROOT"
/root/$ISO_MNT/apks/x86_64/sbin/apk.static \
  --repository "https://dl-cdn.alpinelinux.org/alpine/latest-stable/main" \
  --allow-untrusted -U --root "$CHROOT" --initdb add alpine-base linux-virt syslinux e2fsprogs openssh || ERROR "Failed to bootstrap Alpine"

# Bind mount system dirs and copy resolv.conf
LOG "Mounting dev, proc, sys into chroot..."
for d in dev proc sys; do
  mount --bind "/$d" "$CHROOT/$d" || ERROR "Failed to mount /$d"
done
cp /etc/resolv.conf "$CHROOT/etc/" || ERROR "Failed to copy resolv.conf"

# Partition and format disk
LOG "Wiping and partitioning $DISK..."
sgdisk --zap-all "$DISK" || ERROR "Failed to wipe disk"
sgdisk -n1:0:+256M -t1:8300 "$DISK" || ERROR "Failed to create /boot partition"
sgdisk -n2:0:0 -t2:8300 "$DISK" || ERROR "Failed to create root partition"
partprobe "$DISK" || ERROR "Failed to update partition table. Ensure $DISK is not mounted."

LOG "Formatting partitions..."
mkfs.ext4 -F "${DISK}1" || ERROR "Failed to format /boot"
mkfs.ext4 -F "${DISK}2" || ERROR "Failed to format root"

LOG "Mounting partitions..."
mkdir -p "$CHROOT/boot"
mount "${DISK}2" "$CHROOT" || ERROR "Failed to mount root"
mount "${DISK}1" "$CHROOT/boot" || ERROR "Failed to mount /boot"

# Configure Alpine in chroot
LOG "Configuring Alpine in chroot..."
chroot "$CHROOT" /bin/sh -eux << 'EOF'
# Repos
echo "https://dl-cdn.alpinelinux.org/alpine/latest-stable/main" > /etc/apk/repositories

# fstab
cat > /etc/fstab << F
/dev/vda2 /      ext4 defaults 0 1
/dev/vda1 /boot  ext4 defaults 0 2
F

# Network (adjust interface if needed)
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
extlinux --install /boot || exit 1
dd if=/usr/lib/syslinux/mbr/mbr.bin of=/dev/vda bs=440 count=1 conv=notrunc

# extlinux.conf
cat > /boot/extlinux.conf << C
default alpine
prompt 1
timeout 5

label alpine
  kernel /boot/vmlinuz-virt
  append initrd=/boot/initramfs-virt modloop=/modloop modules=loop,squashfs,sd-mod,usb-storage,ext4 root=/dev/vda2 rw console=ttyS0
C

# Copy kernel and initramfs
apk update
apk add linux-virt
cp /usr/lib/syslinux/mbr/mbr.bin /boot/
EOF

# Cleanup and reboot
LOG "Cleaning up mounts..."
for d in dev proc sys; do
  umount "$CHROOT/$d" 2>/dev/null || WARN "Failed to unmount $CHROOT/$d"
done
umount "$CHROOT/boot" 2>/dev/null || WARN "Failed to unmount $CHROOT/boot"
umount "$CHROOT" 2>/dev/null || WARN "Failed to unmount $CHROOT"

LOG "Syncing and rebooting..."
sync
reboot
