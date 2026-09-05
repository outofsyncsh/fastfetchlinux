; fastfetchlinux custom bootloader (MBR, BIOS, x86 real mode)
; Loads a Linux bzImage + initramfs directly from raw disk sectors and
; boots it, implementing the Linux/x86 boot protocol by hand (no GRUB/syslinux).
;
; Disk layout (built by build_disk.py):
;   LBA 0                              : this boot sector (512 bytes)
;   LBA 1 .. REALMODE_SECTORS          : bzImage real-mode part (boot sector + setup code)
;   LBA (1+REALMODE_SECTORS) ..        : bzImage protected-mode part (compressed vmlinux)
;   LBA ... .. end                     : initramfs.cpio.gz
;
; Constants REALMODE_SECTORS, KERNEL_PM_SECTORS, INITRD_SECTORS, INITRD_BYTES
; are injected at assemble time via `nasm -D...` by build_disk.py.

BITS 16
ORG 0x8000

REALMODE_SEG    equ 0x1000      ; where the bzImage real-mode part is loaded
STAGING_SEG     equ 0x2000      ; low scratch buffer for chunked reads
CHUNK_SECTORS   equ 64          ; 32KiB per read+move iteration
KERNEL_PM_DEST  equ 0x00100000  ; 1MiB, standard bzImage load address
INITRD_DEST     equ 0x00800000  ; 8MiB, safely below the 16MiB INT15h/87h limit
CMDLINE_ADDR    equ 0x00090000  ; scratch area for the kernel command line string

; boot animation: plain 80x25 BIOS text mode, no VBE/framebuffer
TOTAL_LOAD_SECTORS equ KERNEL_PM_SECTORS + INITRD_SECTORS
HEADER_ROW      equ 8
HEADER_COL      equ 33           ; centers "FASTFETCHLINUX" (14 chars) on an 80-col line
LOADING_ROW     equ 10
LOADING_COL     equ 15           ; centers the 50-char loading line
BAR_ROW         equ 12
BAR_COL         equ 26           ; centers the 27-char "[....] 100% " bar

start:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7C00
    sti
    mov [boot_drive], dl

    mov si, msg_banner
    call print

    ; ---- 1. load bzImage real-mode part (boot sector + setup) to REALMODE_SEG:0 ----
    mov si, msg_realmode
    call print
    mov ax, REALMODE_SEG
    mov word [dap_buf_seg], ax
    mov word [dap_buf_off], 0
    mov dword [dap_lba_lo], REALMODE_LBA_START
    mov word [dap_count], REALMODE_SECTORS
    call disk_read
    jc disk_error

    ; ---- 2. patch the Linux boot header fields in the loaded copy ----
    mov si, msg_patch
    call print
    mov ax, REALMODE_SEG
    mov es, ax
    mov byte [es:0x210], 0xFF          ; type_of_loader = unknown/custom
    mov byte [es:0x211], 0x81          ; loadflags = LOADED_HIGH | CAN_USE_HEAP
    mov dword [es:0x218], INITRD_DEST  ; ramdisk_image
    mov dword [es:0x21C], INITRD_BYTES ; ramdisk_size
    mov dword [es:0x228], CMDLINE_ADDR ; cmd_line_ptr (protocol >= 2.02)

    ; write the command line string itself
    mov ax, CMDLINE_ADDR >> 4
    mov es, ax
    mov di, 0
    mov si, cmdline_str
.cpycmd:
    lodsb
    stosb
    or al, al
    jnz .cpycmd

    ; ---- 3. boot animation: clear screen, draw header + empty progress bar ----
    mov ax, 0x0003          ; set video mode 3 (80x25 text), also clears screen
    int 0x10

    mov dh, HEADER_ROW
    mov dl, HEADER_COL
    call set_cursor
    mov si, msg_header
    call print

    mov dh, LOADING_ROW
    mov dl, LOADING_COL
    call set_cursor
    mov si, msg_loading
    call print

    mov byte [last_pct], 0xFF
    mov al, 0
    call draw_progress

    ; ---- 4. load protected-mode kernel in chunks, moving each chunk above 1MB ----
    mov word [cur_lba_lo], REALMODE_LBA_START + REALMODE_SECTORS
    mov word [cur_lba_hi], 0
    mov dword [dest_lin], KERNEL_PM_DEST
    mov word [remaining], KERNEL_PM_SECTORS
    call load_and_move_all

    ; ---- 5. load initramfs in chunks, moving each chunk to INITRD_DEST ----
    mov ax, REALMODE_LBA_START + REALMODE_SECTORS
    add ax, KERNEL_PM_SECTORS
    mov word [cur_lba_lo], ax
    mov word [cur_lba_hi], 0
    mov dword [dest_lin], INITRD_DEST
    mov word [remaining], INITRD_SECTORS
    call load_and_move_all

    ; ---- 6. final animation frame: DONE + Booting..., then jump into the kernel ----
    mov dh, LOADING_ROW
    mov dl, LOADING_COL + LOADING_TEXT_LEN
    call set_cursor
    mov si, msg_done_suffix
    call print

    mov dh, LOADING_ROW + 2
    mov dl, HEADER_COL
    call set_cursor
    mov si, msg_booting
    call print

    cli
    mov ax, REALMODE_SEG
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax
    mov sp, 0xE000
    jmp REALMODE_SEG + 0x20 : 0x0000

