// app/scripts/gen-tray-icons.js - composite a coloured status dot onto the base tray icon.
// Run: node app/scripts/gen-tray-icons.js   (from the repo root, or `node scripts/gen-tray-icons.js` from app/)
const fs = require('fs');
const path = require('path');
const { PNG } = require('pngjs');

const ASSETS = path.join(__dirname, '..', 'assets');
const base = PNG.sync.read(fs.readFileSync(path.join(ASSETS, 'tray.png')));

const COLORS = {
  'tray-normal': [46, 204, 113, 255],   // green
  'tray-amber':  [243, 156, 18, 255],   // amber
  'tray-grey':   [127, 140, 141, 255],  // grey
  'tray-busy':   [52, 152, 219, 255],   // blue
};

function withDot(src, rgba, dimBase) {
  const out = new PNG({ width: src.width, height: src.height });
  src.data.copy(out.data);
  if (dimBase) { for (let i = 3; i < out.data.length; i += 4) out.data[i] = Math.round(out.data[i] * 0.5); }
  const r = Math.max(3, Math.round(src.width * 0.28));
  const cx = src.width - r - 1, cy = src.height - r - 1;
  for (let y = 0; y < src.height; y++) {
    for (let x = 0; x < src.width; x++) {
      if ((x - cx) * (x - cx) + (y - cy) * (y - cy) <= r * r) {
        const i = (src.width * y + x) << 2;
        out.data[i] = rgba[0]; out.data[i + 1] = rgba[1]; out.data[i + 2] = rgba[2]; out.data[i + 3] = rgba[3];
      }
    }
  }
  return out;
}

for (const [name, rgba] of Object.entries(COLORS)) {
  const img = withDot(base, rgba, name === 'tray-grey');
  fs.writeFileSync(path.join(ASSETS, name + '.png'), PNG.sync.write(img));
  console.log('wrote ' + name + '.png (' + img.width + 'x' + img.height + ')');
}
