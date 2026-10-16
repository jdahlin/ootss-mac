// The subset of the Windows API types, structures and constants that the shims use.
//
// The real Windows SDK headers (or mingw's) assume LLP64, where `long` is 32 bits. macOS is LP64, so
// those headers would produce wrong layouts. Everything here uses fixed-width types and every structure
// is checked against its x64 Windows size.
#pragma once
#include <stddef.h>
#include <stdint.h>

// ---------------------------------------------------------------- basic types
typedef uint8_t BYTE;
typedef uint16_t WORD;
typedef uint32_t DWORD;
typedef uint64_t DWORDLONG;
typedef int32_t LONG;
typedef uint32_t ULONG;
typedef uint32_t UINT;
typedef int32_t WBOOL; // BOOL, renamed to avoid Objective-C's BOOL
typedef uint16_t WCHAR;
typedef int32_t HRESULT;
typedef void *HANDLE;
typedef void *HWND;
typedef uintptr_t WPARAM;
typedef intptr_t LPARAM;
typedef intptr_t LRESULT;
typedef uintptr_t ULONG_PTR;

typedef struct {
    uint32_t Data1;
    uint16_t Data2, Data3;
    uint8_t Data4[8];
} GUID;

typedef struct {
    DWORD dwLowDateTime, dwHighDateTime;
} FILETIME;

typedef struct {
    WORD wYear, wMonth, wDayOfWeek, wDay, wHour, wMinute, wSecond, wMilliseconds;
} SYSTEMTIME;

typedef struct {
    LONG x, y;
} POINT;

typedef struct {
    LONG left, top, right, bottom;
} RECT;

// ---------------------------------------------------------------- HRESULTs and Win32 errors
#define S_OK                 ((HRESULT)0)
#define S_FALSE              ((HRESULT)1)
#define E_NOTIMPL            ((HRESULT)0x80004001)
#define E_NOINTERFACE        ((HRESULT)0x80004002)
#define E_FAIL               ((HRESULT)0x80004005)
#define E_NOTFOUND           ((HRESULT)0x80070490)
#define REGDB_E_CLASSNOTREG  ((HRESULT)0x80040154)
#define DXGI_ERROR_NOT_FOUND ((HRESULT)0x887A0002)

#define ERROR_SUCCESS             0
#define ERROR_FILE_NOT_FOUND      2
#define ERROR_PATH_NOT_FOUND      3
#define ERROR_ACCESS_DENIED       5
#define ERROR_NOT_ENOUGH_MEMORY   8
#define ERROR_NO_MORE_FILES       18
#define ERROR_INSUFFICIENT_BUFFER 122
#define ERROR_MOD_NOT_FOUND       126
#define ERROR_ALREADY_EXISTS      183
#define ERROR_MORE_DATA           234
#define ERROR_NO_MORE_ITEMS       259

// ---------------------------------------------------------------- registry
#define REG_SZ    1
#define REG_DWORD 4

// ---------------------------------------------------------------- PE image format
#define IMAGE_DIRECTORY_ENTRY_IMPORT    1
#define IMAGE_DIRECTORY_ENTRY_BASERELOC 5
#define IMAGE_DIRECTORY_ENTRY_TLS       9
#define IMAGE_REL_BASED_DIR64           10
#define IMAGE_ORDINAL_FLAG64            (1ull << 63)

typedef struct {
    WORD e_magic;
    BYTE _unused[58];
    LONG e_lfanew; // offset of IMAGE_NT_HEADERS64
} IMAGE_DOS_HEADER;

typedef struct {
    DWORD VirtualAddress, Size;
} IMAGE_DATA_DIRECTORY;

