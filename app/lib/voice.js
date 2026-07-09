// Voice out: edge-tts (free Microsoft neural voices) -> temp mp3 -> renderer plays it.
// Voice is user-selectable (state.voice); phrases are cached by hash to avoid regeneration.
const { execFile } = require('child_process');
const path = require('path');
const os = require('os');
const fs = require('fs');
const crypto = require('crypto');

const CACHE_DIR = path.join(os.tmpdir(), 'jarvis-voice');
if (!fs.existsSync(CACHE_DIR)) fs.mkdirSync(CACHE_DIR, { recursive: true });

function speak(text, voice = 'en-GB-RyanNeural') {
  const clean = String(text).slice(0, 3000);
  const key = crypto.createHash('sha1').update(voice + '|' + clean).digest('hex').slice(0, 16);
  const file = path.join(CACHE_DIR, `${key}.mp3`);
  if (fs.existsSync(file) && fs.statSync(file).size > 0) return Promise.resolve(file);
  return new Promise((resolve, reject) => {
    execFile('python', ['-m', 'edge_tts', '--voice', voice, '--text', clean, '--write-media', file],
      { timeout: 60000, windowsHide: true },
      (err) => {
        if (err || !fs.existsSync(file)) return reject(err || new Error('tts produced no file'));
        resolve(file);
      });
  });
}

module.exports = { speak };
