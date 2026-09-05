; fastfetchlinux-init (ffinit) - our own PID 1, our own shell, our own commands.
; No busybox, no libc, no crt0: pure Linux i386 syscalls via int 0x80.
; Syscall numbers verified against our own kernel source
; (arch/x86/entry/syscalls/syscall_32.tbl); reboot magic/cmd values from
; include/uapi/linux/reboot.h.

BITS 32

%define SYS_EXIT       1
%define SYS_FORK       2
%define SYS_READ       3
%define SYS_WRITE      4
%define SYS_OPEN       5
%define SYS_CLOSE      6
%define SYS_EXECVE     11
%define SYS_GETPID     20
%define SYS_MOUNT      21
%define SYS_SIGNAL     48
%define SYS_SETHOSTNAME 74
%define SYS_REBOOT     88
%define SYS_WAIT4      114
%define SYS_GETDENTS64 220

section .data

proc_src:   db "proc", 0
proc_tgt:   db "/proc", 0
proc_type:  db "proc", 0

sys_src:    db "sysfs", 0
sys_tgt:    db "/sys", 0
sys_type:   db "sysfs", 0

dev_src:    db "devtmpfs", 0
dev_tgt:    db "/dev", 0
dev_type:   db "devtmpfs", 0

hostname_path: db "/etc/hostname", 0

fastfetch_path: db "/bin/fastfetch", 0
fastfetch_argv: dd fastfetch_path, 0

env_user:    db "USER=root", 0
env_logname: db "LOGNAME=root", 0
env_home:    db "HOME=/root", 0
env_shell:   db "SHELL=/sbin/ffinit", 0
env_path:    db "PATH=/bin", 0
envp:        dd env_user, env_logname, env_home, env_shell, env_path, 0

msg_banner:     db 10, "ffinit", 10, 0
msg_prompt:     db 10, "fastfetchlinux shell. type 'help' for commands.", 10, 10, 0
err_notpid1:    db "ffinit: PID 1 olarak calistirilmali", 10, 0
prompt_str:     db "~ # ", 0
err_unknown:    db ": komut bulunamadi", 10, 0

bin_path:       db "/bin", 0
block_path:     db "/sys/block", 0
size_suffix:    db "/size", 0
dev_prefix:     db "/dev/", 0
block_prefix:   db "/sys/block/", 0

img_path:       db "/root/fastfetchlinux.img", 0
err_noimg:      db "install-disk: /root/fastfetchlinux.img bulunamadi (bu live/installer ortami degil)", 10, 0
err_nodisk:     db "install-disk: hicbir disk bulunamadi", 10, 0

sysrq_path:     db "/proc/sysrq-trigger", 0
panic_char:     db "c"
err_nopanic:    db "forcepanic: sysrq-trigger yazilamadi (CONFIG_MAGIC_SYSRQ?)", 10, 0

help_text:
    db 10
    db "Available commands:", 10, 10
    db "  fastfetch     Display system information", 10
    db "  ls            List /bin", 10
    db "  install-disk  Install fastfetchlinux onto a disk", 10
    db "  forcepanic    Trigger a kernel panic, on purpose", 10
    db "  poweroff      Turn off the computer", 10
    db 10
    db "That's all. 5 commands.", 10
    db "0 packages.", 10
    db "0 purpose.", 10, 0
msg_pick:       db 10, "Kuruluma hangi diski hedefleyelim? [numara, veya q ile cik]: ", 0
msg_cancel:     db "Iptal edildi.", 10, 0
msg_badchoice:  db "Gecersiz secim.", 10, 0
msg_warn1:      db 10, "!!!! UYARI: secilen diskin TUM VERISI SILINECEK !!!!", 10, 0
msg_confirm:    db "Devam etmek icin diskin adini (orn. /dev/vda) tekrar yazip Enter'a basin: ", 0
msg_mismatch:   db "Onay eslesmedi, iptal edildi.", 10, 0
msg_writing:    db "Yaziliyor...", 10, 0
msg_done:       db "Tamamlandi. Bu diskten boot edebilirsiniz.", 10, 0
paren_open:     db ") ", 0
mib_suffix:     db " MiB", 10, 0

