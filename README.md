# alpine-vps
Script set and guide for installing Alpine Linux on VPS and cloud services that do not provide custom ISO uploads

# why
I made this to wrestle with my IONOS VPS not having a proper custom iso or KVM console. I discovered it runs its gparted image as a bootable drive and doesn't hard write it to the /dev/vda which, when imaging with gparted, would let me take proper control of the system.

# how

1. Boot your IONOS VPS into the GParted Live ISO  
   - In the menu, choose “Enter command line prompt”

2. Bring up networking  
   ```bash
   ip link show            # find your iface (e.g. eth0, enp0s3)
   dhclient <iface>        # or: udhcpc -i <iface>

3. Prepare your SSH key on your local machine
   ```bash
   ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519

4. Copy your public key to the VPS
   If you can't scp it since it's gparted just painstakingly copy it
   (paste the contents of ~/.ssh/id_ed25519.pub into /root/id_ed25519.pub)

5. Fetch and make the bootstrap script executable
   ```bash
   wget -O alpine-bootstrap.sh https://raw.githubusercontent.com/ult1m4/alpine-vps/main/alpine-bootstrap.sh
   chmod +x alpine-bootstrap.sh

6. Run the installer script (double check lsblk to verify you're at /dev/vda)
   ```bash
   ./alpine-bootstrap.sh /dev/vda /root/id_ed25519.pub

7. Wait for the VPS to reboot, then log in over SSH
   ```bash
   ssh root@<VPS_IP>
