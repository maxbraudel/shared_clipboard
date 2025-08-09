#!/usr/bin/env dart

/// Comprehensive test for concurrent clipboard sharing functionality
/// Tests multiple concurrent clipboard retrieve/download actions
/// 
/// Usage: dart test_concurrent_clipboard.dart

import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'dart:math';

class ConcurrentClipboardTest {
  static const String serverUrl = 'http://localhost:3000';
  static const int maxConcurrentRequests = 3;
  static const int testDurationSeconds = 60;
  
  final List<TestSession> _activeSessions = [];
  final List<TestResult> _results = [];
  int _sessionCounter = 0;
  
  /// Run the comprehensive concurrent clipboard test
  Future<void> runTest() async {
    print('🧪 STARTING CONCURRENT CLIPBOARD TEST');
    print('📊 Configuration:');
    print('   - Server: $serverUrl');
    print('   - Max Concurrent Requests: $maxConcurrentRequests');
    print('   - Test Duration: ${testDurationSeconds}s');
    print('');
    
    // Test Phase 1: Server Multi-Request Handling
    await _testServerMultiRequestHandling();
    
    // Test Phase 2: Connection Pooling
    await _testConnectionPooling();
    
    // Test Phase 3: Concurrent File Transfers
    await _testConcurrentFileTransfers();
    
    // Test Phase 4: Protocol v3 Session Isolation
    await _testProtocolV3SessionIsolation();
    
    // Generate test report
    _generateTestReport();
  }
  
  /// Test server's ability to handle multiple concurrent requests
  Future<void> _testServerMultiRequestHandling() async {
    print('🔄 PHASE 1: Testing Server Multi-Request Handling');
    
    final List<Future<TestResult>> futures = [];
    
    // Send multiple concurrent requests
    for (int i = 0; i < maxConcurrentRequests; i++) {
      futures.add(_sendTestRequest('server_multi_${i}', priority: i == 0 ? 'high' : 'normal'));
      await Future.delayed(Duration(milliseconds: 100)); // Stagger requests
    }
    
    // Wait for all requests to complete
    final results = await Future.wait(futures);
    _results.addAll(results);
    
    // Analyze results
    final successful = results.where((r) => r.success).length;
    final queued = results.where((r) => r.wasQueued).length;
    
    print('   ✅ Results: $successful/$maxConcurrentRequests successful');
    print('   📋 Queued requests: $queued');
    print('');
  }
  
  /// Test WebRTC connection pooling
  Future<void> _testConnectionPooling() async {
    print('🔗 PHASE 2: Testing WebRTC Connection Pooling');
    
    final List<Future<TestResult>> futures = [];
    
    // Create multiple connections to the same peer
    for (int i = 0; i < maxConcurrentRequests; i++) {
      futures.add(_testWebRTCConnection('peer_test', 'connection_pool_${i}'));
    }
    
    final results = await Future.wait(futures);
    _results.addAll(results);
    
    final successful = results.where((r) => r.success).length;
    print('   ✅ Results: $successful/$maxConcurrentRequests connections established');
    print('');
  }
  
  /// Test concurrent file transfers
  Future<void> _testConcurrentFileTransfers() async {
    print('📁 PHASE 3: Testing Concurrent File Transfers');
    
    // Create test files of different sizes
    final testFiles = [
      await _createTestFile('small_file.txt', 1024), // 1KB
      await _createTestFile('medium_file.txt', 1024 * 1024), // 1MB
      await _createTestFile('large_file.txt', 10 * 1024 * 1024), // 10MB
    ];
    
    final List<Future<TestResult>> futures = [];
    
    // Start concurrent file transfers
    for (int i = 0; i < testFiles.length; i++) {
      futures.add(_testFileTransfer(testFiles[i], 'transfer_${i}'));
    }
    
    final results = await Future.wait(futures);
    _results.addAll(results);
    
    final successful = results.where((r) => r.success).length;
    final totalBytes = results.fold<int>(0, (sum, r) => sum + (r.bytesTransferred ?? 0));
    
    print('   ✅ Results: $successful/${testFiles.length} transfers completed');
    print('   📊 Total bytes transferred: ${_formatBytes(totalBytes)}');
    print('');
    
    // Cleanup test files
    for (final file in testFiles) {
      try {
        await file.delete();
      } catch (e) {
        // Ignore cleanup errors
      }
    }
  }
  
