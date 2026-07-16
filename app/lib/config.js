// app/lib/config.js - Node mirror of skill/bin/get-jarvis-config.ps1. ONE source of truth for
// machine/person-specific values; keep DEFAULTS in lockstep with Get-JarvisConfigDefaults (a parity
// test compares them). Missing file -> generic HOME defaults with EMPTY owner_email (self-only locks
// fail closed). Corrupt file -> throws loudly; silently defaulting would point the app at the wrong
// vault without anyone noticing.
const fs = require('fs');
const os = require('os');
const path = require('path');

const HOME = os.homedir();
const DEFAULTS = {
  vault_path:     path.join(HOME, 'JarvisVault', 'jarvis'),
  projects_root:  path.join(HOME, 'Projects'),
  job_search_dir: path.join(HOME, 'Documents', 'Job Search'),
  skill_dir:      path.join(HOME, '.claude', 'skills', 'jarvis'),
  owner_email:    '',
  app_id:         'com.jarvis.assistant',
  roadmap_index:  '',
};

function loadConfig(configPath) {
  const p = configPath || path.join(HOME, '.jarvis', 'config.json');
  const cfg = { ...DEFAULTS };
  if (fs.existsSync(p)) {
    // strip a UTF-8 BOM: PS 5.1 writes one and JSON.parse rejects it (the bank-heartbeat lesson)
    const raw = fs.readFileSync(p, 'utf8').replace(/^﻿/, '');
    const file = JSON.parse(raw); // corrupt JSON throws here - deliberately loud
    for (const key of Object.keys(DEFAULTS)) {
      if (file[key] !== undefined && file[key] !== null && String(file[key]) !== '') cfg[key] = file[key];
    }
  }
  return cfg;
}

module.exports = loadConfig;
