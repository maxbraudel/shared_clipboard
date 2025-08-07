import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'package:shared_clipboard/services/webrtc_service.dart';

class SocketService {
  late IO.Socket socket;
  late WebRTCService _webrtcService;

  void init({required WebRTCService webrtcService}) {
    _webrtcService = webrtcService;
    socket = IO.io('https://test3.braudelserveur.com', <String, dynamic>{
      'transports': ['websocket'],
      'autoConnect': false,
    });
    socket.connect();

    socket.onConnect((_) {
      print('connected to server');
      socket.emit('register', {});
    });

    socket.on('share-request', (data) {
      print('Share request received from ${data['from']}');
      _webrtcService.createOffer(null); // Content will be sent via data channel
    });

    socket.on('webrtc-signal', (data) {
      if (data['signal']['type'] == 'offer') {
        _webrtcService.handleOffer(data['signal'], data['from']);
      } else if (data['signal']['type'] == 'answer') {
        _webrtcService.handleAnswer(data['signal']);
      } else if (data['signal']['type'] == 'candidate') {
        _webrtcService.handleCandidate(data['signal']);
      }
    });

    socket.onDisconnect((_) => print('disconnected from server'));
  }

  void sendShareReady() {
    socket.emit('share-ready');
  }

  void sendRequestShare() {
    socket.emit('request-share', {});
  }

  void sendSignal(String to, dynamic signal) {
    socket.emit('webrtc-signal', {'to': to, 'signal': signal});
  }
}
