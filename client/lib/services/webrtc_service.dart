import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

class WebRTCService {
  RTCPeerConnection? _peerConnection;
  RTCDataChannel? _dataChannel;
  String? _peerId;
  bool _isInitialized = false;
  String? _pendingClipboardContent;
  
  // Callback to send signals back to socket service
  Function(String to, dynamic signal)? onSignalGenerated;

  WebRTCService();

  // Helper function for timestamped logging
  void _log(String message, [dynamic data]) {
    final timestamp = DateTime.now().toIso8601String();
    if (data != null) {
      print('[$timestamp] WEBRTC: $message - $data');
    } else {
      print('[$timestamp] WEBRTC: $message');
    }
  }

  Future<void> init() async {
    if (_isInitialized) return;
    
    _log('🚀 INITIALIZING WEBRTC SERVICE');
    
    final configuration = {
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
      ]
    };
    _peerConnection = await createPeerConnection(configuration);
    _isInitialized = true;

    _peerConnection?.onIceCandidate = (candidate) {
      _log('🧊 ICE CANDIDATE GENERATED');
      if (_peerId != null && onSignalGenerated != null) {
        onSignalGenerated!(_peerId!, {
          'type': 'candidate',
          'candidate': candidate.candidate,
          'sdpMid': candidate.sdpMid,
          'sdpMLineIndex': candidate.sdpMLineIndex,
        });
      }
    };

    _peerConnection?.onConnectionState = (state) {
      _log('🔗 CONNECTION STATE CHANGED', state.toString());
    };

    _peerConnection?.onDataChannel = (channel) {
      _log('📡 DATA CHANNEL RECEIVED');
      _setupDataChannel(channel);
    };
    
