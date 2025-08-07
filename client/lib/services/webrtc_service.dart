import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:shared_clipboard/services/socket_service.dart';

class WebRTCService {
  final SocketService socketService;
  RTCPeerConnection? _peerConnection;
  RTCDataChannel? _dataChannel;
  String? _peerId;
  bool _isInitialized = false;

  WebRTCService({required this.socketService});

  Future<void> init() async {
    if (_isInitialized) return;
    
    final configuration = {
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
      ]
    };
    _peerConnection = await createPeerConnection(configuration);
    _isInitialized = true;

    _peerConnection?.onIceCandidate = (candidate) {
      if (_peerId != null) {
        socketService.sendSignal(_peerId!, {
          'type': 'candidate',
          'candidate': candidate.candidate,
          'sdpMid': candidate.sdpMid,
          'sdpMLineIndex': candidate.sdpMLineIndex,
        });
      }
    };

    _peerConnection?.onDataChannel = (channel) {
      _dataChannel = channel;
      _dataChannel?.onMessage = (message) {
        print("Received data: ${message.text}");
        Clipboard.setData(ClipboardData(text: message.text));
      };
    };
  }

  Future<void> createOffer(String? content, [String? peerId]) async {
    if (!_isInitialized) {
      await init();
    }
    
    if (_peerConnection == null) {
      print('ERROR: PeerConnection is null, cannot create offer');
      return;
    }
    
    // Set peer ID if provided
    if (peerId != null) {
      _peerId = peerId;
    }
    
    _dataChannel = await _peerConnection?.createDataChannel('clipboard', RTCDataChannelInit());
    if (content != null) {
      _dataChannel?.send(RTCDataChannelMessage(content));
    }
    RTCSessionDescription description = await _peerConnection!.createOffer();
    await _peerConnection!.setLocalDescription(description);
    
    if (_peerId != null) {
      socketService.sendSignal(_peerId!, {'type': 'offer', 'sdp': description.sdp});
    } else {
      print('ERROR: _peerId is null, cannot send signal');
    }
  }

  Future<void> handleOffer(dynamic offer, String from) async {
    if (!_isInitialized) {
      await init();
    }
    
    if (_peerConnection == null) {
      print('ERROR: PeerConnection is null, cannot handle offer');
      return;
    }
    
    _peerId = from;
    await _peerConnection?.setRemoteDescription(RTCSessionDescription(offer['sdp'], offer['type']));
    RTCSessionDescription description = await _peerConnection!.createAnswer();
    await _peerConnection!.setLocalDescription(description);
    socketService.sendSignal(_peerId!, {'type': 'answer', 'sdp': description.sdp});
  }

  Future<void> handleAnswer(dynamic answer) async {
    if (!_isInitialized) {
      await init();
    }
    
    if (_peerConnection == null) {
      print('ERROR: PeerConnection is null, cannot handle answer');
      return;
    }
    
    await _peerConnection?.setRemoteDescription(RTCSessionDescription(answer['sdp'], answer['type']));
  }

  Future<void> handleCandidate(dynamic candidate) async {
    if (!_isInitialized) {
      await init();
    }
    
    if (_peerConnection == null) {
      print('ERROR: PeerConnection is null, cannot handle candidate');
      return;
    }
    
    await _peerConnection?.addCandidate(
      RTCIceCandidate(
        candidate['candidate'],
        candidate['sdpMid'],
        candidate['sdpMLineIndex'],
      ),
    );
  }

  void dispose() {
    _dataChannel?.close();
    _peerConnection?.close();
  }
}
