# diy-bootloader

A two-stage x86 real mode bootloader that loads a 256-color raw image blob from disk and displays it with a fade in/out effect and a static caption — no operating system, no drivers.

Built as a learning experiment to understand the PC boot process at the bare metal level.

![Tux on an Athlon II](screenshot.png)

---

## How It Works

```
BIOS → stage1 (512 bytes) → stage2-raw (2KB) → tux-8.raw → VGA framebuffer
```

**Stage 1** (`stage1.asm`) fits in the 512-byte MBR. It normalizes the CPU state, saves the boot drive number from the BIOS, loads stage 2 from disk via LBA and jumps to it.

**Stage 2** (`stage2-raw.asm`) switches the display to VGA mode 13h (320×200, 256 colors), loads a raw pixel+palette blob from disk (see [Bitmap Requirements](#bitmap-requirements)), blits the pixel data to the framebuffer at `0xA0000`, draws a static caption using an embedded 8×8 font, and runs a continuous fade in/out loop synchronized to the vertical blank signal.

The fade works by scaling the VGA DAC's palette registers, never touching the framebuffer after the initial draw. The caption's color (palette index 253) is deliberately excluded from that scaling, so it stays at fixed full brightness while Tux fades independently around it — the same trick behind old BIOS POST screens showing static text alongside an animated logo.

---

## Requirements

- `nasm`
- `qemu-system-x86_64` or `qemu-system-i386` for testing
- Python 3 + Pillow (`bmp2raw.py`, image → raw blob conversion)
- A USB drive and a machine with a BIOS that supports LBA for real hardware

```bash
sudo apt install nasm qemu-system-x86 python3-pil
```

---

## Build

```bash
# Convert the source image to the raw blob format (palette + pixels)
python3 bmp2raw.py tux-source.png tux-8.raw

nasm -f bin stage1.asm -o stage1.bin
nasm -f bin stage2-raw.asm -o stage2-raw.bin
cat stage1.bin stage2-raw.bin tux-8.raw > disk.img
truncate -s 1474560 disk.img
```

---

## Run in QEMU

```bash
# Must use if=ide — floppy emulation does not support LBA extensions
qemu-system-i386 -drive format=raw,file=disk.img,if=ide
```

---

## Run on Real Hardware

```bash
# Confirm your device with lsblk first — dd will overwrite without warning
sudo umount /dev/sdX*
sudo dd if=disk.img of=/dev/sdX bs=512 conv=fsync status=progress
```

Boot the target machine from USB. In the BIOS boot menu, prefer **USB-HDD** over USB-FDD if both are available.

---

## Disk Layout

| Sectors | Content |
|---------|---------|
| 0 | Stage 1 (MBR, 512 bytes) |
| 1–4 | Stage 2 (2048 bytes) |
| 5–38 | `tux-8.raw` (768-byte palette + 16384 pixel bytes) |

Stage 2 is padded to exactly 2048 bytes by the `times 2048-($-$$) db 0` directive so the raw blob always lands at a known sector boundary.

---

## Bitmap Requirements

`tux-8.raw` is a custom format, not a BMP file — generated offline by `bmp2raw.py` (Python + Pillow):

- 768 bytes: palette, 256 × (R, G, B), 6-bit components (0–63)
- 16384 bytes: pixel data, 128×128, one palette-index byte per pixel

Palette index 253 is reserved for the caption text and excluded from the fade scaling; `bmp2raw.py` and the source image are unaffected as long as the image doesn't use that index (currently 49 of 256 indices are unused by the pixel data — see `stage2-raw.asm` header comments for the full free list).

To swap the image, regenerate `tux-8.raw` and update `IMG_W`/`IMG_H` in `stage2-raw.asm` if the dimensions change.

---

## Key Concepts

- **Real mode**: the 16-bit CPU mode active at boot, 1MB address space, no memory protection
- **LBA vs CHS**: CHS disk addressing encodes physical geometry assumptions that vary by device type; LBA treats the disk as a flat array of sectors and works consistently across USB drives, hard disks, and emulators
- **VGA mode 13h**: 320×200 linear framebuffer at `0xA0000`, one byte per pixel, palette indexed
- **VGA DAC**: 256 RGB registers programmed via ports `0x3C8`/`0x3C9`; the fade effect works by scaling these registers, never touching the framebuffer
- **Vertical blank sync**: port `0x3DA` bit 3 signals the vblank interval (~70Hz in mode 13h); palette updates are synchronized to it to avoid tearing
- **Independent palette animation**: reserving specific DAC indices from the fade's scaling loop lets static and animated content share one framebuffer, same as classic BIOS POST + logo splash screens

---

## To-Do

- [ ] Test on K6-II / Super Socket 7 hardware
- [ ] Add a simple text menu in stage 2
- [ ] Stage 3 in 32-bit protected mode
- [ ] VESA modes for higher resolution

---

## Tags

`bare metal` `x86 assembly` `bootloader` `real mode` `VGA mode 13h` `BIOS`