typedef struct {
    DWORD Signature;
    // IMAGE_FILE_HEADER
    WORD Machine, NumberOfSections;
    DWORD TimeDateStamp, PointerToSymbolTable, NumberOfSymbols;
    WORD SizeOfOptionalHeader, Characteristics;
    // IMAGE_OPTIONAL_HEADER64
    WORD Magic;
    BYTE MajorLinkerVersion, MinorLinkerVersion;
    DWORD SizeOfCode, SizeOfInitializedData, SizeOfUninitializedData, AddressOfEntryPoint, BaseOfCode;
    uint64_t ImageBase;
    DWORD SectionAlignment, FileAlignment;
    WORD MajorOperatingSystemVersion, MinorOperatingSystemVersion, MajorImageVersion, MinorImageVersion;
    WORD MajorSubsystemVersion, MinorSubsystemVersion;
    DWORD Win32VersionValue, SizeOfImage, SizeOfHeaders, CheckSum;
    WORD Subsystem, DllCharacteristics;
    uint64_t SizeOfStackReserve, SizeOfStackCommit, SizeOfHeapReserve, SizeOfHeapCommit;
    DWORD LoaderFlags, NumberOfRvaAndSizes;
    IMAGE_DATA_DIRECTORY DataDirectory[16];
} IMAGE_NT_HEADERS64;

typedef struct {
    BYTE Name[8];
    DWORD VirtualSize, VirtualAddress, SizeOfRawData, PointerToRawData;
    DWORD PointerToRelocations, PointerToLinenumbers;
    WORD NumberOfRelocations, NumberOfLinenumbers;
    DWORD Characteristics;
} IMAGE_SECTION_HEADER;

typedef struct {
    DWORD OriginalFirstThunk; // import lookup table
    DWORD TimeDateStamp, ForwarderChain, Name;
    DWORD FirstThunk; // import address table
} IMAGE_IMPORT_DESCRIPTOR;

typedef struct {
    DWORD VirtualAddress, SizeOfBlock; // followed by WORD entries: type << 12 | offset
} IMAGE_BASE_RELOCATION;

typedef struct {
    uint64_t StartAddressOfRawData, EndAddressOfRawData, AddressOfIndex, AddressOfCallBacks;
    DWORD SizeOfZeroFill, Characteristics;
} IMAGE_TLS_DIRECTORY64;

// ---------------------------------------------------------------- kernel32
#define INVALID_HANDLE_VALUE    ((HANDLE)(intptr_t)-1)
#define INVALID_FILE_ATTRIBUTES 0xFFFFFFFFu
#define INFINITE                0xFFFFFFFFu
#define WAIT_OBJECT_0           0x000u
#define WAIT_IO_COMPLETION      0x0C0u
#define WAIT_TIMEOUT            0x102u
#define STD_INPUT_HANDLE        ((DWORD) - 10)
#define STD_ERROR_HANDLE        ((DWORD) - 12)
#define CREATE_SUSPENDED        0x4
#define MS_VC_EXCEPTION         0x406D1388u // RaiseException code used to name threads

#define GENERIC_READ      0x80000000u
#define GENERIC_WRITE     0x40000000u
#define CREATE_NEW        1
#define CREATE_ALWAYS     2
#define OPEN_EXISTING     3
#define OPEN_ALWAYS       4
#define TRUNCATE_EXISTING 5
#define FILE_BEGIN        0
#define FILE_CURRENT      1
#define FILE_END          2

#define FILE_ATTRIBUTE_DIRECTORY 0x10
#define FILE_ATTRIBUTE_NORMAL    0x80

#define MEM_COMMIT             0x1000
#define MEM_RESERVE            0x2000
#define MEM_RELEASE            0x8000
#define MEM_PRIVATE            0x20000
#define PAGE_READWRITE         0x04
#define PAGE_EXECUTE_ANY_MASK  0xF0 // PAGE_EXECUTE, _READ, _READWRITE, _WRITECOPY
#define HEAP_ZERO_MEMORY       0x08
#define FILE_MAP_WRITE         0x02
#define ALLOCATION_GRANULARITY 0x10000

