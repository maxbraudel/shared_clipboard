#import <FlutterMacOS/FlutterMacOS.h>

@interface NativeFileClipboardPlugin : NSObject<FlutterPlugin>
+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar;
@end