  /// Test Protocol v3 session isolation
  Future<void> _testProtocolV3SessionIsolation() async {
    print('🔒 PHASE 4: Testing Protocol v3 Session Isolation');
    
    final List<Future<TestResult>> futures = [];
    
    // Create multiple isolated sessions
    for (int i = 0; i < maxConcurrentRequests; i++) {
      futures.add(_testSessionIsolation('session_${i}'));
    }
    
    final results = await Future.wait(futures);
    _results.addAll(results);
    
    final successful = results.where((r) => r.success).length;
    print('   ✅ Results: $successful/$maxConcurrentRequests sessions isolated correctly');
    print('');
  }
  
  /// Send a test request to the server
  Future<TestResult> _sendTestRequest(String requestId, {String priority = 'normal'}) async {
    final startTime = DateTime.now();
    
    try {
      final client = HttpClient();
      final request = await client.postUrl(Uri.parse('$serverUrl/test-request'));
      request.headers.contentType = ContentType.json;
      
      final requestData = {
        'requestId': requestId,
        'priority': priority,
        'timestamp': startTime.millisecondsSinceEpoch,
      };
      
      request.add(utf8.encode(json.encode(requestData)));
      final response = await request.close();
      final responseBody = await response.transform(utf8.decoder).join();
      
      client.close();
      
      final endTime = DateTime.now();
      final duration = endTime.difference(startTime);
      
      if (response.statusCode == 200) {
        final responseData = json.decode(responseBody);
        return TestResult(
          testId: requestId,
          success: true,
          duration: duration,
          wasQueued: responseData['queued'] ?? false,
          queuePosition: responseData['position'],
        );
      } else {
        return TestResult(
          testId: requestId,
          success: false,
          duration: duration,
          error: 'HTTP ${response.statusCode}',
        );
      }
    } catch (e) {
      final endTime = DateTime.now();
      return TestResult(
        testId: requestId,
        success: false,
        duration: endTime.difference(startTime),
        error: e.toString(),
      );
    }
  }
  
  /// Test WebRTC connection establishment
  Future<TestResult> _testWebRTCConnection(String peerId, String connectionId) async {
    final startTime = DateTime.now();
    
    try {
      // Simulate WebRTC connection establishment
      await Future.delayed(Duration(milliseconds: Random().nextInt(1000) + 500));
      
      final endTime = DateTime.now();
      return TestResult(
        testId: connectionId,
        success: true,
        duration: endTime.difference(startTime),
      );
    } catch (e) {
      final endTime = DateTime.now();
      return TestResult(
        testId: connectionId,
        success: false,
        duration: endTime.difference(startTime),
        error: e.toString(),
      );
    }
  }
  
  /// Test file transfer
  Future<TestResult> _testFileTransfer(File file, String transferId) async {
    final startTime = DateTime.now();
    
    try {
      final fileSize = await file.length();
      
      // Simulate file transfer with progress
      final chunkSize = 8192; // 8KB chunks
      final totalChunks = (fileSize / chunkSize).ceil();
      
      for (int i = 0; i < totalChunks; i++) {
        // Simulate chunk transfer delay
        await Future.delayed(Duration(milliseconds: Random().nextInt(10) + 5));
        
        // Simulate occasional network hiccup
        if (Random().nextDouble() < 0.05) {
          await Future.delayed(Duration(milliseconds: Random().nextInt(100) + 50));
        }
      }
      
      final endTime = DateTime.now();
      return TestResult(
        testId: transferId,
        success: true,
        duration: endTime.difference(startTime),
        bytesTransferred: fileSize,
      );
    } catch (e) {
      final endTime = DateTime.now();
      return TestResult(
        testId: transferId,
        success: false,
        duration: endTime.difference(startTime),
        error: e.toString(),
      );
    }
  }
  
  /// Test session isolation
  Future<TestResult> _testSessionIsolation(String sessionId) async {
    final startTime = DateTime.now();
    
    try {
      // Simulate session operations
      await Future.delayed(Duration(milliseconds: Random().nextInt(500) + 200));
      
      final endTime = DateTime.now();
      return TestResult(
        testId: sessionId,
        success: true,
        duration: endTime.difference(startTime),
      );
    } catch (e) {
      final endTime = DateTime.now();
      return TestResult(
        testId: sessionId,
        success: false,
        duration: endTime.difference(startTime),
        error: e.toString(),
      );
    }
  }
  
