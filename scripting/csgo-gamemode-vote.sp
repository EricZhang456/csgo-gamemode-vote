#include <sourcemod>
#include <sdktools_gamerules>
#include <cstrike>
#include <clientprefs>
#include <json>

// 5 mb of stack/heap so we don't run out of heap when parsing the config
#pragma dynamic 1310720

#define BASE_STR_LEN 256

#define ID_PROPERTY_NAME "id"
#define TITLE_PROPERTY_NAME "title"
#define MAPGROUP_PROPERTY_NAME "mapgroup"
#define MAPLIST_PROPERTY_NAME "maplist"
#define GAMETYPE_PROPERTY_NAME "game_type"
#define GAMEMODE_PROPERTY_NAME "game_mode"
#define SKIRMISH_PROPERTY_NAME "skirmish_id"
#define GAME_MODE_FLAGS_PROPERTY_NAME "game_mode_flags"

#define PLUGIN_VERSION "1.2.3"

public Plugin myinfo = {
    name = "CSGO Game Mode Vote",
    author = "Eric Zhang",
    description = "Vote for CSGO game mode.",
    version = PLUGIN_VERSION,
    url = "https://ericaftereric.top"
};

char currentModeId[BASE_STR_LEN];
int voteCooldownExpireTime;
bool voteInCooldown;

JSON_Array gameModes;

Cookie cookieNoHintWhenEnter;

ConVar cvarPluginVersion;
ConVar cvarGameMode;
ConVar cvarGameType;
ConVar cvarGameModeFlags;
ConVar cvarSkirmishId;
ConVar cvarWarGameModeNumModes;
ConVar cvarWarGameModes;
ConVar cvarConfigPath;
ConVar cvarStartupMode;
ConVar cvarShowHintByDefault;
ConVar cvarVoteAllowSpec;
ConVar cvarVoteAllowWarmup;
ConVar cvarVoteCooldown;
ConVar cvarVoteTimer;
ConVar cvarVoteDuration;
ConVar cvarVotePercent;
ConVar cvarVoteAllowSameMode;
ConVar cvarReloadOnMapLoad;
ConVar cvarVoteAlternativeHint;

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max) {
    char game[PLATFORM_MAX_PATH];
    GetGameFolderName(game, sizeof(game));
    if (!StrEqual(game, "csgo")) {
        strcopy(error, err_max, "This plugin only works on Counter-Strike: Global Offensive");
        return APLRes_SilentFailure;
    }
    return APLRes_Success;
}

