; fastfetchlinux - stage3 test: move data above 1MB via INT 15h/AH=87h, then read it back
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

    mov si, msg_start
    call print

    ; fill a small buffer at 0x20000 (seg 0x2000:0000) with a known pattern
    mov ax, 0x2000
    mov es, ax
    xor di, di
    mov cx, 16
    mov al, 0
.fill:
    mov [es:di], al
    inc di
    inc al
    loop .fill

    ; move 16 bytes (8 words) from linear 0x20000 to linear 0x110000 (above 1MB)
    xor ax, ax
    mov es, ax          ; ES:SI must point to GDT; ES=0 matches our ORG 0x7C00 addressing
    mov si, gdt
    mov cx, 8          ; word count
    mov ah, 0x87
    int 0x15
    jc .fail

    mov si, msg_moved
    call print

    ; now move it back down from 0x110000 to 0x30000 to verify contents
    xor ax, ax
    mov es, ax
    mov si, gdt2
    mov cx, 8
    mov ah, 0x87
    int 0x15
    jc .fail

    ; print bytes at 0x30000 as hex to verify pattern 00 01 02 ... 0F
    mov ax, 0x3000
    mov es, ax
    xor di, di
    mov cx, 16
.printloop:
    mov al, [es:di]
    call print_hex
    mov al, ' '
    mov ah, 0x0E
    int 0x10
    inc di
    loop .printloop

    mov si, msg_done
    call print

    jmp hang

.fail:
    mov si, msg_fail
    call print

hang:
    hlt
    jmp hang

print:
.loop:
    lodsb
    or al, al
    jz .ret
    mov ah, 0x0E
    mov bh, 0
    mov bl, 7
    int 0x10
    jmp .loop
.ret:
    ret

; print AL as 2 hex digits
print_hex:
    push ax
    mov ah, al
    shr al, 4
    call .nibble
    mov al, ah
    and al, 0x0F
    call .nibble
    pop ax
    ret
.nibble:
    cmp al, 10
    jl .digit
    add al, 'A' - 10
    jmp .out
.digit:
    add al, '0'
.out:
    push ax
    mov ah, 0x0E
    mov bh, 0
    mov bl, 7
    int 0x10
    pop ax
    ret

msg_start db "stage3: testing INT15h/87h big memory move...", 13, 10, 0
msg_moved db "stage3: move to >1MB reported success", 13, 10, 0
msg_fail  db "stage3: MOVE FAILED (carry set)", 13, 10, 0
msg_done  db 13, 10, "stage3: if pattern above reads 00 01 02...0F, extended move works!", 13, 10, 0

; ---- GDT for INT15h/87h: move 0x20000 -> 0x110000 ----
; layout per BIOS spec: 0=null 1=GDT-self 2=source 3=dest 4=BIOS_CS 5=BIOS_DS/SS
align 8
gdt:
    dq 0                                   ; 00h null descriptor (unused)
    dw 0x002F                              ; 08h GDT self-descriptor: limit=47
    dw gdt
    db 0, 0x93, 0, 0
    ; 10h source descriptor: base=0x020000, limit=0xFFFF, access=0x93
    dw 0xFFFF, 0x0000
    db 0x02, 0x93, 0x00, 0x00
    ; 18h destination descriptor: base=0x110000, limit=0xFFFF, access=0x93
    dw 0xFFFF, 0x0000
    db 0x11, 0x93, 0x00, 0x00
    ; 20h BIOS CS (used internally)
    dw 0xFFFF, 0x0000
    db 0x00, 0x9B, 0x00, 0x00
    ; 28h BIOS DS/SS (used internally)
    dw 0xFFFF, 0x0000
    db 0x00, 0x93, 0x00, 0x00

; ---- GDT for INT15h/87h: move 0x110000 -> 0x30000 (verify) ----
align 8
gdt2:
    dq 0
    dw 0x002F
    dw gdt2
    db 0, 0x93, 0, 0
    ; source: base=0x110000
    dw 0xFFFF, 0x0000
    db 0x11, 0x93, 0x00, 0x00
    ; dest: base=0x030000
    dw 0xFFFF, 0x0000
    db 0x03, 0x93, 0x00, 0x00
    dw 0xFFFF, 0x0000
    db 0x00, 0x9B, 0x00, 0x00
    dw 0xFFFF, 0x0000
    db 0x00, 0x93, 0x00, 0x00

times 510 - ($ - $$) db 0
dw 0xAA55
