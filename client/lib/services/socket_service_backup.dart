import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'package:shared_clipboard/services/webrtc_service.dart';

class SocketService {
  late IO.Socket socket;
  late WebRTCService _webrtcService;
  
  // Callbacks for UI updates
  Function(Map<String, dynamic> device)? onDeviceConnected;
  Function(Map<String, dynamic> device)? onDeviceDisconnected;
  Function(List<Map<String, dynamic>> devices)? onConnectedDevicesList;

  // Helper function for timestamped logging
  void _log(String message, [dynamic data]) {
    final timestamp = DateTime.now().toIso8601String();
    if (data != null) {
      print('[$timestamp] CLIENT: $message - $data');
    } else {
      print('[$timestamp] CLIENT: $message');
    }
  }

  void init({required WebRTCService webrtcService}) {
    _log('🚀 INITIALIZING SOCKET SERVICE');
    _webrtcService = webrtcService;
    
    // Set up the callback for WebRTC to send signals back through socket
    _webrtcService.onSignalGenerated = (String to, dynamic signal) {
      sendSignal(to, signal);
    };
    
    _log('🔗 CREATING SOCKET CONNECTION');
    
    socket = IO.io('https://test3.braudelserveur.com', <String, dynamic>{
      'transports': ['websocket', 'polling'],
      'autoConnect': false,
      'timeout': 20000,
      'forceNew': true,
      'upgrade': true,
      'rememberUpgrade': false,
    });

    socket.onConnectError((error) {
      _log('❌ CONNECTION ERROR', error.toString());
    });

    socket.onError((error) {
      _log('❌ SOCKET ERROR', error.toString());
    });

    _log('🔌 ATTEMPTING TO CONNECT');
    socket.connect();

    socket.onConnect((_) {
      _log('✅ CONNECTED TO SERVER');
      _log('🆔 OUR SOCKET ID', socket.id);
      socket.emit('register', {});
    });

    socket.on('share-request', (data) async {
      _log('📥 SHARE REQUEST RECEIVED', data);
      String requesterId = data['from'] ?? 'unknown';
      _log('📤 CREATING OFFER TO SEND CLIPBOARD TO REQUESTER', requesterId);
      
      try {
        await _webrtcService.createOffer(requesterId);
        _log('✅ WEBRTC createOffer COMPLETED SUCCESSFULLY');
      } catch (e, stackTrace) {
        _log('❌ ERROR CALLING WEBRTC createOffer', e.toString());
        _log('❌ STACK TRACE', stackTrace.toString());
      }
    });

    socket.on('webrtc-signal', (data) async {
      _log('🔄 WEBRTC SIGNAL RECEIVED', {
        'from': data['from'],
        'signalType': data['signal']['type']
      });
      
      if (data['signal']['type'] == 'offer') {
        await _webrtcService.handleOffer(data['signal'], data['from']);
      } else if (data['signal']['type'] == 'answer') {
        await _webrtcService.handleAnswer(data['signal']);
      } else if (data['signal']['type'] == 'candidate') {
        await _webrtcService.handleCandidate(data['signal']);
      }
    });

    // CRITICAL DEBUG: Log every single event to understand the server behavior
    socket.onAny((event, data) {
      _log('🔍 EVERY EVENT', {'event': event, 'data': data, 'ourId': socket.id});
    });

    socket.on('device-connected', (data) {
      _log('📱 DEVICE CONNECTED EVENT', data);
      _log('📱 OUR ID WHEN DEVICE CONNECTED', socket.id);
      
      if (data is Map) {
        final deviceId = data['id'] ?? data['socketId'] ?? data['clientId'];
        _log('📱 DEVICE ID IN EVENT', deviceId);
        _log('📱 IS THIS US?', deviceId == socket.id);
      }
      
      if (onDeviceConnected != null) {
        onDeviceConnected!(data);
      }
    });

    socket.on('device-disconnected', (data) {
      _log('📱 DEVICE DISCONNECTED EVENT', data);
      if (onDeviceDisconnected != null) {
        onDeviceDisconnected!(data);
      }
    });

    socket.on('share-available', (data) {
      _log('🚀 SHARE AVAILABLE', data);
    });

    socket.onDisconnect((reason) {
      _log('❌ DISCONNECTED FROM SERVER', reason);
    });
  }

  void sendShareReady() {
    _log('📤 SENDING SHARE-READY');
    socket.emit('share-ready');
  }

  void sendRequestShare() {
    _log('📤 SENDING REQUEST-SHARE');
    socket.emit('request-share', {});
  }

  void sendSignal(String to, dynamic signal) {
    _log('📤 SENDING WEBRTC SIGNAL', {
      'to': to,
      'signalType': signal['type'],
    });
    
    socket.emit('webrtc-signal', {'to': to, 'signal': signal});
  }

  bool get isConnected => socket.connected;
  
  void reconnect() {
    _log('🔄 MANUAL RECONNECTION ATTEMPT');
    socket.disconnect();
    socket.connect();
  }
}
