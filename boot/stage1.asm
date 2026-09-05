; fastfetchlinux bootloader - stage1: tiny MBR that loads stage2 and jumps to it
BITS 16
ORG 0x7C00

STAGE2_SEG equ 0x0000
STAGE2_OFF equ 0x8000

start:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7C00
    sti
    mov [boot_drive], dl

    mov si, dap
    mov ah, 0x42
    mov dl, [boot_drive]
    int 0x13
    jc fail

    mov dl, [boot_drive]
    jmp STAGE2_SEG:STAGE2_OFF

fail:
    mov si, msg_fail
.p:
    lodsb
    or al, al
    jz .h
    mov ah, 0x0E
    mov bh, 0
    int 0x10
    jmp .p
.h:
    hlt
    jmp .h

boot_drive db 0
msg_fail db "stage1: disk read failed", 13, 10, 0

align 4
dap:
    db 0x10
    db 0
    dw STAGE2_SECTORS
    dw STAGE2_OFF
    dw STAGE2_SEG
    dd 1
    dd 0

times 510 - ($ - $$) db 0
dw 0xAA55
