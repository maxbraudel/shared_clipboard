#import <FlutterMacOS/FlutterMacOS.h>
#import <AppKit/AppKit.h>
#import <CoreServices/CoreServices.h>
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
  } else if ([@"getFilesFromClipboard" isEqualToString:call.method]) {
    [self getFilesFromClipboard:result];
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

- (void)getFilesFromClipboard:(FlutterResult)result {
  NSPasteboard* pasteboard = [NSPasteboard generalPasteboard];
  NSLog(@"[NativeFileClipboard] Reading file URLs from pasteboard");
  
  NSMutableArray<NSString*>* paths = [[NSMutableArray alloc] init];
  
  // 1) Prefer modern file URLs via readObjectsForClasses
  NSArray* classes = @[[NSURL class]];
  NSDictionary* options = @{ NSPasteboardURLReadingFileURLsOnlyKey: @YES };
  BOOL canRead = [pasteboard canReadItemWithDataConformingToTypes:@[(NSString*)kUTTypeFileURL, @"public.file-url"]];
  if (canRead) {
    NSArray* urls = [pasteboard readObjectsForClasses:classes options:options];
    if (urls && [urls count] > 0) {
      for (NSURL* url in urls) {
        if (url.isFileURL && url.path) {
          [paths addObject:url.path];
        }
      }
    }
  }
  
  // 2) Fallback: iterate items for public.file-url strings
  if ([paths count] == 0) {
    for (NSPasteboardItem* item in [pasteboard pasteboardItems]) {
      NSString* fileUrlString = [item stringForType:NSPasteboardTypeFileURL];
      if (fileUrlString) {
        NSURL* url = [NSURL URLWithString:fileUrlString];
        if (url.isFileURL && url.path) {
          [paths addObject:url.path];
        }
      }
    }
  }
  
  // 3) Legacy fallback: NSFilenamesPboardType (array of file paths)
  if ([paths count] == 0) {
    NSPasteboardType legacyType = @"NSFilenamesPboardType";
    id plist = [pasteboard propertyListForType:legacyType];
    if ([plist isKindOfClass:[NSArray class]]) {
      for (id obj in (NSArray*)plist) {
        if ([obj isKindOfClass:[NSString class]]) {
          [paths addObject:(NSString*)obj];
        }
      }
    }
  }
  
  NSLog(@"[NativeFileClipboard] Found %lu file paths", (unsigned long)[paths count]);
  result(paths);
}

@end