public void OnPluginStart() {
    LoadTranslations("common.phrases");
    LoadTranslations("basevotes.phrases");
    LoadTranslations("csgo-gamemode-vote.phrases");

    cvarGameMode = FindConVar("game_mode");
    cvarGameType = FindConVar("game_type");
    cvarGameModeFlags = FindConVar("sv_game_mode_flags");
    cvarSkirmishId = FindConVar("sv_skirmish_id");
    cvarWarGameModeNumModes = FindConVar("mp_endmatch_votenextmap_wargames_nummodes");
    cvarWarGameModes = FindConVar("mp_endmatch_votenextmap_wargames_modes");
    cvarVoteAllowSpec = FindConVar("sv_vote_allow_spectators");
    cvarVoteAllowWarmup = FindConVar("sv_vote_allow_in_warmup");
    
    cvarWarGameModeNumModes.IntValue = 0;
    cvarWarGameModes.SetString("0");

    cvarWarGameModeNumModes.AddChangeHook(OnVoteModeCvarChanged);
    cvarWarGameModes.AddChangeHook(OnVoteModeCvarChanged);

    cvarPluginVersion = CreateConVar("sm_game_mode_vote_version", PLUGIN_VERSION, "Version of the CSGO game mode vote plugin.", FCVAR_DONTRECORD | FCVAR_NOTIFY);
    cvarConfigPath = CreateConVar("sm_game_mode_vote_config_path", "configs/gamemode-vote.json", "Path to the config file relative to the SourceMod root directory");
    cvarStartupMode = CreateConVar("sm_game_mode_startup_mode", "", "Game mode server should start at.");
    cvarShowHintByDefault = CreateConVar("sm_game_mode_vote_show_hint_default", "1", "Tell clients they can vote for game mode by default.");
    cvarVoteDuration = CreateConVar("sm_game_mode_vote_duration", "30", "How long should the game mode vote last?", _, true, 0.0);
    cvarVoteCooldown = CreateConVar("sm_game_mode_vote_cooldown", "300", "Minimum time before another game mode vote can occur (in seconds).", _, true, 0.0);
    cvarVoteTimer = CreateConVar("sm_game_mode_vote_timer", "5.0", "How long should the plugin wait before the game mode is applied when a vote is successful?", _, true, 0.0);
    cvarVotePercent = CreateConVar("sm_game_mode_vote_percent", "0.6", "How many players are required for the vote to pass?", _, true, 0.0, true, 1.0);
    cvarVoteAllowSameMode = CreateConVar("sm_game_mode_vote_allow_same_vote", "0", "Allow clients to vote for the same game mode.");
    cvarReloadOnMapLoad = CreateConVar("sm_game_mode_reload_on_map_load", "0", "Reload the config on every map load.");
    cvarVoteAlternativeHint = CreateConVar("sm_game_mode_print_alt_hint", "0", "Prints an alternative hint message to clients that they can vote for a new map");

    cvarPluginVersion.AddChangeHook(OnVersionCvarChanged);

    cookieNoHintWhenEnter = new Cookie("Show game mode vote hint", "Toggle the game mode vote hint when you enter the server.", CookieAccess_Public);
    cookieNoHintWhenEnter.SetPrefabMenu(CookieMenu_OnOff_Int, "Show game mode vote hint", OnHintCookieMenu);

    RegConsoleCmd("sm_votemode", Cmd_VoteMode, "Vote for the next game mode.");
    RegAdminCmd("sm_changemode", Cmd_ChangeMode, ADMFLAG_CHANGEMAP, "Change the current game mode.");
    RegAdminCmd("sm_reload_gamemode_vote_config", Cmd_ReloadModeConfig, ADMFLAG_CONFIG, "Reload config for game mode vote.");

    HookEvent("player_spawn", Event_PlayerSpawn);

    AutoExecConfig();
}

public void OnMapStart() {
    voteInCooldown = false;
}

public void OnConfigsExecuted() {
    if (gameModes == null || gameModes.Length == 0 || cvarReloadOnMapLoad.BoolValue) {
        LoadGameModeVoteConfig();
    }
    if (!strlen(currentModeId)) {
        char startupMode[BASE_STR_LEN];
        cvarStartupMode.GetString(startupMode, sizeof(startupMode));
        JSON_Object mode = GetGameModeFromId(startupMode);
        if (mode == null) {
            mode = gameModes.GetObject(0);
            char modeId[BASE_STR_LEN];
            mode.GetString(ID_PROPERTY_NAME, modeId, sizeof(modeId));
            LogMessage("Warning: no startup game mode specified or startup game mode doesn't exist. Starting the first game mode in config (%s)...", modeId);
        }
        LogMessage("Starting startup game mode.");
        ApplyGameModeFirstMap(mode);
    } else {
        LogMessage("Current game mode id: %s", currentModeId);
    }
}

