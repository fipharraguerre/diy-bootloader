; stage2-raw.asm
; Disk layout:
;   sector 0        stage1 (512 bytes)
;   sectors 1–4     stage2-raw (2048 bytes)
;   sectors 5–38    tux-8.raw (768 palette + 16384 pixels = 17152 bytes, 34 sectors)
;
; Raw blob format:
;   768 bytes   palette: 256 × (R, G, B), 6-bit components (0..63)
;   16384 bytes pixels:  128×128, top-to-bottom, left-to-right, one byte per index
;
; Text overlay:
;   Tux occupies palette indices 0..252 and is scaled every frame by the
;   fade loop. Index 253 is reserved as fixed white for the static caption
;   ("wrong way penguin custom bootloader") and is written once, never
;   touched by apply_palette, so it stays at full brightness while Tux
;   fades in/out around it — same trick the old BIOS POST text + Energy
;   Star logo used: shared framebuffer, independently animated palette
;   entries.
;
;   Free palette indices confirmed unused by tux-8.raw's pixel data:
;   66, 206, 207, 210-252, 253, 254, 255 (49 total) — 253 picked arbitrarily
;   from that set as text-white.

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

; ── Text overlay constants ──
TEXT_COLOR_INDEX  equ 253       ; reserved palette slot, fixed white, never faded
TUX_PAL_COUNT     equ 253       ; apply_palette scales indices 0..252 only
GLYPH_W           equ 8
GLYPH_H           equ 8
TEXT_X            equ 20        ; (320 - 35*8) / 2 = 20, centers the 35-char string
TEXT_Y            equ 178       ; centered in the 36px band below Tux (164..199)

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

    call load_raw
    call patch_text_color   ; force palette slot 253 to white in RAM before it's ever sent to the DAC
    call clear_screen       ; explicit clear — don't assume BIOS left 0xA0000 blank
    call write_palette      ; initial full 256-entry load (Tux colors + text white)
    call blit               ; draw Tux once
    call draw_text          ; draw caption once, never touched again

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
; patch_text_color: overwrite palette slot TEXT_COLOR_INDEX (in the loaded
; RAM copy) with full-brightness white, so both the initial write_palette
; and the never-scaled DAC slot show white regardless of what tux-8.raw
; happened to store there.
patch_text_color:
    push ds
    mov ax, RAW_LOAD_SEG
    mov ds, ax
    mov bx, TEXT_COLOR_INDEX * 3
    mov byte [bx], 63       ; R
    mov byte [bx+1], 63     ; G
    mov byte [bx+2], 63     ; B
    pop ds
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
; apply_palette: BX = brightness (0..63)
; Reads original palette from RAW_LOAD_SEG:0, scales only indices
; 0..TUX_PAL_COUNT-1 (Tux's own colors) and writes them to the DAC.
; Index TEXT_COLOR_INDEX and above are left untouched in hardware —
; whatever write_palette set them to (white) persists at full brightness.
apply_palette:
    push ds
    push bx                 ; save brightness

    mov ax, RAW_LOAD_SEG
    mov ds, ax
    xor si, si              ; palette starts at offset 0 (raw blob layout)

    mov dx, 0x3C8
    xor al, al
    out dx, al              ; DAC write index = 0

    mov dx, 0x3C9
    mov cx, TUX_PAL_COUNT    ; only Tux's own palette entries

.pal_loop:
    ; R
    lodsb
    call scale_component
    out dx, al
    ; G
    lodsb
    call scale_component
    out dx, al
    ; B
    lodsb
    call scale_component
    out dx, al
    loop .pal_loop

    pop bx
    pop ds
    ret

; al = component (0..63), bx = brightness (0..63) → al = al*bx/63
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
; draw_text: blit the caption string using the 8x8 font table.
; Foreground pixels use TEXT_COLOR_INDEX; background bits are skipped
; (left as whatever clear_screen put there), so no background box is drawn.
; DS is assumed 0 throughout (flat addressing, consistent with the rest
; of this file) — font_table and message live in this same segment.
draw_text:
    mov ax, 0xA000
    mov es, ax

    mov si, message

.char_loop:
    lodsb                    ; AL = next character, DS:SI advances
    or al, al
    jz .done

    call get_glyph_ptr       ; BX = pointer to this char's 8-byte glyph

    push si                  ; save string pointer (SI reused below as row index)
    xor si, si               ; SI = row index 0..7

.row_loop:
    mov al, [bx+si]          ; glyph row byte

    ; DI = (TEXT_Y + row) * SCREEN_W + cursor_x
    push ax                  ; save row byte
    mov ax, si
    add ax, TEXT_Y
    mov dx, SCREEN_W
    mul dx                   ; AX = (TEXT_Y+row)*SCREEN_W ; max 185*320=59200, fits in AX
    add ax, [cursor_x]
    mov di, ax
    pop ax                   ; restore row byte into AL

    mov ah, 0x80             ; leftmost-pixel bit mask (AH, not BL — BX is the glyph pointer)
    mov cx, GLYPH_W          ; 8 columns
.bit_loop:
    test al, ah
    jz .skip_px
    mov byte [es:di], TEXT_COLOR_INDEX
.skip_px:
    inc di
    shr ah, 1
    loop .bit_loop

    inc si
    cmp si, GLYPH_H
    jl .row_loop

    pop si                   ; restore string pointer
    add word [cursor_x], GLYPH_W
    jmp .char_loop

.done:
    xor ax, ax
    mov es, ax
    ret

; get_glyph_ptr: AL = ASCII char (space or a-z only) → BX = glyph table pointer
get_glyph_ptr:
    cmp al, ' '
    jne .not_space
    mov bx, font_table
    ret
.not_space:
    sub al, 'a'
    movzx bx, al
    shl bx, 3                ; × 8 bytes per glyph
    add bx, font_table + 8   ; +8 to skip the space glyph
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
brightness          db 0
err_msg             db "Disk read error!", 0
message             db "wrong way penguin custom bootloader", 0
cursor_x            dw TEXT_X

; 8x8 font, extracted from the real Linux console font Lat15-VGA8.psf
; (glyph index = ASCII code, standard IBM VGA bitmap), covering space + a-z.
font_table:
; ' '
    db 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
; 'a'
    db 0x00, 0x00, 0x78, 0x0C, 0x7C, 0xCC, 0x76, 0x00
; 'b'
    db 0xE0, 0x60, 0x7C, 0x66, 0x66, 0x66, 0xDC, 0x00
; 'c'
    db 0x00, 0x00, 0x7C, 0xC6, 0xC0, 0xC6, 0x7C, 0x00
; 'd'
    db 0x1C, 0x0C, 0x7C, 0xCC, 0xCC, 0xCC, 0x76, 0x00
; 'e'
    db 0x00, 0x00, 0x7C, 0xC6, 0xFE, 0xC0, 0x7C, 0x00
; 'f'
    db 0x3C, 0x66, 0x60, 0xF8, 0x60, 0x60, 0xF0, 0x00
; 'g'
    db 0x00, 0x00, 0x76, 0xCC, 0xCC, 0x7C, 0x0C, 0xF8
; 'h'
    db 0xE0, 0x60, 0x6C, 0x76, 0x66, 0x66, 0xE6, 0x00
; 'i'
    db 0x18, 0x00, 0x38, 0x18, 0x18, 0x18, 0x3C, 0x00
; 'j'
    db 0x06, 0x00, 0x06, 0x06, 0x06, 0x66, 0x66, 0x3C
; 'k'
    db 0xE0, 0x60, 0x66, 0x6C, 0x78, 0x6C, 0xE6, 0x00
; 'l'
    db 0x38, 0x18, 0x18, 0x18, 0x18, 0x18, 0x3C, 0x00
; 'm'
    db 0x00, 0x00, 0xEC, 0xFE, 0xD6, 0xD6, 0xD6, 0x00
; 'n'
    db 0x00, 0x00, 0xDC, 0x66, 0x66, 0x66, 0x66, 0x00
; 'o'
    db 0x00, 0x00, 0x7C, 0xC6, 0xC6, 0xC6, 0x7C, 0x00
; 'p'
    db 0x00, 0x00, 0xDC, 0x66, 0x66, 0x7C, 0x60, 0xF0
; 'q'
    db 0x00, 0x00, 0x76, 0xCC, 0xCC, 0x7C, 0x0C, 0x1E
; 'r'
    db 0x00, 0x00, 0xDC, 0x76, 0x60, 0x60, 0xF0, 0x00
; 's'
    db 0x00, 0x00, 0x7E, 0xC0, 0x7C, 0x06, 0xFC, 0x00
; 't'
    db 0x30, 0x30, 0xFC, 0x30, 0x30, 0x36, 0x1C, 0x00
; 'u'
    db 0x00, 0x00, 0xCC, 0xCC, 0xCC, 0xCC, 0x76, 0x00
; 'v'
    db 0x00, 0x00, 0xC6, 0xC6, 0xC6, 0x6C, 0x38, 0x00
; 'w'
    db 0x00, 0x00, 0xC6, 0xD6, 0xD6, 0xFE, 0x6C, 0x00
; 'x'
    db 0x00, 0x00, 0xC6, 0x6C, 0x38, 0x6C, 0xC6, 0x00
; 'y'
    db 0x00, 0x00, 0xC6, 0xC6, 0xC6, 0x7E, 0x06, 0xFC
; 'z'
    db 0x00, 0x00, 0x7E, 0x4C, 0x18, 0x32, 0x7E, 0x00

times 2048-($-$$) db 0
