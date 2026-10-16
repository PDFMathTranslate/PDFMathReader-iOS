#!/usr/bin/env python3
"""Convert the desktop artwork to full-bleed iOS alternate icons.

Requires Pillow and NumPy. Run with the desktop repo path as the first argument.
The primary iOS icon remains unchanged; its existing image supplies its preview.
"""
import json
import sys
from pathlib import Path

import numpy as np
from PIL import Image

assets = Path(__file__).resolve().parents[1] / 'App/Resources/Assets.xcassets'
desktop = Path(sys.argv[1]) if len(sys.argv) > 1 else Path.home() / 'Developer/oss/PDFMathReader'
styles = {'base': None, 'warm': 'Warm', 'spring': 'Spring', 'hist': 'Classic',
          'tech': 'Blueprint', 'moon': 'Moon', 'modern': 'Modern'}
info = {'author': 'xcode', 'version': 1}
for style, suffix in styles.items():
    if suffix is None:
        icon = Image.open(assets / 'AppIcon.appiconset/AppIcon-1024.png').convert('RGB')
    else:
        source = Image.open(desktop / f'doc/icons/app-{style}.png').convert('RGBA')
        # Remove the macOS canvas and outer shadow, matching the existing primary's scale.
        source = source.crop((219, 214, 1819, 1814))
        pixels = np.array(source)
        # Extend the opaque body into its rounded corners; iOS applies its own mask.
        # This also avoids white seams on the dark and gradient variants.
        transparent = pixels[:, :, 3] < 255
        rgb = pixels[:, :, :3].copy()
        for y in range(rgb.shape[0]):
            opaque = np.flatnonzero(~transparent[y])
            if not len(opaque):
                raise ValueError(f'{style}: crop misses opaque icon body at row {y}')
            for channel in range(3):
                rgb[y, :, channel] = np.interp(
                    np.arange(rgb.shape[1]), opaque, rgb[y, opaque, channel])
        icon = Image.fromarray(rgb).resize((1024, 1024), Image.Resampling.LANCZOS)
        directory = assets / f'AppIcon{suffix}.appiconset'
        directory.mkdir(exist_ok=True)
        icon.save(directory / 'Icon-1024.png')
        (directory / 'Contents.json').write_text(json.dumps({'images': [{
            'filename': 'Icon-1024.png', 'idiom': 'universal', 'platform': 'ios',
            'size': '1024x1024'}], 'info': info}, indent=2) + '\n')
    directory = assets / f'AppIconPreview-{style}.imageset'
    directory.mkdir(exist_ok=True)
    icon.resize((192, 192), Image.Resampling.LANCZOS).save(directory / 'preview.png')
    (directory / 'Contents.json').write_text(json.dumps({'images': [{
        'filename': 'preview.png', 'idiom': 'universal'}], 'info': info}, indent=2) + '\n')
print('Generated six alternate icons and seven previews; primary unchanged.')