; =====================================================================
; load_and_move_all: reads [remaining] sectors starting at cur_lba,
; CHUNK_SECTORS at a time, into STAGING_SEG, then moves each chunk to
; the (growing) dest_lin address via INT15h/87h.
; =====================================================================
load_and_move_all:
.loop:
    mov ax, [remaining]
    or ax, ax
    jz .done
    cmp ax, CHUNK_SECTORS
    jbe .lastchunk
    mov ax, CHUNK_SECTORS
.lastchunk:
    mov [this_count], ax

    ; read this_count sectors from cur_lba to STAGING_SEG:0
    mov word [dap_buf_seg], STAGING_SEG
    mov word [dap_buf_off], 0
    mov ax, [cur_lba_lo]
    mov word [dap_lba_lo], ax
    mov ax, [cur_lba_hi]
    mov word [dap_lba_lo+2], ax
    mov ax, [this_count]
    mov [dap_count], ax
    call disk_read
    jc disk_error

    ; move this_count*512 bytes from STAGING_SEG (linear 0x20000) to dest_lin
    mov ax, [this_count]
    mov bx, 256
    mul bx                  ; dx:ax = word count (sectors*256 words per sector)
    mov [move_words], ax    ; word counts here always fit in 16 bits (<=64*256=16384)

    ; patch destination descriptor base in gdt_move (offset 0x18: base_lo,mid,hi)
    mov eax, [dest_lin]
    mov [gdt_move_dest_base_lo], ax
    shr eax, 16
    mov [gdt_move_dest_base_mid], al
    mov [gdt_move_dest_base_hi], ah

    xor ax, ax
    mov es, ax
    mov si, gdt_move
    mov cx, [move_words]
    mov ah, 0x87
    int 0x15
    jc disk_error

    ; advance counters
    mov ax, [this_count]
    add [cur_lba_lo], ax
    adc word [cur_lba_hi], 0
    sub [remaining], ax

    mov ax, [this_count]
    xor dx, dx
    mov bx, 512
    mul bx                  ; dx:ax = bytes moved this chunk
    add [dest_lin], ax
    adc [dest_lin+2], dx

    ; update overall kernel+initramfs load progress (real progress, not timed)
    movzx eax, word [this_count]
    add dword [sectors_done], eax
    mov eax, [sectors_done]
    imul eax, 100
    mov ecx, TOTAL_LOAD_SECTORS
    xor edx, edx
    div ecx                     ; eax = percentage done so far (0-100)
    cmp al, [last_pct]
    je .loop
    mov [last_pct], al
    call draw_progress

    jmp .loop
.done:
    ret

; =====================================================================
; disk_read: reads [dap_count] sectors starting at LBA [dap_lba_lo] (qword)
; into [dap_buf_seg]:[dap_buf_off], using INT13h AH=42h. Sets CF on error.
; =====================================================================
disk_read:
    pusha
    mov si, dap
    mov ah, 0x42
    mov dl, [boot_drive]
    int 0x13
    popa
    ret

disk_error:
    mov si, msg_diskerr
    call print
    cli
.hang:
    hlt
    jmp .hang

; =====================================================================
; set_cursor: DH=row, DL=col (BIOS text mode, page 0)
; =====================================================================
set_cursor:
    push ax
    push bx
    mov ah, 0x02
    xor bh, bh
    int 0x10
    pop bx
    pop ax
    ret

