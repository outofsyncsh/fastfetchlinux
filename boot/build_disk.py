#!/usr/bin/env python3
"""Build a raw bootable disk image: 2-stage custom bootloader + bzImage + initramfs."""
import subprocess, os

ROOT = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(ROOT, "..", "..", "out")
KERNEL = os.path.join(OUT, "bzImage")
INITRD = os.path.join(OUT, "initramfs.cpio.gz")
DISK_IMG = os.path.join(OUT, "fastfetchlinux.img")

SECTOR = 512
STAGE2_SECTORS = 8  # 4KiB reserved for stage2, generous margin


def pad(data, size):
    if len(data) % size:
        data += b"\x00" * (size - len(data) % size)
    return data


def main():
    kernel = open(KERNEL, "rb").read()
    initrd = open(INITRD, "rb").read()

    setup_sects = kernel[0x1F1]
    if setup_sects == 0:
        setup_sects = 4
    realmode_sectors = setup_sects + 1
    realmode_bytes = realmode_sectors * SECTOR
    assert kernel[0x1FE:0x200] == b"\x55\xAA", "bad boot signature"
    assert kernel[0x202:0x206] == b"HdrS", "not a valid bzImage header"

    realmode_part = kernel[:realmode_bytes]
    pm_part = pad(kernel[realmode_bytes:], SECTOR)
    kernel_pm_sectors = len(pm_part) // SECTOR

    initrd_bytes = len(initrd)
    initrd_padded = pad(initrd, SECTOR)
    initrd_sectors = len(initrd_padded) // SECTOR

    realmode_lba_start = 1 + STAGE2_SECTORS

    print(f"setup_sects={setup_sects} realmode_sectors={realmode_sectors}")
    print(f"kernel protected-mode: {len(pm_part)} bytes -> {kernel_pm_sectors} sectors")
    print(f"initramfs: {initrd_bytes} bytes -> {initrd_sectors} sectors")
    print(f"realmode_lba_start={realmode_lba_start}")

    # --- stage1 ---
    s1 = ["nasm", "-f", "bin", f"-DSTAGE2_SECTORS={STAGE2_SECTORS}",
          os.path.join(ROOT, "stage1.asm"), "-o", os.path.join(ROOT, "stage1.bin")]
    print("+", " ".join(s1))
    subprocess.run(s1, check=True)
    stage1 = open(os.path.join(ROOT, "stage1.bin"), "rb").read()
    assert len(stage1) == SECTOR, f"stage1 must be exactly 512 bytes, got {len(stage1)}"

    # --- stage2 ---
    defines = [
        f"-DREALMODE_SECTORS={realmode_sectors}",
        f"-DKERNEL_PM_SECTORS={kernel_pm_sectors}",
        f"-DINITRD_SECTORS={initrd_sectors}",
        f"-DINITRD_BYTES={initrd_bytes}",
        f"-DREALMODE_LBA_START={realmode_lba_start}",
    ]
    s2 = ["nasm", "-f", "bin"] + defines + [os.path.join(ROOT, "stage2.asm"), "-o", os.path.join(ROOT, "stage2.bin")]
    print("+", " ".join(s2))
    subprocess.run(s2, check=True)
    stage2 = open(os.path.join(ROOT, "stage2.bin"), "rb").read()
    print(f"stage2 size: {len(stage2)} bytes (budget: {STAGE2_SECTORS * SECTOR})")
    assert len(stage2) <= STAGE2_SECTORS * SECTOR, "stage2 too big for reserved sectors, bump STAGE2_SECTORS"
    stage2_padded = pad(stage2, STAGE2_SECTORS * SECTOR)

    total_sectors = 1 + STAGE2_SECTORS + realmode_sectors + kernel_pm_sectors + initrd_sectors
    # generous headroom so the partition covers more than just today's payload
    part_sectors = max(total_sectors + 65536, 65536)

    # Bake a real MBR partition table into stage1's reserved area (bytes
    # 0x1BE-0x1FD) so the resulting image is a normal partitioned disk from
    # sector 0 -- installing it is then just a single `dd`, no sfdisk/fdisk
    # needed on the target (which may only have busybox).
    stage1 = bytearray(stage1)
    entry_off = 0x1BE
    stage1[entry_off + 0] = 0x80        # bootable
    stage1[entry_off + 1:entry_off + 4] = b"\xFE\xFF\xFF"  # CHS start (unused, LBA)
    stage1[entry_off + 4] = 0x83        # type: Linux
    stage1[entry_off + 5:entry_off + 8] = b"\xFE\xFF\xFF"  # CHS end (unused, LBA)
    stage1[entry_off + 8:entry_off + 12] = (1).to_bytes(4, "little")             # LBA start
    stage1[entry_off + 12:entry_off + 16] = part_sectors.to_bytes(4, "little")   # sector count
    assert stage1[0x1FE:0x200] == b"\x55\xAA", "boot signature got clobbered"
    stage1 = bytes(stage1)

    print(f"partition: start=1 sectors={part_sectors} ({part_sectors * SECTOR / 1024 / 1024:.1f} MiB)")

    with open(DISK_IMG, "wb") as f:
        f.write(stage1)
        f.write(stage2_padded)
        f.write(realmode_part)
        f.write(pm_part)
        f.write(initrd_padded)

    total = SECTOR + len(stage2_padded) + len(realmode_part) + len(pm_part) + len(initrd_padded)
    print(f"wrote {DISK_IMG} ({total} bytes, {total // SECTOR} sectors, {total/1024/1024:.1f} MiB)")


if __name__ == "__main__":
    main()
