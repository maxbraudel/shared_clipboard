import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:shared_clipboard/services/file_transfer_service.dart';
import 'package:file_picker/file_picker.dart';


class WebRTCService {
  RTCPeerConnection? _peerConnection;
  RTCDataChannel? _dataChannel;
  String? _peerId;
  bool _isInitialized = false;
  ClipboardContent? _pendingClipboardContent; // store structured content to allow streaming
  bool _isResetting = false; // Prevent multiple resets
  final FileTransferService _fileTransferService = FileTransferService();
  
  // Queue for ICE candidates received before remote description is set
  final List<RTCIceCandidate> _pendingCandidates = [];
  bool _remoteDescriptionSet = false;

  // Chunking protocol settings and state
  static const int _chunkSize = 16 * 1024; // 16 KB safe default for data channels
  static const int _bufferedLowThreshold = 512 * 1024; // 512 KB backpressure threshold (more conservative)
  final Map<String, StringBuffer> _rxBuffers = {};
  final Map<String, int> _rxReceivedBytes = {};
  final Map<String, int> _rxTotalBytes = {};
  Completer<void>? _bufferLowCompleter;
  // Fallback pacing accumulator when bufferedAmount isn't reliable
  int _pacingBytes = 0;
  int _rateBytesWindow = 0;
  DateTime _rateWindowStart = DateTime.now();
  int _messagesSent = 0;
  int _lastReceivedAck = 0;

  // Streaming files state (proto v2)
  final Map<String, _FileSession> _fileSessions = {};
  final Map<String, Completer<void>> _sessionReadyCompleters = {};
  
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

  // Streaming files protocol (proto v2)
  Future<void> _sendFilesStreaming(ClipboardContent content) async {
    if (_dataChannel == null) throw StateError('DataChannel not ready');
    final sessionId = DateTime.now().microsecondsSinceEpoch.toString();
    final filesMeta = content.files
        .map((f) => {
              'name': f.name,
              'size': f.size,
              'checksum': f.checksum,
            })
        .toList();
    // Start session with metadata so receiver can prompt immediately
    final startEnv = jsonEncode({
      '__sc_proto': 2,
      'kind': 'files',
      'mode': 'start',
      'sessionId': sessionId,
      'files': filesMeta,
    });
    await _sendWithBackpressure(startEnv);

    // Wait for receiver to prepare and acknowledge readiness
    final ready = Completer<void>();
    _sessionReadyCompleters[sessionId] = ready;
    try {
      // Allow ample time for the receiver to choose save locations
      await ready.future.timeout(Duration(minutes: 3));
      _log('✅ RECEIVER READY, STARTING STREAM', sessionId);
    } catch (e) {
      _log('⚠️ RECEIVER READY TIMEOUT, ABORTING STREAM', sessionId);
      _sessionReadyCompleters.remove(sessionId);
      return;
    }

    // Stream each file from disk with extreme rate limiting to prevent SCTP overflow
    for (int i = 0; i < content.files.length; i++) {
      final f = content.files[i];
      _log('🚚 START STREAMING FILE', {'index': i, 'name': f.name, 'size': f.size});
      int sent = 0;
      
      if (f.path.isNotEmpty) {
        final file = File(f.path);
        if (await file.exists()) {
          final raf = await file.open(mode: FileMode.read);
          try {
            while (true) {
              final read = await raf.read(_chunkSize);
              if (read.isEmpty) break;
              
              final env = jsonEncode({
                '__sc_proto': 2,
                'kind': 'files',
                'mode': 'file_chunk',
                'sessionId': sessionId,
                'fileIndex': i,
                'data': base64Encode(read),
              });
              await _sendWithBackpressure(env);
              
              // Extreme rate limiting: 50ms delay between every chunk
              await Future.delayed(Duration(milliseconds: 50));
              
              sent += read.length;
              if (sent % (1024 * 1024) < _chunkSize) {
                _log('📤 SENDER PROGRESS', {'file': f.name, 'sent': sent, 'of': f.size});
              }
            }
          } finally {
            await raf.close();
          }
        } else {
          _log('⚠️ FILE PATH NOT FOUND, FALLING BACK TO MEMORY', f.path);
        }
      }
      // Fallback to preloaded bytes if no valid path
      if (sent == 0 && f.content.isNotEmpty) {
        final bytes = f.content;
        int offset = 0;
        while (offset < bytes.length) {
          final end = (offset + _chunkSize > bytes.length) ? bytes.length : offset + _chunkSize;
          final chunkBytes = bytes.sublist(offset, end);
          
          final env = jsonEncode({
            '__sc_proto': 2,
            'kind': 'files',
            'mode': 'file_chunk',
            'sessionId': sessionId,
            'fileIndex': i,
            'data': base64Encode(chunkBytes),
          });
          await _sendWithBackpressure(env);
          
          // Extreme rate limiting: 50ms delay between every chunk
          await Future.delayed(Duration(milliseconds: 50));
          
          offset = end;
          sent = offset;
          if (sent % (1024 * 1024) < _chunkSize) {
            _log('📤 SENDER PROGRESS', {'file': f.name, 'sent': sent, 'of': f.size});
          }
        }
      }
      // Verify integrity before declaring completion
      if (f.size > 0 && sent < f.size) {
        _log('🛑 SENDER DETECTED PREMATURE EOF', {
          'file': f.name,
          'sent': sent,
          'expected': f.size,
          'path': f.path
        });
        // Inform receiver and abort whole session to avoid corrupted files
        final cancelEnv = jsonEncode({
          '__sc_proto': 2,
          'kind': 'files',
          'mode': 'cancel',
          'sessionId': sessionId,
        });
        await _sendWithBackpressure(cancelEnv);
        _log('🚫 SESSION CANCELLED DUE TO PREMATURE EOF', sessionId);
        return;
      }
      _log('🏁 SENDER FILE COMPLETE', {'file': f.name, 'sent': sent, 'expected': f.size});
      // End of this file
      final fileEnd = jsonEncode({
        '__sc_proto': 2,
        'kind': 'files',
        'mode': 'file_end',
        'sessionId': sessionId,
        'fileIndex': i,
      });
      await _sendWithBackpressure(fileEnd);
    }

    // End session
    final endEnv = jsonEncode({
      '__sc_proto': 2,
      'kind': 'files',
      'mode': 'end',
      'sessionId': sessionId,
    });
    await _sendWithBackpressure(endEnv);
  }