public void OnAllPluginsLoaded() {
    if (FindPluginByFile("mapchooser.smx") != null) {
        LogMessage("Unloading mapchooser to prevent conflicts with the mapgroup system...");
        ServerCommand("sm plugins unload mapchooser");
    }
    if (FindPluginByFile("rockthevote.smx") != null) {
        LogMessage("Unloading rockthevote to prevent conflicts with the mapgroup system...");
        ServerCommand("sm plugins unload rockthevote");
    }
    if (FindPluginByFile("nominations.smx") != null) {
        LogMessage("Unloading nominations to prevent conflicts with the mapgroup system...");
        ServerCommand("sm plugins unload nominations");
    }
    if (FindPluginByFile("randomcycle.smx") != null) {
        LogMessage("Unloading randomcycle to prevent conflicts with the mapgroup system...");
        ServerCommand("sm plugins unload randomcycle");
    }
    if (FindPluginByFile("nextmap.smx") != null) {
        LogMessage("Unloading nextmap to prevent conflicts with the mapgroup system...");
        ServerCommand("sm plugins unload nextmap");
    }
}

public void OnVoteModeCvarChanged(ConVar convar, const char[] oldValue, const char[] newValue) {
    char name[BASE_STR_LEN];
    convar.GetName(name, sizeof(name));
    LogMessage("Resetting %s to 0 to avoid conflicts with the game mode vote plugin...", name);
    convar.SetString("0");
}

public void OnVersionCvarChanged(ConVar convar, const char[] oldValue, const char[] newValue) {
    convar.SetString(PLUGIN_VERSION);
}

public void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast) {
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (!IsValidClient(client)) {
        return;
    }
    if (cookieNoHintWhenEnter.GetInt(client, cvarShowHintByDefault.BoolValue ? 1 : 0)) {
        PrintToChat(client, "%t", cvarVoteAlternativeHint.BoolValue ? "CSGO_GAMEMODE_VOTE_HINT_MAP" : "CSGO_GAMEMODE_VOTE_HINT");
    }
}

public void OnHintCookieMenu(int client, CookieMenuAction action, any info, char[] buffer, int maxlen) {
    if (action == CookieMenuAction_DisplayOption) {
        Format(buffer, maxlen, "%T", "CSGO_GAMEMODE_VOTE_HINT_TOGGLE", client);
    }
}

void LoadGameModeVoteConfig() {
    LogMessage("Reloading game mode config...");
    if (gameModes != null) {
        json_cleanup_and_delete(gameModes);
    }
    char basePath[PLATFORM_MAX_PATH], path[PLATFORM_MAX_PATH];
    cvarConfigPath.GetString(basePath, sizeof(basePath));
    BuildPath(Path_SM, path, sizeof(path), basePath);
    if (!FileExists(path)) {
        SetFailState("Config file for game mode vote doesn't exist: %s", path);
    }
    JSON_Array config = view_as<JSON_Array>(json_read_from_file(path));
    if (config == null) {
        char error[BASE_STR_LEN];
        if (!json_get_last_error(error, sizeof(error))) {
            SetFailState("Error occurred when parsing config file for game mode vote but I don't know what went wrong!!!");
        }
        SetFailState("Error occurred while parsing game mode vote config: %s", error);
    }

    if (config.Length == 0) {
        SetFailState("Error occurred while parsing game mode vote config: config is empty");
    }
    for (int i = 0; i < config.Length; i++) {
        if (config.GetType(i) != JSON_Type_Object) {
            SetFailState("Error occurred while parsing game mode vote config: item at index %d is not of type object", i);
        }
        char error[BASE_STR_LEN];
        if (!ValidateGameModeEntry(config.GetObject(i), config, error, sizeof(error))) {
            SetFailState("Error occurred while parsing game mode vote config: item at index %d has this error: %s", i, error);
        }
    }

    gameModes = view_as<JSON_Array>(json_copy_deep(config));
    json_cleanup_and_delete(config);
}