section .bss

line_buf:     resb 128
dirent_buf:   resb 4096
copy_buf:     resb 65536

disk_names:   resb 16*32     ; up to 16 disks, 32 bytes each
disk_count:   resd 1

path_buf:     resb 128       ; scratch path buffer
num_buf:      resb 16        ; scratch number->ascii buffer

ls_total:     resd 1
ls_off:       resd 1
ls_reclen:    resd 1

blk_total:    resd 1
blk_off:      resd 1
blk_reclen:   resd 1
name_ptr:     resd 1

section .text
global _start

; =====================================================================
; helpers
; =====================================================================

; strlen: esi = string ptr -> returns ecx = length
strlen:
    xor ecx, ecx
.loop:
    cmp byte [esi + ecx], 0
    je .done
    inc ecx
    jmp .loop
.done:
    ret

; write_str: esi = null-terminated string, fd in ebx
write_str:
    push ebx
    call strlen
    mov edx, ecx
    mov ecx, esi
    mov eax, SYS_WRITE
    int 0x80
    pop ebx
    ret

; write_out: shortcut, fd=1
write_out:
    push ebx
    mov ebx, 1
    call write_str
    pop ebx
    ret

; streq: esi, edi = two null-terminated strings -> eax=1 if equal, 0 if not
streq:
    push esi
    push edi
.loop:
    mov al, [esi]
    mov ah, [edi]
    cmp al, ah
    jne .neq
    test al, al
    jz .eq
    inc esi
    inc edi
    jmp .loop
.eq:
    pop edi
    pop esi
    mov eax, 1
    ret
.neq:
    pop edi
    pop esi
    xor eax, eax
    ret

; starts_with: esi=string, edi=prefix -> eax=1 if esi starts with prefix
starts_with:
    push esi
    push edi
.loop:
    mov al, [edi]
    test al, al
    jz .yes
    mov ah, [esi]
    cmp al, ah
    jne .no
    inc esi
    inc edi
    jmp .loop
.yes:
    pop edi
    pop esi
    mov eax, 1
    ret
.no:
    pop edi
    pop esi
    xor eax, eax
    ret

; strcpy: esi=src, edi=dst -> copies including null terminator, edi left past end
strcpy:
.loop:
    mov al, [esi]
    mov [edi], al
    inc esi
    inc edi
    test al, al
    jnz .loop
    ret

; read_line: reads a line from stdin into line_buf (max 127), strips \n,
; null-terminates. Returns length in eax.
read_line:
    mov eax, SYS_READ
    mov ebx, 0
    mov ecx, line_buf
    mov edx, 127
    int 0x80
    cmp eax, 0
    jg .strip
    mov eax, 0
    mov byte [line_buf], 0
    ret
.strip:
    mov ecx, eax
    mov esi, line_buf
.scan:
    cmp dword ecx, 0
    je .term
    cmp byte [esi + ecx - 1], 10
    jne .term
    dec ecx
    jmp .scan
.term:
    mov byte [line_buf + ecx], 0
    mov eax, ecx
    ret

; itoa_unsigned: eax = number -> writes ascii digits to num_buf, returns
; ecx=length. (simple, base 10, no sign)
itoa_unsigned:
    mov edi, num_buf
    test eax, eax
    jnz .conv
    mov byte [edi], '0'
    inc edi
    mov byte [edi], 0
    jmp .fin
.conv:
    push ebp
    mov ebp, edi           ; remember start
    mov ecx, 10
