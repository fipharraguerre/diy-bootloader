"""
Parses the font_table `db` lines directly out of stage2-raw.asm and renders
every glyph (plus a sample string) to a PNG. This validates the embedded
byte data in isolation, independent of any bug in the asm render routine.
"""
import re
import sys
from PIL import Image

ASM_PATH = sys.argv[1] if len(sys.argv) > 1 else "stage2-raw.asm"
CHARS = " abcdefghijklmnopqrstuvwxyz"  # order matches font_table layout

with open(ASM_PATH) as f:
    text = f.read()

# Grab everything from "font_table:" to the "times 2048..." padding line
m = re.search(r"font_table:(.*?)times 2048", text, re.DOTALL)
if not m:
    raise SystemExit("font_table section not found")

# Pull every db line's hex/dec byte list
db_lines = re.findall(r"db\s+([0-9A-Fa-fx,\s]+)", m.group(1))
all_bytes = []
for line in db_lines:
    for tok in line.split(","):
        tok = tok.strip()
        if tok:
            all_bytes.append(int(tok, 0))

if len(all_bytes) != len(CHARS) * 8:
    raise SystemExit(f"Expected {len(CHARS)*8} bytes, got {len(all_bytes)}")

glyphs = {ch: all_bytes[i*8:(i+1)*8] for i, ch in enumerate(CHARS)}

def render_string(s, scale=8):
    img = Image.new("L", (len(s)*8, 8), 0)
    for i, ch in enumerate(s):
        rows = glyphs.get(ch, glyphs[' '])
        for y, byte in enumerate(rows):
            for x in range(8):
                if byte & (0x80 >> x):
                    img.putpixel((i*8+x, y), 255)
    return img.resize((img.width*scale, img.height*scale), Image.NEAREST)

alphabet_img = render_string(" abcdefghijklmnopqrstuvwxyz")
alphabet_img.save("alphabet_check.png")

message_img = render_string("wrong way penguin custom bootloader")
message_img.save("message_check.png")

print(f"Parsed {len(glyphs)} glyphs OK")
print("Saved alphabet_check.png and message_check.png")