bool ValidateGameModeEntry(JSON_Object obj, JSON_Array allModes, char[] error, int errorLen) {
    if (obj == null) {
        strcopy(error, errorLen, "object is null");
        return false;
    }
    if (allModes == null) {
        strcopy(error, errorLen, "all mode array is null");
        return false;
    }

    if (!obj.HasKey(ID_PROPERTY_NAME) || obj.GetType(ID_PROPERTY_NAME) != JSON_Type_String) {
        strcopy(error, errorLen, "id is invalid or missing");
        return false;
    }
    if (!obj.HasKey(TITLE_PROPERTY_NAME) || obj.GetType(TITLE_PROPERTY_NAME) != JSON_Type_String) {
        strcopy(error, errorLen, "title is inavlid or missing");
        return false;
    }
    if (!obj.HasKey(MAPGROUP_PROPERTY_NAME) || obj.GetType(MAPGROUP_PROPERTY_NAME) != JSON_Type_String) {
        strcopy(error, errorLen, "mapgroup is invalid or missing");
        return false;
    }
    if (!obj.HasKey(MAPLIST_PROPERTY_NAME) || obj.GetType(MAPLIST_PROPERTY_NAME) != JSON_Type_Object) {
        strcopy(error, errorLen, "maplist is invalid or missing");
        return false;
    }
    if (!obj.HasKey(GAMETYPE_PROPERTY_NAME) || obj.GetType(GAMETYPE_PROPERTY_NAME) != JSON_Type_Int) {
        strcopy(error, errorLen, "game_type is invalid or missing");
        return false;
    }
    if (!obj.HasKey(GAMEMODE_PROPERTY_NAME) || obj.GetType(GAMEMODE_PROPERTY_NAME) != JSON_Type_Int) {
        strcopy(error, errorLen, "game_mode is invalid or missing");
        return false;
    }

    if (obj.HasKey(SKIRMISH_PROPERTY_NAME) && obj.GetType(SKIRMISH_PROPERTY_NAME) != JSON_Type_Int) {
        strcopy(error, errorLen, "skirmish_id is invalid");
        return false;
    }
    if (obj.HasKey(GAME_MODE_FLAGS_PROPERTY_NAME) && obj.GetType(GAME_MODE_FLAGS_PROPERTY_NAME) != JSON_Type_Int) {
        strcopy(error, errorLen, "game_mode_flags is invalid");
        return false;
    }

    char objId[BASE_STR_LEN], objTitle[BASE_STR_LEN];
    obj.GetString(ID_PROPERTY_NAME, objId, sizeof(objId));
    obj.GetString(TITLE_PROPERTY_NAME, objTitle, sizeof(objTitle));
    if (StrEqual(objId, "_admin")) {
        strcopy(error, errorLen, "id cannot be called _admin as it is reserved");
        return false;
    }
    if (StrContains(objId, ";") != -1) {
        strcopy(error, errorLen, "id cannot contain semicolons");
        return false;
    }
    if (StrContains(objTitle, ";") != -1) {
        strcopy(error, errorLen, "title cannot contain semicolons");
        return false;
    }
    JSON_Array maplist = view_as<JSON_Array>(obj.GetObject(MAPLIST_PROPERTY_NAME));
    if (maplist == null || maplist.Length == 0) {
        strcopy(error, errorLen, "maplist is empty");
        return false;
    }

    int duplicateCount = 0;
    for (int i = 0; i < allModes.Length; i++) {
        JSON_Object current = allModes.GetObject(i);
        if (current == null) {
            strcopy(error, errorLen, "invalid type while iterating through all game modes. if the laws of physics don't apply, god help you.");
            return false;
        }
        char currentId[BASE_STR_LEN];
        if (!current.GetString(ID_PROPERTY_NAME, currentId, sizeof(currentId))) {
            strcopy(error, errorLen, "invalid id encountered while iterating through all game modes, please help");
            return false;
        }
        if (StrEqual(objId, currentId)) {
            duplicateCount++;
        }
    }

    if (duplicateCount > 1) {
        Format(error, errorLen, "duplicate id: %s", objId);
        return false;
    }

    return true;
}

