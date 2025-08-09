#include "windows_notifications_plugin.h"

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <sstream>
#include <string>
#include <windows.h>

// Simplified implementation without WinRT for now
// This will at least compile and allow the app to run
// We can enhance it later with proper toast notifications

// static
void WindowsNotificationsPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows* registrar) {
  auto channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          registrar->messenger(), "windows_notifications",
          &flutter::StandardMethodCodec::GetInstance());

  auto plugin = std::make_unique<WindowsNotificationsPlugin>();

  channel->SetMethodCallHandler(
      [plugin_pointer = plugin.get()](const auto& call, auto result) {
        plugin_pointer->HandleMethodCall(call, std::move(result));
      });

  registrar->AddPlugin(std::move(plugin));
}

WindowsNotificationsPlugin::WindowsNotificationsPlugin() : initialized_(false) {}

WindowsNotificationsPlugin::~WindowsNotificationsPlugin() {}

void WindowsNotificationsPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  
  try {
    if (method_call.method_name().compare("initialize") == 0) {
      Initialize();
      result->Success(flutter::EncodableValue(true));
    }
    else if (method_call.method_name().compare("showProgressToast") == 0) {
      const auto* arguments = std::get_if<flutter::EncodableMap>(method_call.arguments());
      if (arguments) {
        auto title_it = arguments->find(flutter::EncodableValue("title"));
        auto subtitle_it = arguments->find(flutter::EncodableValue("subtitle"));
        auto progress_it = arguments->find(flutter::EncodableValue("progress"));
        auto status_it = arguments->find(flutter::EncodableValue("status"));
        auto label_it = arguments->find(flutter::EncodableValue("progressLabel"));

        if (title_it != arguments->end() && subtitle_it != arguments->end() && 
            progress_it != arguments->end()) {
          
          std::string title = std::get<std::string>(title_it->second);
          std::string subtitle = std::get<std::string>(subtitle_it->second);
          int progress = std::get<int>(progress_it->second);
          std::string status = status_it != arguments->end() ? 
                              std::get<std::string>(status_it->second) : "";
          std::string label = label_it != arguments->end() ? 
                             std::get<std::string>(label_it->second) : "Progress";

          ShowProgressToast(title, subtitle, progress, status, label);
          result->Success(flutter::EncodableValue(true));
        } else {
          result->Error("INVALID_ARGUMENTS", "Missing required arguments");
        }
      } else {
        result->Error("INVALID_ARGUMENTS", "Arguments must be a map");
      }
    }
    else if (method_call.method_name().compare("updateProgress") == 0) {
      const auto* arguments = std::get_if<flutter::EncodableMap>(method_call.arguments());
      if (arguments) {
        auto progress_it = arguments->find(flutter::EncodableValue("progress"));
        auto status_it = arguments->find(flutter::EncodableValue("status"));

        if (progress_it != arguments->end()) {
          int progress = std::get<int>(progress_it->second);
          std::string status = status_it != arguments->end() ? 
                              std::get<std::string>(status_it->second) : "";
          
          UpdateProgress(progress, status);
          result->Success(flutter::EncodableValue(true));
        } else {
          result->Error("INVALID_ARGUMENTS", "Missing progress argument");
        }
      } else {
        result->Error("INVALID_ARGUMENTS", "Arguments must be a map");
      }
    }
    else if (method_call.method_name().compare("hideToast") == 0) {
      HideToast();
      result->Success(flutter::EncodableValue(true));
    }
    else if (method_call.method_name().compare("showCompletionToast") == 0) {
      const auto* arguments = std::get_if<flutter::EncodableMap>(method_call.arguments());
      if (arguments) {
        auto title_it = arguments->find(flutter::EncodableValue("title"));
        auto subtitle_it = arguments->find(flutter::EncodableValue("subtitle"));
        auto message_it = arguments->find(flutter::EncodableValue("message"));

        if (title_it != arguments->end() && subtitle_it != arguments->end()) {
          std::string title = std::get<std::string>(title_it->second);
          std::string subtitle = std::get<std::string>(subtitle_it->second);
          std::string message = message_it != arguments->end() ? 
                               std::get<std::string>(message_it->second) : "";

          ShowCompletionToast(title, subtitle, message);
          result->Success(flutter::EncodableValue(true));
        } else {
          result->Error("INVALID_ARGUMENTS", "Missing required arguments");
        }
      } else {
        result->Error("INVALID_ARGUMENTS", "Arguments must be a map");
      }
    }
    else {
      result->NotImplemented();
    }
  } catch (const std::exception& e) {
    result->Error("NATIVE_ERROR", e.what());
  } catch (...) {
    result->Error("NATIVE_ERROR", "Unknown native error occurred");
  }
}

void WindowsNotificationsPlugin::Initialize() {
  // Simplified initialization - just set flag
  initialized_ = true;
}

void WindowsNotificationsPlugin::ShowProgressToast(const std::string& title, 
                                                  const std::string& subtitle,
                                                  int progress,
                                                  const std::string& status,
                                                  const std::string& progressLabel) {
  if (!initialized_) {
    return;
  }

  // For now, just output to console - we can enhance this later
  std::string message = title + ": " + subtitle + " (" + std::to_string(progress) + "%) - " + status;
  OutputDebugStringA(("[TOAST] " + message + "\n").c_str());
}