#define PROCESSOR_ARCHITECTURE_AMD64   9
#define PROCESSOR_AMD_X8664            8664
#define PF_FASTFAIL_AVAILABLE          23
#define RELATION_PROCESSOR_CORE        0
#define RELATION_ALL                   0xFFFF
#define FORMAT_MESSAGE_ALLOCATE_BUFFER 0x100
#define VER_PLATFORM_WIN32_NT          2
#define LCID_EN_US                     0x409

// Windows FILETIME counts 100 ns ticks since 1601-01-01.
#define FILETIME_UNIX_EPOCH 116444736000000000ull

typedef struct {
    ULONG_PTR Internal;     // status
    ULONG_PTR InternalHigh; // bytes transferred
    DWORD Offset, OffsetHigh;
    HANDLE hEvent;
} OVERLAPPED;

typedef struct {
    void *DebugInfo; // the shims keep a pthread mutex pointer here
    LONG LockCount, RecursionCount;
    HANDLE OwningThread, LockSemaphore;
    ULONG_PTR SpinCount;
} CRITICAL_SECTION;

typedef struct {
    DWORD dwFileAttributes;
    FILETIME ftCreationTime, ftLastAccessTime, ftLastWriteTime;
    DWORD nFileSizeHigh, nFileSizeLow, dwReserved0, dwReserved1;
    WCHAR cFileName[260];
    WCHAR cAlternateFileName[14];
} WIN32_FIND_DATAW;

typedef struct {
    WORD wProcessorArchitecture, wReserved;
    DWORD dwPageSize;
    void *lpMinimumApplicationAddress, *lpMaximumApplicationAddress;
    uint64_t dwActiveProcessorMask;
    DWORD dwNumberOfProcessors, dwProcessorType, dwAllocationGranularity;
    WORD wProcessorLevel, wProcessorRevision;
} SYSTEM_INFO;

typedef struct {
    DWORD dwLength, dwMemoryLoad;
    DWORDLONG ullTotalPhys, ullAvailPhys, ullTotalPageFile, ullAvailPageFile;
    DWORDLONG ullTotalVirtual, ullAvailVirtual, ullAvailExtendedVirtual;
} MEMORYSTATUSEX;

typedef struct {
    void *BaseAddress, *AllocationBase;
    DWORD AllocationProtect;
    WORD PartitionId;
    size_t RegionSize;
    DWORD State, Protect, Type;
} MEMORY_BASIC_INFORMATION;

typedef struct {
    DWORD dwOSVersionInfoSize, dwMajorVersion, dwMinorVersion, dwBuildNumber, dwPlatformId;
    WCHAR szCSDVersion[128];
} OSVERSIONINFOW;

typedef struct {
    DWORD cb;
    BYTE _rest[100]; // never read by the game
} STARTUPINFOW;

// One RelationProcessorCore record of SYSTEM_LOGICAL_PROCESSOR_INFORMATION_EX.
typedef struct {
    DWORD Relationship, Size;
    BYTE Flags, EfficiencyClass, Reserved[20];
    WORD GroupCount;
    struct {
        uint64_t Mask;
        WORD Group, Reserved[3];
    } GroupMask[1];
} PROCESSOR_CORE_INFO;

// ---------------------------------------------------------------- user32
#define WM_CREATE      0x0001
#define WM_SIZE        0x0005
#define WM_ACTIVATE    0x0006
#define WM_SETFOCUS    0x0007
#define WM_KILLFOCUS   0x0008
#define WM_CLOSE       0x0010
#define WM_QUIT        0x0012
#define WM_SHOWWINDOW  0x0018
#define WM_ACTIVATEAPP 0x001C
#define WM_NCCREATE    0x0081
#define WM_INPUT       0x00FF
#define WM_KEYDOWN     0x0100
#define WM_KEYUP       0x0101
#define WM_CHAR        0x0102
#define WM_SYSKEYDOWN  0x0104
#define WM_SYSKEYUP    0x0105
#define WM_SYSCHAR     0x0106
#define WM_MOUSEMOVE   0x0200
#define WM_LBUTTONDOWN 0x0201
#define WM_RBUTTONDOWN 0x0204
#define WM_MBUTTONDOWN 0x0207
#define WM_MOUSEWHEEL  0x020A
#define WM_XBUTTONDOWN 0x020B // the matching *UP message is always DOWN + 1

