import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:shared_clipboard/services/file_transfer_service.dart';

class WebRTCService {
  RTCPeerConnection? _peerConnection;
  RTCDataChannel? _dataChannel;
  String? _peerId;
  bool _isInitialized = false;
  String? _pendingClipboardContent;
  bool _isResetting = false; // Prevent multiple resets
  final FileTransferService _fileTransferService = FileTransferService();
  
  // Queue for ICE candidates received before remote description is set
  final List<RTCIceCandidate> _pendingCandidates = [];
  bool _remoteDescriptionSet = false;
  
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
    if (_isInitialized) {
      _log('⚠️ ALREADY INITIALIZED, SKIPPING');
      return;
    }
    
    _log('🚀 INITIALIZING WEBRTC SERVICE');
    
    try {
      final configuration = {
        'iceServers': [
          {'urls': 'stun:stun.l.google.com:19302'},
        ]
      };
      
      // Create peer connection with timeout protection
      _peerConnection = await Future.any([
        createPeerConnection(configuration),
        Future.delayed(Duration(seconds: 2)).then((_) => throw TimeoutException('PeerConnection creation timeout', Duration(seconds: 2))),
      ]);
      
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
    } catch (e) {
      _log('❌ ERROR INITIALIZING WEBRTC SERVICE', e.toString());
      _isInitialized = false;
      _peerConnection = null;
      rethrow;
    }
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
      _log('📥 RECEIVED DATA MESSAGE (RECEIVER ROLE)', '${message.text.length} bytes');
      try {
        // Deserialize the received content
        final clipboardContent = _fileTransferService.deserializeClipboardContent(message.text);
        
        if (clipboardContent.isFiles) {
          _log('📁 RECEIVED FILES', '${clipboardContent.files.length} files');
          _fileTransferService.setClipboardContent(clipboardContent);
          _log('✅ FILES SET TO CLIPBOARD/TEMP FOLDER');
        } else {
          _log('📝 RECEIVED TEXT', clipboardContent.text);
          Clipboard.setData(ClipboardData(text: clipboardContent.text));
          _log('📋 TEXT CLIPBOARD UPDATED SUCCESSFULLY');
        }
      } catch (e) {
        _log('❌ ERROR PROCESSING RECEIVED DATA', e.toString());
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
    // Prevent multiple simultaneous resets
    if (_isResetting) {
      _log('⚠️ RESET ALREADY IN PROGRESS, SKIPPING');
      return;
    }
    
    _isResetting = true;
    _log('🔄 RESETTING PEER CONNECTION FOR NEW SHARE');
    
    // Reset candidate queue and remote description flag
    _log('🔍 BEFORE RESET - Remote desc set: $_remoteDescriptionSet, Queue size: ${_pendingCandidates.length}');
    _pendingCandidates.clear();
    _remoteDescriptionSet = false;
    _log('🔍 AFTER RESET - Remote desc set: $_remoteDescriptionSet, Queue size: ${_pendingCandidates.length}');
    
    try {
      // Quick synchronous cleanup first
      _forceCleanup();
      
      // Close connections with individual try-catch blocks
      if (_dataChannel != null) {
        _log('📡 CLOSING EXISTING DATA CHANNEL');
        try {
          _dataChannel?.close();
        } catch (e) {
          _log('⚠️ ERROR CLOSING DATA CHANNEL (IGNORING)', e.toString());
        }
        _dataChannel = null;
      }
      
      if (_peerConnection != null) {
        _log('🔗 CLOSING EXISTING PEER CONNECTION');
        try {
          _peerConnection?.close();
        } catch (e) {
          _log('⚠️ ERROR CLOSING PEER CONNECTION (IGNORING)', e.toString());
        }
        _peerConnection = null;
      }
      
      // Reinitialize with timeout protection
      await _initWithTimeout();
      _log('✅ PEER CONNECTION RESET COMPLETE');
    } catch (e) {
      _log('❌ ERROR DURING RESET (FORCING CLEANUP)', e.toString());
      _forceCleanup();
      
      // Try to reinitialize anyway
      try {
        await _initWithTimeout();
        _log('✅ FORCED RESET RECOVERY SUCCESSFUL');
      } catch (recoveryError) {
        _log('❌ FORCED RESET RECOVERY FAILED', recoveryError.toString());
      }
    } finally {
      _isResetting = false;
    }
  }

