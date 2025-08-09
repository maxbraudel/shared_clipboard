#ifndef WINDOWS_NOTIFICATIONS_PLUGIN_H_
#define WINDOWS_NOTIFICATIONS_PLUGIN_H_

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <string>
#include <windows.h>

// WinRT forward declarations - temporarily disabled due to build issues
// #include <winrt/Windows.UI.Notifications.h>

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

  // Helper methods for WinRT functionality - temporarily removed
  // std::wstring CreateProgressToastXml(...);
  // std::wstring CreateCompletionToastXml(...);
  // std::wstring StringToWString(...);

  // Member variables
  bool initialized_ = false;
  // WinRT member variables temporarily disabled due to build issues
  // winrt::Windows::UI::Notifications::ToastNotifier toast_notifier_{nullptr};
  // winrt::Windows::UI::Notifications::ToastNotification current_notification_{nullptr};
  std::string current_tag_;
};

// External C function for plugin registration
extern "C" __declspec(dllexport) void WindowsNotificationsPluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar);

#endif  // WINDOWS_NOTIFICATIONS_PLUGIN_H_