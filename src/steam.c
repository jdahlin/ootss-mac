// steam_api64.dll: Steam is reported as running but offline. Interfaces are inert, no callbacks ever
// arrive, stats and achievements are unavailable, and the language is English.
#include "shim.h"

#define STEAM_APP_ID             499170
#define STEAM_ID_ANONYMOUS       76561197960265728ull // the first individual-account SteamID
#define STEAM_API_INIT_RESULT_OK 0
#define STEAM_INPUT_TYPE_UNKNOWN 0

// The versioned interface accessors only need to return distinct non-NULL pointers.
static struct {
    uint8_t apps, friends, input, user_stats, user, utils;
} g_interfaces;

SHIM(WBOOL, SteamAPI_RestartAppIfNecessary, uint32_t app_id) { return false; }

SHIM(int, SteamInternal_SteamAPI_Init, const char *versions, char *error_message) {
    LOG("Steam: reporting initialized (offline)");
    return STEAM_API_INIT_RESULT_OK;
}

SHIM(void, SteamAPI_Shutdown, void) {}
SHIM(int32_t, SteamAPI_GetHSteamPipe, void) { return 1; }

SHIM(void *, SteamAPI_SteamApps_v009, void) { return &g_interfaces.apps; }
SHIM(void *, SteamAPI_SteamFriends_v018, void) { return &g_interfaces.friends; }
SHIM(void *, SteamAPI_SteamInput_v007, void) { return &g_interfaces.input; }
SHIM(void *, SteamAPI_SteamUserStats_v013, void) { return &g_interfaces.user_stats; }
SHIM(void *, SteamAPI_SteamUser_v023, void) { return &g_interfaces.user; }
SHIM(void *, SteamAPI_SteamUtils_v011, void) { return &g_interfaces.utils; }

// Callbacks
SHIM(void, SteamAPI_ManualDispatch_Init, void) {}
SHIM(void, SteamAPI_ManualDispatch_RunFrame, int32_t pipe) {}
SHIM(WBOOL, SteamAPI_ManualDispatch_GetNextCallback, int32_t pipe, void *message) { return false; }
SHIM(void, SteamAPI_ManualDispatch_FreeLastCallback, int32_t pipe) {}

SHIM(WBOOL, SteamAPI_ManualDispatch_GetAPICallResult, int32_t pipe, uint64_t call, void *result, int size, int expected,
     WBOOL *failed) {
    if (failed) *failed = true;
    return false;
}

// ISteamApps
SHIM(const char *, SteamAPI_ISteamApps_GetCurrentGameLanguage, void *self) { return "english"; }
SHIM(const char *, SteamAPI_ISteamApps_GetAvailableGameLanguages, void *self) { return "english"; }
SHIM(int, SteamAPI_ISteamApps_GetAppBuildId, void *self) { return 0; }

SHIM(WBOOL, SteamAPI_ISteamApps_GetCurrentBetaName, void *self, char *name, int size) {
    if (name && size) name[0] = 0;
    return false;
}

// ISteamUtils, ISteamUser
SHIM(uint32_t, SteamAPI_ISteamUtils_GetAppID, void *self) { return STEAM_APP_ID; }
SHIM(WBOOL, SteamAPI_ISteamUtils_IsRunningOnSteamHardware, void *self) { return false; }
SHIM(uint64_t, SteamAPI_ISteamUser_GetSteamID, void *self) { return STEAM_ID_ANONYMOUS; }

// ISteamUserStats
SHIM(WBOOL, SteamAPI_ISteamUserStats_RequestUserStats, void *self, uint64_t steam_id) { return false; }
SHIM(WBOOL, SteamAPI_ISteamUserStats_SetAchievement, void *self, const char *name) { return false; }
SHIM(WBOOL, SteamAPI_ISteamUserStats_StoreStats, void *self) { return false; }

SHIM(WBOOL, SteamAPI_ISteamUserStats_GetAchievement, void *self, const char *name, WBOOL *achieved) {
    if (achieved) *achieved = false;
    return false;
}

// ISteamInput: no controllers through Steam
SHIM(WBOOL, SteamAPI_ISteamInput_Init, void *self, WBOOL explicitly_call_run_frame) { return false; }
SHIM(uint64_t, SteamAPI_ISteamInput_GetControllerForGamepadIndex, void *self, int index) { return 0; }
SHIM(int, SteamAPI_ISteamInput_GetInputTypeForHandle, void *self, uint64_t handle) { return STEAM_INPUT_TYPE_UNKNOWN; }
