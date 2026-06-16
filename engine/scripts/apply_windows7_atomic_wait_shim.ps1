param(
  [string]$FlutterEnginePath = (Join-Path $PSScriptRoot "..\src\flutter")
)

$ErrorActionPreference = "Stop"

$enginePath = (Resolve-Path -LiteralPath $FlutterEnginePath).Path
$windowsPath = Join-Path $enginePath "shell\platform\windows"
$buildGnPath = Join-Path $windowsPath "BUILD.gn"
$shimPath = Join-Path $windowsPath "win7_atomic_wait_shim.cc"

if (-not (Test-Path -LiteralPath $buildGnPath)) {
  throw "Windows BUILD.gn was not found: $buildGnPath"
}

$shimSource = @'
// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// Windows SDK 10 imports WaitOnAddress through api-ms-win-core-synch-l1-2-0,
// which is not present on Windows 7. This translation unit satisfies callers
// of the SDK import pointer locally, forwards to the native implementation on
// newer Windows versions, and falls back to condition variables on Windows 7.

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif

#ifndef NOMINMAX
#define NOMINMAX
#endif

#define WaitOnAddress WaitOnAddress_DontImport
#define WakeByAddressSingle WakeByAddressSingle_DontImport
#define WakeByAddressAll WakeByAddressAll_DontImport
#include <Windows.h>
#undef WaitOnAddress
#undef WakeByAddressSingle
#undef WakeByAddressAll

using WaitOnAddressProc =
    BOOL(WINAPI*)(volatile VOID* address,
                  PVOID compare_address,
                  SIZE_T address_size,
                  DWORD milliseconds);
using WakeByAddressProc = VOID(WINAPI*)(PVOID address);

namespace {

struct SystemWaitAddressApi {
  WaitOnAddressProc wait_on_address = nullptr;
  WakeByAddressProc wake_by_address_single = nullptr;
  WakeByAddressProc wake_by_address_all = nullptr;
};

struct AddressWaiter {
  PVOID address = nullptr;
  CONDITION_VARIABLE condition = CONDITION_VARIABLE_INIT;
  AddressWaiter* next = nullptr;
};

INIT_ONCE g_system_api_once = INIT_ONCE_STATIC_INIT;
SystemWaitAddressApi g_system_api;

INIT_ONCE g_fallback_once = INIT_ONCE_STATIC_INIT;
CRITICAL_SECTION g_waiters_lock;
AddressWaiter* g_waiters = nullptr;

BOOL CALLBACK InitSystemWaitAddressApi(PINIT_ONCE init_once,
                                       PVOID parameter,
                                       PVOID* context) {
  HMODULE kernel32 = ::GetModuleHandleW(L"kernel32.dll");
  if (kernel32 == nullptr) {
    return TRUE;
  }

  auto wait_on_address = reinterpret_cast<WaitOnAddressProc>(
      ::GetProcAddress(kernel32, "WaitOnAddress"));
  auto wake_by_address_single = reinterpret_cast<WakeByAddressProc>(
      ::GetProcAddress(kernel32, "WakeByAddressSingle"));
  auto wake_by_address_all = reinterpret_cast<WakeByAddressProc>(
      ::GetProcAddress(kernel32, "WakeByAddressAll"));

  if (wait_on_address != nullptr && wake_by_address_single != nullptr &&
      wake_by_address_all != nullptr) {
    g_system_api.wait_on_address = wait_on_address;
    g_system_api.wake_by_address_single = wake_by_address_single;
    g_system_api.wake_by_address_all = wake_by_address_all;
  }

  return TRUE;
}

BOOL CALLBACK InitFallbackWaiters(PINIT_ONCE init_once,
                                  PVOID parameter,
                                  PVOID* context) {
  ::InitializeCriticalSection(&g_waiters_lock);
  return TRUE;
}

const SystemWaitAddressApi& GetSystemWaitAddressApi() {
  ::InitOnceExecuteOnce(
      &g_system_api_once, InitSystemWaitAddressApi, nullptr, nullptr);
  return g_system_api;
}

void EnsureFallbackWaitersInitialized() {
  ::InitOnceExecuteOnce(&g_fallback_once, InitFallbackWaiters, nullptr, nullptr);
}

bool IsSupportedAddressSize(SIZE_T address_size) {
  return address_size == 1 || address_size == 2 || address_size == 4 ||
         address_size == 8;
}

bool AddressEquals(volatile VOID* address,
                   PVOID compare_address,
                   SIZE_T address_size) {
  auto address_bytes = static_cast<volatile unsigned char*>(address);
  auto compare_bytes = static_cast<unsigned char*>(compare_address);
  for (SIZE_T i = 0; i < address_size; ++i) {
    if (address_bytes[i] != compare_bytes[i]) {
      return false;
    }
  }
  return true;
}

PVOID NonVolatileAddress(volatile VOID* address) {
  return const_cast<PVOID>(static_cast<const volatile VOID*>(address));
}

void AddWaiter(AddressWaiter* waiter) {
  waiter->next = g_waiters;
  g_waiters = waiter;
}

void RemoveWaiter(AddressWaiter* waiter) {
  AddressWaiter** current = &g_waiters;
  while (*current != nullptr) {
    if (*current == waiter) {
      *current = waiter->next;
      waiter->next = nullptr;
      return;
    }
    current = &(*current)->next;
  }
}

DWORD RemainingTimeout(ULONGLONG deadline) {
  ULONGLONG now = ::GetTickCount64();
  if (now >= deadline) {
    return 0;
  }

  ULONGLONG remaining = deadline - now;
  if (remaining > MAXDWORD) {
    return MAXDWORD;
  }
  return static_cast<DWORD>(remaining);
}

BOOL FallbackWaitOnAddress(volatile VOID* address,
                           PVOID compare_address,
                           SIZE_T address_size,
                           DWORD milliseconds) {
  if (!IsSupportedAddressSize(address_size)) {
    ::SetLastError(ERROR_INVALID_PARAMETER);
    return FALSE;
  }

  EnsureFallbackWaitersInitialized();

  ULONGLONG deadline = 0;
  if (milliseconds != INFINITE) {
    deadline = ::GetTickCount64() + milliseconds;
  }

  AddressWaiter waiter;
  waiter.address = NonVolatileAddress(address);
  ::InitializeConditionVariable(&waiter.condition);

  BOOL result = TRUE;
  DWORD last_error = ERROR_SUCCESS;

  ::EnterCriticalSection(&g_waiters_lock);
  AddWaiter(&waiter);

  while (AddressEquals(address, compare_address, address_size)) {
    DWORD wait_time = milliseconds;
    if (milliseconds != INFINITE) {
      wait_time = RemainingTimeout(deadline);
    }

    if (!::SleepConditionVariableCS(
            &waiter.condition, &g_waiters_lock, wait_time)) {
      last_error = ::GetLastError();
      result = FALSE;
      break;
    }
  }

  RemoveWaiter(&waiter);
  ::LeaveCriticalSection(&g_waiters_lock);

  if (!result) {
    ::SetLastError(last_error);
  }
  return result;
}

void WakeFallbackWaiters(PVOID address, bool wake_all) {
  EnsureFallbackWaitersInitialized();

  ::EnterCriticalSection(&g_waiters_lock);
  for (AddressWaiter* waiter = g_waiters; waiter != nullptr;
       waiter = waiter->next) {
    if (waiter->address != address) {
      continue;
    }

    ::WakeConditionVariable(&waiter->condition);
    if (!wake_all) {
      break;
    }
  }
  ::LeaveCriticalSection(&g_waiters_lock);
}

}  // namespace

