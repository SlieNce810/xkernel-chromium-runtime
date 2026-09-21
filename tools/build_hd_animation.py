from pathlib import Path
import sys

from PIL import Image


source = Path(sys.argv[1])
output_dir = Path(sys.argv[2])
output_dir.mkdir(parents=True, exist_ok=True)

base = Image.open(source).convert("RGB")
size = min(base.size)
base = base.crop(((base.width - size) // 2, (base.height - size) // 2, (base.width + size) // 2, (base.height + size) // 2))

frames = []
for step, (zoom, dx, dy) in enumerate([
    (1.008, 0, 0),
    (1.009, 0, 1),
    (1.010, 1, 1),
    (1.009, 1, 0),
    (1.008, 0, -1),
    (1.009, -1, -1),
    (1.010, -1, 0),
    (1.009, 0, 1),
]):
    enlarged_size = round(size * zoom)
    enlarged = base.resize((enlarged_size, enlarged_size), Image.Resampling.LANCZOS)
    margin = enlarged_size - size
    left = margin // 2 + dx
    top = margin // 2 + dy
    frames.append(enlarged.crop((left, top, left + size, top + size)))

sequence = frames + frames[-2:0:-1]
gif_path = output_dir / "cool_cat_float_hd.gif"
webp_path = output_dir / "cool_cat_float_hd.webp"

sequence[0].save(
    gif_path,
    save_all=True,
    append_images=sequence[1:],
    duration=120,
    loop=0,
    optimize=True,
    disposal=2,
)
sequence[0].save(
    webp_path,
    save_all=True,
    append_images=sequence[1:],
    duration=120,
    loop=0,
    lossless=True,
    method=6,
)

print(f"size={size}x{size}")
print(f"gif={gif_path} bytes={gif_path.stat().st_size}")
print(f"webp={webp_path} bytes={webp_path.stat().st_size}")
