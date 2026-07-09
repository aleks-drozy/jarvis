// Jarvis Companion - preload: narrow, explicit bridge (no raw node in renderer)
const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('jarvis', {
  read: (name) => ipcRenderer.invoke('vault:read', name),
  calendar: () => ipcRenderer.invoke('collector:calendar'),
  inbox: () => ipcRenderer.invoke('collector:inbox'),
  activity: () => ipcRenderer.invoke('collector:activity'),
  liveStatus: () => ipcRenderer.invoke('live:status'),
  chat: (message) => ipcRenderer.invoke('chat:send', message),
  speak: (text) => ipcRenderer.invoke('voice:speak', text),
  state: () => ipcRenderer.invoke('app:state'),
  setVoice: (v) => ipcRenderer.invoke('app:setVoice', v),
  hudClicked: () => ipcRenderer.send('hud:clicked'),
  summonToggle: () => ipcRenderer.send('summon:toggle'),
  summonHide: () => ipcRenderer.send('summon:hide'),
  onSummonShow: (cb) => ipcRenderer.on('summon:show', () => cb()),
  onPlayAudio: (cb) => ipcRenderer.on('audio:play', (_e, file) => cb(file)),
  onHudShow: (cb) => ipcRenderer.on('hud:show', (_e, data) => cb(data)),
  onHudHide: (cb) => ipcRenderer.on('hud:hide', () => cb()),
  onHudPlay: (cb) => ipcRenderer.on('hud:play', (_e, file) => cb(file)),
  onRefresh: (cb) => ipcRenderer.on('data:refresh', () => cb()),
});
