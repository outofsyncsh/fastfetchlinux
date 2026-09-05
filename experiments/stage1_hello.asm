; fastfetchlinux - stage1 test: hello world boot sector
BITS 16
ORG 0x7C00

start:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7C00
    sti

    mov si, msg
.print:
    lodsb
    or al, al
    jz .hang
    mov ah, 0x0E
    mov bh, 0x00
    mov bl, 0x07
    int 0x10
    jmp .print

.hang:
    hlt
    jmp .hang

msg db "fastfetchlinux stage1 boot sector OK", 13, 10, 0

times 510 - ($ - $$) db 0
dw 0xAA55
