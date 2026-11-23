#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  SYSTEM_INFO system_info{};
  ::GetSystemInfo(&system_info);
  constexpr SIZE_T working_set_bytes = 360000000;
  const SIZE_T page_size = system_info.dwPageSize;
  const SIZE_T max_working_set = working_set_bytes / page_size * page_size;
  SIZE_T min_working_set, previous_max;
  DWORD flags;
  HANDLE process = ::GetCurrentProcess();
  if (!::GetProcessWorkingSetSizeEx(process, &min_working_set, &previous_max,
                                    &flags) ||
      !::SetProcessWorkingSetSizeEx(process, min_working_set, max_working_set,
                                    QUOTA_LIMITS_HARDWS_MAX_ENABLE)) {
    ::MessageBoxW(nullptr, L"Windows could not apply the 384 MB memory limit.",
                  L"ArcadiaPlus", MB_OK | MB_ICONERROR);
    return EXIT_FAILURE;
  }

  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments = GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"ArcadiaPlus", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