JSON_Object GetGameModeFromId(const char[] id) {
    if (!strlen(id)) {
        return null;
    }
    for (int i = 0; i < gameModes.Length; i++) {
        JSON_Object current = gameModes.GetObject(i);
        char currentId[BASE_STR_LEN];
        current.GetString(ID_PROPERTY_NAME, currentId, sizeof(currentId));
        if (StrEqual(currentId, id)) {
            return current;
        }
    }
    return null;
}

void ApplyGameMode(JSON_Object obj, const char[] map) {
    if (obj == null) {
        SetFailState("null passed to ApplyGameMode");
        return;
    }
    char mapgroup[BASE_STR_LEN], id[BASE_STR_LEN];
    int gameType = obj.GetInt(GAMETYPE_PROPERTY_NAME);
    int gameMode = obj.GetInt(GAMEMODE_PROPERTY_NAME);
    obj.GetString(ID_PROPERTY_NAME, id, sizeof(id));
    obj.GetString(MAPGROUP_PROPERTY_NAME, mapgroup, sizeof(mapgroup));
    int skirmishId = 0;
    int gameModeFlags = 0;
    if (obj.HasKey(SKIRMISH_PROPERTY_NAME)) {
        skirmishId = obj.GetInt(SKIRMISH_PROPERTY_NAME);
    }
    if (obj.HasKey(GAME_MODE_FLAGS_PROPERTY_NAME)) {
        gameModeFlags = obj.GetInt(GAME_MODE_FLAGS_PROPERTY_NAME);
    }
    cvarGameType.IntValue = gameType;
    cvarGameMode.IntValue = gameMode;
    cvarSkirmishId.IntValue = skirmishId;
    cvarGameModeFlags.IntValue = gameModeFlags;
    strcopy(currentModeId, sizeof(currentModeId), id);
    ServerCommand("mapgroup %s", mapgroup);
    ServerCommand("changelevel %s", map);
}

void ApplyGameModeFirstMap(JSON_Object obj) {
    if (obj == null) {
        SetFailState("null passed to ApplyGameModeFirstMap");
        return;
    }
    JSON_Array maplist = view_as<JSON_Array>(obj.GetObject(MAPLIST_PROPERTY_NAME));
    char map[BASE_STR_LEN];
    maplist.GetString(0, map, sizeof(map));
    ApplyGameMode(obj, map);
}

