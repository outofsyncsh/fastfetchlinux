#!/bin/sh
# fastfetchlinux - boot the minimal x86 kernel + fastfetch initramfs in QEMU
cd "$(dirname "$0")"
exec qemu-system-i386 \
  -kernel bzImage \
  -initrd initramfs.cpio.gz \
  -append "console=ttyS0 quiet rdinit=/sbin/ffinit" \
  -nographic -no-reboot \
  -m "${1:-24}"
