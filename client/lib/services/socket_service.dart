import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'package:shared_clipboard/services/webrtc_service.dart';

class SocketService {
  late IO.Socket socket;
  late WebRTCService _webrtcService;
  
  // Callbacks for UI updates
  Function(Map<String, dynamic> device)? onDeviceConnected;
  Function(Map<String, dynamic> device)? onDeviceDisconnected;

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
    
    _log('🔗 CREATING SOCKET CONNECTION', {
      'url': 'https://test3.braudelserveur.com',
      'transports': ['websocket'],
      'autoConnect': false
    });
    
    socket = IO.io('https://test3.braudelserveur.com', <String, dynamic>{
      'transports': ['websocket', 'polling'], // Try polling as fallback
      'autoConnect': false,
      'timeout': 20000,
      'forceNew': true,
      'upgrade': true,
      'rememberUpgrade': false,
    });

    // Add connection error handlers
    socket.onConnectError((error) {
      _log('❌ CONNECTION ERROR', error.toString());
    });

    socket.onError((error) {
      _log('❌ SOCKET ERROR', error.toString());
    });

    socket.onReconnectError((error) {
      _log('❌ RECONNECTION ERROR', error.toString());
    });

    socket.onConnectTimeout((timeout) {
      _log('⏰ CONNECTION TIMEOUT', timeout.toString());
    });

    _log('🔌 ATTEMPTING TO CONNECT');
    socket.connect();

    socket.onConnect((_) {
      _log('✅ CONNECTED TO SERVER');
      _log('📝 SENDING REGISTRATION');
      socket.emit('register', {});
    });

    socket.on('share-request', (data) async {
      _log('📥 SHARE REQUEST RECEIVED', data);
      // When we receive a share request, we should create an offer and send our clipboard
      String requesterId = data['from'] ?? 'unknown';
      _log('📤 CREATING OFFER TO SEND CLIPBOARD TO REQUESTER', requesterId);
      
      try {
        _log('🔧 CALLING WEBRTC SERVICE createOffer');
        await _webrtcService.createOffer(requesterId); // Make it await
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
        _log('📥 PROCESSING OFFER SIGNAL');
        await _webrtcService.handleOffer(data['signal'], data['from']);
      } else if (data['signal']['type'] == 'answer') {
        _log('📥 PROCESSING ANSWER SIGNAL');
        await _webrtcService.handleAnswer(data['signal']);
      } else if (data['signal']['type'] == 'candidate') {
        _log('📥 PROCESSING CANDIDATE SIGNAL');
        await _webrtcService.handleCandidate(data['signal']);
      }
    });

    socket.on('device-connected', (data) {
      _log('📱 DEVICE CONNECTED', data);
      if (onDeviceConnected != null) {
        onDeviceConnected!(data);
      }
    });

    socket.on('device-disconnected', (data) {
      _log('📱 DEVICE DISCONNECTED', data);
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

    socket.onReconnect((attemptNumber) {
      _log('🔄 RECONNECTED TO SERVER', 'Attempt: $attemptNumber');
    });

    socket.onReconnecting((attemptNumber) {
      _log('🔄 ATTEMPTING RECONNECTION', 'Attempt: $attemptNumber');
    });

    // Log any unhandled events
    socket.onAny((event, data) {
      if (!['connect', 'disconnect', 'share-request', 'webrtc-signal', 
            'device-connected', 'device-disconnected', 'share-available'].contains(event)) {
        _log('🔍 UNHANDLED EVENT', {'event': event, 'data': data});
      }
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
      'signal_size': signal.toString().length
    });
    
    if (signal['type'] == 'offer') {
      _log('📤 SENDING OFFER SIGNAL', {
        'to': to,
        'sdp_length': signal['sdp']?.length ?? 0
      });
    }
    
    socket.emit('webrtc-signal', {'to': to, 'signal': signal});
    _log('✅ SIGNAL EMITTED TO SERVER');
  }

  // Add method to check connection status
  bool get isConnected => socket.connected;
  
  // Add method to manually reconnect
  void reconnect() {
    _log('🔄 MANUAL RECONNECTION ATTEMPT');
    socket.disconnect();
    socket.connect();
  }
}