void WindowsNotificationsPlugin::UpdateProgress(int progress, const std::string& status) {
  if (!initialized_) {
    return;
  }

  // For now, just output to console
  std::string message = "Progress: " + std::to_string(progress) + "% - " + status;
  OutputDebugStringA(("[TOAST UPDATE] " + message + "\n").c_str());
}

void WindowsNotificationsPlugin::HideToast() {
  if (!initialized_) {
    return;
  }

  // For now, just output to console
  OutputDebugStringA("[TOAST] Hidden\n");
}

void WindowsNotificationsPlugin::ShowCompletionToast(const std::string& title,
                                                    const std::string& subtitle,
                                                    const std::string& message) {
  if (!initialized_) {
    return;
  }

  // For now, just output to console
  std::string msg = title + ": " + subtitle + " - " + message;
  OutputDebugStringA(("[TOAST COMPLETE] " + msg + "\n").c_str());
}

// External C function for plugin registration
extern "C" __declspec(dllexport) void WindowsNotificationsPluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  WindowsNotificationsPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}



void WindowsNotificationsPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  
  try {
    if (method_call.method_name().compare("initialize") == 0) {
      Initialize();
      result->Success(flutter::EncodableValue(true));
    }
    else if (method_call.method_name().compare("showProgressToast") == 0) {
      const auto* arguments = std::get_if<flutter::EncodableMap>(method_call.arguments());
      if (arguments) {
        auto title_it = arguments->find(flutter::EncodableValue("title"));
        auto subtitle_it = arguments->find(flutter::EncodableValue("subtitle"));
        auto progress_it = arguments->find(flutter::EncodableValue("progress"));
        auto status_it = arguments->find(flutter::EncodableValue("status"));
        auto label_it = arguments->find(flutter::EncodableValue("progressLabel"));

        if (title_it != arguments->end() && subtitle_it != arguments->end() && 
            progress_it != arguments->end()) {
          
          std::string title = std::get<std::string>(title_it->second);
          std::string subtitle = std::get<std::string>(subtitle_it->second);
          int progress = std::get<int>(progress_it->second);
          std::string status = status_it != arguments->end() ? 
                              std::get<std::string>(status_it->second) : "";
          std::string label = label_it != arguments->end() ? 
                             std::get<std::string>(label_it->second) : "Progress";

          ShowProgressToast(title, subtitle, progress, status, label);
          result->Success(flutter::EncodableValue(true));
        } else {
          result->Error("INVALID_ARGUMENTS", "Missing required arguments");
        }
      } else {
        result->Error("INVALID_ARGUMENTS", "Arguments must be a map");
      }
    }
    else if (method_call.method_name().compare("updateProgress") == 0) {
      const auto* arguments = std::get_if<flutter::EncodableMap>(method_call.arguments());
      if (arguments) {
        auto progress_it = arguments->find(flutter::EncodableValue("progress"));
        auto status_it = arguments->find(flutter::EncodableValue("status"));

        if (progress_it != arguments->end()) {
          int progress = std::get<int>(progress_it->second);
          std::string status = status_it != arguments->end() ? 
                              std::get<std::string>(status_it->second) : "";
          
          UpdateProgress(progress, status);
          result->Success(flutter::EncodableValue(true));
        } else {
          result->Error("INVALID_ARGUMENTS", "Missing progress argument");
        }
      } else {
        result->Error("INVALID_ARGUMENTS", "Arguments must be a map");
      }
    }
    else if (method_call.method_name().compare("hideToast") == 0) {
      HideToast();
      result->Success(flutter::EncodableValue(true));
    }
    else if (method_call.method_name().compare("showCompletionToast") == 0) {
      const auto* arguments = std::get_if<flutter::EncodableMap>(method_call.arguments());
      if (arguments) {
        auto title_it = arguments->find(flutter::EncodableValue("title"));
        auto subtitle_it = arguments->find(flutter::EncodableValue("subtitle"));
        auto message_it = arguments->find(flutter::EncodableValue("message"));

        if (title_it != arguments->end() && subtitle_it != arguments->end()) {
          std::string title = std::get<std::string>(title_it->second);
          std::string subtitle = std::get<std::string>(subtitle_it->second);
          std::string message = message_it != arguments->end() ? 
                               std::get<std::string>(message_it->second) : "";

          ShowCompletionToast(title, subtitle, message);
          result->Success(flutter::EncodableValue(true));
        } else {
          result->Error("INVALID_ARGUMENTS", "Missing required arguments");
        }
      } else {
        result->Error("INVALID_ARGUMENTS", "Arguments must be a map");
      }
    }
    else {
      result->NotImplemented();
    }
  } catch (const std::exception& e) {
    result->Error("NATIVE_ERROR", e.what());
  } catch (...) {
    result->Error("NATIVE_ERROR", "Unknown native error occurred");
  }
}