    _log('✅ WEBRTC SERVICE INITIALIZED');
  }

  void _setupDataChannel(RTCDataChannel channel) {
    _dataChannel = channel;
    _log('📡 SETTING UP DATA CHANNEL', {
      'label': channel.label,
      'state': channel.state.toString(),
      'hasPendingContent': _pendingClipboardContent != null,
      'role': _pendingClipboardContent != null ? 'SENDER' : 'RECEIVER'
    });
    
    // Check if channel is already open
    if (channel.state == RTCDataChannelState.RTCDataChannelOpen) {
      _log('📡 DATA CHANNEL IS ALREADY OPEN DURING SETUP');
      _handleDataChannelOpen();
    }
    
    _dataChannel?.onDataChannelState = (state) {
      _log('📡 DATA CHANNEL STATE CHANGED', state.toString());
      if (state == RTCDataChannelState.RTCDataChannelOpen) {
        _handleDataChannelOpen();
      }
    };

    _dataChannel?.onMessage = (message) {
      _log('📥 RECEIVED DATA MESSAGE (RECEIVER ROLE)', message.text);
      try {
        Clipboard.setData(ClipboardData(text: message.text));
        _log('📋 CLIPBOARD UPDATED SUCCESSFULLY');
      } catch (e) {
        _log('❌ ERROR UPDATING CLIPBOARD', e.toString());
      }
    };
  }

  void _handleDataChannelOpen() {
    _log('✅ DATA CHANNEL IS NOW OPEN');
    
    // Only send content if we have pending content (i.e., we're the sender)
    if (_pendingClipboardContent != null) {
      _log('📤 SENDING PENDING CLIPBOARD CONTENT (SENDER ROLE)', _pendingClipboardContent);
      try {
        _dataChannel?.send(RTCDataChannelMessage(_pendingClipboardContent!));
        _log('✅ CLIPBOARD CONTENT SENT SUCCESSFULLY');
        _pendingClipboardContent = null;
      } catch (e) {
        _log('❌ ERROR SENDING CLIPBOARD CONTENT', e.toString());
      }
    } else {
      _log('⚠️ NO PENDING CLIPBOARD CONTENT TO SEND');
    }
  }

  Future<void> _resetConnection() async {
    _log('🔄 RESETTING PEER CONNECTION FOR NEW SHARE');
    
    // Close existing data channel
    if (_dataChannel != null) {
      _log('📡 CLOSING EXISTING DATA CHANNEL');
      _dataChannel?.close();
      _dataChannel = null;
    }
    
    // Close existing peer connection
    if (_peerConnection != null) {
      _log('🔗 CLOSING EXISTING PEER CONNECTION');
      _peerConnection?.close();
      _peerConnection = null;
    }
    
    // Clear any pending content and peer ID
    _pendingClipboardContent = null;
    _peerId = null;
    _isInitialized = false;
    
    // Reinitialize
    await init();
    _log('✅ PEER CONNECTION RESET COMPLETE');
  }

  Future<void> createOffer(String? peerId) async {
    try {
      _log('🎯 createOffer CALLED', peerId);
      
      // Reset connection state for clean start
      await _resetConnection();
      
      if (_peerConnection == null) {
        _log('❌ ERROR: PeerConnection is null after reset, cannot create offer');
        return;
      }
      
      // Set peer ID if provided
      if (peerId != null) {
        _peerId = peerId;
        _log('🎯 CREATING OFFER FOR PEER', peerId);
      }
      
      // Read current clipboard content
      try {
        _log('📋 READING CLIPBOARD FOR OFFER');
        final clipboardData = await Clipboard.getData(Clipboard.kTextPlain);
        if (clipboardData != null && clipboardData.text != null) {
          _pendingClipboardContent = clipboardData.text;
          _log('📋 CLIPBOARD CONTENT TO SHARE', clipboardData.text);
        } else {
          _log('❌ NO CLIPBOARD CONTENT TO SHARE');
        }
      } catch (e) {
        _log('❌ ERROR READING CLIPBOARD', e.toString());
      }
      
      // Create data channel
      _log('📡 CREATING DATA CHANNEL');
      _dataChannel = await _peerConnection?.createDataChannel('clipboard', RTCDataChannelInit());
      if (_dataChannel != null) {
        _log('✅ DATA CHANNEL CREATED', {
          'label': _dataChannel!.label,
          'state': _dataChannel!.state.toString()
        });
        _log('📡 SETTING UP DATA CHANNEL MANUALLY (SENDER SIDE)');
        _setupDataChannel(_dataChannel!);
      } else {
        _log('❌ FAILED TO CREATE DATA CHANNEL');
      }
      
      // Create and send offer
      _log('📡 CREATING OFFER');
      RTCSessionDescription description = await _peerConnection!.createOffer();
      await _peerConnection!.setLocalDescription(description);
      
      if (_peerId != null && onSignalGenerated != null) {
        _log('📤 SENDING OFFER TO PEER', _peerId);
        onSignalGenerated!(_peerId!, {'type': 'offer', 'sdp': description.sdp});
      } else {
        _log('❌ ERROR: _peerId is null or callback not set, cannot send signal');
      }
      
      _log('✅ createOffer COMPLETED SUCCESSFULLY');
    } catch (e) {
      _log('❌ CRITICAL ERROR in createOffer', e.toString());
      _log('❌ STACK TRACE', e.toString());
    }
  }

  Future<void> handleOffer(dynamic offer, String from) async {
    _log('📥 HANDLING OFFER FROM', from);
    
    // Reset connection state for clean start
    await _resetConnection();
    
    if (_peerConnection == null) {
      _log('❌ ERROR: PeerConnection is null after reset, cannot handle offer');
      return;
    }
    
    _peerId = from;
    await _peerConnection?.setRemoteDescription(RTCSessionDescription(offer['sdp'], offer['type']));
    RTCSessionDescription description = await _peerConnection!.createAnswer();
    await _peerConnection!.setLocalDescription(description);
    _log('📤 SENDING ANSWER');
    if (onSignalGenerated != null) {
      onSignalGenerated!(_peerId!, {'type': 'answer', 'sdp': description.sdp});
    }
  }

  Future<void> handleAnswer(dynamic answer) async {
    if (!_isInitialized) {
      await init();
    }
    
    if (_peerConnection == null) {
      _log('❌ ERROR: PeerConnection is null, cannot handle answer');
      return;
    }
    
    _log('📥 HANDLING ANSWER');
    await _peerConnection?.setRemoteDescription(RTCSessionDescription(answer['sdp'], answer['type']));
  }

  Future<void> handleCandidate(dynamic candidate) async {
    if (!_isInitialized) {
      await init();
    }
    
    if (_peerConnection == null) {
      _log('❌ ERROR: PeerConnection is null, cannot handle candidate');
      return;
    }
    
    _log('🧊 HANDLING ICE CANDIDATE');
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
