// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#define WaitOnAddress FlutterWindowsUnusedWaitOnAddress
#define WakeByAddressSingle FlutterWindowsUnusedWakeByAddressSingle
#define WakeByAddressAll FlutterWindowsUnusedWakeByAddressAll
#include <windows.h>
#undef WaitOnAddress
#undef WakeByAddressSingle
#undef WakeByAddressAll

// VS2022's static STL atomic_wait.obj can reference the WaitOnAddress import
// pointers directly. Provide local definitions so linking does not pull in the
// Windows 8 api-ms-win-core-synch-l1-2-0.dll import library on Windows 7.
namespace {

using WaitOnAddressProc = BOOL(WINAPI*)(volatile VOID*, PVOID, SIZE_T, DWORD);
using WakeByAddressSingleProc = VOID(WINAPI*)(PVOID);
using WakeByAddressAllProc = VOID(WINAPI*)(PVOID);

struct SystemWaitAddressApi {
  WaitOnAddressProc wait_on_address = nullptr;
  WakeByAddressSingleProc wake_by_address_single = nullptr;
  WakeByAddressAllProc wake_by_address_all = nullptr;
};

struct AddressWaiter {
  volatile VOID* address = nullptr;
  HANDLE event = nullptr;
  bool signaled = false;
  AddressWaiter* next = nullptr;
};

INIT_ONCE g_system_api_once = INIT_ONCE_STATIC_INIT;
SystemWaitAddressApi g_system_api;

SRWLOCK g_waiters_lock = SRWLOCK_INIT;
AddressWaiter* g_waiters = nullptr;

BOOL CALLBACK InitSystemWaitAddressApi(PINIT_ONCE, PVOID, PVOID*) {
  HMODULE kernel32 = GetModuleHandleW(L"kernel32.dll");
  if (kernel32 != nullptr) {
    g_system_api.wait_on_address = reinterpret_cast<WaitOnAddressProc>(
        GetProcAddress(kernel32, "WaitOnAddress"));
    g_system_api.wake_by_address_single =
        reinterpret_cast<WakeByAddressSingleProc>(
            GetProcAddress(kernel32, "WakeByAddressSingle"));
    g_system_api.wake_by_address_all = reinterpret_cast<WakeByAddressAllProc>(
        GetProcAddress(kernel32, "WakeByAddressAll"));
  }
  return TRUE;
}

const SystemWaitAddressApi& GetSystemWaitAddressApi() {
  InitOnceExecuteOnce(&g_system_api_once, InitSystemWaitAddressApi, nullptr,
                      nullptr);
  return g_system_api;
}

bool IsSupportedAddressSize(SIZE_T size) {
  return size == 1 || size == 2 || size == 4 || size == 8;
}

bool AddressEquals(volatile VOID* address, PVOID compare_address, SIZE_T size) {
  auto* address_bytes =
      reinterpret_cast<volatile const unsigned char*>(address);
  auto* compare_bytes = reinterpret_cast<const unsigned char*>(compare_address);
  for (SIZE_T i = 0; i < size; ++i) {
    if (address_bytes[i] != compare_bytes[i]) {
      return false;
    }
  }
  return true;
}

void AddWaiter(AddressWaiter* waiter) {
  AcquireSRWLockExclusive(&g_waiters_lock);
  waiter->next = g_waiters;
  g_waiters = waiter;
  ReleaseSRWLockExclusive(&g_waiters_lock);
}

void RemoveWaiter(AddressWaiter* waiter) {
  AcquireSRWLockExclusive(&g_waiters_lock);
  AddressWaiter** current = &g_waiters;
  while (*current != nullptr) {
    if (*current == waiter) {
      *current = waiter->next;
      break;
    }
    current = &(*current)->next;
  }
  ReleaseSRWLockExclusive(&g_waiters_lock);
}

void WakeFallbackWaiters(PVOID address, bool wake_all) {
  AcquireSRWLockExclusive(&g_waiters_lock);
  for (AddressWaiter* waiter = g_waiters; waiter != nullptr;
       waiter = waiter->next) {
    if (waiter->address == address && !waiter->signaled) {
      waiter->signaled = true;
      SetEvent(waiter->event);
      if (!wake_all) {
        break;
      }
    }
  }
  ReleaseSRWLockExclusive(&g_waiters_lock);
}

BOOL FallbackWaitOnAddress(volatile VOID* address,
                           PVOID compare_address,
                           SIZE_T address_size,
                           DWORD milliseconds) {
  if (address == nullptr || compare_address == nullptr ||
      !IsSupportedAddressSize(address_size)) {
    SetLastError(ERROR_INVALID_PARAMETER);
    return FALSE;
  }

  if (!AddressEquals(address, compare_address, address_size)) {
    return TRUE;
  }

  HANDLE event = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  if (event == nullptr) {
    return FALSE;
  }

  AddressWaiter waiter;
  waiter.address = address;
  waiter.event = event;
  AddWaiter(&waiter);

  BOOL result = TRUE;
  DWORD last_error = ERROR_SUCCESS;
  if (AddressEquals(address, compare_address, address_size)) {
    DWORD wait_result = WaitForSingleObject(event, milliseconds);
    if (wait_result == WAIT_TIMEOUT) {
      result = FALSE;
      last_error = ERROR_TIMEOUT;
    } else if (wait_result == WAIT_FAILED) {
      result = FALSE;
      last_error = GetLastError();
    }
  }

  RemoveWaiter(&waiter);
  CloseHandle(event);

  if (!result) {
    SetLastError(last_error);
  }
  return result;
}

void FallbackWakeByAddress(PVOID address, bool wake_all) {
  if (address == nullptr) {
    return;
  }
  WakeFallbackWaiters(address, wake_all);
}

}  // namespace

extern "C" BOOL WINAPI WaitOnAddress(volatile VOID* address,
                                     PVOID compare_address,
                                     SIZE_T address_size,
                                     DWORD milliseconds) {
  const SystemWaitAddressApi& api = GetSystemWaitAddressApi();
  if (api.wait_on_address != nullptr && api.wake_by_address_single != nullptr) {
    return api.wait_on_address(address, compare_address, address_size,
                               milliseconds);
  }
  return FallbackWaitOnAddress(address, compare_address, address_size,
                               milliseconds);
}

extern "C" VOID WINAPI WakeByAddressSingle(PVOID address) {
  const SystemWaitAddressApi& api = GetSystemWaitAddressApi();
  if (api.wake_by_address_single != nullptr) {
    api.wake_by_address_single(address);
    return;
  }
  FallbackWakeByAddress(address, false);
}

extern "C" VOID WINAPI WakeByAddressAll(PVOID address) {
  const SystemWaitAddressApi& api = GetSystemWaitAddressApi();
  if (api.wake_by_address_all != nullptr) {
    api.wake_by_address_all(address);
    return;
  }
  FallbackWakeByAddress(address, true);
}

#if defined(_M_X64) || defined(__x86_64__)
extern "C" {
// Import-library references use these data symbols instead of calling the
// functions above by name.
WaitOnAddressProc __imp_WaitOnAddress = &WaitOnAddress;
WakeByAddressSingleProc __imp_WakeByAddressSingle = &WakeByAddressSingle;
WakeByAddressAllProc __imp_WakeByAddressAll = &WakeByAddressAll;
}
#endif  // defined(_M_X64) || defined(__x86_64__)
