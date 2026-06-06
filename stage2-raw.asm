; stage2-raw.asm
; Disk layout:
;   sector 0        stage1 (512 bytes)
;   sectors 1–4     stage2-raw (2048 bytes)
;   sector 5        unused
;   sectors 6–39    tux-8.raw (768 palette + 16384 pixels = 17152 bytes)
;
; Raw blob format:
;   768 bytes   palette: 256 × (R, G, B), 6-bit components (0..63)
;   16384 bytes pixels:  128×128, top-to-bottom, left-to-right, one byte per index

BITS 16
ORG 0x8000

RAW_LOAD_SEG    equ 0x0900      ; physical 0x9000, safe below 0xA0000
RAW_SECTOR      equ 5
RAW_SECTORS     equ 34          ; 17152 bytes = 34 × 512
MAX_PER_READ    equ 18          ; safe chunk size for all BIOS implementations

SCREEN_W        equ 320
SCREEN_H        equ 200
IMG_W           equ 128
IMG_H           equ 128

ORIGIN_X        equ (SCREEN_W - IMG_W) / 2
ORIGIN_Y        equ (SCREEN_H - IMG_H) / 2

PALETTE_BYTES   equ 768         ; 256 × 3
PIXEL_BYTES     equ IMG_W * IMG_H

start:
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7C00
    mov [boot_drive], dl

    mov ax, 0x0013
    int 0x10

    call load_raw
    call write_palette
    call blit
    jmp $

; ─────────────────────────────────────────────
; load_raw: read RAW_SECTORS sectors from LBA RAW_SECTOR into RAW_LOAD_SEG:0000
load_raw:
    mov byte [sectors_remaining], RAW_SECTORS
    mov dword [dap+8], RAW_SECTOR

    mov ax, RAW_LOAD_SEG
    mov es, ax
    xor bx, bx              ; buffer offset starts at 0

.chunk:
    mov al, [sectors_remaining]
    cmp al, MAX_PER_READ
    jle .set_count
    mov al, MAX_PER_READ
.set_count:
    mov [dap+2], al
    mov [sectors_this_read], al
    mov [dap+4], bx

    mov ah, 0x42
    mov dl, [boot_drive]
    mov si, dap
    int 0x13
    jc disk_error

    movzx ax, byte [sectors_this_read]
    mov cx, 512
    mul cx
    add bx, ax

    movzx eax, byte [sectors_this_read]
    add [dap+8], eax

    mov al, [sectors_this_read]
    sub [sectors_remaining], al
    jnz .chunk

    xor ax, ax
    mov es, ax
    ret

; ─────────────────────────────────────────────
; write_palette: send 768 bytes from RAW_LOAD_SEG:0000 to VGA DAC
write_palette:
    push ds

    mov ax, RAW_LOAD_SEG
    mov ds, ax
    xor si, si              ; palette starts at offset 0

    mov dx, 0x3C8
    xor al, al
    out dx, al              ; DAC write index = 0

    mov dx, 0x3C9
    mov cx, PALETTE_BYTES   ; 768 bytes = 256 × 3 components
.pal:
    lodsb
    out dx, al
    loop .pal

    pop ds
    ret

; ─────────────────────────────────────────────
; blit: copy 128×128 pixels from RAW_LOAD_SEG:768 to VGA framebuffer
blit:
    push ds

    mov ax, RAW_LOAD_SEG
    mov ds, ax
    mov si, PALETTE_BYTES   ; pixels start right after palette

    mov ax, 0xA000
    mov es, ax

    mov bx, ORIGIN_Y        ; starting row on screen
    mov cx, IMG_H

.row:
    ; DI = (row * SCREEN_W) + ORIGIN_X
    mov ax, bx
    mov dx, SCREEN_W
    mul dx
    add ax, ORIGIN_X
    mov di, ax

    push cx
    mov cx, IMG_W
    rep movsb
    pop cx

    inc bx
    loop .row

    pop ds
    ret

; ─────────────────────────────────────────────
disk_error:
    mov ax, 0x0003
    int 0x10
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

; ─────────────────────────────────────────────
align 4
dap:
    db 0x10
    db 0x00
    dw 0                    ; sector count (filled at runtime)
    dw 0                    ; buffer offset (filled at runtime)
    dw RAW_LOAD_SEG
    dd 0                    ; LBA low (filled at runtime)
    dd 0                    ; LBA high

boot_drive          db 0
sectors_remaining   db 0
sectors_this_read   db 0
err_msg             db "Disk read error!", 0

times 2048-($-$$) db 0
