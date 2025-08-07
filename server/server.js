const express = require('express');
const http = require('http');
const socketIo = require('socket.io');

const app = express();
const server = http.createServer(app);
const io = socketIo(server, {
  cors: {
    origin: "*",
    methods: ["GET", "POST"]
  }
});

let devices = {};

io.on('connection', (socket) => {
  console.log('a user connected:', socket.id);

  socket.on('register', (data) => {
    console.log('registering device:', socket.id);
    devices[socket.id] = { readyToShare: false, signalingData: null };
    socket.broadcast.emit('device-connected', { deviceId: socket.id });
  });

  socket.on('share-ready', () => {
    if (devices[socket.id]) {
      devices[socket.id].readyToShare = true;
      console.log(`Device ${socket.id} is ready to share`);
      // Notify other devices that a device is ready to share
      io.emit('share-available', { deviceId: socket.id });
    }
  });

  socket.on('request-share', (data) => {
    const sharingDevice = Object.keys(devices).find(id => devices[id].readyToShare);
    if (sharingDevice) {
      console.log(`Device ${socket.id} is requesting share from ${sharingDevice}`);
      // Send request to the sharing device
      io.to(sharingDevice).emit('share-request', { from: socket.id });
    }
  });

  socket.on('webrtc-signal', (data) => {
    console.log(`Signal from ${socket.id} to ${data.to}`);
    io.to(data.to).emit('webrtc-signal', { from: socket.id, signal: data.signal });
  });

  socket.on('disconnect', () => {
    console.log('user disconnected:', socket.id);
    delete devices[socket.id];
    io.emit('device-disconnected', { deviceId: socket.id });
  });
});

const PORT = process.env.PORT || 3000;
server.listen(PORT, () => console.log(`Server listening on port ${PORT}`));