extern "C" BOOL WINAPI WaitOnAddress(volatile VOID* address,
                                     PVOID compare_address,
                                     SIZE_T address_size,
                                     DWORD milliseconds) {
  const SystemWaitAddressApi& api = GetSystemWaitAddressApi();
  if (api.wait_on_address != nullptr) {
    return api.wait_on_address(
        address, compare_address, address_size, milliseconds);
  }

  return FallbackWaitOnAddress(
      address, compare_address, address_size, milliseconds);
}

extern "C" VOID WINAPI WakeByAddressSingle(PVOID address) {
  const SystemWaitAddressApi& api = GetSystemWaitAddressApi();
  if (api.wake_by_address_single != nullptr) {
    api.wake_by_address_single(address);
    return;
  }

  WakeFallbackWaiters(address, false);
}

extern "C" VOID WINAPI WakeByAddressAll(PVOID address) {
  const SystemWaitAddressApi& api = GetSystemWaitAddressApi();
  if (api.wake_by_address_all != nullptr) {
    api.wake_by_address_all(address);
    return;
  }

  WakeFallbackWaiters(address, true);
}

extern "C" {
#if defined(_M_X64) || defined(__x86_64__)
WaitOnAddressProc __imp_WaitOnAddress = &WaitOnAddress;
WakeByAddressProc __imp_WakeByAddressSingle = &WakeByAddressSingle;
WakeByAddressProc __imp_WakeByAddressAll = &WakeByAddressAll;
#endif
}
'@

$existingShim = ""
if (Test-Path -LiteralPath $shimPath) {
  $existingShim = Get-Content -LiteralPath $shimPath -Raw
}

if ($existingShim -ne $shimSource) {
  [System.IO.File]::WriteAllText(
      $shimPath, $shimSource, [System.Text.Encoding]::ASCII)
  Write-Host "Wrote Windows 7 atomic wait shim: $shimPath"
} else {
  Write-Host "Windows 7 atomic wait shim is already up to date: $shimPath"
}

$buildGn = Get-Content -LiteralPath $buildGnPath -Raw
if ($buildGn -notmatch '"win7_atomic_wait_shim\.cc"') {
  $needle = '    "windows_proc_table.h",' + "`r`n"
  $newline = "`r`n"
  if (-not $buildGn.Contains($needle)) {
    $needle = '    "windows_proc_table.h",' + "`n"
    $newline = "`n"
  }
  if (-not $buildGn.Contains($needle)) {
    throw "Could not find insertion point in $buildGnPath"
  }

  $buildGn = $buildGn.Replace(
      $needle, $needle + '    "win7_atomic_wait_shim.cc",' + $newline)
  [System.IO.File]::WriteAllText(
      $buildGnPath, $buildGn, [System.Text.Encoding]::ASCII)
  Write-Host "Added win7_atomic_wait_shim.cc to flutter_windows_source."
} else {
  Write-Host "win7_atomic_wait_shim.cc is already listed in BUILD.gn."
}