  Future<void> _initWithTimeout() async {
    return Future.any([
      init(),
      Future.delayed(Duration(seconds: 3)).then((_) => throw TimeoutException('Init timeout', Duration(seconds: 3))),
    ]);
  }

  void _forceCleanup() {
    _dataChannel = null;
    _peerConnection = null;
    _pendingClipboardContent = null;
    _peerId = null;
    _isInitialized = false;
    _pendingCandidates.clear();
    _remoteDescriptionSet = false;
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
      
      // Read current clipboard content (text or files)
      try {
        _log('📋 READING CLIPBOARD FOR OFFER');
        final clipboardContent = await _fileTransferService.getClipboardContent();
        
        if (clipboardContent.isFiles) {
          _log('📁 FOUND FILES IN CLIPBOARD', '${clipboardContent.files.length} files');
          _pendingClipboardContent = _fileTransferService.serializeClipboardContent(clipboardContent);
          _log('� FILES SERIALIZED FOR TRANSFER', '${_pendingClipboardContent!.length} bytes');
        } else if (clipboardContent.text.isNotEmpty) {
          _log('📝 FOUND TEXT IN CLIPBOARD', clipboardContent.text);
          _pendingClipboardContent = _fileTransferService.serializeClipboardContent(clipboardContent);
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
    _log('🔍 CURRENT STATE - Remote desc set: $_remoteDescriptionSet, Queue size: ${_pendingCandidates.length}');
    
    // Reset connection state for clean start
    await _resetConnection();
    
    if (_peerConnection == null) {
      _log('❌ ERROR: PeerConnection is null after reset, cannot handle offer');
      return;
    }
    
    _peerId = from;
    await _peerConnection?.setRemoteDescription(RTCSessionDescription(offer['sdp'], offer['type']));
    _remoteDescriptionSet = true;
    _log('✅ REMOTE DESCRIPTION SET - Flag: $_remoteDescriptionSet');
    
    // Process any queued candidates
    await _processQueuedCandidates();
    
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
    _remoteDescriptionSet = true;
    
    // Process any queued candidates
    await _processQueuedCandidates();
  }

  Future<void> handleCandidate(dynamic candidate) async {
    if (!_isInitialized) {
      await init();
    }
    
    if (_peerConnection == null) {
      _log('❌ ERROR: PeerConnection is null, cannot handle candidate');
      return;
    }
    
    final iceCandidate = RTCIceCandidate(
      candidate['candidate'],
      candidate['sdpMid'],
      candidate['sdpMLineIndex'],
    );
    
    _log('🧊 HANDLING ICE CANDIDATE - Remote desc set: $_remoteDescriptionSet, Queue size: ${_pendingCandidates.length}');
    
    if (!_remoteDescriptionSet) {
      _log('📦 QUEUEING ICE CANDIDATE (remote description not set yet)');
      _pendingCandidates.add(iceCandidate);
      return;
    }
    
    _log('🧊 ADDING ICE CANDIDATE DIRECTLY');
    try {
      await _peerConnection?.addCandidate(iceCandidate);
      _log('✅ ICE CANDIDATE ADDED SUCCESSFULLY');
    } catch (e) {
      _log('❌ ERROR ADDING ICE CANDIDATE', e.toString());
      // If adding fails due to remote description being null, queue it
      if (e.toString().contains('remote description was null')) {
        _log('📦 QUEUEING CANDIDATE DUE TO ERROR');
        _remoteDescriptionSet = false;
        _pendingCandidates.add(iceCandidate);
      }
    }
  }

  Future<void> _processQueuedCandidates() async {
    if (_pendingCandidates.isEmpty) return;
    
    _log('📦 PROCESSING ${_pendingCandidates.length} QUEUED ICE CANDIDATES');
    
    for (final candidate in _pendingCandidates) {
      try {
        await _peerConnection?.addCandidate(candidate);
        _log('✅ QUEUED ICE CANDIDATE ADDED SUCCESSFULLY');
      } catch (e) {
        _log('❌ ERROR ADDING QUEUED ICE CANDIDATE', e.toString());
      }
    }
    
    _pendingCandidates.clear();
    _log('📦 FINISHED PROCESSING QUEUED CANDIDATES');
  }

  void dispose() {
    _dataChannel?.close();
    _peerConnection?.close();
  }
}
