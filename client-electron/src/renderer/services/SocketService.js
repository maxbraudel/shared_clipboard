const { electronAPI } = window;

class SocketService {
    constructor() {
        this.socket = null;
        this.isConnected = false;
        
        // Callbacks for UI updates
        this.onDeviceConnected = null;
        this.onDeviceDisconnected = null;
        this.onConnectedDevicesList = null;
        this.onSignalReceived = null;
    }

    // Helper function for timestamped logging
    _log(message, data = null) {
        const timestamp = new Date().toISOString();
        if (data) {
            console.log(`[${timestamp}] SOCKET: ${message}`, data);
        } else {
            console.log(`[${timestamp}] SOCKET: ${message}`);
        }
    }

    async init(webrtcService) {
        this._log('🚀 INITIALIZING SOCKET SERVICE');
        this.webrtcService = webrtcService;
        
        // Set up the callback for WebRTC to send signals back through socket
        if (this.webrtcService) {
            this.webrtcService.onSignalGenerated = (to, signal) => {
                this.sendSignal(to, signal);
            };
        }
        
        this._log('🔗 CREATING SOCKET CONNECTION');
        
        this.socket = electronAPI.io('https://test3.braudelserveur.com', {
            transports: ['websocket', 'polling'],
            autoConnect: false,
            timeout: 20000,
            forceNew: true,
            upgrade: true,
            rememberUpgrade: false,
        });

        this.socket.on('connect_error', (error) => {
            this._log('❌ CONNECTION ERROR', error.toString());
        });

        this.socket.on('error', (error) => {
            this._log('❌ SOCKET ERROR', error.toString());
        });

        this._log('🔌 ATTEMPTING TO CONNECT');
        this.socket.connect();

        this.socket.on('connect', async () => {
            this._log('✅ CONNECTED TO SERVER');
            this._log('🆔 OUR SOCKET ID', this.socket.id);
            this.isConnected = true;
            
            // Get device name
            const deviceName = await electronAPI.invoke('get-device-name');
            const platform = await electronAPI.invoke('get-platform');
            
            this._log('📝 REGISTERING WITH DEVICE NAME', deviceName);
            this.socket.emit('register', {
                deviceName: deviceName,
                platform: platform,
            });
            
            // Request existing connected devices with a delay to ensure we're registered
            setTimeout(() => {
                this._log('📋 REQUESTING EXISTING DEVICES');
                this.socket.emit('get-devices', {});
                this.socket.emit('list-devices', {});
                this.socket.emit('get-connected-devices', {});
                this.socket.emit('devices', {});
                this.socket.emit('clients', {});
            }, 500);
        });

        this.socket.on('disconnect', () => {
            this._log('🔌 DISCONNECTED FROM SERVER');
            this.isConnected = false;
        });

        // Listen for device events
        this.socket.on('device-connected', (data) => {
            this._log('📱 DEVICE CONNECTED', data);
            if (this.onDeviceConnected) {
                this.onDeviceConnected(data);
            }
        });

        this.socket.on('device-disconnected', (data) => {
            this._log('📱 DEVICE DISCONNECTED', data);
            if (this.onDeviceDisconnected) {
                this.onDeviceDisconnected(data);
            }
        });

        // Listen for device list events
        ['devices', 'clients', 'room-info'].forEach(event => {
            this.socket.on(event, (data) => {
                this._log(`📋 RECEIVED ${event.toUpperCase()}`, data);
                let devices = data;
                if (event === 'room-info' && data.clients) {
                    devices = data.clients;
                }
                if (this.onConnectedDevicesList) {
                    this.onConnectedDevicesList(devices);
                }
            });
        });

        // Listen for WebRTC signaling
        this.socket.on('signal', (data) => {
            this._log('📡 RECEIVED SIGNAL', { from: data.from, type: data.signal?.type });
            if (this.onSignalReceived) {
                this.onSignalReceived(data.from, data.signal);
            }
        });

        // Listen for share events
        this.socket.on('share-ready', (data) => {
            this._log('🎯 SHARE READY RECEIVED', data);
            if (this.webrtcService) {
                this.webrtcService.handleShareReady(data.from);
            }
        });

        this.socket.on('request-share', (data) => {
            this._log('📋 REQUEST SHARE RECEIVED', data);
            if (this.webrtcService) {
                this.webrtcService.handleRequestShare(data.from);
            }
        });
    }

    sendSignal(to, signal) {
        if (this.socket && this.isConnected) {
            this._log('📤 SENDING SIGNAL', { to: to.substring(0, 8) + '...', type: signal.type });
            this.socket.emit('signal', {
                to: to,
                signal: signal
            });
        } else {
            this._log('❌ CANNOT SEND SIGNAL - NOT CONNECTED');
        }
    }

    sendShareReady() {
        if (this.socket && this.isConnected) {
            this._log('📤 SENDING SHARE READY');
            this.socket.emit('share-ready', {});
        }
    }

    sendRequestShare() {
        if (this.socket && this.isConnected) {
            this._log('📤 SENDING REQUEST SHARE');
            this.socket.emit('request-share', {});
        }
    }

    disconnect() {
        if (this.socket) {
            this.socket.disconnect();
            this.isConnected = false;
        }
    }
}

// Export for use in renderer
window.SocketService = SocketService;
