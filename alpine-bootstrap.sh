#!/usr/bin/env bash
set -euo pipefail

# Logging functions
LOG()   { echo "[$(date +%H:%M:%S)] $*" >&1; }
WARN()  { echo "[$(date +%H:%M:%S)] WARN: $*" >&2; }
ERROR() { echo "[$(date +%H:%M:%S)] ERROR: $*" >&2; exit 1; }

# Defaults
ISO_TYPE="virt"          # "virt" or "standard"
CHROOT="/mnt/alpine"
ISO_MNT="/mnt/iso"

# Parse command-line options
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

# Validate arguments
[ $# -eq 2 ] || ERROR "Usage: $0 [-t virt|standard] <disk> <ssh-pubkey-file>
Example: $0 -t virt /dev/vda /root/id_ed25519.pub"
DISK=$1
PUBKEY_FILE=$2

# Check dependencies & inputs
for cmd in wget sgdisk mkfs.ext4 mount tar extlinux dd partprobe lsblk blockdev gpg; do
  command -v "$cmd" >/dev/null 2>&1 || ERROR "Missing required tool: $cmd"
done
[ -b "$DISK" ]       || ERROR "Block device '$DISK' not found. Check with 'lsblk'."
[ -f "$PUBKEY_FILE" ]|| ERROR "SSH key file '$PUBKEY_FILE' not found."
PUBKEY=$(<"$PUBKEY_FILE")
[ -n "$PUBKEY" ]     || ERROR "SSH pubkey file is empty."

# Determine partition suffix (e.g. 'p' for nvme)
PART_PREFIX=""
[[ $DISK =~ nvme ]] && PART_PREFIX="p"
PART1="${DISK}${PART_PREFIX}1"
PART2="${DISK}${PART_PREFIX}2"

# Ensure no partitions are mounted
LOG "Verifying no mounted partitions on $DISK..."
if lsblk -n -o MOUNTPOINT "$DISK" | grep -q .; then
  ERROR "$DISK is mounted. Unmount it first."
fi
for p in "${DISK}${PART_PREFIX}"*; do
  [ -b "$p" ] || continue
  if lsblk -n -o MOUNTPOINT "$p" | grep -q .; then
    ERROR "Partition $p is mounted. Unmount it."
  fi
done

# Cleanup previous mounts & data
LOG "Cleaning up old mounts and dirs..."
umount -l "$ISO_MNT"             2>/dev/null || true
umount -l "$CHROOT/dev"          2>/dev/null || true
umount -l "$CHROOT/proc"         2>/dev/null || true
umount -l "$CHROOT/sys"          2>/dev/null || true
umount -l "$CHROOT/boot"         2>/dev/null || true
rm -rf "$CHROOT" "$ISO_MNT"

# Confirm destructive action
echo
LOG "WARNING: This will ERASE ALL DATA on $DISK and install Alpine Linux."
LOG "Type 'yes' to proceed:"
read -r confirm
[ "$confirm" = "yes" ] || ERROR "Aborted by user."

# -------------------------------------------------------------------
# 1) Download and verify ISO
# -------------------------------------------------------------------
LOG "Selecting latest Alpine ${ISO_TYPE} ISO..."
LISTING="https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/x86_64/"
PATTERN="alpine-${ISO_TYPE}-[0-9.]+-x86_64.iso"

LATEST=$(wget --progress=dot:giga -qO- "$LISTING" 2>/tmp/wget_err \
  | grep -Eo "$PATTERN" \
  | grep -v rc \
  | sort -V \
  | tail -1)
[ -n "$LATEST" ] || { cat /tmp/wget_err >&2; ERROR "Could not find Alpine ${ISO_TYPE} ISO."; }

ISO_URL="${LISTING}${LATEST}"
LOG "Detected ISO: $LATEST"

cd /root
if [ -f "$LATEST" ]; then
  LOG "Reusing existing ISO /root/$LATEST"
else
  LOG "Downloading ISO + checksums + key..."
  wget --progress=dot:giga \
    "$ISO_URL" \
    "$ISO_URL.sha256" \
    "$ISO_URL.asc" \
    "https://alpinelinux.org/keys/ncopa.asc" \
    || ERROR "Failed to download ISO or verification files"
fi

LOG "Verifying ISO integrity..."
sha256sum -c "${LATEST}.sha256"   || ERROR "SHA256 check failed"
gpg --import ncopa.asc           &>/dev/null || ERROR "GPG import failed"
gpg --verify "${LATEST}.asc" "$LATEST" &>/dev/null || ERROR "Signature failed"

# -------------------------------------------------------------------
# 2) Mount ISO & extract apk-tools-static
# -------------------------------------------------------------------
LOG "Mounting ISO to $ISO_MNT..."
mkdir -p "$ISO_MNT"
mount -o loop "/root/$LATEST" "$ISO_MNT" || ERROR "Failed to mount ISO"

LOG "Fetching package index to pick apk-tools-static..."
TMP_INDEX="/tmp/alpine-index.html"
wget --progress=dot:giga -O "$TMP_INDEX" \
  "https://dl-cdn.alpinelinux.org/alpine/latest-stable/main/x86_64/" \
  || ERROR "Failed to fetch package index"

APK_PKG=$(grep -Eo 'apk-tools-static-[0-9.]+(-r[0-9]+)?\.apk' "$TMP_INDEX" \
  | sort -V \
  | tail -1)
rm -f "$TMP_INDEX"
[ -n "$APK_PKG" ] || ERROR "Could not find apk-tools-static package"

LOG "Downloading $APK_PKG..."
wget --progress=dot:giga -O "/root/$APK_PKG" \
  "https://dl-cdn.alpinelinux.org/alpine/latest-stable/main/x86_64/$APK_PKG" \
  || ERROR "Failed to download apk-tools-static"

LOG "Extracting apk.static..."
mkdir -p /root/sbin
tar -C /root -xzf "/root/$APK_PKG" sbin/apk.static || ERROR "Failed to extract apk.static"
APK_STATIC="/root/sbin/apk.static"
[ -x "$APK_STATIC" ] || ERROR "apk.static is not executable"
rm -f "/root/$APK_PKG"
umount "$ISO_MNT" || WARN "ISO still mounted"

# -------------------------------------------------------------------
# 3) Bootstrap Alpine into chroot
# -------------------------------------------------------------------
LOG "Bootstrapping Alpine into $CHROOT..."
mkdir -p "$CHROOT"
"$APK_STATIC" \
  --repository "https://dl-cdn.alpinelinux.org/alpine/latest-stable/main" \
  --allow-untrusted -U --root "$CHROOT" --initdb \
  add alpine-base linux-virt syslinux e2fsprogs openssh \
  || ERROR "Bootstrap failed"

# -------------------------------------------------------------------
# 4) Bind mounts + resolv
# -------------------------------------------------------------------
LOG "Setting up bind mounts..."
for d in dev proc sys; do
  mount --bind "/$d" "$CHROOT/$d" || ERROR "Bind mount $d failed"
done
cp /etc/resolv.conf "$CHROOT/etc/" || ERROR "Copy resolv.conf failed"

# -------------------------------------------------------------------
# 5) Partition, format & mount
# -------------------------------------------------------------------
LOG "Partitioning $DISK..."

DISK_SIZE_MB=$(( $(blockdev --getsize64 "$DISK") / 1024 / 1024 ))
[ $DISK_SIZE_MB -ge 512 ] || ERROR "Disk (${DISK_SIZE_MB} MB) is below minimum (512 MB)"

BOOT_SIZE_MB=256
if [ $DISK_SIZE_MB -gt 10240 ]; then
  BOOT_SIZE_MB=$(( DISK_SIZE_MB / 20 ))
  [ $BOOT_SIZE_MB -gt 512 ] && BOOT_SIZE_MB=512
fi
LOG "Disk=$DISK ($DISK_SIZE_MB MB): /boot=${BOOT_SIZE_MB} MB, root=$((DISK_SIZE_MB-BOOT_SIZE_MB)) MB"

sgdisk --zap-all "$DISK"                                  \
  && sgdisk -n1:0:+${BOOT_SIZE_MB}M -t1:8300 "$DISK"      \
  && sgdisk -n2:0:0           -t2:8300 "$DISK"            \
  && partprobe "$DISK"                                   \
  || ERROR "Partitioning failed"

LOG "Formatting partitions..."
mkfs.ext4 -F "$PART1" || ERROR "Failed to format $PART1"
mkfs.ext4 -F "$PART2" || ERROR "Failed to format $PART2"

LOG "Mounting partitions..."
mkdir -p "$CHROOT"         || ERROR "mkdir $CHROOT failed"
mount "$PART2" "$CHROOT"   || ERROR "Mount $PART2 failed"
mkdir -p "$CHROOT/boot"    || ERROR "mkdir $CHROOT/boot failed"
mount "$PART1" "$CHROOT/boot" || ERROR "Mount $PART1 failed"

# -------------------------------------------------------------------
# 6) Configure system in chroot
# -------------------------------------------------------------------
LOG "Configuring Alpine in chroot..."
chroot "$CHROOT" /bin/sh -eux <<EOF
# Repositories
echo "https://dl-cdn.alpinelinux.org/alpine/latest-stable/main" > /etc/apk/repositories

# fstab
cat > /etc/fstab <<FSTAB
$PART2 /      ext4 defaults 0 1
$PART1 /boot  ext4 defaults 0 2
FSTAB

# Networking
IFACE=\$(ip -o link show | awk -F': ' '{print \$2}' | grep -v lo | head -1)
[ -z "\$IFACE" ] && IFACE=eth0
cat > /etc/network/interfaces <<NETCFG
auto lo
iface lo inet loopback

auto \$IFACE
iface \$IFACE inet dhcp
NETCFG

# SSH key
mkdir -p /root/.ssh
cat > /root/.ssh/authorized_keys <<KEY
$PUBKEY
KEY
chmod 700 /root/.ssh
chmod 600 /root/.ssh/authorized_keys

# Install bootloader
extlinux --install /boot
dd if=/usr/lib/syslinux/mbr/mbr.bin of="$DISK" bs=440 count=1 conv=notrunc

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

# Kernel install
apk update
apk add linux-virt
cp /usr/lib/syslinux/mbr/mbr.bin /boot/
EOF

# -------------------------------------------------------------------
# 7) Cleanup & reboot
# -------------------------------------------------------------------
LOG "Cleaning up and rebooting..."
for d in dev proc sys; do
  umount "$CHROOT/$d" 2>/dev/null || WARN "Failed to unmount $d"
done
umount "$CHROOT/boot" 2>/dev/null || WARN "Failed to unmount boot"
umount "$CHROOT"      2>/dev/null || WARN "Failed to unmount root"
sync; sleep 5
reboot
