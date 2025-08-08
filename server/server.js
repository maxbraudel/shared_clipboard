const express = require('express');
const http = require('http');
const socketIo = require('socket.io');

const app = express();
const server = http.createServer(app);

// Add health check endpoint
app.get('/health', (req, res) => {
  const healthData = {
    status: 'OK',
    timestamp: new Date().toISOString(),
    uptime: process.uptime(),
    server: 'shared_clipboard_server',
    version: '1.0.0',
    connectedDevices: Object.keys(devices || {}).length,
    devicesReadyToShare: Object.keys(devices || {}).filter(id => devices[id].readyToShare).length
  };
  
  log('🏥 HEALTH CHECK REQUEST', {
    remoteAddress: req.ip || req.connection.remoteAddress,
    userAgent: req.get('User-Agent'),
    healthData
  });
  
  res.status(200).json(healthData);
});

const io = socketIo(server, {
  cors: {
    origin: "*",
    methods: ["GET", "POST"]
  }
});

let devices = {};

// Helper function to send devices list to a specific client
function sendDevicesList(socket) {
  const otherDevices = Object.keys(devices).filter(id => id !== socket.id);
  const devicesList = otherDevices.map(deviceId => {
    const deviceInfo = devices[deviceId];
    
    // Use the stored device name from registration
    const deviceName = deviceInfo.deviceName || `Device ${deviceId.substring(0, 8)}`;
    
    return {
      id: deviceId,
      deviceId: deviceId,
      socketId: deviceId,
      name: deviceName,
      readyToShare: deviceInfo.readyToShare
    };
  });
  
  log('📤 SENDING DEVICES LIST', {
    to: socket.id.substring(0, 8) + '...',
    devicesCount: devicesList.length,
    devices: devicesList.map(d => ({
      id: d.id.substring(0, 8) + '...',
      name: d.name,
      readyToShare: d.readyToShare
    }))
  });
  
  // Send the list using multiple event names to match what the client is listening for
  socket.emit('devices', devicesList);
  socket.emit('clients', devicesList);
  socket.emit('room-info', { clients: devicesList });
  
  // Also emit individual device-connected events for each existing device
  otherDevices.forEach(deviceId => {
    const deviceInfo = devicesList.find(d => d.id === deviceId);
    log('📱 SENDING INDIVIDUAL device-connected', {
      to: socket.id.substring(0, 8) + '...',
      deviceId: deviceId.substring(0, 8) + '...',
      deviceName: deviceInfo.name
    });
    socket.emit('device-connected', { 
      id: deviceId, 
      deviceId: deviceId,
      socketId: deviceId,
      name: deviceInfo.name
    });
  });
}

// Helper function for timestamped logging
function log(message, data = null) {
  const timestamp = new Date().toISOString();
  if (data) {
    console.log(`[${timestamp}] ${message}`, JSON.stringify(data, null, 2));
  } else {
    console.log(`[${timestamp}] ${message}`);
  }
}

// Log server startup
log('=== SERVER STARTING ===');
log('CORS configuration:', {
  origin: "*",
  methods: ["GET", "POST"]
});