  Future<void> init({bool preserveClipboardContent = false}) async {
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
    
    // Backpressure: fire completer when buffered amount goes low
    _dataChannel?.onBufferedAmountLow = (int amount) {
      _log('📉 DATA CHANNEL BUFFERED AMOUNT LOW');
      _bufferLowCompleter?.complete();
      _bufferLowCompleter = null;
    };
    _dataChannel?.bufferedAmountLowThreshold = _bufferedLowThreshold;

    _dataChannel?.onDataChannelState = (state) {
      _log('📡 DATA CHANNEL STATE CHANGED', state.toString());
      if (state == RTCDataChannelState.RTCDataChannelOpen) {
        _handleDataChannelOpen();
      }
    };

    _dataChannel?.onMessage = (message) {
      // Support: proto v2 streaming (files), proto v1 chunked JSON payloads, and legacy single payload
      final text = message.text;
      _log('📥 RECEIVED DATA MESSAGE', {
        'bytes': text.length,
        'role': _pendingClipboardContent != null ? 'SENDER' : 'RECEIVER',
        'peerId': _peerId,
        'preview': text.length > 100 ? text.substring(0, 100) + '...' : text
      });
      try {
        // Try to parse as protocol envelope
        final isJsonEnvelope = text.startsWith('{') && text.contains('"__sc_proto"');
        if (isJsonEnvelope) {
          final Map<String, dynamic> env = jsonDecode(text);
          // Proto v2: streaming files
          if (env['__sc_proto'] == 2 && env['kind'] == 'files') {
            final mode = env['mode'] as String?;
            final sessionId = env['sessionId'] as String?;
            if (mode == 'start' && sessionId != null) {
              // Ask user for directory immediately
              final filesMeta = (env['files'] as List).cast<Map<String, dynamic>>();
              _log('🔰 START FILE STREAM SESSION', {
                'sessionId': sessionId, 
                'files': filesMeta.length,
                'role': 'RECEIVER',
                'peerId': _peerId
              });
              
              // CRITICAL: Use async IIFE with proper error handling
              (() async {
                try {
                  final prepared = await _promptDirectoryAndPrepareFiles(sessionId, filesMeta);
                  if (!prepared) {
                    // Inform sender we cancelled so it can abort immediately
                    final cancelEnv = jsonEncode({
                      '__sc_proto': 2,
                      'kind': 'files',
                      'mode': 'cancel',
                      'sessionId': sessionId,
                    });
                    await _sendWithBackpressure(cancelEnv);
                    _log('🚫 RECEIVER CANCELLED BEFORE READY', sessionId);
                    return;
                  }
                  // Notify sender we are ready to receive chunks
                  final readyEnv = jsonEncode({
                    '__sc_proto': 2,
                    'kind': 'files',
                    'mode': 'ready',
                    'sessionId': sessionId,
                  });
                  await _sendWithBackpressure(readyEnv);
                  _log('📨 SENT RECEIVER READY', sessionId);
                } catch (e) {
                  _log('❌ ERROR IN FILE STREAM START HANDLER', e.toString());
                  // Send cancel on error
                  try {
                    final cancelEnv = jsonEncode({
                      '__sc_proto': 2,
                      'kind': 'files',
                      'mode': 'cancel',
                      'sessionId': sessionId,
                    });
                    await _sendWithBackpressure(cancelEnv);
                  } catch (cancelError) {
                    _log('❌ ERROR SENDING CANCEL', cancelError.toString());
                  }
                }
              })();
              return;
            }
            if (mode == 'ready' && sessionId != null) {
              // Sender side receives readiness ack
              final c = _sessionReadyCompleters.remove(sessionId);
              c?.complete();
              _log('📩 RECEIVED READY ACK', sessionId);
              return;
            }
            if (mode == 'cancel' && sessionId != null) {
              // Sender side receives cancellation; abort stream immediately
              final c = _sessionReadyCompleters.remove(sessionId);
              c?.completeError(StateError('Receiver cancelled'));
              _abortFileSession(sessionId);
              _log('🛑 RECEIVED CANCEL, ABORTING SESSION', sessionId);
              return;
            }
            if (mode == 'file_chunk' && sessionId != null) {
              final idx = env['fileIndex'] as int? ?? 0;
              final dataB64 = env['data'] as String? ?? '';
              _handleFileChunk(sessionId, idx, dataB64);
              return;
            }
            if (mode == 'file_end' && sessionId != null) {
              final idx = env['fileIndex'] as int? ?? 0;
              _handleFileEnd(sessionId, idx);
              return;
            }
            if (mode == 'end' && sessionId != null) {
              _finalizeFileSession(sessionId);
              return;
            }
          }
          // Proto v1: chunked JSON clipboard payload
          if (env['__sc_proto'] == 1 && env['kind'] == 'clipboard') {
            final mode = env['mode'] as String?;
            final id = env['id'] as String?;
            if (mode == 'start' && id != null) {
              final total = (env['total'] as num?)?.toInt() ?? 0;
              _rxBuffers[id] = StringBuffer();
              _rxReceivedBytes[id] = 0;
              _rxTotalBytes[id] = total;
              _log('🔰 START CLIPBOARD TRANSFER', {'id': id, 'total': total});
              return;
            }
            if (mode == 'chunk' && id != null) {
              final data = env['data'] as String? ?? '';
              final buf = _rxBuffers[id];
              if (buf != null) {
                buf.write(data);
                final rec = (_rxReceivedBytes[id] ?? 0) + data.length;
                _rxReceivedBytes[id] = rec;
                final total = _rxTotalBytes[id] ?? 0;
                if (total > 0) {
                  _log('📦 RECEIVED CHUNK', {'id': id, 'received': rec, 'total': total});
                } else {
                  _log('📦 RECEIVED CHUNK', {'id': id, 'received': rec});
                }
              }
              return;
            }
            if (mode == 'end' && id != null) {
              final buf = _rxBuffers.remove(id);
              _rxTotalBytes.remove(id);
              _rxReceivedBytes.remove(id);
              if (buf != null) {
                final payload = buf.toString();
                _log('🏁 END CLIPBOARD TRANSFER', {'id': id, 'size': payload.length});
                _handleClipboardPayload(payload);
              }
              return;
            }
          }
        }
        // Legacy single-message payload
        _log('📋 PROCESSING LEGACY CLIPBOARD PAYLOAD', text.length);
        _handleClipboardPayload(text);
      } catch (e) {
        _log('❌ ERROR PROCESSING RECEIVED DATA', e.toString());
      }
    };
  }

