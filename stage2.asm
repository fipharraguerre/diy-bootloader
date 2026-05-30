; stage2.asm
BITS 16
ORG 0x8000

BMP_LOAD_SEG        equ 0x0900
BMP_SECTOR          equ 6
BMP_SECTOR_COUNT    equ 35
BMP_PIXEL_OFFSET    equ 1078
MAX_PER_READ        equ 18

SCREEN_W            equ 320
SCREEN_H            equ 200
IMG_W               equ 128
IMG_H               equ 128
IMG_ROW_BYTES       equ 128

ORIGIN_X            equ (SCREEN_W - IMG_W) / 2
ORIGIN_Y            equ (SCREEN_H - IMG_H) / 2

FADE_STEPS          equ 64      ; brightness levels 0..63
VBLANKS_PER_STEP    equ 3       ; ~3s total fade (64 * 3 / 70Hz ≈ 2.7s)
HOLD_VBLANKS        equ 210     ; ~3s hold (210 / 70Hz = 3s)

start:
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7C00
    mov [boot_drive], dl

    mov ax, 0x0013
    int 0x10

    call load_bmp
    call clear_screen
    call blit_tux           ; draw once, never touch framebuffer again

fade_loop:
    ; Fade in: brightness 0 → 63
    mov byte [brightness], 0
.fi:
    mov cl, VBLANKS_PER_STEP
.fi_vb: call wait_vblank
    dec cl
    jnz .fi_vb
    movzx bx, byte [brightness]
    call apply_palette
    inc byte [brightness]
    cmp byte [brightness], FADE_STEPS
    jl .fi

    ; Hold at full brightness
    mov cx, HOLD_VBLANKS
.hold:
    call wait_vblank
    loop .hold

    ; Fade out: brightness 63 → 0
    mov byte [brightness], FADE_STEPS - 1
.fo:
    mov cl, VBLANKS_PER_STEP
.fo_vb: call wait_vblank
    dec cl
    jnz .fo_vb
    movzx bx, byte [brightness]
    call apply_palette
    cmp byte [brightness], 0
    je .fo_done
    dec byte [brightness]
    jmp .fo
.fo_done:

    ; Brief black pause (~0.5s) before looping
    mov cx, 35
.pause: call wait_vblank
    loop .pause

    jmp fade_loop

; ─────────────────────────────────────────────
; apply_palette: BX = brightness (0..63)
; Reads original palette from BMP, scales each component, writes to DAC
apply_palette:
    push ds
    push bx                 ; save brightness

    mov ax, BMP_LOAD_SEG
    mov ds, ax
    mov si, 54              ; BMP palette offset

    mov dx, 0x3C8
    xor al, al
    out dx, al              ; DAC write index = 0

    mov dx, 0x3C9
    mov cx, 256

.pal_loop:
    ; R
    mov al, [si+2]
    shr al, 2               ; 8-bit → 6-bit (0..63)
    call scale_component
    out dx, al
    ; G
    mov al, [si+1]
    shr al, 2
    call scale_component
    out dx, al
    ; B
    mov al, [si]
    shr al, 2
    call scale_component
    out dx, al
    add si, 4
    loop .pal_loop

    pop bx
    pop ds
    ret

; al = component (0..63), bx = brightness (0..63) → al = al*bx/63
; uses AX for mul so save/restore carefully
scale_component:
    push cx
    push dx
    movzx ax, al
    mul bx                  ; DX:AX = component * brightness (max 63*63=3969, fits in AX)
    mov cx, 63
    div cx                  ; AX = result / 63, DX = remainder
    pop dx
    pop cx
    ret                     ; AL = scaled component

; ─────────────────────────────────────────────
; Wait for vertical blank rising edge (port 0x3DA bit 3)
wait_vblank:
    mov dx, 0x3DA
.not_blank:
    in al, dx
    test al, 0x08
    jnz .not_blank          ; spin until we're OUT of vblank
.blank:
    in al, dx
    test al, 0x08
    jz .blank               ; spin until vblank STARTS
    ret

; ─────────────────────────────────────────────
clear_screen:
    mov ax, 0xA000
    mov es, ax
    xor di, di
    mov cx, SCREEN_W * SCREEN_H
    xor al, al
    rep stosb
    xor ax, ax
    mov es, ax
    ret

; ─────────────────────────────────────────────
blit_tux:
    xor bx, bx

.row_loop:
    cmp bx, IMG_H
    jge .done

    movzx eax, bx
    mov ecx, IMG_ROW_BYTES
    mul ecx
    add eax, BMP_PIXEL_OFFSET
    mov si, ax

    mov ax, IMG_H - 1
    sub ax, bx
    add ax, ORIGIN_Y
    mov cx, SCREEN_W
    mul cx
    add ax, ORIGIN_X
    mov di, ax

    push ds
    mov ax, BMP_LOAD_SEG
    mov ds, ax
    mov ax, 0xA000
    mov es, ax
    mov cx, IMG_ROW_BYTES
    rep movsb
    pop ds

    inc bx
    jmp .row_loop
.done:
    ret

; ─────────────────────────────────────────────
; Disk Address Packet for int 13h extended read
align 4
dap:
    db 0x10         ; packet size
    db 0x00         ; reserved
    dw 0            ; sectors to read (filled at runtime)
    dw 0            ; buffer offset (filled at runtime)
    dw BMP_LOAD_SEG ; buffer segment
    dd 0            ; LBA low dword (filled at runtime)
    dd 0            ; LBA high dword (always 0 for us)

load_bmp:
    mov ax, BMP_LOAD_SEG
    mov es, ax
    xor bx, bx

    mov byte [sectors_remaining], BMP_SECTOR_COUNT
    mov dword [dap+8], BMP_SECTOR   ; starting LBA

.chunk:
    ; Clamp to 18 sectors per read (safe for all implementations)
    mov al, [sectors_remaining]
    cmp al, 18
    jle .set_count
    mov al, 18
.set_count:
    movzx ax, al
    mov [dap+2], ax             ; sector count into DAP
    mov [sectors_this_read], al

    ; Buffer offset advances as we load
    mov [dap+4], bx

    mov ah, 0x42                ; extended read
    mov dl, [boot_drive]
    mov si, dap                 ; DS:SI → DAP
    int 0x13
    jc disk_error

    ; Advance buffer pointer
    movzx ax, byte [sectors_this_read]
    mov cx, 512
    mul cx
    add bx, ax

    ; Advance LBA
    movzx eax, byte [sectors_this_read]
    add [dap+8], eax

    mov al, [sectors_this_read]
    sub [sectors_remaining], al
    jnz .chunk

    xor ax, ax
    mov es, ax
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
boot_drive          db 0
brightness          db 0
sectors_remaining   db 0
current_sector      db 0
sectors_this_read   db 0
cyl                 db 0
head                db 0
sect                db 0
err_msg             db "Disk read error!", 0

times 2048-($-$$) db 0