.digits:
    xor edx, edx
    div ecx
    add dl, '0'
    mov [edi], dl
    inc edi
    test eax, eax
    jnz .digits
    mov byte [edi], 0      ; null-terminate (num_buf is reused across calls)
    mov ecx, edi           ; save end pointer (length = ecx - num_buf, computed below)
    ; reverse [ebp .. edi-1]
    mov esi, ebp
    dec edi
.rev:
    cmp esi, edi
    jge .revdone
    mov al, [esi]
    mov ah, [edi]
    mov [esi], ah
    mov [edi], al
    inc esi
    dec edi
    jmp .rev
.revdone:
    mov edi, ecx           ; restore end pointer
    pop ebp
.fin:
    mov ecx, edi
    sub ecx, num_buf
    ret

; atoi_simple: esi = string -> eax = parsed unsigned integer (leading digits)
atoi_simple:
    xor eax, eax
.loop:
    movzx edx, byte [esi]
    cmp edx, '0'
    jl .done
    cmp edx, '9'
    jg .done
    imul eax, eax, 10
    sub edx, '0'
    add eax, edx
    inc esi
    jmp .loop
.done:
    ret

; =====================================================================
; set_hostname: read /etc/hostname, strip trailing newline, sethostname()
; =====================================================================
set_hostname:
    mov eax, SYS_OPEN
    mov ebx, hostname_path
    xor ecx, ecx
    xor edx, edx
    int 0x80
    cmp eax, 0
    jl .done

    mov ebp, eax

    mov eax, SYS_READ
    mov ebx, ebp
    mov ecx, line_buf
    mov edx, 120
    int 0x80
    cmp eax, 0
    jle .close

    mov ecx, line_buf
    mov edx, eax
    xor esi, esi
.scan:
    cmp esi, edx
    jge .scandone
    cmp byte [ecx + esi], 10
    je .scandone
    inc esi
    jmp .scan
.scandone:
    mov byte [ecx + esi], 0

    mov eax, SYS_SETHOSTNAME
    mov ebx, line_buf
    mov ecx, esi
    int 0x80

.close:
    mov eax, SYS_CLOSE
    mov ebx, ebp
    int 0x80
.done:
    ret

; =====================================================================
; run_fastfetch: fork + execve(/bin/fastfetch) + wait4
; =====================================================================
run_fastfetch:
    mov eax, SYS_FORK
    int 0x80
    cmp eax, 0
    jne .wait

    mov eax, SYS_EXECVE
    mov ebx, fastfetch_path
    mov ecx, fastfetch_argv
    mov edx, envp
    int 0x80
    mov eax, SYS_EXIT
    mov ebx, 127
    int 0x80

.wait:
    mov ebx, eax
    mov eax, SYS_WAIT4
    xor ecx, ecx
    xor edx, edx
    xor esi, esi
    int 0x80
    ret

; =====================================================================
; cmd_ls: list /bin directory contents (skips "." and "..")
; =====================================================================
cmd_ls:
    mov eax, SYS_OPEN
    mov ebx, bin_path
    xor ecx, ecx
    xor edx, edx
    int 0x80
    cmp eax, 0
    jl .ret
    mov ebp, eax            ; dir fd

.readmore:
    mov eax, SYS_GETDENTS64
    mov ebx, ebp
    mov ecx, dirent_buf
    mov edx, 4096
    int 0x80
    cmp eax, 0
    jle .closeit

    mov [ls_total], eax      ; total bytes in buffer
    mov dword [ls_off], 0
.entloop:
    mov eax, [ls_off]
    cmp eax, [ls_total]
    jge .readmore

    mov ebx, eax
    movzx edx, word [dirent_buf + ebx + 16]   ; d_reclen
    mov [ls_reclen], edx
    lea eax, [dirent_buf + ebx + 19]          ; d_name ptr

    ; skip "." and ".."
    cmp byte [eax], '.'
    jne .printit
    cmp byte [eax + 1], 0
    je .skip
    cmp byte [eax + 1], '.'
    jne .printit
    cmp byte [eax + 2], 0
    je .skip

