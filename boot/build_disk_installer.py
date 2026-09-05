#!/usr/bin/env python3
"""Build the bootable LIVE/INSTALLER disk image (same bootloader, installer initramfs)."""
import build_disk

build_disk.INITRD = build_disk.INITRD.replace("initramfs.cpio.gz", "initramfs-installer.cpio.gz")
build_disk.DISK_IMG = build_disk.DISK_IMG.replace("fastfetchlinux.img", "fastfetchlinux-installer.img")

if __name__ == "__main__":
    build_disk.main()
