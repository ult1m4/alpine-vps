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

# Cleanup any old mounts
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
# 1) Fetch latest Alpine virt ISO (slimmer than extended, includes virt kernel)
# -------------------------------------------------------------------
LOG "Fetching latest Alpine virt ISO name..."
LISTING="https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/x86_64/"
LATEST=$(wget --progress=dot:giga -qO- "$LISTING" 2>/tmp/wget_err \
  | grep -o 'alpine-virt-[0-9.]\+-x86_64.iso' \
  | grep -v '_rc' \
  | sort -V \
  | tail -n1)
[ -n "$LATEST" ] || { cat /tmp/wget_err >&2; ERROR "Couldn't find virt ISO."; }

VERSION=${LATEST#alpine-virt-}
VERSION=${VERSION%-x86_64.iso}
ISO_URL="$LISTING$LATEST"
SHA256_URL="$ISO_URL.sha256"
ASC_URL="$ISO_URL.asc"

LOG "Alpine version: $VERSION"
LOG "Downloading $LATEST..."
cd /root
wget --progress=dot:giga -q "$ISO_URL" "$SHA256_URL" "$ASC_URL" "https://alpinelinux.org/keys/ncopa.asc" \
  || ERROR "Download failed"
[ -f "$LATEST" ] || ERROR "ISO missing after download"

LOG "Verifying ISO..."
sha256sum -c "${LATEST}.sha256" || ERROR "Checksum failed"
gpg --import ncopa.asc 2>/dev/null || ERROR "GPG import failed"
gpg --verify "${LATEST}.asc" "$LATEST" 2>/dev/null || ERROR "Signature failed"

# -------------------------------------------------------------------
# 2) Mount ISO
# -------------------------------------------------------------------
mkdir -p "$ISO_MNT"
mount -o loop "/root/$LATEST" "$ISO_MNT" || ERROR "Mount failed"

# -------------------------------------------------------------------
# 3) Fetch apk-tools-static separately (small ~2 MB)
# -------------------------------------------------------------------
LOG "Fetching apk-tools-static from repo..."
APK_PKG=$(wget --progress=dot:giga -qO- https://dl-cdn.alpinelinux.org/alpine/latest-stable/main/x86_64/ \
  | grep -m1 'apk-tools-static-[0-9.]\+\.apk')
[ -n "$APK_PKG" ] || ERROR "Could not find apk-tools-static package name"

wget --progress=dot:giga -q "https://dl-cdn.alpinelinux.org/alpine/latest-stable/main/x86_64/${APK_PKG}" \
  -O "/root/${APK_PKG}" || ERROR "Failed to download apk-tools-static"

LOG "Extracting apk.static..."
tar -C /root -xzf "/root/${APK_PKG}" sbin/apk.static || ERROR "Extract failed"
APK_STATIC="/root/sbin/apk.static"
[ -x "$APK_STATIC" ] || ERROR "apk.static not extracted"

umount "$ISO_MNT"

# -------------------------------------------------------------------
# 4) Bootstrap Alpine into chroot using apk.static
# -------------------------------------------------------------------
LOG "Bootstrapping Alpine into $CHROOT..."
mkdir -p "$CHROOT"
"$APK_STATIC" \
  --repository "https://dl-cdn.alpinelinux.org/alpine/latest-stable/main" \
  --allow-untrusted -U --root "$CHROOT" --initdb add alpine-base linux-virt syslinux e2fsprogs openssh \
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

LOG "Formatting..."
mkfs.ext4 -F "${DISK}1" || ERROR "/boot format failed"
mkfs.ext4 -F "${DISK}2" || ERROR "root format failed"

LOG "Mounting partitions..."
mkdir -p "$CHROOT/boot"
mount "${DISK}2" "$CHROOT" || ERROR "Mount root failed"
mount "${DISK}1" "$CHROOT/boot" || ERROR "Mount boot failed"

# -------------------------------------------------------------------
# 7) Chroot and configure
# -------------------------------------------------------------------
LOG "Configuring in chroot..."
chroot "$CHROOT" /bin/sh -eux << 'EOF'
# Repos
echo "https://dl-cdn.alpinelinux.org/alpine/latest-stable/main" > /etc/apk/repositories

# fstab
cat > /etc/fstab Feveraloopack << F
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
  append initrd=/boot/initramfs-virt modloop=/modloop modules=loop,squashfs,sd-mod,usb-storage,ext4 root=/dev/vda2 rw console=ttyS0
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

LOG "Sync & reboot in 5 seconds..."
sync
sleep 5
reboot
