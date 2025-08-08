const { app, BrowserWindow, Tray, Menu, globalShortcut, ipcMain, dialog } = require('electron');
const path = require('path');
const os = require('os');

class App {
  constructor() {
    this.mainWindow = null;
    this.tray = null;
    this.isQuitting = false;
    this.enabled = true;
    
    this.init();
  }

  init() {
    console.log('🚀 App initializing...');
    
    // Hide dock icon on macOS to make it a proper menubar app
    if (process.platform === 'darwin') {
      app.dock.hide();
      console.log('🔒 Dock icon hidden on macOS');
    }
    
    // Handle app ready
    app.whenReady().then(() => {
      console.log('✅ App ready, creating tray...');
      this.createTray();
      this.registerGlobalShortcuts();
      this.setupIPC();
      console.log('🎯 Initialization complete - app running in background');
      // Don't create window on startup - only when tray is clicked
    }).catch(error => {
      console.error('❌ App initialization failed:', error);
    });

    // Handle window-all-closed - keep app running in background
    app.on('window-all-closed', () => {
      // Keep app running in background on all platforms
      // App should only quit when user explicitly quits from tray
    });

    // Handle activate (macOS) - don't auto-create window
    app.on('activate', () => {
      // On macOS, don't automatically create window on dock click
      // User should click tray icon to show window
      // Keep dock hidden
      if (process.platform === 'darwin') {
        app.dock.hide();
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
    if (this.mainWindow) {
      // Window already exists, just show it
      this.showWindow();
      return;
    }

    this.mainWindow = new BrowserWindow({
      width: 800,
      height: 800,
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

    // Handle window closed - set to null so it can be recreated
    this.mainWindow.on('closed', () => {
      this.mainWindow = null;
    });

    // Show and focus window when ready (only for menubar click)
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
      console.log('🔧 Creating tray icon...');
      
      // Create tray icon
      const iconPath = this.getTrayIconPath();
      console.log('📁 Tray icon path:', iconPath);

      if (!iconPath) {
        throw new Error('No valid tray icon path found');
      }

      // On macOS, load as nativeImage and mark as template for proper theming
      let trayImage = iconPath;
      if (process.platform === 'darwin') {
        const { nativeImage } = require('electron');
        const img = nativeImage.createFromPath(iconPath);
        if (!img.isEmpty()) {
          img.setTemplateImage(true);
          trayImage = img;
        } else {
          console.warn('⚠️ Loaded tray image is empty; using path directly');
        }
      }

      this.tray = new Tray(trayImage);
      console.log('✅ Tray created successfully');

      // Set tooltip
      this.tray.setToolTip('Shared Clipboard - Click to show window');
      console.log('📝 Tray tooltip set');

      // Temporary: also set a short title on macOS to ensure visibility in menubar
      // If you see the text but not the icon, the icon asset likely needs adjustment (size ~18-22px, alpha, template)
      if (process.platform === 'darwin' && this.tray.setTitle) {
        try { this.tray.setTitle('SC'); } catch (e) { console.warn('setTitle not supported:', e); }
      }

      // Create and attach context menu
      this.tray.setContextMenu(this.buildContextMenu());
      console.log('📋 Tray context menu set');

      // Handle tray left-click - show the context menu (do NOT open window)
      this.tray.on('click', () => {
        console.log('🖱️ Tray icon clicked');
        this.tray.popUpContextMenu();
      });

      // Handle tray right-click (Windows/Linux)
      this.tray.on('right-click', () => {
        console.log('🖱️ Tray icon right-clicked');
        this.tray.popUpContextMenu();
      });
      
      console.log('🎉 Tray setup complete - icon should be visible in menubar');
    } catch (error) {
      console.error('❌ Failed to create tray:', error);
      console.error('Stack trace:', error.stack);
    }
  }

  buildContextMenu() {
    // Single toggle (checkbox) for enabled/disabled state
    return Menu.buildFromTemplate([
      {
        label: 'Show Window',
        click: () => {
          if (!this.mainWindow) {
            this.createWindow();
          } else {
            this.showWindow();
          }
        }
      },
      {
        label: 'Hide Window',
        click: () => this.hideWindow()
      },
      { type: 'separator' },
      {
        label: 'Enabled',
        type: 'checkbox',
        checked: this.enabled,
        click: (menuItem) => this.setEnabled(menuItem.checked)
      },
      { type: 'separator' },
      {
        label: 'Quit',
        click: () => this.quit()
      }
    ]);
  }

  getTrayIconPath() {
    const fs = require('fs');
    console.log('🔍 Getting tray icon path for platform:', process.platform);
    
    let iconName;
    if (process.platform === 'darwin') {
      iconName = 'trayTemplate.png';
    } else if (process.platform === 'win32') {
      iconName = 'icon.ico';
    } else {
      iconName = 'icon.png';
    }
    
    console.log('📄 Icon name:', iconName);
    const iconPath = path.join(__dirname, '../assets', iconName);
    console.log('📁 Full icon path:', iconPath);

    // Check if the icon file exists, fallback to a simple icon if not
    if (!fs.existsSync(iconPath)) {
      console.warn(`❌ Icon not found at ${iconPath}, using empty nativeImage as fallback`);
      const { nativeImage } = require('electron');
      return nativeImage.createEmpty();
    }
    
    console.log('✅ Icon file exists, using:', iconPath);
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
    // Update internal state and refresh menu to reflect checkbox
    this.enabled = enabled;
    if (this.tray) {
      this.tray.setContextMenu(this.buildContextMenu());
    }
  }

  quit() {
    this.isQuitting = true;
    app.quit();
  }
}

// Create app instance
new App();
