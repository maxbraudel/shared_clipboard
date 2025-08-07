import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_clipboard/services/socket_service.dart';
import 'package:shared_clipboard/services/webrtc_service.dart';
import 'package:shared_clipboard/services/file_transfer_service.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  _HomePageState createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  String _status = 'Initializing...';
  late SocketService _socketService;
  late WebRTCService _webrtcService;
  late FileTransferService _fileTransferService;
  bool _isInitialized = false;

  @override
  void initState() {
    super.initState();
    _initializeServices();
  }

  void _initializeServices() async {
    try {
      print('🚀 STARTING SERVICE INITIALIZATION');
      
      // Initialize services
      _socketService = SocketService();
      _webrtcService = WebRTCService();
      _fileTransferService = FileTransferService();
      
      // Initialize WebRTC first
      print('🔧 INITIALIZING WEBRTC SERVICE');
      _webrtcService.init();
      
      // Then initialize Socket service
      print('🔧 INITIALIZING SOCKET SERVICE');
      _socketService.init(webrtcService: _webrtcService);
      
      setState(() {
        _status = 'Ready';
        _isInitialized = true;
      });
      
      print('✅ SERVICES INITIALIZED SUCCESSFULLY');
    } catch (e) {
      print('❌ SERVICE INITIALIZATION ERROR: $e');
      setState(() {
        _status = 'Initialization failed: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Shared Clipboard'),
        backgroundColor: Colors.blue,
      ),
      body: Container(
        color: Colors.white,
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              const Icon(
                Icons.content_copy,
                size: 64,
                color: Colors.blue,
              ),
              const SizedBox(height: 20),
              const Text(
                'Shared Clipboard',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                _status,
                style: TextStyle(
                  fontSize: 16,
                  color: Colors.grey[600],
                ),
              ),
              const SizedBox(height: 40),
              ElevatedButton.icon(
                onPressed: _isInitialized ? () {
                  _shareClipboard();
                } : null,
                icon: const Icon(Icons.share),
                label: const Text('Share Clipboard (Cmd/Ctrl+F12)'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                ),
              ),
              const SizedBox(height: 10),
              ElevatedButton.icon(
                onPressed: _isInitialized ? () {
                  _shareFiles();
                } : null,
                icon: const Icon(Icons.file_upload),
                label: const Text('Share Files'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                  backgroundColor: Colors.green,
                ),
              ),
              const SizedBox(height: 10),
              ElevatedButton.icon(
                onPressed: _isInitialized ? () {
                  _requestClipboard();
                } : null,
                icon: const Icon(Icons.download),
                label: const Text('Get Clipboard (Cmd/Ctrl+F11)'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _shareFiles() async {
    if (!_isInitialized) return;
    
    setState(() {
      _status = 'Selecting files to share...';
    });
    
    try {
      print('📁 OPENING FILE PICKER FOR SHARING');
      final clipboardContent = await _fileTransferService.selectFilesToShare();
      
      if (clipboardContent.isFiles && clipboardContent.files.isNotEmpty) {
        print('📤 FILES SELECTED: ${clipboardContent.files.length} files');
        print('📤 SENDING SHARE-READY TO SERVER');
        _socketService.sendShareReady();
        setState(() {
          _status = 'Ready to share ${clipboardContent.files.length} files: ${clipboardContent.files.map((f) => f.name).join(', ')}';
        });
        print("📋 FILES READY TO SHARE: ${clipboardContent.files.map((f) => f.name).join(', ')}");
      } else {
        setState(() {
          _status = 'No files selected';
        });
        print('❌ NO FILES SELECTED');
      }
    } catch (e) {
      setState(() {
        _status = 'Error selecting files: $e';
      });
      print('❌ FILE SELECTION ERROR: $e');
    }
  }

  void _shareClipboard() async {
    if (!_isInitialized) return;
    
    setState(() {
      _status = 'Sharing clipboard...';
    });
    
    try {
      print('📋 READING CLIPBOARD FOR SHARING');
      final clipboardData = await Clipboard.getData(Clipboard.kTextPlain);
      if (clipboardData != null && clipboardData.text != null) {
        print('📤 CLIPBOARD CONTENT FOUND: "${clipboardData.text}"');
        print('📤 SENDING SHARE-READY TO SERVER');
        _socketService.sendShareReady();
        setState(() {
          _status = 'Ready to share: "${clipboardData.text}"';
        });
        print("📋 CLIPBOARD READY TO SHARE: ${clipboardData.text}");
      } else {
        setState(() {
          _status = 'No text in clipboard';
        });
        print('❌ NO TEXT IN CLIPBOARD');
      }
    } catch (e) {
      setState(() {
        _status = 'Error reading clipboard: $e';
      });
      print('❌ CLIPBOARD READ ERROR: $e');
    }
  }

  void _requestClipboard() {
    if (!_isInitialized) return;
    
    setState(() {
      _status = 'Requesting clipboard...';
    });
    print("📥 REQUESTING CLIPBOARD FROM SERVER");
    
    _socketService.sendRequestShare();
    
    // Reset status after a delay if no response
    Future.delayed(const Duration(seconds: 5), () {
      if (mounted && _status == 'Requesting clipboard...') {
        setState(() {
          _status = 'Ready';
        });
      }
    });
  }
}
