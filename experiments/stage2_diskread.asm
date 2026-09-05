; fastfetchlinux - stage2 test: LBA disk read via INT 13h extensions (AH=42h)
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

    mov [boot_drive], dl

    mov si, msg_start
    call print

    ; read 1 sector (LBA 1) into 0x0000:0x8000
    mov si, dap
    mov ah, 0x42
    mov dl, [boot_drive]
    int 0x13
    jc .fail

    mov si, msg_ok
    call print

    ; print the sector we just loaded (should be "SECOND STAGE DATA...")
    mov si, 0x8000
    call print

    jmp .hang

.fail:
    mov si, msg_fail
    call print

.hang:
    hlt
    jmp .hang

print:
.loop:
    lodsb
    or al, al
    jz .done
    mov ah, 0x0E
    mov bh, 0x00
    mov bl, 0x07
    int 0x10
    jmp .loop
.done:
    ret

boot_drive db 0
msg_start db "stage2: reading sector via LBA...", 13, 10, 0
msg_ok    db "stage2: read OK, sector contents follow:", 13, 10, 0
msg_fail  db "stage2: DISK READ FAILED", 13, 10, 0

; Disk Address Packet for INT 13h/42h
align 4
dap:
    db 0x10        ; size of packet
    db 0            ; reserved
    dw 1            ; number of sectors to read
    dw 0x8000       ; offset of buffer
    dw 0x0000       ; segment of buffer
    dq 1            ; starting LBA (sector 1, i.e. second sector on disk)

times 510 - ($ - $$) db 0
dw 0xAA55

; ---- this is sector 1 (LBA 1), loaded by our bootloader above ----
second_stage_marker: db "SECOND STAGE DATA LOADED CORRECTLY!", 13, 10, 0
times 1024 - ($ - $$) db 0