void WindowsNotificationsPlugin::Initialize() {
  try {
    winrt::init_apartment();
    toast_notifier_ = winrt::Windows::UI::Notifications::ToastNotificationManager::CreateToastNotifier(L"SharedClipboard");
    initialized_ = true;
  } catch (...) {
    initialized_ = false;
    throw std::runtime_error("Failed to initialize Windows notifications");
  }
}

void WindowsNotificationsPlugin::ShowProgressToast(const std::string& title, 
                                                  const std::string& subtitle,
                                                  int progress,
                                                  const std::string& status,
                                                  const std::string& progressLabel) {
  if (!initialized_) {
    throw std::runtime_error("Windows notifications not initialized");
  }

  try {
    // Hide current notification if exists
    HideToast();

    // Create new toast XML
    std::wstring toastXml = CreateProgressToastXml(title, subtitle, progress, status, progressLabel);
    
    // Create toast notification
    auto xmlDoc = winrt::Windows::Data::Xml::Dom::XmlDocument();
    xmlDoc.LoadXml(toastXml);
    
    current_notification_ = winrt::Windows::UI::Notifications::ToastNotification(xmlDoc);
    current_tag_ = "progress_" + std::to_string(GetTickCount64());
    current_notification_.Tag(StringToWString(current_tag_));
    
    // Show the toast
    toast_notifier_.Show(current_notification_);
  } catch (...) {
    throw std::runtime_error("Failed to show progress toast");
  }
}

void WindowsNotificationsPlugin::UpdateProgress(int progress, const std::string& status) {
  if (!initialized_ || !current_notification_) {
    return; // Silently ignore if no active notification
  }

  try {
    // For simplicity, we'll create a new notification to update progress
    // In a more sophisticated implementation, you could use data binding
    // But this approach works reliably across Windows versions
    
    // We need to get the original title and subtitle from somewhere
    // For now, we'll just update with generic info
    ShowProgressToast("File Download", "Updating...", progress, status, "Downloaded");
  } catch (...) {
    // Ignore update errors
  }
}

void WindowsNotificationsPlugin::HideToast() {
  if (current_notification_ && toast_notifier_) {
    try {
      toast_notifier_.Hide(current_notification_);
    } catch (...) {
      // Ignore hide errors
    }
    current_notification_ = nullptr;
    current_tag_.clear();
  }
}

void WindowsNotificationsPlugin::ShowCompletionToast(const std::string& title,
                                                    const std::string& subtitle,
                                                    const std::string& message) {
  if (!initialized_) {
    return; // Silently ignore if not initialized
  }

  try {
    // Hide current progress notification
    HideToast();

    // Create completion toast XML
    std::wstring toastXml = CreateCompletionToastXml(title, subtitle, message);
    
    // Create toast notification
    auto xmlDoc = winrt::Windows::Data::Xml::Dom::XmlDocument();
    xmlDoc.LoadXml(toastXml);
    
    auto notification = winrt::Windows::UI::Notifications::ToastNotification(xmlDoc);
    
    // Show the completion toast
    toast_notifier_.Show(notification);
  } catch (...) {
    // Ignore completion toast errors
  }
}

std::wstring WindowsNotificationsPlugin::CreateProgressToastXml(const std::string& title,
                                                               const std::string& subtitle,
                                                               int progress,
                                                               const std::string& status,
                                                               const std::string& progressLabel) {
  std::wstringstream xml;
  xml << L"<toast>"
      << L"<visual>"
      << L"<binding template=\"ToastGeneric\">"
      << L"<text>" << StringToWString(title) << L"</text>"
      << L"<text>" << StringToWString(subtitle) << L"</text>"
      << L"<text>" << StringToWString(status) << L"</text>"
      << L"<progress title=\"" << StringToWString(progressLabel) << L"\" "
      << L"value=\"" << (progress / 100.0) << L"\" "
      << L"valueStringOverride=\"" << progress << L"%\" "
      << L"status=\"" << StringToWString(status) << L"\"/>"
      << L"</binding>"
      << L"</visual>"
      << L"</toast>";
  
  return xml.str();
}

std::wstring WindowsNotificationsPlugin::CreateCompletionToastXml(const std::string& title,
                                                                 const std::string& subtitle,
                                                                 const std::string& message) {
  std::wstringstream xml;
  xml << L"<toast>"
      << L"<visual>"
      << L"<binding template=\"ToastGeneric\">"
      << L"<text>" << StringToWString(title) << L"</text>"
      << L"<text>" << StringToWString(subtitle) << L"</text>"
      << L"<text>" << StringToWString(message) << L"</text>"
      << L"</binding>"
      << L"</visual>"
      << L"</toast>";
  
  return xml.str();
}

std::wstring WindowsNotificationsPlugin::StringToWString(const std::string& str) {
  if (str.empty()) return std::wstring();
  
  int size_needed = MultiByteToWideChar(CP_UTF8, 0, &str[0], (int)str.size(), NULL, 0);
  std::wstring wstrTo(size_needed, 0);
  MultiByteToWideChar(CP_UTF8, 0, &str[0], (int)str.size(), &wstrTo[0], size_needed);
  return wstrTo;
}

}  // namespace

void WindowsNotificationsPluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  WindowsNotificationsPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