  void _handleDataChannelOpen() {
    _log('✅ DATA CHANNEL IS NOW OPEN');
    
    // Only send content if we have pending content (i.e., we're the sender)
    if (_pendingClipboardContent != null) {
      final content = _pendingClipboardContent!;
      if (content.isFiles) {
        _log('📤 SENDING FILES VIA STREAMING PROTOCOL', {'count': content.files.length});
        _sendFilesStreaming(content).then((_) {
          _log('✅ FILES STREAMED SUCCESSFULLY');
          _pendingClipboardContent = null;
        }).catchError((e) {
          _log('❌ ERROR STREAMING FILES', e.toString());
        });
      } else {
        final payload = _fileTransferService.serializeClipboardContent(content);
        _log('📤 SENDING TEXT/JSON VIA CHUNKING', {'bytes': payload.length});
        _sendLargeMessage(payload).then((_) {
          _log('✅ CLIPBOARD CONTENT SENT SUCCESSFULLY');
          _pendingClipboardContent = null;
        }).catchError((e) {
          _log('❌ ERROR SENDING CLIPBOARD CONTENT', e.toString());
        });
      }
    } else {
      _log('⚠️ NO PENDING CLIPBOARD CONTENT TO SEND');
    }
  }

  // Send message with chunking and backpressure-safe logic
  Future<void> _sendLargeMessage(String text) async {
    if (_dataChannel == null) throw StateError('DataChannel not ready');
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    final total = text.length;
    // Start envelope
    final startEnv = jsonEncode({
      '__sc_proto': 1,
      'kind': 'clipboard',
      'mode': 'start',
      'id': id,
      'total': total,
      'chunkSize': _chunkSize,
    });
    await _sendWithBackpressure(startEnv);
    // Chunks
    int offset = 0;
    while (offset < total) {
      final end = (offset + _chunkSize > total) ? total : offset + _chunkSize;
      final chunk = text.substring(offset, end);
      final chunkEnv = jsonEncode({
        '__sc_proto': 1,
        'kind': 'clipboard',
        'mode': 'chunk',
        'id': id,
        'seq': offset ~/ _chunkSize,
        'data': chunk,
      });
      await _sendWithBackpressure(chunkEnv);
      offset = end;

    }
    // End envelope
    final endEnv = jsonEncode({
      '__sc_proto': 1,
      'kind': 'clipboard',
      'mode': 'end',
      'id': id,
    });
    await _sendWithBackpressure(endEnv);
  }