#define WA_INACTIVE            0
#define WA_ACTIVE              1
#define PM_REMOVE              0x1
#define WHEEL_DELTA            120
#define WS_VISIBLE             0x10000000
#define SWP_NOSIZE             0x1
#define GWLP_WNDPROC           (-4)
#define GWL_STYLE              (-16)
#define GWL_EXSTYLE            (-20)
#define MONITORINFOF_PRIMARY   1
#define ENUM_CURRENT_SETTINGS  ((DWORD) - 1)
#define ENUM_REGISTRY_SETTINGS ((DWORD) - 2)
#define DM_BITSPERPEL          0x00040000
#define DM_PELSWIDTH           0x00080000
#define DM_PELSHEIGHT          0x00100000
#define DM_DISPLAYFREQUENCY    0x00400000

#define SM_CXSCREEN        0
#define SM_CYSCREEN        1
#define SM_CXFULLSCREEN    16
#define SM_CYFULLSCREEN    17
#define SM_CXVIRTUALSCREEN 78
#define SM_CYVIRTUALSCREEN 79
#define SM_CMONITORS       80

#define MK_LBUTTON  0x01
#define MK_RBUTTON  0x02
#define MK_MBUTTON  0x10
#define MK_XBUTTON1 0x20
#define MK_XBUTTON2 0x40

#define VK_LBUTTON    0x01
#define VK_RBUTTON    0x02
#define VK_MBUTTON    0x04
#define VK_XBUTTON1   0x05
#define VK_XBUTTON2   0x06
#define VK_BACK       0x08
#define VK_TAB        0x09
#define VK_RETURN     0x0D
#define VK_SHIFT      0x10
#define VK_CONTROL    0x11
#define VK_MENU       0x12 // Alt
#define VK_CAPITAL    0x14
#define VK_ESCAPE     0x1B
#define VK_SPACE      0x20
#define VK_PRIOR      0x21
#define VK_NEXT       0x22
#define VK_END        0x23
#define VK_HOME       0x24
#define VK_LEFT       0x25
#define VK_UP         0x26
#define VK_RIGHT      0x27
#define VK_DOWN       0x28
#define VK_INSERT     0x2D
#define VK_DELETE     0x2E
#define VK_LWIN       0x5B
#define VK_NUMPAD0    0x60
#define VK_MULTIPLY   0x6A
#define VK_ADD        0x6B
#define VK_SUBTRACT   0x6D
#define VK_DECIMAL    0x6E
#define VK_DIVIDE     0x6F
#define VK_F1         0x70
#define VK_LSHIFT     0xA0
#define VK_RSHIFT     0xA1
#define VK_LCONTROL   0xA2
#define VK_RCONTROL   0xA3
#define VK_LMENU      0xA4
#define VK_RMENU      0xA5
#define VK_OEM_1      0xBA // ;
#define VK_OEM_PLUS   0xBB
#define VK_OEM_COMMA  0xBC
#define VK_OEM_MINUS  0xBD
#define VK_OEM_PERIOD 0xBE
#define VK_OEM_2      0xBF // /
#define VK_OEM_3      0xC0 // `
#define VK_OEM_4      0xDB // [
#define VK_OEM_5      0xDC // backslash
#define VK_OEM_6      0xDD // ]
#define VK_OEM_7      0xDE // '
#define VK_OEM_102    0xE2 // ISO <> key

typedef intptr_t(__attribute__((ms_abi)) * WNDPROC)(HWND, UINT, WPARAM, LPARAM);

typedef struct {
    HWND hwnd;
    UINT message;
    WPARAM wParam;
    LPARAM lParam;
    DWORD time;
    POINT pt;
    DWORD lPrivate;
} MSG;

