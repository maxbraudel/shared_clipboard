const { contextBridge, ipcRenderer } = require('electron');
const clipboardy = require('clipboardy');
const fs = require('fs').promises;
const path = require('path');
const crypto = require('crypto');
const mime = require('mime-types');
const os = require('os');
const io = require('socket.io-client');

// Expose protected methods that allow the renderer process to use
// the ipcRenderer without exposing the entire object
contextBridge.exposeInMainWorld('electronAPI', {
  // IPC methods
  invoke: (channel, ...args) => ipcRenderer.invoke(channel, ...args),
  on: (channel, func) => ipcRenderer.on(channel, func),
  send: (channel, ...args) => ipcRenderer.send(channel, ...args),
  
  // Node.js modules
  clipboard: {
    read: () => clipboardy.read(),
    write: (text) => clipboardy.write(text)
  },
  
  fs: {
    readFile: (path) => fs.readFile(path),
    writeFile: (path, data) => fs.writeFile(path, data),
    stat: (path) => fs.stat(path),
    access: (path) => fs.access(path)
  },
  
  path: {
    join: (...paths) => path.join(...paths),
    basename: (path) => path.basename(path),
    extname: (path) => path.extname(path)
  },
  
  crypto: {
    createHash: (algorithm) => crypto.createHash(algorithm)
  },
  
  mime: {
    lookup: (path) => mime.lookup(path)
  },
  
  os: {
    homedir: () => os.homedir(),
    platform: () => process.platform
  },
  
  io: (url, options) => io(url, options)
});