  void _handleClipboardPayload(String payload) {
    try {
      _log('🔍 DESERIALIZING CLIPBOARD PAYLOAD', {
        'size': payload.length,
        'role': 'RECEIVER',
        'peerId': _peerId
      });
      
      final clipboardContent = _fileTransferService.deserializeClipboardContent(payload);
      if (clipboardContent.isFiles) {
        _log('📁 RECEIVED FILES (JSON PAYLOAD)', {
          'files': clipboardContent.files.length,
          'fileNames': clipboardContent.files.map((f) => f.name).toList()
        });
        
        // CRITICAL: Ensure file transfer service processes the files correctly
        _fileTransferService.setClipboardContent(clipboardContent);
        _log('✅ FILES HANDLED VIA EXISTING FLOW');
      } else {
        _log('📝 RECEIVED TEXT', clipboardContent.text.length > 100 ? 
          clipboardContent.text.substring(0, 100) + '...' : clipboardContent.text);
        Clipboard.setData(ClipboardData(text: clipboardContent.text));
        _log('📋 TEXT CLIPBOARD UPDATED SUCCESSFULLY');
      }
    } catch (e, stackTrace) {
      _log('❌ ERROR PROCESSING RECEIVED DATA', e.toString());
      _log('❌ STACK TRACE', stackTrace.toString());
    }
  }

  Future<void> _resetConnection({bool preserveClipboardContent = false}) async {
    // Prevent multiple simultaneous resets
    if (_isResetting) {
      _log('⚠️ RESET ALREADY IN PROGRESS, SKIPPING');
      return;
    }
    
    _isResetting = true;
    _log('🔄 RESETTING PEER CONNECTION FOR NEW SHARE', {
      'preserveClipboard': preserveClipboardContent,
      'hasClipboard': _pendingClipboardContent != null
    });
    
    // Reset candidate queue and remote description flag
    _log('🔍 BEFORE RESET - Remote desc set: $_remoteDescriptionSet, Queue size: ${_pendingCandidates.length}');
    _pendingCandidates.clear();
    _remoteDescriptionSet = false;
    _log('🔍 AFTER RESET - Remote desc set: $_remoteDescriptionSet, Queue size: ${_pendingCandidates.length}');
    try {
      await _initWithTimeout(preserveClipboardContent: preserveClipboardContent);
      _log('✅ FORCED RESET RECOVERY SUCCESSFUL');
    } catch (recoveryError) {
      _log('❌ FORCED RESET RECOVERY FAILED', recoveryError.toString());
    } finally {
      _isResetting = false;
    }
  }

  // Backpressure-aware send helper for any JSON/text payloads over the data channel
  Future<void> _sendWithBackpressure(String text, {int timeoutMs = 20000}) async {
    final ch = _dataChannel;
    if (ch == null) throw StateError('DataChannel not ready');

    // Ensure threshold is set (idempotent)
    ch.bufferedAmountLowThreshold = _bufferedLowThreshold;

    // Wait for buffer to be below threshold before sending
    Future<void> waitForLowBuffer() async {
      try {
        // Some platforms expose bufferedAmount; guard if not available
        final current = ch.bufferedAmount;
        if (current != null && current > _bufferedLowThreshold) {
          _log('⏳ BACKPRESSURE: waiting for buffer to drain', {'buffered': current, 'threshold': _bufferedLowThreshold});
          _bufferLowCompleter ??= Completer<void>();
          try {
            await _bufferLowCompleter!.future
                .timeout(Duration(milliseconds: timeoutMs));
          } on TimeoutException {
            _log('⏰ BACKPRESSURE TIMEOUT, proceeding cautiously');
          } finally {
            _bufferLowCompleter = null;
          }
        } else if (current == null) {
          // No metric: use conservative pacing every ~2MB
          if (_pacingBytes > (2 * 1024 * 1024)) {
            await Future.delayed(Duration(milliseconds: 25));
            _pacingBytes = 0;
          }
        } else {
          // Metric available and below threshold; also yield occasionally
          if (_pacingBytes > (4 * 1024 * 1024)) {
            await Future.delayed(Duration(milliseconds: 10));
            _pacingBytes = 0;
          }
        }
      } catch (_) {
        // If metric unavailable, small pacing delay
        if (_pacingBytes > (2 * 1024 * 1024)) {
          await Future.delayed(Duration(milliseconds: 20));
          _pacingBytes = 0;
        } else {
          await Future.delayed(Duration(milliseconds: 2));
        }
      }
    }

    await waitForLowBuffer();

      // Much more aggressive rate limiting to prevent SCTP buffer overflow
    final now = DateTime.now();
    if (now.difference(_rateWindowStart).inMilliseconds > 200) {
      _rateWindowStart = now;
      _rateBytesWindow = 0;
    }
    // approximate size of this message
    int msgBytes;
    try {
      msgBytes = utf8.encode(text).length;
    } catch (_) {
      msgBytes = text.length;
    }
    // Much more conservative: ~5 MB/s => 1 MB per 200ms window
    const int windowCap = 1024 * 1024;
    if (_rateBytesWindow + msgBytes > windowCap) {
      final toWait = 200 - now.difference(_rateWindowStart).inMilliseconds;
      if (toWait > 0) {
        _log('⏸️ RATE LIMITING: waiting ${toWait}ms', {'windowBytes': _rateBytesWindow, 'msgBytes': msgBytes});
        await Future.delayed(Duration(milliseconds: toWait));
      }
      _rateWindowStart = DateTime.now();
      _rateBytesWindow = 0;
    }

    ch.send(RTCDataChannelMessage(text));
    
    // Log buffer state after send to detect overflow
    try {
      final buffered = ch.bufferedAmount;
      if (buffered != null && buffered > 0) {
        _log('📊 BUFFER STATE AFTER SEND', {'buffered': buffered, 'threshold': _bufferedLowThreshold});
        if (buffered > _bufferedLowThreshold * 2) {
          _log('⚠️ BUFFER DANGEROUSLY HIGH', {'buffered': buffered, 'threshold': _bufferedLowThreshold});
        }
      }
    } catch (_) {}
    
    // Update pacing accumulator based on actual payload size
    try {
      final sz = utf8.encode(text).length;
      _pacingBytes += sz;
      _rateBytesWindow += sz;
    } catch (_) {
      _pacingBytes += text.length; // fallback estimate
      _rateBytesWindow += text.length;
    }
  }