.printit:
    mov esi, eax
    call write_out
    mov ebx, 1
    mov ecx, nl_char
    mov edx, 1
    mov eax, SYS_WRITE
    int 0x80

.skip:
    mov eax, [ls_off]
    add eax, [ls_reclen]
    mov [ls_off], eax
    jmp .entloop

.closeit:
    mov eax, SYS_CLOSE
    mov ebx, ebp
    int 0x80
.ret:
    ret

section .data
nl_char: db 10
section .text

; =====================================================================
; cmd_install_disk: enumerate /sys/block, let user pick, confirm, copy
; the embedded /root/fastfetchlinux.img onto the chosen device.
; =====================================================================
cmd_install_disk:
    ; verify the embedded image exists
    mov eax, SYS_OPEN
    mov ebx, img_path
    xor ecx, ecx
    xor edx, edx
    int 0x80
    cmp eax, 0
    jl .noimg
    mov ebx, eax
    mov eax, SYS_CLOSE
    int 0x80

    mov dword [disk_count], 0

    mov eax, SYS_OPEN
    mov ebx, block_path
    xor ecx, ecx
    xor edx, edx
    int 0x80
    cmp eax, 0
    jl .nodisk
    mov ebp, eax             ; dir fd

.readmore:
    mov eax, SYS_GETDENTS64
    mov ebx, ebp
    mov ecx, dirent_buf
    mov edx, 4096
    int 0x80
    cmp eax, 0
    jle .listdone

    mov [blk_total], eax
    mov dword [blk_off], 0
.entloop:
    mov eax, [blk_off]
    cmp eax, [blk_total]
    jge .readmore

    mov ebx, eax
    movzx edx, word [dirent_buf + ebx + 16]   ; d_reclen
    mov [blk_reclen], edx
    lea eax, [dirent_buf + ebx + 19]          ; d_name ptr
    mov [name_ptr], eax

    ; skip "." and ".."
    cmp byte [eax], '.'
    jne .checkloop
    cmp byte [eax + 1], 0
    je .skip
    cmp byte [eax + 1], '.'
    jne .checkloop
    cmp byte [eax + 2], 0
    je .skip

.checkloop:
    mov esi, [name_ptr]
    mov edi, loop_pfx
    call starts_with
    test eax, eax
    jnz .skip

    mov esi, [name_ptr]
    mov edi, ram_pfx
    call starts_with
    test eax, eax
    jnz .skip

    mov esi, [name_ptr]
    mov edi, sr_pfx
    call starts_with
    test eax, eax
    jnz .skip

    ; passed all filters: store name into disk_names[disk_count]
    mov ecx, [disk_count]
    cmp ecx, 16
    jge .skip
    imul ebx, ecx, 32
    lea edi, [disk_names + ebx]
    mov esi, [name_ptr]
    call strcpy
    inc dword [disk_count]

.skip:
    mov eax, [blk_off]
    add eax, [blk_reclen]
    mov [blk_off], eax
    jmp .entloop

.listdone:
    mov eax, SYS_CLOSE
    mov ebx, ebp
    int 0x80

    mov eax, [disk_count]
    test eax, eax
    jz .nodisk2

    ; print numbered list
    xor ebx, ebx              ; index 0
.printloop:
    cmp ebx, [disk_count]
    jge .afterlist

    mov eax, ebx
    inc eax
    call itoa_unsigned
    push ebx
    mov esi, num_buf
    call write_out
    mov esi, paren_open
    call write_out
    mov esi, dev_prefix
    call write_out
    pop ebx

    imul eax, ebx, 32
    lea esi, [disk_names + eax]
    call write_out
    mov esi, nl_str
    call write_out

    inc ebx
    jmp .printloop

