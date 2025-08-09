#ifndef WINDOWS_NOTIFICATIONS_PLUGIN_H_
#define WINDOWS_NOTIFICATIONS_PLUGIN_H_

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>
#include <memory>
#include <string>
#include <windows.h>

class WindowsNotificationsPlugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);

  WindowsNotificationsPlugin();
  virtual ~WindowsNotificationsPlugin();

  // Disallow copy and assign.
  WindowsNotificationsPlugin(const WindowsNotificationsPlugin&) = delete;
  WindowsNotificationsPlugin& operator=(const WindowsNotificationsPlugin&) = delete;

 private:
  // Called when a method is called on this plugin's channel from Dart.
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  // Initialize Windows notifications
  void Initialize();

  // Show progress toast notification
  void ShowProgressToast(const std::string& title, 
                        const std::string& subtitle,
                        int progress,
                        const std::string& status,
                        const std::string& progressLabel);

  // Update progress of existing toast
  void UpdateProgress(int progress, const std::string& status);

  // Hide current toast
  void HideToast();

  // Show completion toast
  void ShowCompletionToast(const std::string& title,
                          const std::string& subtitle,
                          const std::string& message);

  // Simplified state tracking
  bool initialized_ = false;
};

// External C function for plugin registration
extern "C" __declspec(dllexport) void WindowsNotificationsPluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar);

#endif  // WINDOWS_NOTIFICATIONS_PLUGIN_H_
