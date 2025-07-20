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

3. Prepare your SSH key on your local machine
   ```bash
   ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519

4. Copy your public key to the VPS
   Paste ~/.ssh/id_ed25519.pub into /root/id_ed25519.pub on the GParted shell.
   Tip: use a private Gist and wget if clipboard isn’t working.

6. Download and make the bootstrap script executable
   ```bash
   wget -O alpine-bootstrap.sh https://raw.githubusercontent.com/ult1m4/alpine-vps/main/alpine-bootstrap.sh
   chmod +x alpine-bootstrap.sh

7. Run the installer (use lsblk or gparted to find /dev/vda or device name)
   Default (add -t flag if you rather Alpine standard ISO over virtual machine ISO):
   ```bash
   #virt:
   ./alpine-bootstrap.sh /dev/vda /root/id_ed25519.pub
   #standard:
   ./alpine-bootstrap.sh -t standard /dev/vda /root/id_ed25519.pub

9. Allow install to complete. After reboot, log in over SSH
   ```bash
   ssh root@<VPS_IP>

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
