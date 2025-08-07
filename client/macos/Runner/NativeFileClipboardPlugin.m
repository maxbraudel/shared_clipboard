#import <FlutterMacOS/FlutterMacOS.h>
#import <AppKit/AppKit.h>
#import "NativeFileClipboardPlugin.h"

@implementation NativeFileClipboardPlugin

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
  FlutterMethodChannel* channel = [FlutterMethodChannel
      methodChannelWithName:@"native_file_clipboard"
            binaryMessenger:[registrar messenger]];
  NativeFileClipboardPlugin* instance = [[NativeFileClipboardPlugin alloc] init];
  [registrar addMethodCallDelegate:instance channel:channel];
}

- (void)handleMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
  NSLog(@"[NativeFileClipboard] Method called: %@", call.method);
  
  if ([@"putFilesToClipboard" isEqualToString:call.method]) {
    [self putFilesToClipboard:call.arguments result:result];
  } else if ([@"clearClipboard" isEqualToString:call.method]) {
    [self clearClipboard:result];
  } else {
    result(FlutterMethodNotImplemented);
  }
}

- (void)putFilesToClipboard:(NSDictionary*)arguments result:(FlutterResult)result {
  NSArray* filePaths = arguments[@"filePaths"];
  
  if (!filePaths || [filePaths count] == 0) {
    NSLog(@"[NativeFileClipboard] No file paths provided");
    result(@NO);
    return;
  }
  
  NSLog(@"[NativeFileClipboard] Putting %lu files to macOS clipboard", (unsigned long)[filePaths count]);
  
  // Get the pasteboard
  NSPasteboard* pasteboard = [NSPasteboard generalPasteboard];
  
  // Clear existing content
  [pasteboard clearContents];
  
  // Create array of file URLs
  NSMutableArray* fileURLs = [[NSMutableArray alloc] init];
  
  for (NSString* filePath in filePaths) {
    // Check if file exists
    if (![[NSFileManager defaultManager] fileExistsAtPath:filePath]) {
      NSLog(@"[NativeFileClipboard] File does not exist: %@", filePath);
      continue;
    }
    
    NSURL* fileURL = [NSURL fileURLWithPath:filePath];
    [fileURLs addObject:fileURL];
    NSLog(@"[NativeFileClipboard] Added file URL: %@", fileURL);
  }
  
  if ([fileURLs count] == 0) {
    NSLog(@"[NativeFileClipboard] No valid files to add to clipboard");
    result(@NO);
    return;
  }
  
  // Write file URLs to pasteboard - this makes files pasteable like from Finder!
  BOOL success = [pasteboard writeObjects:fileURLs];
  
  if (success) {
    NSLog(@"[NativeFileClipboard] Successfully added %lu files to macOS clipboard", (unsigned long)[fileURLs count]);
    NSLog(@"[NativeFileClipboard] Files are now pasteable like from Finder!");
    result(@YES);
  } else {
    NSLog(@"[NativeFileClipboard] Failed to add files to macOS clipboard");
    result(@NO);
  }
}

- (void)clearClipboard:(FlutterResult)result {
  NSLog(@"[NativeFileClipboard] Clearing macOS clipboard");
  
  NSPasteboard* pasteboard = [NSPasteboard generalPasteboard];
  [pasteboard clearContents];
  
  result(@YES);
}

@end