import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class HomePage extends StatefulWidget {
  @override
  _HomePageState createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  String _status = 'Ready';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Shared Clipboard'),
        backgroundColor: Colors.blue,
      ),
      body: Container(
        color: Colors.white,
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Icon(
                Icons.content_copy,
                size: 64,
                color: Colors.blue,
              ),
              SizedBox(height: 20),
              Text(
                'Shared Clipboard',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                ),
              ),
              SizedBox(height: 10),
              Text(
                _status,
                style: TextStyle(
                  fontSize: 16,
                  color: Colors.grey[600],
                ),
              ),
              SizedBox(height: 40),
              ElevatedButton.icon(
                onPressed: () {
                  _shareClipboard();
                },
                icon: Icon(Icons.share),
                label: Text('Share Clipboard (Cmd/Ctrl+F12)'),
                style: ElevatedButton.styleFrom(
                  padding: EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                ),
              ),
              SizedBox(height: 10),
              ElevatedButton.icon(
                onPressed: () {
                  _requestClipboard();
                },
                icon: Icon(Icons.download),
                label: Text('Get Clipboard (Cmd/Ctrl+F11)'),
                style: ElevatedButton.styleFrom(
                  padding: EdgeInsets.symmetric(horizontal: 20, vertical: 12),
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
    Future.delayed(Duration(seconds: 1), () {
      setState(() {
        _status = 'Ready';
      });
    });
  }
}
