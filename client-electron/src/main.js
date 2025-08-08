const { app, BrowserWindow, Tray, Menu, globalShortcut, ipcMain, dialog } = require('electron');
const path = require('path');
const os = require('os');

class App {
  constructor() {
    this.mainWindow = null;
    this.tray = null;
    this.isQuitting = false;
    
    this.init();
  }

  init() {
    // Handle app ready
    app.whenReady().then(() => {
      this.createWindow();
      this.createTray();
      this.registerGlobalShortcuts();
      this.setupIPC();
    });

    // Handle window-all-closed
    app.on('window-all-closed', () => {
      // On macOS, keep app running even when all windows are closed
      if (process.platform !== 'darwin') {
        app.quit();
      }
    });

    // Handle activate (macOS)
    app.on('activate', () => {
      if (BrowserWindow.getAllWindows().length === 0) {
        this.createWindow();
      }
    });

    // Handle before-quit
    app.on('before-quit', () => {
      this.isQuitting = true;
    });

    // Handle will-quit
    app.on('will-quit', () => {
      // Unregister all shortcuts
      globalShortcut.unregisterAll();
    });
  }

  createWindow() {
    this.mainWindow = new BrowserWindow({
      width: 800,
      height: 600,
      show: false, // Start hidden
      skipTaskbar: true,
      webPreferences: {
        nodeIntegration: false,
        contextIsolation: true,
        enableRemoteModule: false,
        webSecurity: false,
        preload: path.join(__dirname, 'preload.js')
      },
      icon: path.join(__dirname, '../assets/icon.png')
    });

    this.mainWindow.loadFile(path.join(__dirname, 'renderer/index.html'));

    // Handle window close - hide instead of quit
    this.mainWindow.on('close', (event) => {
      if (!this.isQuitting) {
        event.preventDefault();
        this.hideWindow();
      }
    });

    // Show and focus window when ready
    this.mainWindow.once('ready-to-show', () => {
      this.mainWindow.show();
      this.mainWindow.focus();
      this.mainWindow.setSkipTaskbar(false);
      console.log('Window ready to show');
    });

    // Open DevTools in development
    if (process.argv.includes('--dev')) {
      this.mainWindow.webContents.openDevTools();
    }
  }

  createTray() {
    try {
      // Create tray icon
      const iconPath = this.getTrayIconPath();
      this.tray = new Tray(iconPath);

      // Set tooltip
      this.tray.setToolTip('Shared Clipboard - Click to show window');

      // Create context menu
      const contextMenu = Menu.buildFromTemplate([
        {
          label: 'Show Window',
          click: () => this.showWindow()
        },
        {
          label: 'Hide Window',
          click: () => this.hideWindow()
        },
        { type: 'separator' },
        {
          label: 'Enable',
          click: () => this.setEnabled(true)
        },
        {
          label: 'Disable',
          click: () => this.setEnabled(false)
        },
        { type: 'separator' },
        {
          label: 'Quit',
          click: () => this.quit()
        }
      ]);

      this.tray.setContextMenu(contextMenu);

      // Handle tray click
      this.tray.on('click', () => {
        this.showWindow();
      });

      // Handle tray right-click (Windows/Linux)
      this.tray.on('right-click', () => {
        this.tray.popUpContextMenu();
      });
    } catch (error) {
      console.error('Failed to create tray:', error);
    }
  }

  getTrayIconPath() {
    const fs = require('fs');
    let iconName;
    if (process.platform === 'darwin') {
      iconName = 'trayTemplate.png';
    } else if (process.platform === 'win32') {
      iconName = 'icon.ico';
    } else {
      iconName = 'icon.png';
    }

    const iconPath = path.join(__dirname, '../assets', iconName);

    // Check if the icon file exists, fallback to a simple icon if not
    if (!fs.existsSync(iconPath)) {
      console.warn(`Icon not found at ${iconPath}, using fallback`);
      const { nativeImage } = require('electron');
      return nativeImage.createEmpty();
    }

    return iconPath;
  }

  registerGlobalShortcuts() {
    // Register global shortcuts equivalent to Flutter hotkeys
    // Share clipboard (Cmd/Ctrl+F12)
    globalShortcut.register('CommandOrControl+F12', () => {
      console.log('Share clipboard shortcut pressed');
      this.mainWindow?.webContents.send('share-clipboard');
    });

    // Request clipboard (Cmd/Ctrl+F11)
    globalShortcut.register('CommandOrControl+F11', () => {
      console.log('Request clipboard shortcut pressed');
      this.mainWindow?.webContents.send('request-clipboard');
    });
  }

  setupIPC() {
    // Handle messages from renderer process
    ipcMain.handle('get-device-name', async () => {
      return os.hostname();
    });

    ipcMain.handle('get-platform', async () => {
      return process.platform;
    });

    ipcMain.handle('show-error-dialog', async (event, title, content) => {
      return dialog.showErrorBox(title, content);
    });

    ipcMain.handle('show-info-dialog', async (event, title, content) => {
      return dialog.showMessageBox(this.mainWindow, {
        type: 'info',
        title: title,
        message: content,
        buttons: ['OK']
      });
    });
  }

  showWindow() {
    if (this.mainWindow) {
      this.mainWindow.show();
      this.mainWindow.focus();
      this.mainWindow.setSkipTaskbar(false);
    }
  }

  hideWindow() {
    if (this.mainWindow) {
      this.mainWindow.hide();
      this.mainWindow.setSkipTaskbar(true);
    }
  }

  setEnabled(enabled) {
    console.log(`Service enabled: ${enabled}`);
    // Send message to renderer to enable/disable services
    this.mainWindow?.webContents.send('set-enabled', enabled);
  }

  quit() {
    this.isQuitting = true;
    app.quit();
  }
}

// Create app instance
new App();
