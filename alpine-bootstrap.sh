#!/usr/bin/env bash
set -euo pipefail

# Logging functions
LOG()   { echo "[$(date +%H:%M:%S)] $*"; }
WARN()  { echo "[$(date +%H:%M:%S)] WARN: $*" >&2; }
ERROR() { echo "[$(date +%H:%M:%S)] ERROR: $*" >&2; exit 1; }

# Check dependencies
for cmd in wget gpg sgdisk mkfs.ext4 mount extlinux sha256sum tar dd; do
  command -v "$cmd" >/dev/null || ERROR "Missing required tool: $cmd"
done

# Parse arguments
if [ $# -ne 2 ]; then
  ERROR "Usage: $0 <disk> \"<your-public-key>\"  (e.g., $0 /dev/vda \"ssh-ed25519 AAAAC3Nza... you@example.com\")"
fi
DISK="$1"
PUBKEY="$2"

# Validate disk
if [ ! -b "$DISK" ]; then
  ERROR "Disk '$DISK' does not exist or isn’t a block device. Check with 'lsblk'."
fi
if [ -z "$PUBKEY" ]; then
  ERROR "Public key cannot be empty."
fi

# Fetch latest Alpine virt ISO version from directory listing
LOG "Fetching latest Alpine virt ISO version from directory listing..."
LISTING_URL="https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/x86_64/"
LATEST_ISO=$(wget -qO- "$LISTING_URL" 2>/tmp/wget_err | grep -o 'alpine-virt-[0-9.]\+-x86_64.iso' | grep -v '_rc' | sort -V | tail -n1)
if [ -z "$LATEST_ISO" ]; then
  WARN "Failed to find latest virt ISO in directory listing."
  cat /tmp/wget_err >&2
  ERROR "Please check the Alpine CDN or specify a version manually."
fi
VERSION=$(echo "$LATEST_ISO" | sed 's/alpine-virt-\([0-9.]\+\)-x86_64.iso/\1/')
SHORT="${VERSION%.*}"
ISO="$LATEST_ISO"
URL="$LISTING_URL$ISO"
SHA256_URL="$LISTING_URL${ISO}.sha256"
ASC_URL="$LISTING_URL${ISO}.asc"

# Confirmation
LOG "Target disk: $DISK"
LOG "Alpine version: $VERSION"
LOG "ISO URL: $URL"
LOG "SSH public key: $PUBKEY"
echo "WARNING: This will ERASE ALL DATA on $DISK and install Alpine Linux $VERSION."
echo "Type 'yes' to proceed, anything else to abort."
read -r confirm
[ "$confirm" != "yes" ] && ERROR "Aborted by user."

# Partition disk: 256M /boot, rest /
LOG "Wiping and partitioning $DISK..."
sgdisk --zap-all "$DISK" || ERROR "Failed to wipe disk"
sgdisk -n1:0:+256M -t1:8300 "$DISK" || ERROR "Failed to create /boot partition"
sgdisk -n2:0:0 -t2:8300 "$DISK" || ERROR "Failed to create root partition"
partprobe "$DISK" || ERROR "Failed to update partition table"

# Format partitions
LOG "Formatting partitions..."
mkfs.ext4 -F "${DISK}1" || ERROR "Failed to format /boot"
mkfs.ext4 -F "${DISK}2" || ERROR "Failed to format root"

# Mount filesystems
LOG "Mounting filesystems..."
mount "${DISK}2" /mnt || ERROR "Failed to mount root"
mkdir -p /mnt/boot
mount "${DISK}1" /mnt/boot || ERROR "Failed to mount /boot"

# Download and verify ISO
LOG "Downloading Alpine ISO and signatures..."
cd /root
wget -q "$URL" "$SHA256_URL" "$ASC_URL" "https://alpinelinux.org/keys/ncopa.asc" || ERROR "Download failed"
[ -f "$ISO" ] || ERROR "ISO file missing after download"

LOG "Verifying ISO..."
sha256sum -c "${ISO}.sha256" || ERROR "Checksum verification failed"
gpg --import ncopa.asc 2>/dev/null || ERROR "GPG key import failed"
gpg --verify "${ISO}.asc" "$ISO" 2>/dev/null || ERROR "Signature verification failed"

# Extract ISO contents
LOG "Extracting Alpine files..."
mkdir -p /mnt/iso
mount -o loop "$ISO" /mnt/iso || ERROR "Failed to mount ISO"
cp /mnt/iso/boot/vmlinuz-virt /mnt/boot/vmlinuz || ERROR "Failed to copy kernel"
cp /mnt/iso/boot/initramfs-virt /mnt/boot/initramfs || ERROR "Failed to copy initramfs"
cp -a /mnt/iso/modloop /mnt/modloop || ERROR "Failed to copy modloop"
cp -a /mnt/iso/apks /mnt/apks || ERROR "Failed to copy apks"
umount /mnt/iso

# Build overlay (SSH + DHCP)
LOG "Building overlay with SSH key and DHCP..."
mkdir -p /root/overlay/etc/{lbu,network} /root/overlay/root/.ssh
echo "/root/.ssh" > /root/overlay/etc/lbu/include
# eth0 is common; adjust if your VPS uses a different interface (e.g., ens3)
echo "auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp" > /root/overlay/etc/network/interfaces
echo "$PUBKEY" > /root/overlay/root/.ssh/authorized_keys
chmod 700 /root/overlay/root/.ssh
chmod 600 /root/overlay/root/.ssh/authorized_keys
cd /root/overlay
tar czf /mnt/apks/apkovl.tar.gz . || ERROR "Failed to create overlay tarball"

# Install bootloader
LOG "Installing extlinux bootloader..."
extlinux --install /mnt/boot || ERROR "Failed to install extlinux"
cp /usr/lib/syslinux/modules/bios/* /mnt/boot/ 2>/dev/null || true
dd if=/usr/lib/syslinux/mbr/mbr.bin of="$DISK" bs=440 count=1 conv=notrunc || ERROR "Failed to write MBR"

# Write extlinux.conf
LOG "Writing extlinux.conf..."
cat > /mnt/boot/extlinux.conf << ELX
default alpine
prompt 1
timeout 3

label alpine
  kernel /vmlinuz
  append initrd=/initramfs modloop=/modloop modules=loop,squashfs,sd-mod,usb-storage,ext4 alpine_dev=${DISK}2:ext4 overlay=/apkovl.tar.gz
ELX

# Cleanup and reboot
LOG "Unmounting and rebooting..."
umount /mnt/boot || WARN "Failed to unmount /boot; proceeding anyway"
umount /mnt || WARN "Failed to unmount root; proceeding anyway"
sync
LOG "Rebooting into Alpine $VERSION..."
reboot
