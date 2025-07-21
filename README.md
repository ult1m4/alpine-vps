# alpine linux vps bootstrapper (chroot install)
Script and guide for installing Alpine Linux on VPS or cloud servers without custom-ISO support.

(this is a work in progress, but it does currently boot to a functional rescue shell on Alpine)

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

8. Allow install to complete and reboot. You should have a functioning Alpine system, with your ssh key present.
    
# features

1. ISO Flavor Selection  
   Choose between “virt” or “standard” builds via `-t`, automatically fetching the latest Alpine ISO.

2. Smart Disk Setup  
   Auto-detects NVMe vs classic disks, wipes existing RAID/LVM metadata, and partitions for BIOS+GRUB: BIOS-GRUB, 256 MiB `/boot`, rest `/`.

3. Robust Download & Verification  
   Live‐progress ISO pulls with retries, SHA256 checksum and GPG signature checks ensure a tamper-proof base.

4. Minimal Apk-tools-static Bootstrap  
   Fetches just the `apk-tools-static` package from Alpine’s main repo—no huge ISOs—then bootstraps `alpine-base` cleanly in chroot.

5. Automated Chroot Configuration  
   Sets up `/etc/fstab`, networking (DHCP), SSH authorized_keys, and installs `linux-virt` (or LTS), `grub`, and essential packages.

6. Real GRUB Bootloader  
   Installs and configures GRUB (not Syslinux) for a solid, BIOS-bootable system—no MBR hacks or “hope-it-boots” tricks.

7. Defensive, POSIX-Compatible Scripting  
   Strict `set -euo pipefail`, comprehensive mount checks, retry loops, and cleanup ensure reproducible runs even in rescue shells.

8. Clear Logging & Finalization  
   Verbose timestamps, error context (including mount/GRUB logs), and safe reboot steps give you instant insight and a one-shot installation.

# things to add

Potential support for other distros with auto-fetch isos

UEFI support via grub-efi

Optional disk encryption

Cloud-init or SSH provisioning hooks

A --dry-run or --no-reboot flag for testing
