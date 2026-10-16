// Internals shared by the kernel32 shims (sync.c, files.c, kernel32.c).
#pragma once
#include "shim.h"
#include <pthread.h>

// Asynchronous procedure calls: ReadFileEx/WriteFileEx completions run on the issuing thread
// during its next alertable wait.
typedef WINAPI void (*CompletionRoutine)(DWORD error, DWORD bytes, OVERLAPPED *overlapped);
void queue_apc(CompletionRoutine fn, DWORD error, DWORD bytes, OVERLAPPED *overlapped);
bool run_apcs(void); // true if any ran

// Convert a FILETIME-sized count of 100 ns ticks since 1601 from a timespec.
uint64_t timespec_to_filetime(struct timespec t);

int logical_cpu_count(void);
