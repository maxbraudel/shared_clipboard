# Shared Clipboard - Electron Client

A cross-platform clipboard sharing application built with Electron.

## Features

- **Cross-platform clipboard sharing** between multiple devices
- **System tray integration** for background operation
- **Global hotkeys** for quick clipboard operations
- **File transfer support** through clipboard detection
- **WebRTC peer-to-peer** communication for secure data transfer
- **Real-time device discovery** and connection status

## Installation

### Prerequisites

- Node.js (v16 or higher)
- npm or yarn

### Setup

1. Install dependencies:
```bash
npm install
```

2. Run in development mode:
```bash
npm run dev
```

3. Build for production:
```bash
npm run build
```

### Platform-specific builds

- **macOS**: `npm run build:mac`
- **Windows**: `npm run build:win`
- **Linux**: `npm run build:linux`

## Usage

### Global Shortcuts

- **Ctrl+F12** (Cmd+F12 on Mac): Share clipboard content
- **Ctrl+F11** (Cmd+F11 on Mac): Request clipboard from other devices

### System Tray

The app runs in the system tray and provides the following options:
- Show/Hide main window
- Enable/Disable service
- Quit application

### Device Discovery

The app automatically discovers other devices running the Shared Clipboard application on the same network through a central signaling server.

## Architecture

### Core Components

1. **Main Process** (`src/main.js`)
   - Electron main process
   - Window management
   - System tray functionality
   - Global shortcuts registration
   - IPC communication with renderer

2. **Renderer Process** (`src/renderer/`)
   - Web-based UI using HTML/CSS/JavaScript
   - Service coordination and management
   - Real-time device list updates

3. **Services**
   - **SocketService**: WebSocket communication with signaling server
   - **WebRTCService**: Peer-to-peer data transfer
   - **ClipboardService**: System clipboard integration
   - **FileTransferService**: File handling and transfer

### Communication Flow

1. **Device Discovery**: Devices connect to signaling server and announce presence
2. **Clipboard Sharing**: 
   - Device A signals readiness to share
   - Device B requests clipboard content
   - WebRTC peer connection established
   - Data transferred directly between devices
3. **File Transfer**: Files detected in clipboard are processed and transferred as base64-encoded data

## Configuration

### Server Configuration

The app connects to a signaling server at `https://test3.braudelserveur.com`. To use a different server, modify the URL in `src/renderer/services/SocketService.js`.

### File Transfer Limits

- Maximum file size: 50MB (configurable in `FileTransferService.js`)
- Supported file types: All (detected via MIME types)
- Download location: User's Downloads folder

## Development

### Project Structure

```
client-electron/
├── src/
│   ├── main.js                 # Electron main process
│   └── renderer/
│       ├── index.html          # Main UI
│       ├── styles.css          # Styling
│       ├── app.js              # App coordination
│       └── services/
│           ├── SocketService.js
│           ├── WebRTCService.js
│           ├── ClipboardService.js
│           └── FileTransferService.js
├── assets/
│   └── icon.png               # App icon
├── package.json
└── README.md
```

### Adding Features

1. **New Service**: Create a new service file in `src/renderer/services/`
2. **UI Updates**: Modify `src/renderer/index.html` and `src/renderer/styles.css`
3. **Main Process Features**: Add functionality to `src/main.js`

### Debugging

Run with development flag to enable DevTools:
```bash
npm run dev
```

## Security Considerations

- All data transfer occurs through encrypted WebRTC connections
- No persistent storage of clipboard data
- File transfers include checksum verification
- Direct peer-to-peer communication (no data stored on server)

## Troubleshooting

### Common Issues

1. **App not appearing in system tray**
   - Check if system tray is enabled on your system
   - On Linux, ensure a system tray is available

2. **Global shortcuts not working**
   - Check for conflicts with other applications
   - Try running the app as administrator (Windows) or with appropriate permissions

3. **Connection issues**
   - Verify internet connection
   - Check firewall settings for WebRTC traffic
   - Ensure signaling server is accessible

4. **File transfer failures**
   - Check file size limits
   - Verify permissions for Downloads folder
   - Ensure sufficient disk space

## License

MIT License - see LICENSE file for details.
