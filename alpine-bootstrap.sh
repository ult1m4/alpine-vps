#!/usr/bin/env bash
set -euo pipefail

LOG(){ echo "[$(date +%H:%M:%S)] $*" >&1; }
WARN(){ echo "[$(date +%H:%M:%S)] WARN: $*" >&2; }
ERROR(){ echo "[$(date +%H:%M:%S)] ERROR: $*" >&2; exit 1; }

# Defaults
ISO_TYPE="virt"       # virt or standard
CHROOT="/mnt/alpine"
ISO_MNT="/mnt/iso"

# Parse flags
while getopts ":t:" opt; do
  case $opt in
    t) [[ $OPTARG =~ ^(virt|standard)$ ]] || ERROR "Invalid ISO type '$OPTARG'"
       ISO_TYPE=$OPTARG ;;
    \?) ERROR "Invalid option -$OPTARG" ;;
  esac
done
shift $((OPTIND-1))

# Usage
[ $# -eq 2 ] || ERROR "Usage: $0 [-t virt|standard] <disk> <ssh-pubkey-file>"
DISK=$1
PUBKEY_FILE=$2

# Dependencies & inputs
for c in wget sgdisk mkfs.ext4 mount tar extlinux dd partprobe lsblk blockdev gpg; do
  command -v $c >/dev/null || ERROR "Missing $c"
done
[ -b "$DISK" ]       || ERROR "Disk $DISK not found"
[ -f "$PUBKEY_FILE" ]|| ERROR "Pubkey file not found"
PUBKEY=$(<"$PUBKEY_FILE"); [ -n "$PUBKEY" ] || ERROR "Empty pubkey"

# Partition names (nvme needs 'p')
PREFIX=""; [[ $DISK =~ nvme ]] && PREFIX="p"
PART1="${DISK}${PREFIX}1"
PART2="${DISK}${PREFIX}2"

# Make sure nothing is mounted
LOG "Ensuring $DISK and partitions are unmounted"
if lsblk -n -o MOUNTPOINT "$DISK" | grep -q .; then ERROR "$DISK is mounted"; fi
for p in "${DISK}${PREFIX}"*; do
  [ -b "$p" ] || continue
  if lsblk -n -o MOUNTPOINT "$p" | grep -q .; then ERROR "$p is mounted"; fi
done

# Clean old dirs
LOG "Cleaning old mounts/data"
umount -l "$ISO_MNT"          2>/dev/null || true
umount -l "$CHROOT/dev"       2>/dev/null || true
umount -l "$CHROOT/proc"      2>/dev/null || true
umount -l "$CHROOT/sys"       2>/dev/null || true
umount -l "$CHROOT/boot"      2>/dev/null || true
rm -rf "$CHROOT" "$ISO_MNT"

# Confirm
echo
LOG "!!! Will ERASE ALL DATA on $DISK and install Alpine Linux !!!"
read -p "Type 'yes' to continue: " conf
[ "$conf" = yes ] || ERROR "User aborted"

# 1) Download & verify ISO
LOG "Picking latest Alpine-$ISO_TYPE ISO"
BASE="https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/x86_64"
ISO=$(wget --progress=dot:giga -qO- "$BASE/" \
      | grep -Eo "alpine-$ISO_TYPE-[0-9.]+-x86_64.iso" \
      | grep -v rc | sort -V | tail -1)
[ -n "$ISO" ] || ERROR "No ISO found"
URL="$BASE/$ISO"

cd /root
if [ -f "$ISO" ]; then
  LOG "Reusing $ISO"
else
  LOG "Downloading ISO + checksums + key"
  wget --progress=dot:giga \
    "$URL" "$URL.sha256" "$URL.asc" "https://alpinelinux.org/keys/ncopa.asc" \
    || ERROR "ISO download failed"
fi

LOG "Verifying ISO"
sha256sum -c "${ISO}.sha256"  || ERROR "SHA256 mismatch"
gpg --import ncopa.asc      &>/dev/null || ERROR "GPG import"
gpg --verify "${ISO}.asc" "$ISO" &>/dev/null || ERROR "Signature invalid"

# 2) Extract apk.static
LOG "Mounting ISO"
mkdir -p "$ISO_MNT"
mount -o loop "/root/$ISO" "$ISO_MNT" || ERROR "ISO mount failed"

LOG "Selecting apk-tools-static"
IDX=/tmp/alpine-idx.html
wget --progress=dot:giga -O "$IDX" \
  https://dl-cdn.alpinelinux.org/alpine/latest-stable/main/x86_64/ \
  || ERROR "Index fetch failed"
APK=$(grep -Eo 'apk-tools-static-[0-9.]+(-r[0-9]+)?\.apk' "$IDX" | sort -V | tail -1)
rm -f "$IDX"
[ -n "$APK" ] || ERROR "No apk-tools-static found"

LOG "Downloading $APK"
wget --progress=dot:giga -O "/root/$APK" \
  https://dl-cdn.alpinelinux.org/alpine/latest-stable/main/x86_64/$APK \
  || ERROR "apk download failed"

mkdir -p /root/sbin
LOG "Extracting apk.static"
tar -C /root -xzf "/root/$APK" sbin/apk.static || ERROR "Extract failed"
APK_BIN=/root/sbin/apk.static
[ -x "$APK_BIN" ] || ERROR "apk.static missing"
rm -f "/root/$APK"
umount "$ISO_MNT" || WARN "ISO unmount failed"

# 3) Partition & format
LOG "Partitioning $DISK"
SIZE_MB=$(( $(blockdev --getsize64 $DISK)/1024/1024 ))
[ $SIZE_MB -ge 512 ] || ERROR "Disk too small ($SIZE_MB MB)"
BOOT_MB=256
if [ $SIZE_MB -gt 10240 ]; then
  BOOT_MB=$(( SIZE_MB/20 ))
  [ $BOOT_MB -gt 512 ] && BOOT_MB=512
fi
LOG "Disk $DISK: /boot $BOOT_MB MB, root $((SIZE_MB-BOOT_MB)) MB"

sgdisk --zap-all "$DISK"                        \
  && sgdisk -n1:0:+${BOOT_MB}M -t1:8300 "$DISK"  \
  && sgdisk -n2:0:0           -t2:8300 "$DISK"  \
  && partprobe "$DISK"                           \
  || ERROR "Partitioning failed"

LOG "Formatting"
mkfs.ext4 -F "$PART1" || ERROR "mkfs /boot failed"
mkfs.ext4 -F "$PART2" || ERROR "mkfs / failed"

# 4) Mount new root & boot
LOG "Mounting partitions"
mkdir -p "$CHROOT"
mount "$PART2" "$CHROOT"   || ERROR "Mount root failed"
mkdir -p "$CHROOT/boot"
mount "$PART1" "$CHROOT/boot" || ERROR "Mount boot failed"

# 5) Bootstrap Alpine into that mount
LOG "Bootstrapping Alpine"
"$APK_BIN" \
  --repository https://dl-cdn.alpinelinux.org/alpine/latest-stable/main \
  --allow-untrusted -U --root "$CHROOT" --initdb \
  add alpine-base linux-virt syslinux e2fsprogs openssh \
  || ERROR "Bootstrap failed"

# 6) Bind mounts & resolv
LOG "Binding /dev /proc /sys"
for d in dev proc sys; do
  mount --bind "/$d" "$CHROOT/$d" || ERROR "Bind $d failed"
done
cp /etc/resolv.conf "$CHROOT/etc/"

# 7) Final in‐chroot config
LOG "Entering chroot to finalize"
chroot "$CHROOT" /bin/sh -eux <<EOF
echo https://dl-cdn.alpinelinux.org/alpine/latest-stable/main > /etc/apk/repositories

cat > /etc/fstab <<F
$PART2 /      ext4 defaults 0 1
$PART1 /boot  ext4 defaults 0 2
F

IF=\$(ip -o link show | awk -F': ' '{print \$2}' | grep -v lo | head -1)
[ -z "\$IF" ] && IF=eth0
cat > /etc/network/interfaces <<N
auto lo
iface lo inet loopback

auto \$IF
iface \$IF inet dhcp
N

mkdir -p /root/.ssh
cat > /root/.ssh/authorized_keys <<K
$PUBKEY
K
chmod 700 /root/.ssh
chmod 600 /root/.ssh/authorized_keys

extlinux --install /boot
dd if=/usr/lib/syslinux/mbr/mbr.bin of="$DISK" bs=440 count=1 conv=notrunc

cat > /boot/extlinux.conf <<C
default alpine
prompt 1
timeout 5

label alpine
  kernel /boot/vmlinuz-virt
  append initrd=/boot/initramfs-virt modloop=/modloop \
    modules=loop,squashfs,sd-mod,usb-storage,ext4 root=$PART2 rw console=ttyS0
C

apk update
apk add linux-virt
cp /usr/lib/syslinux/mbr/mbr.bin /boot/
EOF

# 8) Cleanup & reboot
LOG "Cleaning up and rebooting"
for d in dev proc sys; do umount "$CHROOT/$d" 2>/dev/null || true; done
umount "$CHROOT/boot" 2>/dev/null || true
umount "$CHROOT" 2>/dev/null      || true

sync; sleep 5
reboot