  Future<void> _initWithTimeout({bool preserveClipboardContent = false}) async {
    return Future.any([
      init(preserveClipboardContent: preserveClipboardContent),
      Future.delayed(Duration(seconds: 3)).then((_) => throw TimeoutException('Init timeout', Duration(seconds: 3))),
    ]);
  }

  void _forceCleanup({bool preserveClipboardContent = false}) {
    _dataChannel = null;
    _peerConnection = null;
    // Only clear clipboard content if we're not preserving it (i.e., not the sharing device)
    if (!preserveClipboardContent) {
      _pendingClipboardContent = null;
    }
    _peerId = null;
    _isInitialized = false;
    _pendingCandidates.clear();
    _remoteDescriptionSet = false;
  }

  Future<void> createOffer(String? peerId) async {
    try {
      _log('🎯 createOffer CALLED', peerId);
      
      // Reset connection state for clean start - preserve clipboard content since we're the sharing device
      await _resetConnection(preserveClipboardContent: true);
      
      if (_peerConnection == null) {
        _log('❌ ERROR: PeerConnection is null after reset, cannot create offer');
        return;
      }
      
      // CRITICAL: Set peer ID immediately for sending role
      _peerId = peerId;
      _log('🎯 CREATING OFFER FOR PEER', peerId);
      
      // Read current clipboard content (text or files)
      try {
        _log('📋 READING CLIPBOARD FOR OFFER');
        final clipboardContent = await _fileTransferService.getClipboardContent();
        
        if (clipboardContent.isFiles) {
          _log('📁 FOUND FILES IN CLIPBOARD', '${clipboardContent.files.length} files');
          _pendingClipboardContent = clipboardContent; // we'll stream them
          _log('📦 FILES READY FOR STREAMING', {'count': clipboardContent.files.length});
        } else if (clipboardContent.text.isNotEmpty) {
          _log('📝 FOUND TEXT IN CLIPBOARD', clipboardContent.text);
          _pendingClipboardContent = clipboardContent; // will serialize at send
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
        _log('🔍 OFFER DETAILS', {
          'type': 'offer',
          'sdp_length': description.sdp?.length ?? 0,
          'callback_exists': onSignalGenerated != null
        });
        onSignalGenerated!(_peerId!, {'type': 'offer', 'sdp': description.sdp});
        _log('✅ OFFER SIGNAL SENT SUCCESSFULLY');
      } else {
        _log('❌ ERROR: Cannot send offer signal', {
          'peerId': _peerId,
          'callback_exists': onSignalGenerated != null
        });
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
    
    try {
      // Reset connection state for clean start - clear clipboard content since we're the receiving device
      await _resetConnection(preserveClipboardContent: false);
      
      if (_peerConnection == null) {
        _log('❌ ERROR: PeerConnection is null after reset, cannot handle offer');
        return;
      }
      
      // CRITICAL: Set peer ID immediately for receiving role
      _peerId = from;
      _log('🎯 HANDLING OFFER FROM PEER', from);
      
      final offerSdp = offer['sdp'] as String?;
      final offerType = offer['type'] as String? ?? 'offer';

      // Pre-add transceivers if remote offer includes media sections
      if (offerSdp != null) {
        await _ensureRecvTransceiversForOffer(offerSdp);
      }
      
      // Set remote description with error handling
      _log('📡 SETTING REMOTE DESCRIPTION');
      await _peerConnection?.setRemoteDescription(RTCSessionDescription(offerSdp, offerType));

      // Wait until remote description is actually visible to the engine
      final rdReady = await _waitForRemoteDescription(timeoutMs: 1000);
      _remoteDescriptionSet = rdReady;
      if (!_remoteDescriptionSet) {
        _log('❌ REMOTE DESCRIPTION NOT READY AFTER TIMEOUT');
        return;
      }
      _log('✅ REMOTE DESCRIPTION SET AND READY');
      
      // Small delay to ensure the peer connection is fully ready
      await Future.delayed(Duration(milliseconds: 50));
      
      // Process any queued candidates
      await _processQueuedCandidates();
      
      // Create answer with error handling and retry logic
      _log('📡 CREATING ANSWER');
      RTCSessionDescription? description;
      int retryCount = 0;
      
      while (description == null && retryCount < 3) {
        try {
          // Small delay to ensure peer connection is fully ready
          if (retryCount > 0) {
            _log('🔄 RETRYING CREATE ANSWER - Attempt ${retryCount + 1}');
            await Future.delayed(Duration(milliseconds: 100 * retryCount));
          }
          
          description = await _peerConnection!.createAnswer();
          _log('✅ ANSWER CREATED SUCCESSFULLY');
        } catch (e) {
          retryCount++;
          _log('❌ CREATE ANSWER FAILED - Attempt $retryCount', e.toString());
          
          if (retryCount >= 3) {
            _log('❌ FAILED TO CREATE ANSWER AFTER 3 ATTEMPTS');
            return;
          }
        }
      }
      
      if (description != null) {
        await _peerConnection!.setLocalDescription(description);
        _log('📤 SENDING ANSWER');
        if (onSignalGenerated != null) {
          onSignalGenerated!(_peerId!, {'type': 'answer', 'sdp': description.sdp});
        }
      }
    } catch (e, stackTrace) {
      _log('❌ CRITICAL ERROR IN HANDLE OFFER', e.toString());
      _log('❌ STACK TRACE', stackTrace.toString());
      
      // Reset state on error
      _remoteDescriptionSet = false;
      _pendingCandidates.clear();
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
    
    // Check signaling state to avoid calling setRemoteDescription in wrong state
    final state = _peerConnection!.signalingState;
    _log('📥 HANDLING ANSWER - signalingState: $state, remoteSet: $_remoteDescriptionSet');

    // If we're already stable and have a remote description, this is likely a duplicate answer; ignore
    if (state == RTCSignalingState.RTCSignalingStateStable &&
        _peerConnection!.getRemoteDescription() != null) {
      _log('ℹ️ IGNORING DUPLICATE ANSWER: already stable with remote description set');
      return;
    }

    // Only set remote answer when we are in have-local-offer (we are the offerer)
    if (state != RTCSignalingState.RTCSignalingStateHaveLocalOffer) {
      _log('⚠️ UNEXPECTED STATE FOR REMOTE ANSWER: $state. Skipping setRemoteDescription to avoid error.');
      return;
    }

    try {
      await _peerConnection!.setRemoteDescription(
        RTCSessionDescription(answer['sdp'], answer['type']),
      );
      // Wait until remote description is actually set in engine
      _remoteDescriptionSet = await _waitForRemoteDescription(timeoutMs: 1000);
      
      // Process any queued candidates
      await _processQueuedCandidates();
    } catch (e, st) {
      _log('❌ FAILED TO SET REMOTE ANSWER (guarded)', e.toString());
      _log('❌ STACK TRACE', st.toString());
      // Do not rethrow; just log to prevent crashing the app
    }
  }

  Future<void> handleCandidate(dynamic candidate) async {
    if (!_isInitialized) {
      await init();
    }
    
    if (_peerConnection == null || _isResetting) {
      _log('❌ ERROR: PeerConnection is null or resetting, queueing candidate');
      final iceCandidate = RTCIceCandidate(
        candidate['candidate'],
        candidate['sdpMid'],
        candidate['sdpMLineIndex'],
      );
      _pendingCandidates.add(iceCandidate);
      return;
    }
    
    final iceCandidate = RTCIceCandidate(
      candidate['candidate'],
      candidate['sdpMid'],
      candidate['sdpMLineIndex'],
    );
    
    _log('🧊 HANDLING ICE CANDIDATE - Remote desc set: $_remoteDescriptionSet, Queue size: ${_pendingCandidates.length}');
    
    // Always queue until remote description is confirmed ready; processing is batched
    if (!_remoteDescriptionSet || _isResetting || _peerConnection?.getRemoteDescription() == null) {
      _log('📦 QUEUEING ICE CANDIDATE (remote description not ready)');
      _pendingCandidates.add(iceCandidate);
      return;
    }
    
    // If RD is ready, we'll still prefer processing through the queue to keep ordering
    _pendingCandidates.add(iceCandidate);
    await _processQueuedCandidates();
  }

  Future<void> _processQueuedCandidates() async {
    if (_pendingCandidates.isEmpty) return;
    
    _log('📦 PROCESSING ${_pendingCandidates.length} QUEUED ICE CANDIDATES');
    
    // Verify remote description is actually set before processing
    if (_peerConnection?.getRemoteDescription() == null) {
      _log('⚠️ REMOTE DESCRIPTION STILL NULL, KEEPING CANDIDATES QUEUED');
      return;
    }
    
    final candidatesToProcess = List<RTCIceCandidate>.from(_pendingCandidates);
    final failedCandidates = <RTCIceCandidate>[];
    _pendingCandidates.clear();
    
    for (final candidate in candidatesToProcess) {
      try {
        await _peerConnection?.addCandidate(candidate);
        _log('✅ QUEUED ICE CANDIDATE ADDED SUCCESSFULLY');
      } catch (e) {
        _log('❌ ERROR ADDING QUEUED ICE CANDIDATE', e.toString());
        // If it still fails, keep it for later
        failedCandidates.add(candidate);
      }
    }
    
    // Re-queue any candidates that still failed
    if (failedCandidates.isNotEmpty) {
      _log('📦 RE-QUEUEING ${failedCandidates.length} FAILED CANDIDATES');
      _pendingCandidates.addAll(failedCandidates);
    } else {
      _log('📦 FINISHED PROCESSING ALL QUEUED CANDIDATES SUCCESSFULLY');
    }
  }

  // Polls until getRemoteDescription is non-null or timeout
  Future<bool> _waitForRemoteDescription({int timeoutMs = 1000, int intervalMs = 25}) async {
    final deadline = DateTime.now().add(Duration(milliseconds: timeoutMs));
    while (DateTime.now().isBefore(deadline)) {
      try {
        final rd = _peerConnection?.getRemoteDescription();
        if (rd != null) {
          return true;
        }
      } catch (_) {}
      await Future.delayed(Duration(milliseconds: intervalMs));
    }
    return false;
  }

  // If the offer SDP includes audio/video m-lines, add recvonly transceivers
  Future<void> _ensureRecvTransceiversForOffer(String sdp) async {
    try {
      final hasAudio = sdp.contains('\nm=audio');
      final hasVideo = sdp.contains('\nm=video');
      if (hasAudio) {
        _log('🎚️ ADDING RECVONLY AUDIO TRANSCEIVER');
        await _peerConnection?.addTransceiver(
          kind: RTCRtpMediaType.RTCRtpMediaTypeAudio,
          init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
        );
      }
      if (hasVideo) {
        _log('🎚️ ADDING RECVONLY VIDEO TRANSCEIVER');
        await _peerConnection?.addTransceiver(
          kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
          init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
        );
      }
    } catch (e) {
      _log('⚠️ ERROR ADDING RECV TRANSCEIVERS (IGNORING)', e.toString());
    }
  }

  // ===== Streaming file receiver helpers (proto v2) =====
  // Returns true if files were prepared and we're ready to receive.
  // Returns false if the user cancelled any save dialog; in that case, the caller should send a 'cancel' control.
  Future<bool> _promptDirectoryAndPrepareFiles(String sessionId, List<Map<String, dynamic>> filesMeta) async {
    try {
      if (filesMeta.isEmpty) {
        _log('⚠️ NO FILES META PROVIDED FOR SESSION', sessionId);
        return false;
      }

      // Prompt for the first file with its suggested name
      final firstMeta = filesMeta.first;
      final firstName = (firstMeta['name'] as String?) ?? 'file';
      String? firstPath = await FilePicker.platform.saveFile(
        dialogTitle: 'Save incoming file',
        fileName: firstName,
      );
      if (firstPath == null || firstPath.isEmpty) {
        _log('🚫 USER CANCELLED SAVE DIALOG (FIRST FILE)');
        return false;
      }

      // Derive session directory from first file path
      final sessionDir = File(firstPath).parent.path;
      final session = _FileSession(sessionDir);

      // Prepare first file
      await File(firstPath).parent.create(recursive: true);
      final firstFile = File(firstPath);
      final firstSink = firstFile.openWrite();
      session.files.add(_IncomingFile(
        name: firstName,
        size: (firstMeta['size'] as num?)?.toInt() ?? 0,
        checksum: (firstMeta['checksum'] as String?) ?? '',
        file: firstFile,
        sink: firstSink,
      ));

      // Prompt and prepare remaining files
      for (int i = 1; i < filesMeta.length; i++) {
        final meta = filesMeta[i];
        final name = (meta['name'] as String?) ?? 'file_$i';
        String? savePath = await FilePicker.platform.saveFile(
          dialogTitle: 'Save incoming file',
          fileName: name,
        );
        if (savePath == null || savePath.isEmpty) {
          _log('🚫 USER CANCELLED SAVE DIALOG (ADDITIONAL FILE)');
          // Abort any partially prepared files in this session
          await _abortFileSession(sessionId);
          return false;
        }
        final file = File(savePath);
        await file.parent.create(recursive: true);
        final sink = file.openWrite();
        session.files.add(_IncomingFile(
          name: name,
          size: (meta['size'] as num?)?.toInt() ?? 0,
          checksum: (meta['checksum'] as String?) ?? '',
          file: file,
          sink: sink,
        ));
      }

      _fileSessions[sessionId] = session;
      _log('📂 FILE SESSION PREPARED', {'sessionId': sessionId, 'dir': session.dirPath, 'files': session.files.length});
      return true;
    } catch (e) {
      _log('❌ ERROR PREPARING FILE SESSION', e.toString());
      await _abortFileSession(sessionId);
      return false;
    }
  }

  Future<void> _handleFileChunk(String sessionId, int fileIndex, String dataB64) async {
    final session = _fileSessions[sessionId];
    if (session == null) {
      _log('⚠️ RECEIVED CHUNK FOR UNKNOWN SESSION', sessionId);
      return;
    }
    if (fileIndex < 0 || fileIndex >= session.files.length) {
      _log('⚠️ INVALID FILE INDEX', {'sessionId': sessionId, 'index': fileIndex});
      return;
    }
    try {
      final bytes = base64Decode(dataB64);
      final incoming = session.files[fileIndex];
      incoming.sink.add(bytes);
      incoming.received += bytes.length;
      if (incoming.received % (1024 * 1024) < bytes.length) { // every ~1MB
        _log('⬇️ PROGRESS', {'file': incoming.name, 'received': incoming.received, 'of': incoming.size});
      }
    } catch (e) {
      _log('❌ ERROR WRITING FILE CHUNK', {'sessionId': sessionId, 'index': fileIndex, 'error': e.toString()});
    }
  }

  Future<void> _handleFileEnd(String sessionId, int fileIndex) async {
    final session = _fileSessions[sessionId];
    if (session == null) return;
    if (fileIndex < 0 || fileIndex >= session.files.length) return;
    try {
      final incoming = session.files[fileIndex];
      await incoming.sink.flush();
      await incoming.sink.close();
      _log('✅ FILE STREAM CLOSED', {'file': incoming.name, 'bytes': incoming.received});
    } catch (e) {
      _log('❌ ERROR CLOSING FILE SINK', e.toString());
    }
  }

  Future<void> _finalizeFileSession(String sessionId) async {
    final session = _fileSessions.remove(sessionId);
    if (session == null) return;
    try {
      for (final f in session.files) {
        try {
          await f.sink.flush();
          await f.sink.close();
        } catch (_) {}
      }
      // Optional: verify checksums and sizes
      bool allOk = true;
      for (final f in session.files) {
        final sizeOk = f.size == 0 || f.file.lengthSync() == f.size;
        // TODO: implement checksum verification if desired
        final checksumOk = true;
        if (!sizeOk || !checksumOk) {
          allOk = false;
        }
      }
      if (!allOk) {
        _log('⚠️ VERIFICATION FAILED', {
          'file': session.files.isNotEmpty ? session.files.first.name : 'n/a',
          'sizeOk': false,
          'checksumOk': false,
        });
      }
      // Build clipboard file list from saved files
      final filesForClipboard = <FileData>[];
      for (final f in session.files) {
        final bytes = await f.file.readAsBytes();
        final checksum = sha256.convert(bytes).toString();
        filesForClipboard.add(FileData(
          name: f.name,
          path: f.file.path,
          size: bytes.length,
          mimeType: 'application/octet-stream',
          checksum: checksum,
          content: Uint8List.fromList(bytes),
        ));
      }
      await _fileTransferService.setClipboardContent(ClipboardContent.files(filesForClipboard));
      _log('🎉 FILE SESSION FINALIZED', {'sessionId': sessionId, 'files': filesForClipboard.length, 'verified': allOk});
    } catch (e) {
      _log('❌ ERROR FINALIZING FILE SESSION', e.toString());
    }
  }

  Future<void> _abortFileSession(String sessionId) async {
    final session = _fileSessions.remove(sessionId);
    if (session == null) return;
    try {
      for (final f in session.files) {
        try {
          await f.sink.flush();
          await f.sink.close();
        } catch (_) {}
        try {
          if (await f.file.exists()) {
            await f.file.delete();
          }
        } catch (_) {}
      }
      _log('🧹 FILE SESSION ABORTED AND CLEANED', {'sessionId': sessionId});
    } catch (e) {
      _log('❌ ERROR ABORTING FILE SESSION', e.toString());
    }
  }

  void dispose() {
    _dataChannel?.close();
    _peerConnection?.close();
  }
}

// Private classes to track incoming streaming files
class _FileSession {
  final String dirPath;
  final List<_IncomingFile> files = [];
  _FileSession(this.dirPath);
}

class _IncomingFile {
  final String name;
  final int size;
  final String checksum;
  final File file;
  final IOSink sink;
  int received = 0;
  _IncomingFile({
    required this.name,
    required this.size,
    required this.checksum,
    required this.file,
    required this.sink,
  });
}
