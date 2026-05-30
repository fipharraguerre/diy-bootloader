; stage1.asm - LBA version
BITS 16
ORG 0x7C00

start:
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7C00
    mov [boot_drive], dl

    ; Load stage2 via LBA (sectors 2-5 → 0x8000)
    mov si, dap
    mov ah, 0x42
    mov dl, [boot_drive]
    int 0x13
    jc disk_error

    jmp 0x0000:0x8000

disk_error:
    mov si, err_msg
.p: lodsb
    or al, al
    jz .h
    mov ah, 0x0E
    xor bh, bh
    int 0x10
    jmp .p
.h: cli
    hlt

boot_drive  db 0

align 4
dap:
    db 0x10         ; packet size
    db 0x00         ; reserved
    dw 4            ; read 4 sectors (stage2 = 2048 bytes)
    dw 0x8000       ; destination offset
    dw 0x0000       ; destination segment
    dd 1            ; LBA = 1 (second sector, 0-based)
    dd 0

err_msg db "Disk error!", 0

times 510-($-$$) db 0
dw 0xAA55