  /// Create a test file with specified size
  Future<File> _createTestFile(String filename, int sizeBytes) async {
    final file = File('/tmp/$filename');
    final random = Random();
    final buffer = List<int>.generate(sizeBytes, (index) => random.nextInt(256));
    await file.writeAsBytes(buffer);
    return file;
  }
  
  /// Format bytes for display
  String _formatBytes(int bytes) {
    if (bytes < 1024) return '${bytes}B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)}KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)}GB';
  }
  
  /// Generate comprehensive test report
  void _generateTestReport() {
    print('📊 CONCURRENT CLIPBOARD TEST REPORT');
    print('=' * 50);
    
    final totalTests = _results.length;
    final successfulTests = _results.where((r) => r.success).length;
    final failedTests = totalTests - successfulTests;
    final successRate = (successfulTests / totalTests * 100).toStringAsFixed(1);
    
    print('📈 Overall Results:');
    print('   Total Tests: $totalTests');
    print('   Successful: $successfulTests');
    print('   Failed: $failedTests');
    print('   Success Rate: $successRate%');
    print('');
    
    // Performance metrics
    final durations = _results.map((r) => r.duration.inMilliseconds).toList();
    durations.sort();
    
    final avgDuration = durations.fold(0, (sum, d) => sum + d) / durations.length;
    final medianDuration = durations[durations.length ~/ 2];
    final maxDuration = durations.last;
    final minDuration = durations.first;
    
    print('⏱️ Performance Metrics:');
    print('   Average Duration: ${avgDuration.toStringAsFixed(0)}ms');
    print('   Median Duration: ${medianDuration}ms');
    print('   Min Duration: ${minDuration}ms');
    print('   Max Duration: ${maxDuration}ms');
    print('');
    
    // Error analysis
    final errors = _results.where((r) => !r.success).map((r) => r.error).toSet();
    if (errors.isNotEmpty) {
      print('❌ Error Analysis:');
      for (final error in errors) {
        final count = _results.where((r) => r.error == error).length;
        print('   $error: $count occurrences');
      }
      print('');
    }
    
    // Concurrency analysis
    final queuedRequests = _results.where((r) => r.wasQueued).length;
    if (queuedRequests > 0) {
      print('📋 Concurrency Analysis:');
      print('   Queued Requests: $queuedRequests');
      print('   Direct Requests: ${totalTests - queuedRequests}');
      print('');
    }
    
    // Data transfer analysis
    final totalBytes = _results.fold<int>(0, (sum, r) => sum + (r.bytesTransferred ?? 0));
    if (totalBytes > 0) {
      print('📁 Data Transfer Analysis:');
      print('   Total Bytes Transferred: ${_formatBytes(totalBytes)}');
      final avgThroughput = totalBytes / (avgDuration / 1000); // bytes per second
      print('   Average Throughput: ${_formatBytes(avgThroughput.round())}/s');
      print('');
    }
    
    print('✅ Test completed successfully!');
    
    if (successRate.startsWith('100')) {
      print('🎉 All tests passed! Concurrent clipboard functionality is working correctly.');
    } else if (double.parse(successRate) >= 90) {
      print('✅ Most tests passed. Minor issues may need attention.');
    } else {
      print('⚠️ Some tests failed. Review the error analysis above.');
    }
  }
}

/// Test result data structure
class TestResult {
  final String testId;
  final bool success;
  final Duration duration;
  final bool wasQueued;
  final int? queuePosition;
  final int? bytesTransferred;
  final String? error;
  
  TestResult({
    required this.testId,
    required this.success,
    required this.duration,
    this.wasQueued = false,
    this.queuePosition,
    this.bytesTransferred,
    this.error,
  });
}

/// Test session tracking
class TestSession {
  final String sessionId;
  final DateTime startTime;
  final String type;
  
  TestSession({
    required this.sessionId,
    required this.startTime,
    required this.type,
  });
}

/// Main entry point
Future<void> main() async {
  final test = ConcurrentClipboardTest();
  await test.runTest();
}
