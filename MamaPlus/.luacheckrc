-- luacheck config for MamaPlus (WoW: Forever, Lua 5.1), same shape as TeamWatch's.
std = "lua51"
max_line_length = false
exclude_files = { "tests/" }
-- "local addonName, ns = ..." is required on every file even when unused.
unused_args = false
ignore = { "211/addonName", "212/self" }

-- Globals MamaPlus writes.
globals = {
  "MamaPlusDB", "SLASH_MAMAPLUS1", "SlashCmdList",
  "BINDING_HEADER_MAMAPLUS",
  "BINDING_NAME_CLICK MamaPlusTargetLead:LeftButton",
  "BINDING_NAME_CLICK MamaPlusTarget1:LeftButton", "BINDING_NAME_CLICK MamaPlusTarget2:LeftButton",
  "BINDING_NAME_CLICK MamaPlusTarget3:LeftButton", "BINDING_NAME_CLICK MamaPlusTarget4:LeftButton",
  "BINDING_NAME_CLICK MamaPlusTarget5:LeftButton", "BINDING_NAME_CLICK MamaPlusStopFollow:LeftButton",
}

-- WoW API and Mama globals MamaPlus reads. Anything not listed is reported.
read_globals = {
  "MamaForever", "MamaForeverStatus",
  "C_AddOns", "C_ChatInfo", "C_ClassColor", "C_Container", "C_DeathInfo", "C_EventUtils", "C_GameRules",
  "C_Item", "C_Map", "C_QuestLog", "C_Secrets", "C_SettingsUtil", "C_Spell", "C_SpellBook", "C_Timer",
  "CreateFrame", "Enum", "GetBuildInfo", "GetInventoryItemDurability", "GetNumSubgroupMembers", "GetTime",
  "GetServerTime", "GetUnitSpeed", "InCombatLockdown", "IsInGroup", "IsInRaid", "IsPlayerMoving", "PlaySound",
  "RAID_CLASS_COLORS", "RaidNotice_AddMessage", "RaidWarningFrame", "SOUNDKIT", "Settings", "UIParent",
  "UnitCastingInfo", "UnitChannelInfo", "UnitClass", "UnitExists", "UnitGUID", "UnitHealth", "UnitName",
  "UnitIsDeadOrGhost", "UnitIsGhost", "UnitIsDead", "UnitOnTaxi", "UnitAffectingCombat", "UnitIsAFK",
  "UnitIsConnected", "UnitLevel", "UnitXP", "UnitXPMax", "GetXPExhaustion", "IsResting", "GetZoneText",
  "GetSubZoneText", "GetRealZoneText", "CheckInteractDistance", "UnitIsGroupLeader", "WOW_PROJECT_ID",
  "LE_EXPANSION_LEVEL_CURRENT", "date", "issecretvalue", "strsplit", "time", "wipe", "ChatTypeInfo",
  "GameTooltip", "ItemRefTooltip", "TooltipDataProcessor", "TooltipUtil", "geterrorhandler", "hooksecurefunc",
  "GetBindingKey", "FlashClientIcon", "RepopMe", "RetrieveCorpse", "AcceptResurrect", "DeclineResurrect",
  "GetCorpseRecoveryDelay", "GetReleaseTimeRemaining", "ResurrectGetOfferer", "NUM_BAG_SLOTS",
  "NUM_REAGENTBAG_SLOTS", "NUM_TOTAL_EQUIPPED_BAG_SLOTS", "UISpecialFrames", "tinsert", "GameFontHighlightSmall",
  "GameFontNormal", "GameFontHighlight", "ChatFontNormal", "UNKNOWN", "IsModifierKeyDown",
}