.afterlist:
    mov esi, msg_pick
    call write_out
    call read_line
    cmp eax, 0
    je .cancel
    cmp byte [line_buf], 'q'
    je .cancel

    mov esi, line_buf
    call atoi_simple
    cmp eax, 1
    jl .badchoice
    cmp eax, [disk_count]
    jg .badchoice

    dec eax
    imul eax, eax, 32
    lea esi, [disk_names + eax]
    mov edi, path_buf
    push esi
    mov esi, dev_prefix
    call strcpy
    dec edi                    ; back up over the null strcpy just wrote
    pop esi
    call strcpy               ; appends chosen name after "/dev/"

    mov esi, msg_warn1
    call write_out
    mov esi, msg_confirm
    call write_out
    call read_line

    mov esi, line_buf
    mov edi, path_buf
    call streq
    test eax, eax
    jz .mismatch

    ; open image (source) and device (destination)
    mov eax, SYS_OPEN
    mov ebx, img_path
    xor ecx, ecx
    xor edx, edx
    int 0x80
    cmp eax, 0
    jl .noimg
    mov [src_fd], eax

    mov esi, msg_writing
    call write_out

    mov eax, SYS_OPEN
    mov ebx, path_buf
    mov ecx, 1                ; O_WRONLY
    xor edx, edx
    int 0x80
    cmp eax, 0
    jl .openfail
    mov [dst_fd], eax

.copyloop:
    mov eax, SYS_READ
    mov ebx, [src_fd]
    mov ecx, copy_buf
    mov edx, 65536
    int 0x80
    cmp eax, 0
    jle .copydone
    mov ebp, eax               ; bytes read
    mov eax, SYS_WRITE
    mov ebx, [dst_fd]
    mov ecx, copy_buf
    mov edx, ebp
    int 0x80
    jmp .copyloop

.copydone:
    mov eax, SYS_CLOSE
    mov ebx, [src_fd]
    int 0x80
    mov eax, SYS_CLOSE
    mov ebx, [dst_fd]
    int 0x80
    mov esi, msg_done
    call write_out
    ret

.openfail:
    mov eax, SYS_CLOSE
    mov ebx, [src_fd]
    int 0x80
    ret

.mismatch:
    mov esi, msg_mismatch
    call write_out
    ret
.badchoice:
    mov esi, msg_badchoice
    call write_out
    ret
.cancel:
    mov esi, msg_cancel
    call write_out
    ret
.nodisk:
.nodisk2:
    mov esi, err_nodisk
    call write_out
    ret
.noimg:
    mov esi, err_noimg
    call write_out
    ret

section .data
loop_pfx: db "loop", 0
ram_pfx:  db "ram", 0
sr_pfx:   db "sr", 0
nl_str:   db 10, 0
src_fd:   dd 0
dst_fd:   dd 0
section .text

; =====================================================================
; poweroff / halt / restart via reboot(2) -- shared by shell command and
; signal handlers.
; =====================================================================
do_poweroff:
    mov eax, SYS_REBOOT
    mov ebx, 0xfee1dead
    mov ecx, 672274793
    mov edx, 0x4321FEDC
    xor esi, esi
    int 0x80
    ret

; =====================================================================
; cmd_forcepanic: trigger a REAL kernel panic via sysrq-trigger (our
; kernel prints its own custom banner from panic() before the usual
; diagnostic dump -- see kernel/panic.c).
; =====================================================================
cmd_forcepanic:
    mov eax, SYS_OPEN
    mov ebx, sysrq_path
    mov ecx, 1              ; O_WRONLY
    xor edx, edx
    int 0x80
    cmp eax, 0
    jl .fail
    mov ebx, eax

    mov eax, SYS_WRITE
    mov ecx, panic_char
    mov edx, 1
    int 0x80                ; if this returns, the kernel didn't panic

.fail:
    mov esi, err_nopanic
    call write_out
    ret

; =====================================================================
; cmd_help: list available shell commands
; =====================================================================
cmd_help:
    mov esi, help_text
    call write_out
    ret