; =====================================================================
; draw_progress: AL = percentage (0-100). Redraws the whole bar in place
; at BAR_ROW/BAR_COL every call, so it is safe to call repeatedly.
; =====================================================================
draw_progress:
    pusha
    mov [pct_val], al

    mov dh, BAR_ROW
    mov dl, BAR_COL
    call set_cursor
    mov si, bar_open
    call print

    mov al, [pct_val]
    xor ah, ah
    mov bl, 5
    div bl                   ; al = hashes (0-20), 100/5 = 20 max
    mov [hash_count], al

    mov cl, al
    xor ch, ch
.hloop:
    jcxz .hdone
    mov al, '#'
    mov ah, 0x0E
    mov bh, 0
    int 0x10
    loop .hloop
.hdone:
    mov al, 20
    sub al, [hash_count]
    mov cl, al
    xor ch, ch
.dloop:
    jcxz .ddone
    mov al, '-'
    mov ah, 0x0E
    mov bh, 0
    int 0x10
    loop .dloop
.ddone:
    mov si, bar_close
    call print

    mov al, [pct_val]
    call print_pct
    mov si, pct_suffix
    call print

    popa
    ret

; =====================================================================
; print_pct: AL = 0-100, prints as decimal (no leading zeros), no newline
; =====================================================================
print_pct:
    push ax
    push bx
    push cx
    push dx

    xor ah, ah
    mov bl, 100
    div bl                   ; al = hundreds digit (0/1), ah = remainder
    mov cl, al
    mov al, ah
    xor ah, ah
    mov bl, 10
    div bl                   ; al = tens digit, ah = ones digit
    mov ch, al
    mov dl, ah

    cmp cl, 0
    je .skiphundreds
    add cl, '0'
    mov al, cl
    mov ah, 0x0E
    mov bh, 0
    int 0x10
.skiphundreds:
    cmp cl, 0
    jne .forcetens
    cmp ch, 0
    je .skiptens
.forcetens:
    add ch, '0'
    mov al, ch
    mov ah, 0x0E
    mov bh, 0
    int 0x10
.skiptens:
    add dl, '0'
    mov al, dl
    mov ah, 0x0E
    mov bh, 0
    int 0x10

    pop dx
    pop cx
    pop bx
    pop ax
    ret

; =====================================================================
print:
    pusha
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
    popa
    ret

; ---------------------------------------------------------------------
boot_drive   db 0
remaining    dw 0
this_count   dw 0
move_words   dw 0
cur_lba_lo   dw 0
cur_lba_hi   dw 0
dest_lin     dd 0

msg_banner  db "fastfetchlinux bootloader", 13, 10, 0
msg_realmode db "  loading setup...", 13, 10, 0
msg_patch    db "  patching header...", 13, 10, 0
msg_diskerr  db "DISK READ ERROR", 13, 10, 0

; --- boot animation strings/state ---
msg_header      db "FASTFETCHLINUX", 0
msg_loading     db "Loading absolutely unnecessary operating system...", 0
LOADING_TEXT_LEN equ 50
msg_done_suffix db " DONE", 0
msg_booting     db "Booting...", 0

bar_open        db "[", 0
bar_close       db "] ", 0
pct_suffix      db "%  ", 0

sectors_done    dd 0
last_pct        db 0
pct_val         db 0
hash_count      db 0

cmdline_str db "console=ttyS0 quiet rdinit=/sbin/ffinit", 0

; Disk Address Packet for INT 13h/42h
align 4
dap:
    db 0x10
    db 0
dap_count:    dw 0
dap_buf_off:  dw 0
dap_buf_seg:  dw 0
dap_lba_lo:   dd 0
              dd 0

; GDT for INT15h/87h big-memory moves (source is always STAGING_SEG=0x20000)
align 8
gdt_move:
    dq 0                                    ; 00h null
    dw 0x002F                               ; 08h GDT self-descriptor
    dw gdt_move
    db 0, 0x93, 0, 0
    dw 0xFFFF, 0x0000                       ; 10h source: base=0x020000
    db 0x02, 0x93, 0x00, 0x00
    dw 0xFFFF                               ; 18h destination (base patched at runtime)
gdt_move_dest_base_lo: dw 0x0000
gdt_move_dest_base_mid: db 0x00
    db 0x93
    db 0x00
gdt_move_dest_base_hi: db 0x00
    dw 0xFFFF, 0x0000                       ; 20h BIOS CS
    db 0x00, 0x9B, 0x00, 0x00
    dw 0xFFFF, 0x0000                       ; 28h BIOS DS/SS
    db 0x00, 0x93, 0x00, 0x00
