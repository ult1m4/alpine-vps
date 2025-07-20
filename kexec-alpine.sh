#!/usr/bin/env bash
   set -euo pipefail

   # Logging functions
   LOG()   { echo "[$(date +%H:%M:%S)] $*"; }
   WARN()  { echo "[$(date +%H:%M:%S)] WARN: $*" >&2; }
   ERROR() { echo "[$(date +%H:%M:%S)] ERROR: $*" >&2; exit 1; }

   # Check dependencies
   for cmd in wget kexec mount; do
     command -v "$cmd" >/dev/null || ERROR "Missing required tool: $cmd"
   done

   # Fetch latest Alpine virt ISO
   LOG "Fetching latest Alpine virt ISO..."
   LISTING_URL="https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/x86_64/"
   LATEST_ISO=$(wget -qO- "$LISTING_URL" 2>/tmp/wget_err | grep -o 'alpine-virt-[0-9.]\+-x86_64.iso' | grep -v '_rc' | sort -V | tail -n1)
   if [ -z "$LATEST_ISO" ]; then
     WARN "Failed to find latest virt ISO in directory listing."
     cat /tmp/wget_err >&2
     ERROR "Please check the Alpine CDN or specify a version manually."
   fi
   ISO_URL="$LISTING_URL$LATEST_ISO"
   ISO="$LATEST_ISO"

   # Download ISO
   LOG "Downloading $ISO_URL..."
   cd /root
   wget -q "$ISO_URL" || ERROR "Failed to download ISO"

   # Mount ISO and extract kernel/initramfs
   LOG "Extracting kernel and initramfs..."
   mkdir -p /mnt/iso
   mount -o loop "$ISO" /mnt/iso || ERROR "Failed to mount ISO"
   cp /mnt/iso/boot/vmlinuz-virt /root/vmlinuz-alpine || ERROR "Failed to copy kernel"
   cp /mnt/iso/boot/initramfs-virt /root/initramfs-alpine || ERROR "Failed to copy initramfs"
   umount /mnt/iso

   # Load kexec
   LOG "Loading Alpine live environment with kexec..."
   kexec -l /root/vmlinuz-alpine --initrd=/root/initramfs-alpine --append="console=ttyS0" || ERROR "Failed to load kexec"
   LOG "Booting into Alpine live environment..."
   kexec -e