poweroff_handler:
    call do_poweroff
.hang:
    jmp .hang

halt_handler:
    mov eax, SYS_REBOOT
    mov ebx, 0xfee1dead
    mov ecx, 672274793
    mov edx, 0xCDEF0123
    xor esi, esi
    int 0x80
.hang:
    jmp .hang

restart_handler:
    mov eax, SYS_REBOOT
    mov ebx, 0xfee1dead
    mov ecx, 672274793
    mov edx, 0x01234567
    xor esi, esi
    int 0x80
.hang:
    jmp .hang

; =====================================================================
_start:
    mov eax, SYS_GETPID
    int 0x80
    cmp eax, 1
    je .pid1_ok

    mov esi, err_notpid1
    mov ebx, 2
    call write_str
    mov eax, SYS_EXIT
    mov ebx, 1
    int 0x80

.pid1_ok:
    mov eax, SYS_SIGNAL
    mov ebx, 12                 ; SIGUSR2 -> poweroff
    mov ecx, poweroff_handler
    int 0x80
    mov eax, SYS_SIGNAL
    mov ebx, 10                 ; SIGUSR1 -> halt
    mov ecx, halt_handler
    int 0x80
    mov eax, SYS_SIGNAL
    mov ebx, 15                 ; SIGTERM -> restart
    mov ecx, restart_handler
    int 0x80

    mov esi, msg_banner
    call write_out

    mov eax, SYS_MOUNT
    mov ebx, proc_src
    mov ecx, proc_tgt
    mov edx, proc_type
    xor esi, esi
    xor edi, edi
    int 0x80

    mov eax, SYS_MOUNT
    mov ebx, sys_src
    mov ecx, sys_tgt
    mov edx, sys_type
    xor esi, esi
    xor edi, edi
    int 0x80

    mov eax, SYS_MOUNT
    mov ebx, dev_src
    mov ecx, dev_tgt
    mov edx, dev_type
    xor esi, esi
    xor edi, edi
    int 0x80

    call set_hostname
    call run_fastfetch

    mov esi, msg_prompt
    call write_out

; --- our own shell, forever ---
shell_loop:
    mov esi, prompt_str
    call write_out
    call read_line
    test eax, eax
    jz shell_loop

    mov esi, line_buf
    mov edi, cmd_fastfetch
    call streq
    test eax, eax
    jnz .do_fastfetch

    mov esi, line_buf
    mov edi, cmd_ls_str
    call streq
    test eax, eax
    jnz .do_ls

    mov esi, line_buf
    mov edi, cmd_install
    call streq
    test eax, eax
    jnz .do_install

    mov esi, line_buf
    mov edi, cmd_poweroff
    call streq
    test eax, eax
    jnz .do_poweroff

    mov esi, line_buf
    mov edi, cmd_forcepanic_str
    call streq
    test eax, eax
    jnz .do_forcepanic

    mov esi, line_buf
    mov edi, cmd_help_str
    call streq
    test eax, eax
    jnz .do_help

    mov esi, line_buf
    call write_out
    mov esi, err_unknown
    call write_out
    jmp shell_loop

.do_fastfetch:
    call run_fastfetch
    jmp shell_loop
.do_ls:
    call cmd_ls
    jmp shell_loop
.do_install:
    call cmd_install_disk
    jmp shell_loop
.do_poweroff:
    call do_poweroff
    jmp shell_loop
.do_forcepanic:
    call cmd_forcepanic
    jmp shell_loop
.do_help:
    call cmd_help
    jmp shell_loop

section .data
cmd_fastfetch:  db "fastfetch", 0
cmd_ls_str:     db "ls", 0
cmd_install:    db "install-disk", 0
cmd_poweroff:   db "poweroff", 0
cmd_forcepanic_str: db "forcepanic", 0
cmd_help_str:   db "help", 0