typedef struct {
    UINT cbSize, style;
    WNDPROC lpfnWndProc;
    int cbClsExtra, cbWndExtra;
    HANDLE hInstance, hIcon, hCursor, hbrBackground;
    const WCHAR *lpszMenuName, *lpszClassName;
    HANDLE hIconSm;
} WNDCLASSEXW;

typedef struct {
    void *lpCreateParams;
    HANDLE hInstance, hMenu;
    HWND hwndParent;
    int cy, cx, y, x;
    LONG style;
    const WCHAR *lpszName, *lpszClass;
    DWORD dwExStyle;
} CREATESTRUCTW;

typedef struct {
    DWORD cbSize;
    RECT rcMonitor, rcWork;
    DWORD dwFlags;
    union { // only present when cbSize says so (MONITORINFOEXA / MONITORINFOEXW)
        char szDeviceA[32];
        WCHAR szDeviceW[32];
    };
} MONITORINFOEX;

typedef struct {
    char dmDeviceName[32];
    WORD dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra;
    DWORD dmFields;
    BYTE _position_or_orientation[16];
    short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
    char dmFormName[32];
    WORD dmLogPixels;
    DWORD dmBitsPerPel, dmPelsWidth, dmPelsHeight, dmDisplayFlags, dmDisplayFrequency;
    DWORD dmICMMethod, dmICMIntent, dmMediaType, dmDitherType, dmReserved1, dmReserved2;
    DWORD dmPanningWidth, dmPanningHeight;
} DEVMODEA;

// Raw input
#define RIM_TYPEMOUSE              0
#define RIM_TYPEKEYBOARD           1
#define RIM_INPUT                  0
#define RID_INPUT                  0x10000003
#define RID_HEADER                 0x10000005
#define RIDEV_REMOVE               0x00000001
#define RIDEV_NOLEGACY             0x00000030
#define RI_KEY_BREAK               0x01
#define RI_KEY_E0                  0x02
#define RI_MOUSE_LEFT_BUTTON_DOWN  0x0001 // UP is DOWN << 1; right/middle/X1/X2 follow at << 2 each
#define RI_MOUSE_WHEEL             0x0400
#define HID_USAGE_PAGE_GENERIC     0x01
#define HID_USAGE_GENERIC_MOUSE    0x02
#define HID_USAGE_GENERIC_KEYBOARD 0x06

typedef struct {
    DWORD dwType, dwSize;
    HANDLE hDevice;
    WPARAM wParam;
} RAWINPUTHEADER;

typedef struct {
    RAWINPUTHEADER header;
    union {
        struct {
            WORD usFlags;
            WORD usButtonFlags, usButtonData;
            ULONG ulRawButtons;
            LONG lLastX, lLastY;
            ULONG ulExtraInformation;
        } mouse;
        struct {
            WORD MakeCode, Flags, Reserved, VKey;
            UINT Message;
            ULONG ExtraInformation;
        } keyboard;
    } data;
} RAWINPUT;

typedef struct {
    WORD usUsagePage, usUsage;
    DWORD dwFlags;
    HWND hwndTarget;
} RAWINPUTDEVICE;

// ---------------------------------------------------------------- audio (mmreg.h, propidl.h)
#define WAVE_FORMAT_PCM        0x0001
#define WAVE_FORMAT_IEEE_FLOAT 0x0003
#define WAVE_FORMAT_EXTENSIBLE 0xFFFE
#define SPEAKER_FRONT_LEFT     0x1
#define SPEAKER_FRONT_RIGHT    0x2
#define VT_EMPTY               0
#define VT_LPWSTR              31
#define VT_BLOB                65

typedef struct __attribute__((packed)) {
    WORD wFormatTag, nChannels;
    DWORD nSamplesPerSec, nAvgBytesPerSec;
    WORD nBlockAlign, wBitsPerSample, cbSize;
} WAVEFORMATEX;

