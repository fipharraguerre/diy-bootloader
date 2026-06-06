; stage2-pal.asm — synthetic palette test, no BMP, no disk
; Palette:
;   0 = red   (63,0,0)
;   1 = green (0,63,0)
;   2 = blue  (0,0,63)
;   3 = black (0,0,0)
;   4..255 = greyscale ramp, entry N → DAC value (N-4)>>2
;
; Screen:
;   rows   0–99  : red (x<107) | green (107≤x<214) | blue (x≥214)
;   rows 100–199 : greyscale cols 0–255 (index=col+4), cols 256–319 black

BITS 16
ORG 0x8000

SCREEN_W    equ 320

start:
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7C00

    mov ax, 0x0013
    int 0x10

    ; ── program DAC ─────────────────────────────────────────────────────────
    mov dx, 0x3C8
    xor al, al
    out dx, al
    mov dx, 0x3C9

    ; index 0 = red
    mov al, 63
    out dx, al
    xor al, al
    out dx, al
    out dx, al

    ; index 1 = green
    xor al, al
    out dx, al
    mov al, 63
    out dx, al
    xor al, al
    out dx, al

    ; index 2 = blue
    xor al, al
    out dx, al
    out dx, al
    mov al, 63
    out dx, al

    ; index 3 = black
    xor al, al
    out dx, al
    out dx, al
    out dx, al

    ; indices 4..255 = greyscale ramp
    mov cl, 4
.ramp:
    mov al, cl
    sub al, 4
    shr al, 2               ; 0..62 across 252 entries
    out dx, al
    out dx, al
    out dx, al
    inc cl
    jnz .ramp               ; cl wraps 255→0, exits loop

    ; ── top 100 rows: colour bands ───────────────────────────────────────────
    mov ax, 0xA000
    mov es, ax
    xor di, di

    mov bx, 100             ; row counter
.top_row:
    mov cx, SCREEN_W        ; column counter (loop variable)
    xor si, si              ; column index 0..319
.top_col:
    mov al, 2               ; assume blue (x >= 214)
    cmp si, 214
    jae .tw
    mov al, 1               ; green (107 <= x < 214)
    cmp si, 107
    jae .tw
    mov al, 0               ; red (x < 107)
.tw:
    stosb
    inc si
    loop .top_col
    dec bx
    jnz .top_row

    ; ── bottom 100 rows: greyscale ramp ──────────────────────────────────────
    ; Use DL as byte column index (0..255), SI as full column counter (0..319)
    mov bx, 100             ; row counter
.bot_row:
    mov cx, SCREEN_W
    xor si, si
    xor dl, dl              ; byte column index, incremented separately
.bot_col:
    cmp si, 256
    jae .black
    mov al, dl
    add al, 4               ; palette index 4..255
    inc dl
    jmp .bw
.black:
    mov al, 3               ; black padding
.bw:
    stosb
    inc si
    loop .bot_col
    dec bx
    jnz .bot_row

    jmp $

times 2048-($-$$) db 0
