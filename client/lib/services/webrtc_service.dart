import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:shared_clipboard/services/socket_service.dart';

class WebRTCService {
  final SocketService socketService;
  RTCPeerConnection? _peerConnection;
  RTCDataChannel? _dataChannel;
  String? _peerId;

  WebRTCService({required this.socketService});

  void init() async {
    final configuration = {
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
      ]
    };
    _peerConnection = await createPeerConnection(configuration);

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

  Future<void> createOffer(String? content) async {
    _dataChannel = await _peerConnection?.createDataChannel('clipboard', RTCDataChannelInit());
    if (content != null) {
      _dataChannel?.send(RTCDataChannelMessage(content));
    }
    RTCSessionDescription description = await _peerConnection!.createOffer();
    await _peerConnection!.setLocalDescription(description);
    socketService.sendSignal(_peerId!, {'type': 'offer', 'sdp': description.sdp});
  }

  Future<void> handleOffer(dynamic offer, String from) async {
    _peerId = from;
    await _peerConnection?.setRemoteDescription(RTCSessionDescription(offer['sdp'], offer['type']));
    RTCSessionDescription description = await _peerConnection!.createAnswer();
    await _peerConnection!.setLocalDescription(description);
    socketService.sendSignal(_peerId!, {'type': 'answer', 'sdp': description.sdp});
  }

  Future<void> handleAnswer(dynamic answer) async {
    await _peerConnection?.setRemoteDescription(RTCSessionDescription(answer['sdp'], answer['type']));
  }

  Future<void> handleCandidate(dynamic candidate) async {
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