typedef struct __attribute__((packed)) {
    WAVEFORMATEX Format;
    WORD wValidBitsPerSample;
    DWORD dwChannelMask;
    GUID SubFormat;
} WAVEFORMATEXTENSIBLE;

typedef struct {
    WORD vt, wReserved1, wReserved2, wReserved3;
    union {
        WCHAR *pwszVal;
        struct {
            ULONG cbSize;
            BYTE *pBlobData;
        } blob;
    };
} PROPVARIANT;

typedef struct {
    GUID fmtid;
    DWORD pid;
} PROPERTYKEY;

// ---------------------------------------------------------------- layout checks (x64 Windows sizes)
#define CHECK_SIZE(type, size) _Static_assert(sizeof(type) == (size), #type " must match x64 Windows")
CHECK_SIZE(GUID, 16);
CHECK_SIZE(IMAGE_DOS_HEADER, 64);
CHECK_SIZE(IMAGE_NT_HEADERS64, 264);
CHECK_SIZE(IMAGE_SECTION_HEADER, 40);
CHECK_SIZE(IMAGE_IMPORT_DESCRIPTOR, 20);
CHECK_SIZE(IMAGE_TLS_DIRECTORY64, 40);
CHECK_SIZE(OVERLAPPED, 32);
CHECK_SIZE(CRITICAL_SECTION, 40);
CHECK_SIZE(WIN32_FIND_DATAW, 592);
CHECK_SIZE(SYSTEM_INFO, 48);
CHECK_SIZE(MEMORYSTATUSEX, 64);
CHECK_SIZE(MEMORY_BASIC_INFORMATION, 48);
CHECK_SIZE(OSVERSIONINFOW, 276);
CHECK_SIZE(STARTUPINFOW, 104);
CHECK_SIZE(PROCESSOR_CORE_INFO, 48);
CHECK_SIZE(MSG, 48);
CHECK_SIZE(WNDCLASSEXW, 80);
CHECK_SIZE(CREATESTRUCTW, 80);
CHECK_SIZE(MONITORINFOEX, 104);
CHECK_SIZE(DEVMODEA, 156);
CHECK_SIZE(RAWINPUTHEADER, 24);
CHECK_SIZE(RAWINPUT, 48);
CHECK_SIZE(RAWINPUTDEVICE, 16);
CHECK_SIZE(WAVEFORMATEX, 18);
CHECK_SIZE(WAVEFORMATEXTENSIBLE, 40);
CHECK_SIZE(PROPVARIANT, 24);
CHECK_SIZE(PROPERTYKEY, 20);
_Static_assert(offsetof(OVERLAPPED, Offset) == 16, "OVERLAPPED.Offset");
_Static_assert(offsetof(DEVMODEA, dmBitsPerPel) == 104, "DEVMODEA.dmBitsPerPel");
_Static_assert(offsetof(DEVMODEA, dmDisplayFrequency) == 120, "DEVMODEA.dmDisplayFrequency");
_Static_assert(offsetof(WNDCLASSEXW, lpszClassName) == 64, "WNDCLASSEXW.lpszClassName");
_Static_assert(offsetof(CREATESTRUCTW, dwExStyle) == 72, "CREATESTRUCTW.dwExStyle");
_Static_assert(offsetof(RAWINPUT, data.mouse.lLastX) == 36, "RAWMOUSE.lLastX");
_Static_assert(offsetof(RAWINPUT, data.keyboard.VKey) == 30, "RAWKEYBOARD.VKey");
_Static_assert(offsetof(WAVEFORMATEXTENSIBLE, SubFormat) == 24, "WAVEFORMATEXTENSIBLE.SubFormat");
_Static_assert(offsetof(PROPVARIANT, blob.pBlobData) == 16, "PROPVARIANT.blob");
_Static_assert(offsetof(PROCESSOR_CORE_INFO, GroupMask) == 32, "PROCESSOR_RELATIONSHIP.GroupMask");
