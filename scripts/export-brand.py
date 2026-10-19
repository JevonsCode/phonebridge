"""Export platform icon sizes from the single, unchanged generated brand master.

Run with Python 3 and Pillow. This only scales/composites platform backgrounds;
the PhoneBridge artwork is never redrawn independently for any platform.
"""
from pathlib import Path
import json
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
MASTER = ROOT / 'assets/brand/phonebridge.png'
mark = Image.open(MASTER).convert('RGBA')


def save(path, size, background=None):
    image = mark.resize((size, size), Image.Resampling.LANCZOS)
    if background:
        tile = Image.new('RGBA', image.size, background)
        tile.alpha_composite(image)
        image = tile
    target = ROOT / path
    target.parent.mkdir(parents=True, exist_ok=True)
    image.save(target)


for folder in ['mobile/assets/brand', 'desktop_app/assets/brand']:
    save(f'{folder}/logo.png', 512)
save('website/dist/mark.png', 256)
save('website/dist/favicon.png', 64)
for density, size in [('mdpi', 48), ('hdpi', 72), ('xhdpi', 96), ('xxhdpi', 144), ('xxxhdpi', 192)]:
    save(f'mobile/android/app/src/main/res/mipmap-{density}/ic_launcher.png', size, 'white')
save('mobile/android/app/src/main/res/drawable/phonebridge_mark.png', 256)
for language in ['zh-CN', 'en-US']:
    save(f'fastlane/metadata/android/{language}/images/icon.png', 512, 'white')

icon = ROOT / 'assets/brand/phonebridge.ico'
mark.resize((256, 256), Image.Resampling.LANCZOS).save(icon, sizes=[(s, s) for s in [16, 24, 32, 48, 64, 128, 256]])
runner_icon = ROOT / 'desktop_app/windows/runner/resources/app_icon.ico'
if runner_icon.parent.exists():
    runner_icon.write_bytes(icon.read_bytes())
tray_icon = ROOT / 'desktop_app/assets/brand/tray.ico'
if tray_icon.parent.exists():
    tray_icon.write_bytes(icon.read_bytes())

entries = []
for size in [16, 32, 128, 256, 512]:
    for scale in [1, 2]:
        suffix = '@2x' if scale == 2 else ''
        filename = f'icon_{size}x{size}{suffix}.png'
        save(f'assets/brand/PhoneBridge.iconset/{filename}', size * scale, 'white')
        appicon = f'app_icon_{size}_{scale}.png'
        save(f'desktop_app/macos/Runner/Assets.xcassets/AppIcon.appiconset/{appicon}', size * scale, 'white')
        entries.append({'size': f'{size}x{size}', 'idiom': 'mac', 'filename': appicon, 'scale': f'{scale}x'})
contents = ROOT / 'desktop_app/macos/Runner/Assets.xcassets/AppIcon.appiconset/Contents.json'
contents.write_text(json.dumps({'images': entries, 'info': {'version': 1, 'author': 'PhoneBridge'}}, indent=2) + '\n')
print('Exported website, Flutter, Android, Windows and macOS icons from', MASTER.relative_to(ROOT))
