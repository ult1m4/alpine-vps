# alpine linux vps bootstrapper (chroot install)
Script and guide for installing Alpine Linux on VPS or cloud servers without custom-ISO support.

# why
VPS providers may lock you into their own images. This script allows you to reimage a disk from friendly GParted Live iso (available on providers like IONOS) into Alpine Linux entirely from a chroot.

# how

1. Boot your VPS into the GParted Live ISO
   - In the menu, choose “Enter command line prompt” (or use the GUI terminal).

2. Bring up networking  
   ```bash
   ip link show            # find your iface (e.g. eth0, enp0s3)
   dhclient <iface>        # or: udhcpc -i <iface>

3. Prepare your SSH key on your local machine if you haven't already
   ```bash
   ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519

4. Copy your public key to the VPS
   Paste ~/.ssh/id_ed25519.pub into /root/id_ed25519.pub on the GParted shell.
   Tip: use a private Gist and wget if clipboard isn’t working.
   ```bash
   wget -O /root/id_ed25519.pub https://gist.githubusercontent.com/<USERNAME>/<GISTHASHID>/raw

6. Download and make the bootstrap script executable
   ```bash
   wget -O alpine-bootstrap.sh \
   https://raw.githubusercontent.com/ult1m4/alpine-vps/main/alpine-bootstrap.sh
   chmod +x alpine-bootstrap.sh

7. Run the installer (use lsblk or gparted to find /dev/vda or device name)
   Default (add -t flag if you rather Alpine standard ISO over virtual machine ISO):
   ```bash
   #virt:
   ./alpine-bootstrap.sh /dev/vda /root/id_ed25519.pub
   #standard:
   ./alpine-bootstrap.sh -t standard /dev/vda /root/id_ed25519.pub

9. Allow install to complete and reboot.
   If your VPS is similar to mine, it will still boot into GParted. Go ahead and do that. At this point, if you'd like to install GRUB to make Alpine our primary boot, re-enter a terminal in gparted (empty is fine):
   
9.1) Create directory and remount
   ```bash
   mkdir -p /mnt/alpine /mnt/alpine/boot
   mount /dev/vda2 /mnt/alpine
   mount /dev/vda1 /mnt/alpine/boot
```
9.2) Prepare the chroot environment
   ```bash
   mount --bind /dev  /mnt/alpine/dev
   mount --bind /proc /mnt/alpine/proc
   mount --bind /sys  /mnt/alpine/sys
   cp /etc/resolv.conf /mnt/alpine/etc/resolv.conf
```
9.3) Chroot in and install GRUB
   ```bash
   chroot /mnt/alpine /bin/sh -eux <<EOF
   apk update
   apk add grub
   grub-install /dev/vda
   grub-mkconfig -o /boot/grub/grub.cfg
   EOF
```
9.4) Clean up and reboot
   ```bash
   umount /mnt/alpine/{dev,proc,sys,boot}
   umount /mnt/alpine
   reboot
```
10. Now reboot again and you should have a functioning Alpine system, with your ssh key present.
    
# Feature Set

    ISO flavor flag (-t virt / -t standard)

    Auto-detect NVMe (/dev/nvme*) vs classic disks

    Minimum disk size check (≥ 512 MB)

    Auto-sized /boot partition (min 256 MB, max 5% or 512 MB)

    Cache-aware, live-feedback ISO download of the latest Alpine release

    SHA256 + GPG signature verification

    Tiny apk-tools-static fetch & extract (no 1 GB extended ISO)

    Full chroot bootstrap of Alpine with alpine-base, linux-virt, syslinux, openssh, e2fsprogs

    Verbose logging, strict error handling, and clean cleanup/reboot steps

✅ It partitions the disk correctly for BIOS boot ✅ It installs a real bootloader (GRUB), not Syslinux sloppily hoping for MBR magic ✅ It sets up networking, SSH, and kernel without leaving any post-install TODOs ✅ It exits the chroot cleanly, and if it doesn't, it drags it out ✅ It’s POSIX-compatible so it runs even on barebones rescue shells ✅ It checks mount status the right way (not just mount | grep) ✅ It defaults sanely on interface and kernel, with warnings if things look off ✅ It’s future-proofed for expansion: you could add UEFI, other distros, or full automation flags later ✅ And most importantly, it boots 🧨
