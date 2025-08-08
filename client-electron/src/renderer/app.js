const { electronAPI } = window;

class App {
    constructor() {
        this.socketService = null;
        this.webrtcService = null;
        this.isInitialized = false;
        this.isLoadingDevices = true;
        this.connectedDevices = [];
        this.updateTimer = null;
        
        this.init();
    }

    async init() {
        console.log('🚀 INITIALIZING APP');
        
        // Wait for DOM to be loaded
        if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', () => this.initializeServices());
        } else {
            this.initializeServices();
        }
        
        // Set up IPC listeners
        this.setupIPC();
    }

    setupIPC() {
        // Listen for global shortcuts
        electronAPI.on('share-clipboard', () => {
            console.log('📤 Share clipboard shortcut triggered');
            this.shareClipboard();
        });

        electronAPI.on('request-clipboard', () => {
            console.log('📥 Request clipboard shortcut triggered');
            this.requestClipboard();
        });

        electronAPI.on('set-enabled', (event, enabled) => {
            console.log(`🔧 Service ${enabled ? 'enabled' : 'disabled'}`);
            this.setEnabled(enabled);
        });
    }

    async initializeServices() {
        try {
            console.log('🚀 STARTING SERVICE INITIALIZATION');
            
            // Update status
            this.updateStatus('Initializing services...');
            
            // Initialize services
            this.socketService = new window.SocketService();
            this.webrtcService = new window.WebRTCService();
            
            // Initialize WebRTC first
            console.log('🔧 INITIALIZING WEBRTC SERVICE');
            await this.webrtcService.init();
            
            // Set up WebRTC file transfer service
            this.webrtcService.fileTransferService = window.FileTransferService;
            
            // Then initialize Socket service
            console.log('🔧 INITIALIZING SOCKET SERVICE');
            await this.socketService.init(this.webrtcService);
            
            // Set up WebRTC signal handling
            this.socketService.onSignalReceived = (from, signal) => {
                this.webrtcService.handleSignal(from, signal);
            };
            
            // Set up device event callbacks
            this.socketService.onDeviceConnected = (device) => this.handleDeviceConnected(device);
            this.socketService.onDeviceDisconnected = (device) => this.handleDeviceDisconnected(device);
            this.socketService.onConnectedDevicesList = (devices) => this.handleConnectedDevicesList(devices);
            
            this.updateStatus('Ready');
            this.isInitialized = true;
            this.enableButtons();
            
            // Set a timeout to stop loading if no devices are discovered
            setTimeout(() => {
                if (this.isLoadingDevices) {
                    this.isLoadingDevices = false;
                    this.updateDevicesList();
                }
            }, 5000);
            
            // Start timer to update connected devices durations
            this.updateTimer = setInterval(() => {
                if (this.connectedDevices.length > 0) {
                    this.updateDevicesList();
                }
            }, 60000); // Update every minute
            
            console.log('✅ SERVICES INITIALIZED SUCCESSFULLY');
        } catch (error) {
            console.error('❌ SERVICE INITIALIZATION ERROR:', error);
            this.updateStatus(`Initialization failed: ${error.message}`);
        }
    }

    handleDeviceConnected(device) {
        const deviceId = device['id'] || device['socketId'] || 'unknown';
        const isOwnDevice = deviceId === this.socketService.socket.id;
        
        if (!isOwnDevice) {
            const existingIndex = this.connectedDevices.findIndex(d => d.id === deviceId);
            if (existingIndex === -1) {
                this.connectedDevices.push({
                    id: deviceId,
                    name: device['name'] || device['deviceName'] || 'Unknown Device',
                    connectedAt: new Date(),
                });
            }
        }
        
        this.isLoadingDevices = false;
        this.updateDevicesList();
    }

    handleDeviceDisconnected(device) {
        const deviceId = device['deviceId'] || device['id'] || device['socketId'] || 'unknown';
        this.connectedDevices = this.connectedDevices.filter(d => d.id !== deviceId);
        this.updateDevicesList();
    }

    handleConnectedDevicesList(devices) {
        // Replace the current list with the devices from the server (excluding ourselves)
        this.connectedDevices = [];
        for (const device of devices) {
            const deviceId = device['id'] || device['socketId'] || 'unknown';
            const isOwnDevice = deviceId === this.socketService.socket.id;
            
            if (!isOwnDevice) {
                this.connectedDevices.push({
                    id: deviceId,
                    name: device['name'] || device['deviceName'] || 'Unknown Device',
                    connectedAt: new Date(), // We don't know the actual connection time
                });
            }
        }
        
        this.isLoadingDevices = false;
        this.updateDevicesList();
    }

    updateStatus(status) {
        const statusElement = document.getElementById('status');
        if (statusElement) {
            statusElement.textContent = this.truncateText(status, 100);
        }
    }

    updateDevicesList() {
        const devicesListElement = document.getElementById('devices-list');
        const loadingElement = document.getElementById('devices-loading');
        
        if (!devicesListElement) return;
        
        // Show/hide loading indicator
        if (loadingElement) {
            loadingElement.style.display = this.isLoadingDevices ? 'flex' : 'none';
        }
        
        if (this.connectedDevices.length === 0) {
            devicesListElement.innerHTML = '<p class="no-devices">No devices connected</p>';
        } else {
            devicesListElement.innerHTML = this.connectedDevices.map(device => 
                this.renderDeviceItem(device)
            ).join('');
        }
    }

    renderDeviceItem(device) {
        const duration = this.getConnectionDuration(device.connectedAt);
        return `
            <div class="device-item">
                <div class="device-info">
                    <div class="device-name">${this.escapeHtml(device.name)}</div>
                    <div class="device-duration">Connected ${duration}</div>
                </div>
                <div class="device-status connected">Connected</div>
            </div>
        `;
    }

    getConnectionDuration(connectedAt) {
        const now = new Date();
        const diffMs = now - connectedAt;
        const diffMinutes = Math.floor(diffMs / 60000);
        
        if (diffMinutes < 1) {
            return 'just now';
        } else if (diffMinutes < 60) {
            return `${diffMinutes} minute${diffMinutes === 1 ? '' : 's'} ago`;
        } else {
            const diffHours = Math.floor(diffMinutes / 60);
            return `${diffHours} hour${diffHours === 1 ? '' : 's'} ago`;
        }
    }

    enableButtons() {
        const shareBtn = document.getElementById('share-btn');
        const requestBtn = document.getElementById('request-btn');
        
        if (shareBtn) shareBtn.disabled = false;
        if (requestBtn) requestBtn.disabled = false;
    }

    async shareClipboard() {
        if (!this.isInitialized) {
            console.log('⚠️ Services not initialized');
            return;
        }

        try {
            console.log('📤 Sharing clipboard content');
            this.updateStatus('Sharing clipboard...');
            
            // Send share ready signal
            this.socketService.sendShareReady();
            
            // Get clipboard content
            let clipboardContent;
            if (window.FileTransferService) {
                clipboardContent = await window.FileTransferService.getClipboardContent();
            } else if (window.ClipboardService) {
                const textContent = await window.ClipboardService.getClipboard();
                if (textContent) {
                    clipboardContent = { type: 'text', content: textContent };
                }
            }
            
            if (clipboardContent) {
                if (clipboardContent.type === 'text') {
                    await this.webrtcService.createOffer(clipboardContent.content);
                } else if (clipboardContent.type === 'file') {
                    await this.webrtcService.createOffer(JSON.stringify(clipboardContent));
                }
                this.updateStatus('Clipboard shared successfully');
            } else {
                this.updateStatus('No content to share');
            }
        } catch (error) {
            console.error('❌ Error sharing clipboard:', error);
            this.updateStatus(`Error sharing clipboard: ${error.message}`);
        }
    }

    async requestClipboard() {
        if (!this.isInitialized) {
            console.log('⚠️ Services not initialized');
            return;
        }

        try {
            console.log('📥 Requesting clipboard content');
            this.updateStatus('Requesting clipboard...');
            
            this.socketService.sendRequestShare();
            this.updateStatus('Clipboard request sent');
        } catch (error) {
            console.error('❌ Error requesting clipboard:', error);
            this.updateStatus(`Error requesting clipboard: ${error.message}`);
        }
    }

    setEnabled(enabled) {
        if (window.ClipboardService) {
            window.ClipboardService.setEnabled(enabled);
        }
        this.updateStatus(enabled ? 'Service enabled' : 'Service disabled');
    }

    truncateText(text, maxLength = 200) {
        if (!text || text.length <= maxLength) {
            return text;
        }
        return text.substring(0, maxLength) + '...';
    }

    escapeHtml(text) {
        const div = document.createElement('div');
        div.textContent = text;
        return div.innerHTML;
    }
}

// Initialize app when DOM is ready
document.addEventListener('DOMContentLoaded', () => {
    // Set up button event listeners
    const shareBtn = document.getElementById('share-btn');
    const requestBtn = document.getElementById('request-btn');
    
    if (shareBtn) {
        shareBtn.addEventListener('click', () => {
            if (window.app) {
                window.app.shareClipboard();
            }
        });
    }
    
    if (requestBtn) {
        requestBtn.addEventListener('click', () => {
            if (window.app) {
                window.app.requestClipboard();
            }
        });
    }
    
    // Request notification permission
    if (window.Notification && Notification.permission === 'default') {
        Notification.requestPermission();
    }
    
    // Initialize the app
    window.app = new App();
});
