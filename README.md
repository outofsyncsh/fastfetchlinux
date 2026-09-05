# FastFetchLinux

A real Linux distribution.

It boots Linux.
It runs Fastfetch.

That's it.

## Why?

Why not?

## Features

* Custom BIOS bootloader
* Linux 6.6.156
* Custom `ffinit` written in x86 assembly
* Custom shell
* No BusyBox
* No coreutils
* No package manager
* i686
* ~20 MiB RAM usage
* Probably works

## Commands

```text
fastfetch      Display system information
ls             List /bin
install-disk   Install FastFetchLinux onto a disk
forcepanic     Trigger a kernel panic, on purpose
poweroff       Turn off the computer
```

That's all.

**5 commands. 0 packages. 0 purpose.**

## Boot

```text
BIOS
 ↓
Custom Bootloader
 ↓
Linux Kernel
 ↓
ffinit
 ↓
Fastfetch
 ↓
???
```

## System Requirements

### Minimum

* i386-compatible CPU
* 16 MB RAM
* 5 MB storage
* BIOS
* i686-compatible system

### Recommended

* Pentium 4 or newer
* 32 MB RAM
* 10 MB storage
* BIOS

If it has a CPU, there's a chance.

## Installation

Boot the installer and run:

```text
install-disk
```

Select a disk and let it do the questionable thing.

**Warning:** This will overwrite the selected disk.

## Is this useful?

No.

## License

Do whatever you want with it.

We have bigger problems.
