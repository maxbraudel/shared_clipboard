import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  _HomePageState createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  String _status = 'Ready';

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
                onPressed: () {
                  _shareClipboard();
                },
                icon: const Icon(Icons.share),
                label: const Text('Share Clipboard (Cmd/Ctrl+F12)'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                ),
              ),
              const SizedBox(height: 10),
              ElevatedButton.icon(
                onPressed: () {
                  _requestClipboard();
                },
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

  void _shareClipboard() async {
    setState(() {
      _status = 'Sharing clipboard...';
    });
    
    try {
      final clipboardData = await Clipboard.getData(Clipboard.kTextPlain);
      if (clipboardData != null && clipboardData.text != null) {
        // For now, just show what we would share
        setState(() {
          _status = 'Ready to share: "${clipboardData.text}"';
        });
        print("Would share: ${clipboardData.text}");
      } else {
        setState(() {
          _status = 'No text in clipboard';
        });
      }
    } catch (e) {
      setState(() {
        _status = 'Error reading clipboard: $e';
      });
    }
  }

  void _requestClipboard() {
    setState(() {
      _status = 'Requesting clipboard...';
    });
    print("Requesting clipboard content");
    
    // For now, just simulate receiving content
    Future.delayed(const Duration(seconds: 1), () {
      setState(() {
        _status = 'Ready';
      });
    });
  }
}