io.on('connection', (socket) => {
  log('🔌 NEW CONNECTION', {
    socketId: socket.id,
    remoteAddress: socket.request.connection.remoteAddress,
    userAgent: socket.request.headers['user-agent'],
    totalConnections: Object.keys(devices).length + 1
  });

  // Log current state
  log('📊 CURRENT DEVICES STATE', {
    totalDevices: Object.keys(devices).length,
    devices: Object.keys(devices).map(id => ({
      id: id.substring(0, 8) + '...',
      readyToShare: devices[id].readyToShare
    }))
  });

  socket.on('register', (data) => {
    log('📝 DEVICE REGISTRATION', {
      socketId: socket.id.substring(0, 8) + '...',
      data: data,
      previouslyRegistered: !!devices[socket.id],
      userAgent: socket.request.headers['user-agent']
    });
    
    // Use device name from client data if available, otherwise extract from user agent
    let deviceName = data && data.deviceName ? data.deviceName : `Device ${socket.id.substring(0, 8)}`;
    
    // If no device name from client, fall back to user agent extraction
    if (!data || !data.deviceName) {
      if (socket.request.headers['user-agent']) {
        const userAgent = socket.request.headers['user-agent'];
        
        // Try to extract meaningful device info from user agent
        if (userAgent.includes('Macintosh')) {
          deviceName = `Mac Computer`;
        } else if (userAgent.includes('Windows')) {
          deviceName = `Windows PC`;
        } else if (userAgent.includes('iPhone')) {
          deviceName = `iPhone`;
        } else if (userAgent.includes('Android')) {
          deviceName = `Android Device`;
        } else if (userAgent.includes('Linux')) {
          deviceName = `Linux PC`;
        }
      }
    }
    
    // CRITICAL: Always reset readyToShare state on registration to prevent stale state
    devices[socket.id] = { 
      readyToShare: false, 
      signalingData: null,
      deviceName: deviceName,
      platform: data && data.platform ? data.platform : 'unknown'
    };
    
    // CRITICAL: Clear any stale ready-to-share state for this device
    log('🧹 CLEARING STALE READY-TO-SHARE STATE ON REGISTRATION', {
      deviceId: socket.id.substring(0, 8) + '...',
      deviceName: deviceName
    });
    
    log('📢 BROADCASTING device-connected', {
      newDeviceId: socket.id.substring(0, 8) + '...',
      deviceName: deviceName,
      broadcastingTo: Object.keys(devices).filter(id => id !== socket.id).length + ' other clients'
    });
    
    socket.broadcast.emit('device-connected', { 
      deviceId: socket.id,
      id: socket.id,
      socketId: socket.id,
      name: deviceName
    });
    
    // Immediately send existing devices list to the newly registered client
    log('📋 SENDING EXISTING DEVICES TO NEW CLIENT', {
      newClient: socket.id.substring(0, 8) + '...'
    });
    sendDevicesList(socket);
    
    log('📊 UPDATED DEVICES STATE AFTER REGISTRATION', {
      totalDevices: Object.keys(devices).length,
      devices: Object.keys(devices).map(id => ({
        id: id.substring(0, 8) + '...',
        readyToShare: devices[id].readyToShare
      }))
    });
  });

  socket.on('share-ready', () => {
    log('🚀 SHARE-READY RECEIVED', {
      socketId: socket.id.substring(0, 8) + '...',
      deviceExists: !!devices[socket.id]
    });
    
    if (devices[socket.id]) {
      devices[socket.id].readyToShare = true;
      log('✅ DEVICE MARKED AS READY TO SHARE', {
        socketId: socket.id.substring(0, 8) + '...',
        devicesReadyToShare: Object.keys(devices).filter(id => devices[id].readyToShare).length
      });
      
      // Notify other devices that a device is ready to share
      log('📢 BROADCASTING share-available', {
        sharingDeviceId: socket.id.substring(0, 8) + '...',
        broadcastingToAll: Object.keys(devices).length + ' clients'
      });
      
      io.emit('share-available', { deviceId: socket.id });
      
      log('📊 CURRENT SHARING STATE', {
        totalDevices: Object.keys(devices).length,
        devicesReadyToShare: Object.keys(devices).filter(id => devices[id].readyToShare).map(id => id.substring(0, 8) + '...')
      });
    } else {
      log('❌ ERROR: Device not found when trying to mark as ready', {
        socketId: socket.id.substring(0, 8) + '...'
      });
    }
  });

  // Allow clients to explicitly clear their ready-to-share state
  socket.on('share-not-ready', () => {
    log('🧹 SHARE-NOT-READY RECEIVED', {
      socketId: socket.id.substring(0, 8) + '...',
      deviceExists: !!devices[socket.id]
    });
    if (devices[socket.id]) {
      devices[socket.id].readyToShare = false;
      log('✅ DEVICE CLEARED FROM READY STATE', {
        socketId: socket.id.substring(0, 8) + '...',
        devicesReadyToShare: Object.keys(devices).filter(id => devices[id].readyToShare).length
      });
    }
  });

  // Alias some clients may emit
  socket.on('not-ready', () => {
    log('🧹 NOT-READY RECEIVED (alias)');
    if (devices[socket.id]) {
      devices[socket.id].readyToShare = false;
    }
  });

  socket.on('request-share', (data) => {
    log('📥 SHARE REQUEST RECEIVED', {
      requesterSocketId: socket.id.substring(0, 8) + '...',
      requestData: data
    });
    
    // Build list of ready devices EXCLUDING the requester
    const availableDevices = Object
      .keys(devices)
      .filter(id => devices[id].readyToShare && id !== socket.id);
    log('🔍 LOOKING FOR SHARING DEVICES', {
      totalDevices: Object.keys(devices).length,
      devicesReadyToShare: availableDevices.length,
      readyDevices: availableDevices.map(id => id.substring(0, 8) + '...')
    });
    
    const sharingDevice = availableDevices[0]; // Get the first available device
    
    if (sharingDevice) {
      log('✅ FOUND SHARING DEVICE', {
        requester: socket.id.substring(0, 8) + '...',
        sharingDevice: sharingDevice.substring(0, 8) + '...'
      });
      
      log('📤 SENDING share-request TO SHARING DEVICE', {
        to: sharingDevice.substring(0, 8) + '...',
        from: socket.id.substring(0, 8) + '...'
      });
      
      // Send request to the sharing device
      io.to(sharingDevice).emit('share-request', { from: socket.id });
    } else {
      log('❌ NO SHARING DEVICE AVAILABLE', {
        requester: socket.id.substring(0, 8) + '...',
        totalDevices: Object.keys(devices).length,
        message: 'No devices are currently ready to share (excluding requester)'
      });
      // Optionally notify requester so they can provide UI feedback
      io.to(socket.id).emit('no-sharer-available', {
        message: 'No other device is ready to share right now.'
      });
    }
  });

  socket.on('webrtc-signal', (data) => {
    log('🔄 WEBRTC SIGNAL RECEIVED', {
      from: socket.id.substring(0, 8) + '...',
      to: data.to ? data.to.substring(0, 8) + '...' : 'undefined',
      signalType: data.signal ? data.signal.type : 'unknown',
      hasCandidate: data.signal && data.signal.candidate ? 'yes' : 'no'
    });
    
    if (!data.to) {
      log('❌ ERROR: No recipient specified for WebRTC signal', {
        from: socket.id.substring(0, 8) + '...',
        signal: data.signal
      });
      return;
    }
    
    const recipientExists = devices[data.to];
    log('📡 FORWARDING WEBRTC SIGNAL', {
      from: socket.id.substring(0, 8) + '...',
      to: data.to.substring(0, 8) + '...',
      recipientExists: !!recipientExists,
      signalType: data.signal ? data.signal.type : 'unknown'
    });
    
    io.to(data.to).emit('webrtc-signal', { from: socket.id, signal: data.signal });
  });

  socket.on('disconnect', () => {
    log('❌ CLIENT DISCONNECTED', {
      socketId: socket.id.substring(0, 8) + '...',
      wasRegistered: !!devices[socket.id],
      wasReadyToShare: devices[socket.id] ? devices[socket.id].readyToShare : false
    });
    
    delete devices[socket.id];
    
    log('📢 BROADCASTING device-disconnected', {
      disconnectedDevice: socket.id.substring(0, 8) + '...',
      remainingDevices: Object.keys(devices).length
    });
    
    io.emit('device-disconnected', { deviceId: socket.id });
    
    log('📊 UPDATED DEVICES STATE AFTER DISCONNECT', {
      totalDevices: Object.keys(devices).length,
      devices: Object.keys(devices).map(id => ({
        id: id.substring(0, 8) + '...',
        readyToShare: devices[id].readyToShare
      }))
    });
  });

  // Handle requests for connected devices list
  socket.on('get-devices', () => {
    log('📋 GET-DEVICES REQUEST', {
      requester: socket.id.substring(0, 8) + '...'
    });
    sendDevicesList(socket);
  });

  socket.on('list-devices', () => {
    log('📋 LIST-DEVICES REQUEST', {
      requester: socket.id.substring(0, 8) + '...'
    });
    sendDevicesList(socket);
  });

  socket.on('get-connected-devices', () => {
    log('📋 GET-CONNECTED-DEVICES REQUEST', {
      requester: socket.id.substring(0, 8) + '...'
    });
    sendDevicesList(socket);
  });

  socket.on('devices', () => {
    log('📋 DEVICES REQUEST', {
      requester: socket.id.substring(0, 8) + '...'
    });
    sendDevicesList(socket);
  });

  socket.on('clients', () => {
    log('📋 CLIENTS REQUEST', {
      requester: socket.id.substring(0, 8) + '...'
    });
    sendDevicesList(socket);
  });

  socket.on('room-info', () => {
    log('📋 ROOM-INFO REQUEST', {
      requester: socket.id.substring(0, 8) + '...'
    });
    sendDevicesList(socket);
  });

  // Log any unhandled events
  socket.onAny((eventName, ...args) => {
    if (!['register', 'share-ready', 'request-share', 'webrtc-signal', 'disconnect', 
          'get-devices', 'list-devices', 'get-connected-devices', 'devices', 'clients', 'room-info'].includes(eventName)) {
      log('🔍 UNHANDLED EVENT', {
        event: eventName,
        from: socket.id.substring(0, 8) + '...',
        args: args
      });
    }
  });
});

const PORT = process.env.PORT || 3000;
server.listen(PORT, () => {
  log('=== SERVER STARTED SUCCESSFULLY ===');
  log('Server configuration:', {
    port: PORT,
    environment: process.env.NODE_ENV || 'development',
    corsOrigin: '*'
  });
  log('Waiting for client connections...');
});

// Add periodic status logging
setInterval(() => {
  if (Object.keys(devices).length > 0) {
    log('📊 PERIODIC STATUS CHECK', {
      totalConnectedDevices: Object.keys(devices).length,
      devicesReadyToShare: Object.keys(devices).filter(id => devices[id].readyToShare).length,
      devices: Object.keys(devices).map(id => ({
        id: id.substring(0, 8) + '...',
        readyToShare: devices[id].readyToShare
      }))
    });
  }
}, 30000); // Log every 30 seconds if there are connected devices
