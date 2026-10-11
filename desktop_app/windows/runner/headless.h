#pragma once
#include <windows.h>
#include <shellapi.h>
#include <string>
#include <thread>
#include <atomic>

// Return -1 for GUI mode. Keep diagnostic stdio independent of Flutter startup.
inline int RunHeadless() {
  int count = 0;
  LPWSTR* args = CommandLineToArgvW(GetCommandLineW(), &count);
  if (count <= 1) { LocalFree(args); return -1; }
  bool diagnose = false, self_test = false, no_open = false;
  std::wstring report;
  for (int i = 1; i < count; ++i) {
    std::wstring arg(args[i]);
    if (arg == L"--diagnose") diagnose = true;
    else if (arg == L"--self-test") self_test = true;
    else if (arg == L"--no-open") no_open = true;
    else if (arg == L"--report-path" && i + 1 < count) report = args[++i];
    else { LocalFree(args); return 1; }
  }
  LocalFree(args);
  if ((!diagnose && !self_test && !no_open) || (!report.empty() && !diagnose)) return 1;
  wchar_t path[32768];
  DWORD length = GetModuleFileNameW(nullptr, path, 32768);
  if (!length || length == 32768) return 1;
  std::wstring root(path, length);
  root = root.substr(0, root.find_last_of(L"\\/"));
  std::wstring runtime = root + L"\\runtime\\node.exe";
  std::wstring command = L"\"" + runtime + L"\" \"" + root + L"\\desktop\\server.mjs\"";
  if (diagnose) command += L" --diagnose";
  if (self_test) command += L" --self-test";
  if (no_open) command += L" --no-open";
  SECURITY_ATTRIBUTES security{sizeof(SECURITY_ATTRIBUTES), nullptr, TRUE};
  HANDLE output_read = nullptr, output_write = nullptr;
  HANDLE error_read = nullptr, error_write = nullptr;
  if (!CreatePipe(&output_read, &output_write, &security, 0)) return 1;
  if (!CreatePipe(&error_read, &error_write, &security, 0)) { CloseHandle(output_read); CloseHandle(output_write); return 1; }
  SetHandleInformation(output_read, HANDLE_FLAG_INHERIT, 0);
  SetHandleInformation(error_read, HANDLE_FLAG_INHERIT, 0);
  STARTUPINFOW startup{};
  startup.cb = sizeof(startup);
  startup.dwFlags = STARTF_USESTDHANDLES;
  startup.hStdOutput = output_write;
  startup.hStdError = error_write;
  startup.hStdInput = GetStdHandle(STD_INPUT_HANDLE);
  PROCESS_INFORMATION process{};
  const BOOL created = CreateProcessW(runtime.c_str(), command.data(), nullptr, nullptr, TRUE, CREATE_NO_WINDOW, nullptr, root.c_str(), &startup, &process);
  CloseHandle(output_write); CloseHandle(error_write);
  if (!created) { CloseHandle(output_read); CloseHandle(error_read); return 1; }
  std::string output, errors;
  std::atomic<bool> first{false};
  auto drain = [&](HANDLE pipe, std::string& target, size_t limit, bool signal) {
    char bytes[4096]; DWORD size;
    while (ReadFile(pipe, bytes, sizeof(bytes), &size, nullptr) && size) {
      if (target.size() + size <= limit) target.append(bytes, size);
      if (signal && target.find('\n') != std::string::npos) first = true;
    }
  };
  std::thread out_thread(drain, output_read, std::ref(output), 4 * 1024 * 1024, true);
  std::thread err_thread(drain, error_read, std::ref(errors), 65536, false);
  DWORD code = 1;
  if (diagnose || self_test) {
    if (WaitForSingleObject(process.hProcess, 90000) != WAIT_OBJECT_0) TerminateProcess(process.hProcess, 1);
    WaitForSingleObject(process.hProcess, 5000);
    GetExitCodeProcess(process.hProcess, &code);
  } else {
    for (int i = 0; i < 200 && !first && WaitForSingleObject(process.hProcess, 100) == WAIT_TIMEOUT; ++i) {}
    code = first ? 0 : 1;
    if (!first) TerminateProcess(process.hProcess, 1);
    CancelSynchronousIo(out_thread.native_handle());
    CancelSynchronousIo(err_thread.native_handle());
  }
  out_thread.join(); err_thread.join();
  CloseHandle(output_read); CloseHandle(error_read);
  CloseHandle(process.hThread); CloseHandle(process.hProcess);
  DWORD written;
  WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), output.data(), static_cast<DWORD>(output.size()), &written, nullptr);
  WriteFile(GetStdHandle(STD_ERROR_HANDLE), errors.data(), static_cast<DWORD>(errors.size()), &written, nullptr);
  if (!report.empty() && code == 0) {
    HANDLE file = CreateFileW(report.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) return 1;
    BOOL ok = WriteFile(file, output.data(), static_cast<DWORD>(output.size()), &written, nullptr);
    CloseHandle(file);
    if (!ok || written != output.size()) return 1;
  }
  return static_cast<int>(code);
}