void StartGameModeVote(JSON_Object obj, const char[] map, int client) {
    if (!CheckCanStartVote(client)) {
        return;
    }
    Menu vote = new Menu(Menu_GameModeVoteHandler, MENU_ACTIONS_ALL);
    vote.ExitButton = false;
    vote.ExitBackButton = false;
    vote.NoVoteButton = false;
    char modeId[BASE_STR_LEN], modeTitle[BASE_STR_LEN];
    obj.GetString(ID_PROPERTY_NAME, modeId, sizeof(modeId));
    obj.GetString(TITLE_PROPERTY_NAME, modeTitle, sizeof(modeTitle));
    vote.SetTitle("CSGO_GAMEMODE_VOTE_TITLE");
    vote.AddItem(modeTitle, "CSGO_GAMEMODE_VOTE_MODE", ITEMDRAW_DISABLED);
    vote.AddItem(map, "CSGO_GAMEMODE_VOTE_MAP", ITEMDRAW_DISABLED),
    vote.AddItem(modeId, modeId, ITEMDRAW_IGNORE);
    vote.AddItem("yes", "Yes");
    vote.AddItem("no", "No");
    vote.DisplayVoteToAll(cvarVoteDuration.IntValue);

    voteInCooldown = true;
    voteCooldownExpireTime = GetTime() + RoundToNearest(cvarVoteCooldown.FloatValue);
    CreateTimer(cvarVoteCooldown.FloatValue, Timer_OnVoteCooldownTimerEnd, _, TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_OnVoteCooldownTimerEnd(Handle timer) {
    voteInCooldown = false;
    return Plugin_Continue;
}

void ShowModeSelectMenu(int client, bool admin = false) {
    char menuTitle[BASE_STR_LEN];
    Format(menuTitle, sizeof(menuTitle), "%T", "CSGO_GAMEMODE_MENU_TITLE", client);
    Menu gameModeSelectMenu = new Menu(Menu_ModeSelectMenuHandler);
    gameModeSelectMenu.SetTitle(menuTitle);
    if (admin) {
        gameModeSelectMenu.AddItem("_admin", "true", ITEMDRAW_IGNORE);
    }
    for (int i = 0; i < gameModes.Length; i++) {
        char id[BASE_STR_LEN], titlePre[BASE_STR_LEN], title[BASE_STR_LEN];
        int style = ITEMDRAW_DEFAULT;
        JSON_Object obj = gameModes.GetObject(i);
        obj.GetString(ID_PROPERTY_NAME, id, sizeof(id));
        obj.GetString(TITLE_PROPERTY_NAME, titlePre, sizeof(titlePre));
        if (StrEqual(id, currentModeId) && !cvarVoteAllowSameMode.BoolValue) {
            Format(title, sizeof(title), "%T", "CSGO_GAMEMODE_MENU_SELECTED", client, titlePre);
            style = ITEMDRAW_DISABLED;
        } else {
            strcopy(title, sizeof(title), titlePre);
        }
        gameModeSelectMenu.AddItem(id, title, style);
    }
    gameModeSelectMenu.Display(client, MENU_TIME_FOREVER);
}

void ShowMapSelectMenu(int client, JSON_Object mode, bool admin = false) {
    char currentMap[BASE_STR_LEN], menuTitle[BASE_STR_LEN], modeId[BASE_STR_LEN];
    JSON_Array maplist = view_as<JSON_Array>(mode.GetObject(MAPLIST_PROPERTY_NAME));
    mode.GetString(ID_PROPERTY_NAME, modeId, sizeof(modeId));
    Menu mapSelectMenu = new Menu(Menu_MapSelectMenuHandler, MENU_ACTIONS_DEFAULT | MenuAction_Display);
    if (admin) {
        mapSelectMenu.AddItem("_admin", "true", ITEMDRAW_IGNORE);
    }
    Format(menuTitle, sizeof(menuTitle), "%T", "CSGO_GAMEMODE_MAP_MENU_TITLE", client);
    mapSelectMenu.SetTitle(menuTitle);
    GetCurrentMap(currentMap, sizeof(currentMap));
    for (int i = 0; i < maplist.Length; i++) {
        char map[BASE_STR_LEN], itemId[BASE_STR_LEN];
        maplist.GetString(i, map, sizeof(map));
        int style = ITEMDRAW_DEFAULT;
        if (StrEqual(modeId, currentModeId) && StrEqual(map, currentMap)) {
            style = ITEMDRAW_DISABLED;
            Format(map, sizeof(map), "%T", "CSGO_GAMEMODE_MENU_CURRENT_MAP", client, map);
        }
        Format(itemId, sizeof(itemId), "%s;%s", modeId, map);
        mapSelectMenu.AddItem(itemId, map, style);
    }
    mapSelectMenu.ExitBackButton = true;
    mapSelectMenu.Display(client, MENU_TIME_FOREVER);
}

bool CheckCanStartVote(int client) {
    if (!IsValidClient(client)) {
        return false;
    }

    if (!cvarVoteAllowSpec.BoolValue && GetClientTeam(client) == CS_TEAM_SPECTATOR) {
        PrintToChat(client, "%t", "CSGO_GAMEMODE_VOTE_SPEC");
        return false;
    }

    if (GameRules_GetProp("m_bWarmupPeriod") == 1 && !cvarVoteAllowWarmup.BoolValue) {
        PrintToChat(client, "%t", "CSGO_GAMEMODE_VOTE_WARMUP");
        return false;
    }

    if (IsVoteInProgress()) {
        PrintToChat(client, "%t", "CSGO_GAMEMODE_VOTE_IN_PROGRESS");
        return false;
    }

    int voteDelay = CheckVoteDelay();
    if (voteInCooldown || voteDelay) {
        PrintToChat(client, "%t", "CSGO_GAMEMODE_VOTE_COOLDOWN", voteCooldownExpireTime - GetTime() + voteDelay);
        return false;
    }

    return true;
}

public Action Cmd_VoteMode(int client, int args) {
    if (!CheckCanStartVote(client)) {
        return Plugin_Handled;
    }

    ShowModeSelectMenu(client);
    return Plugin_Handled;
}

public Action Cmd_ChangeMode(int client, int args) {
    if (!IsValidClient(client)) {
        return Plugin_Handled;
    }

    ShowModeSelectMenu(client, true);    
    return Plugin_Handled;
}

public void Menu_ModeSelectMenuHandler(Menu menu, MenuAction action, int param1, int param2) {
    switch (action) {
        case MenuAction_Select: {
            char selectedId[BASE_STR_LEN];
            menu.GetItem(param2, selectedId, sizeof(selectedId));
            JSON_Object selectedMode = GetGameModeFromId(selectedId);
            if (selectedMode == null) {
                SetFailState("Selected game mode is null, something has gone horribly wrong.");
            }
            bool admin = false;
            char adminStr[BASE_STR_LEN];
            menu.GetItem(0, adminStr, sizeof(adminStr));
            if (StrEqual(adminStr, "_admin")) {
                admin = true;
            }
            ShowMapSelectMenu(param1, selectedMode, admin);
        }
        case MenuAction_End: {
            delete menu;
        }
    }
}

public int Menu_MapSelectMenuHandler(Menu menu, MenuAction action, int param1, int param2) {
    switch (action) {
        case MenuAction_Select: {
            char id[BASE_STR_LEN], map[BASE_STR_LEN], item[BASE_STR_LEN];
            menu.GetItem(param2, item, sizeof(item));
            SplitStringAtSemicolon(item, id, sizeof(id), map, sizeof(map));
            char admin[BASE_STR_LEN];
            menu.GetItem(0, admin, sizeof(admin));
            if (StrEqual(admin, "_admin")) {
                ScheduleGameModeApply(id, map);
            } else {
                JSON_Object selectedMode = GetGameModeFromId(id);
                if (selectedMode == null) {
                    SetFailState("Selected game mode is null, something has gone horribly wrong.");
                }
                StartGameModeVote(selectedMode, map, param1);
            }
        }
        case MenuAction_Cancel: {
            if (param2 == MenuCancel_ExitBack) {
                ShowModeSelectMenu(param1);
            }
        }
        case MenuAction_End: {
            delete menu;
        }
    }
    return 0;
}

public int Menu_GameModeVoteHandler(Menu menu, MenuAction action, int param1, int param2) {
    switch (action) {
        case MenuAction_Display: {
            char title[64], targetStr[BASE_STR_LEN];
            menu.GetTitle(title, sizeof(title));
            Format(targetStr, sizeof(targetStr), "%T", title, param1);
            Panel panel = view_as<Panel>(param2);
            panel.SetTitle(targetStr);
        }
        case MenuAction_DrawItem: {
            char info[64], display[64];
            menu.GetItem(param2, info, sizeof(info), _, display, sizeof(display));
            if (StrEqual(info, "yes") || StrEqual(info, "no")) {
                return ITEMDRAW_DEFAULT;
            } else if (StrEqual(display, "CSGO_GAMEMODE_VOTE_MODE") || StrEqual(display, "CSGO_GAMEMODE_VOTE_MAP")) {
                return ITEMDRAW_DISABLED;
            }
            return ITEMDRAW_SPACER;
        }
        case MenuAction_DisplayItem: {
            char info[BASE_STR_LEN], display[BASE_STR_LEN];
            menu.GetItem(param2, info, sizeof(info), _, display, sizeof(display));
            if (StrEqual(info, "yes") || StrEqual(info, "no")) {
                char targetStr[BASE_STR_LEN];
                Format(targetStr, sizeof(targetStr), "%T", display, param1);
                return RedrawMenuItem(targetStr);
            }
            if (StrEqual(display, "CSGO_GAMEMODE_VOTE_MODE") || StrEqual(display, "CSGO_GAMEMODE_VOTE_MAP")) {
                char targetStr[BASE_STR_LEN];
                Format(targetStr, sizeof(targetStr), "%T", display, param1, info);
                return RedrawMenuItem(targetStr);
            }
        }
        case MenuAction_VoteCancel: {
            PrintToChatAll("[SM] %t", "No Votes Cast");
        }
        case MenuAction_VoteEnd: {
            char item[BASE_STR_LEN];
            float percent, limit = cvarVotePercent.FloatValue;
            int votes, totalVotes;

            GetMenuVoteInfo(param2, votes, totalVotes);
            menu.GetItem(param1, item, sizeof(item));

            percent = float(votes) / float(totalVotes);
            if (FloatCompare(percent, limit) >= 0 && StrEqual(item, "yes")) {
                char modeTitle[BASE_STR_LEN], map[BASE_STR_LEN], modeId[BASE_STR_LEN];
                menu.GetItem(0, modeTitle, sizeof(modeTitle));
                menu.GetItem(1, map, sizeof(map));
                menu.GetItem(2, modeId, sizeof(modeId));
                PrintToChatAll("[SM] %t", "Vote Successful", RoundToNearest(100.0 * percent), totalVotes);
                ScheduleGameModeApply(modeId, map);
            } else {
                PrintToChatAll("[SM] %t", "Vote Failed", RoundToNearest(100.0 * limit),
                    RoundToNearest(100.0 * (1.0 - percent)), totalVotes);
            }
        }
        case MenuAction_End: {
            delete menu;
        }
    }
    return 0;
}

public Action Cmd_ReloadModeConfig(int client, int args) {
    LoadGameModeVoteConfig();
    return Plugin_Handled;
}

void ScheduleGameModeApply(const char[] id, const char[] map) {
    JSON_Object mode = GetGameModeFromId(id);
    char modeTitle[BASE_STR_LEN];
    mode.GetString(TITLE_PROPERTY_NAME, modeTitle, sizeof(modeTitle));
    PrintToChatAll("[SM] %t", "CSGO_GAMEMODE_VOTE_SUCCESS", modeTitle, map);
    DataPack pack;
    CreateDataTimer(cvarVoteTimer.FloatValue, Timer_ScheduleTimerHandler, pack);
    pack.WriteString(id);
    pack.WriteString(map);
}

public Action Timer_ScheduleTimerHandler(Handle timer, DataPack pack) {
    char id[BASE_STR_LEN], map[BASE_STR_LEN];
    pack.Reset();
    pack.ReadString(id, sizeof(id));
    pack.ReadString(map, sizeof(map));
    JSON_Object mode = GetGameModeFromId(id);
    if (mode == null) {
        SetFailState("Selected game mode is null, something has gone horribly wrong");
    }
    ApplyGameMode(mode, map);
    return Plugin_Continue;
}

void SplitStringAtSemicolon(const char[] source, char[] first, int firstLen, char[] second, int secondLen) {
    char strings[2][BASE_STR_LEN];
    ExplodeString(source, ";", strings, 2, BASE_STR_LEN);
    strcopy(first, firstLen, strings[0]);
    strcopy(second, secondLen, strings[1]);    
}

bool IsValidClient(int client) {
    return !(IsFakeClient(client) || IsClientSourceTV(client) || IsClientReplay(client));
}
