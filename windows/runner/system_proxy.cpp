#include "system_proxy.h"

#include <windows.h>
#include <wininet.h>
#include <flutter/standard_method_codec.h>
#include <array>
#include <string>

namespace {
using Value = flutter::EncodableValue;
using Map = flutter::EncodableMap;

std::string Utf8(const wchar_t* text) {
  if (!text || !*text) return {};
  const int length = static_cast<int>(wcslen(text));
  const int size = WideCharToMultiByte(CP_UTF8, 0, text, length, nullptr, 0,
                                     nullptr, nullptr);
  std::string result(size, '\0');
  WideCharToMultiByte(CP_UTF8, 0, text, length, result.data(), size, nullptr,
                      nullptr);
  return result;
}

bool Wide(const Map& map, const char* key, std::wstring& result) {
  const auto item = map.find(Value(key));
  if (item == map.end()) return false;
  const auto text = std::get_if<std::string>(&item->second);
  if (!text || text->find('\0') != std::string::npos) return false;
  if (text->empty()) { result.clear(); return true; }
  const int size = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
      text->data(), static_cast<int>(text->size()), nullptr, 0);
  if (!size) return false;
  result.resize(size);
  return MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text->data(),
      static_cast<int>(text->size()), result.data(), size) == size;
}

bool ReadOptions(Map& state, DWORD& error, DWORD flags_option) {
  std::array<INTERNET_PER_CONN_OPTIONW, 4> options{};
  options[0].dwOption = flags_option;
  options[1].dwOption = INTERNET_PER_CONN_PROXY_SERVER;
  options[2].dwOption = INTERNET_PER_CONN_PROXY_BYPASS;
  options[3].dwOption = INTERNET_PER_CONN_AUTOCONFIG_URL;
  INTERNET_PER_CONN_OPTION_LISTW list{};
  list.dwSize = sizeof(list);
  list.dwOptionCount = static_cast<DWORD>(options.size());
  list.pOptions = options.data(); // NULL connection selects LAN settings.
  DWORD size = sizeof(list);
  const BOOL ok = InternetQueryOptionW(nullptr,
      INTERNET_OPTION_PER_CONNECTION_OPTION, &list, &size);
  error = ok ? ERROR_SUCCESS : GetLastError();
  if (ok) {
    state[Value("flags")] = Value(static_cast<int64_t>(options[0].Value.dwValue));
    state[Value("server")] = Value(Utf8(options[1].Value.pszValue));
    state[Value("bypass")] = Value(Utf8(options[2].Value.pszValue));
    state[Value("autoConfigUrl")] = Value(Utf8(options[3].Value.pszValue));
  }
  for (size_t i = 1; i < options.size(); ++i) {
    if (options[i].Value.pszValue) GlobalFree(options[i].Value.pszValue);
  }
  return ok != FALSE;
}

bool Read(Map& state, DWORD& error) {
  // FLAGS reports effective autodetection, which can hide the saved WPAD bit.
  // FLAGS_UI preserves the user's settings for verification and restoration.
  if (ReadOptions(state, error, INTERNET_PER_CONN_FLAGS_UI)) return true;
  if (error != ERROR_INVALID_PARAMETER && error != ERROR_INTERNET_INVALID_OPTION)
    return false;
  return ReadOptions(state, error, INTERNET_PER_CONN_FLAGS);
}

bool Apply(const Map& state, DWORD& error) {
  const auto item = state.find(Value("flags"));
  if (item == state.end()) { error = ERROR_INVALID_PARAMETER; return false; }
  int64_t flags = -1;
  if (const auto value = std::get_if<int32_t>(&item->second)) flags = *value;
  if (const auto value = std::get_if<int64_t>(&item->second)) flags = *value;
  std::wstring server, bypass, auto_url;
  if (flags < 0 || flags > 15 || !Wide(state, "server", server) ||
      !Wide(state, "bypass", bypass) || !Wide(state, "autoConfigUrl", auto_url) ||
      ((flags & PROXY_TYPE_PROXY) && server.empty())) {
    error = ERROR_INVALID_PARAMETER;
    return false;
  }
  std::array<INTERNET_PER_CONN_OPTIONW, 4> options{};
  options[0].dwOption = INTERNET_PER_CONN_FLAGS;
  options[0].Value.dwValue = static_cast<DWORD>(flags);
  options[1].dwOption = INTERNET_PER_CONN_PROXY_SERVER;
  options[1].Value.pszValue = server.data();
  options[2].dwOption = INTERNET_PER_CONN_PROXY_BYPASS;
  options[2].Value.pszValue = bypass.data();
  options[3].dwOption = INTERNET_PER_CONN_AUTOCONFIG_URL;
  options[3].Value.pszValue = auto_url.data();
  INTERNET_PER_CONN_OPTION_LISTW list{};
  list.dwSize = sizeof(list);
  list.dwOptionCount = static_cast<DWORD>(options.size());
  list.pOptions = options.data();
  if (!InternetSetOptionW(nullptr, INTERNET_OPTION_PER_CONNECTION_OPTION,
                         &list, sizeof(list))) {
    error = GetLastError();
    return false;
  }
  // Notify both WinINET clients and the cached proxy resolver.
  if (!InternetSetOptionW(nullptr, INTERNET_OPTION_SETTINGS_CHANGED, nullptr, 0) ||
      !InternetSetOptionW(nullptr, INTERNET_OPTION_REFRESH, nullptr, 0)) {
    error = GetLastError();
    return false;
  }
  return true;
}
} // namespace

std::unique_ptr<flutter::MethodChannel<Value>> CreateSystemProxyChannel(
    flutter::BinaryMessenger* messenger) {
  auto channel = std::make_unique<flutter::MethodChannel<Value>>(
      messenger, "com.arcadiaplus/windows_proxy",
      &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler([](const auto& call, auto result) {
    DWORD error = ERROR_SUCCESS;
    Map state;
    if (call.method_name() == "read") {
      if (Read(state, error)) { result->Success(Value(state)); return; }
    } else if (call.method_name() == "apply") {
      const auto args = call.arguments();
      const auto map = args ? std::get_if<Map>(args) : nullptr;
      if (!map) { result->Error("invalid_arguments", "Proxy state is required"); return; }
      Map previous;
      if (Read(previous, error)) {
        if (Apply(*map, error)) { result->Success(); return; }
        DWORD restore_error = ERROR_SUCCESS;
        if (!Apply(previous, restore_error)) {
          Map errors;
          errors[Value("apply")] = Value(static_cast<int64_t>(error));
          errors[Value("restore")] = Value(static_cast<int64_t>(restore_error));
          result->Error("wininet_restore", "Windows proxy update and rollback failed",
                        Value(errors));
          return;
        }
      }
    } else { result->NotImplemented(); return; }
    result->Error("wininet", "Windows proxy operation failed",
                  Value(static_cast<int64_t>(error)));
  });
  return channel;
}
