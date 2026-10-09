-- Minimal WoW API plus a fake Mama-forever for running MamaPlus under plain
-- Lua 5.1. Each test file runs in a fresh interpreter: dofile("tests/mock.lua").
-- Module-specific APIs go in the test file, before LoadModule, like
-- TeamWatch's tests do.
local ADDON = (TEST_ADDON_DIR or "./")
local allFrames = {}
-- The clock counts ticks of 0.05 s as an integer, so Step() never drifts:
-- GetTime() is exact at every tick, every delay the addon uses (0.1, 0.25,
-- 0.5, 1.1 s) lands on a tick, and "75 s later" is exactly 75.
local TICKS_PER_SEC = 20
local nowTicks = 1000 * TICKS_PER_SEC
local EPS = 1e-6   -- GetTime() + 0.1 and the tick's own GetTime() can differ by an ulp

function GetTime() return nowTicks / TICKS_PER_SEC end
local function Ticks(sec) return math.floor(sec * TICKS_PER_SEC + 0.5) end
function GetServerTime() return 1700000000 + math.floor(GetTime()) end
function time() return 1700000000 + math.floor(GetTime()) end
date = os.date
-- Errors raised inside event handlers, listeners, ops and commands land here;
-- tests/run.sh fails a test that ends with any (a test may override this).
handlerErrors = {}
function geterrorhandler() return function(err) handlerErrors[#handlerErrors+1] = tostring(err); print("HANDLER ERROR: " .. tostring(err)) end end
function wipe(t) for k in pairs(t) do t[k] = nil end return t end
tinsert = table.insert
UISpecialFrames = {}
function strsplit(d, s, n)
  local out, pos = {}, 1
  while true do
    if n and #out == n - 1 then out[#out+1] = s:sub(pos) break end
    local a, b = s:find(d, pos, true)
    if not a then out[#out+1] = s:sub(pos) break end
    out[#out+1] = s:sub(pos, a-1); pos = b + 1
  end
  return unpack(out)
end

-- Secret values: any value registered here answers issecretvalue. MakeSecret
-- gives a fresh sentinel and type() reports the kind asked for, as the client
-- reports a secret's real type (a "boolean" sentinel is a unique table
-- underneath, so the weak-key lookup still works). A Lua stand-in cannot
-- raise on "== nil", "if v then" or a table key the way the client does:
-- that check order is guarded by the grep in tests/run.sh and by the
-- in-game probe (/mama plus probe core), not by this file.
local secrets = setmetatable({}, { __mode = "k" })   -- sentinel -> kind
local secretSeq = 0
function issecretvalue(v) return v ~= nil and secrets[v] ~= nil end
function MakeSecret(kind)
  secretSeq = secretSeq + 1
  local v
  if kind == "number" then v = 7000000 + secretSeq
  elseif kind == "string" then v = "\0secret" .. secretSeq
  else v = {} end
  secrets[v] = kind or "table"
  return v
end
local rawtype = type
function type(v)
  local kind = v ~= nil and secrets[v]
  if kind then return kind end
  return rawtype(v)
end

---------------------------------------------------------------------------
-- Frames. The methods the mock implements live in `methods`. Any other
-- capitalised name is a no-op when the real widget of that kind has it (the
-- lists below, from the 12.x widget API, plus the mixin a template adds) and
-- nil otherwise, so a wrong or misspelled call fails here as it does in game
-- ("attempt to call method ... (a nil value)") and `if f.SetBackdrop then`
-- probes answer as the client does. A kind not listed is permissive.
-- Template children (UICheckButtonTemplate's .Text, the scroll bar) are not
-- modelled.
---------------------------------------------------------------------------
local function Set(list) local t = {}; for w in list:gmatch("%S+") do t[w] = true end return t end
local REGION = [[ClearAllPoints GetPoint GetNumPoints SetPoint SetAllPoints AdjustPointsOffset ClearPointsOffset
  GetCenter GetLeft GetRight GetTop GetBottom GetRect GetScaledRect GetSize GetWidth GetHeight SetSize SetWidth
  SetHeight GetScale SetScale GetEffectiveScale GetAlpha SetAlpha GetEffectiveAlpha SetIgnoreParentAlpha
  IsIgnoringParentAlpha SetIgnoreParentScale IsIgnoringParentScale Show Hide SetShown IsShown IsVisible IsRectValid
  IsAnchoringRestricted GetName GetDebugName GetObjectType IsObjectType GetParent SetParent IsForbidden IsDragging
  IsMouseOver GetSourceLocation SetScript GetScript HookScript HasScript EnableMouse EnableMouseWheel
  EnableMouseMotion IsMouseEnabled IsMouseWheelEnabled IsMouseMotionEnabled SetMouseClickEnabled
  SetMouseMotionEnabled IsMouseClickEnabled SetPassThroughButtons SetPropagateMouseClicks SetPropagateMouseMotion]]
local LAYERED = REGION .. [[ SetDrawLayer GetDrawLayer SetVertexColor GetVertexColor]]
local FRAME = REGION .. [[ CreateTexture CreateFontString CreateMaskTexture CreateLine CreateAnimationGroup
  RegisterEvent UnregisterEvent UnregisterAllEvents RegisterUnitEvent RegisterAllEvents IsEventRegistered
  SetFrameStrata GetFrameStrata SetFrameLevel GetFrameLevel SetFixedFrameStrata SetFixedFrameLevel SetToplevel
  IsToplevel Raise Lower SetMovable IsMovable SetResizable IsResizable SetUserPlaced IsUserPlaced StartMoving
  StopMovingOrSizing StartSizing SetResizeBounds GetResizeBounds SetClampedToScreen IsClampedToScreen
  SetClampRectInsets GetClampRectInsets SetHitRectInsets GetHitRectInsets SetID GetID SetAttribute GetAttribute
  SetAttributeNoHandler ExecuteAttribute CanChangeAttribute GetChildren GetNumChildren GetRegions GetNumRegions
  SetClipsChildren DoesClipChildren RegisterForDrag EnableKeyboard IsKeyboardEnabled SetPropagateKeyboardInput
  GetPropagateKeyboardInput EnableGamePadButton EnableGamePadStick SetHyperlinksEnabled GetHyperlinksEnabled
  SetFlattensRenderLayers GetFlattensRenderLayers SetDontSavePosition GetDontSavePosition GetBoundsRect
  IsProtected IsUsingParentLevel SetUsingParentLevel SetDrawLayerEnabled GetEffectiveDepth SetIsFrameBuffer
  SetWindow GetWindow AbortDrag InterceptStartDrag GetEffectivelyFlattensRenderLayers]]
local BUTTON = FRAME .. [[ SetText GetText SetFormattedText SetNormalTexture GetNormalTexture ClearNormalTexture
  SetPushedTexture GetPushedTexture ClearPushedTexture SetHighlightTexture GetHighlightTexture
  ClearHighlightTexture SetDisabledTexture GetDisabledTexture ClearDisabledTexture SetNormalAtlas SetPushedAtlas
  SetHighlightAtlas SetDisabledAtlas SetNormalFontObject GetNormalFontObject SetHighlightFontObject
  GetHighlightFontObject SetDisabledFontObject GetDisabledFontObject SetFontString GetFontString Enable Disable
  IsEnabled SetEnabled RegisterForClicks RegisterForMouse Click SetButtonState GetButtonState LockHighlight
  UnlockHighlight SetHighlightLocked GetHighlightLocked SetMotionScriptsWhileDisabled
  GetMotionScriptsWhileDisabled SetPushedTextOffset GetPushedTextOffset GetTextWidth GetTextHeight]]
local API = {
  Texture = Set(LAYERED .. [[ SetTexture GetTexture SetAtlas GetAtlas SetColorTexture SetTexCoord GetTexCoord
    SetBlendMode GetBlendMode SetDesaturated IsDesaturated SetDesaturation GetDesaturation SetGradient SetRotation
    GetRotation SetHorizTile GetHorizTile SetVertTile GetVertTile SetSnapToPixelGrid IsSnappingToPixelGrid
    SetTexelSnappingBias GetTexelSnappingBias SetMask AddMaskTexture RemoveMaskTexture GetNumMaskTextures
    SetNonBlocking IsBlockingLoadRequested SetTextureSliceMargins SetTextureSliceMode SetVertexOffset
    GetVertexOffset GetTextureFilePath GetTextureFileID]]),
  FontString = Set(LAYERED .. [[ SetText GetText SetFormattedText SetTextColor GetTextColor SetJustifyH GetJustifyH
    SetJustifyV GetJustifyV SetWordWrap CanWordWrap SetNonSpaceWrap CanNonSpaceWrap SetFont GetFont SetFontObject
    GetFontObject SetShadowColor GetShadowColor SetShadowOffset GetShadowOffset SetSpacing GetSpacing SetMaxLines
    GetMaxLines GetNumLines GetStringWidth GetStringHeight GetUnboundedStringWidth GetWrappedWidth GetLineHeight
    SetIndentedWordWrap GetIndentedWordWrap SetAlphaGradient SetFixedColor GetFixedColor SetTextHeight
    SetTextScale GetTextScale IsTruncated SetTextToFit GetFieldSize FindCharacterIndexAtCoordinate
    CalculateScreenAreaFromCharacterSpan SetRotation GetRotation]]),
  Frame = Set(FRAME),
  Button = Set(BUTTON),
  CheckButton = Set(BUTTON .. [[ SetChecked GetChecked SetCheckedTexture GetCheckedTexture ClearCheckedTexture
    SetDisabledCheckedTexture GetDisabledCheckedTexture ClearDisabledCheckedTexture]]),
  ScrollFrame = Set(FRAME .. [[ SetScrollChild GetScrollChild SetVerticalScroll GetVerticalScroll
    SetHorizontalScroll GetHorizontalScroll GetVerticalScrollRange GetHorizontalScrollRange
    UpdateScrollChildRect]]),
  EditBox = Set(FRAME .. [[ SetText GetText GetDisplayText Insert SetMultiLine IsMultiLine SetAutoFocus
    IsAutoFocus SetFocus ClearFocus HasFocus SetMaxLetters GetMaxLetters SetMaxBytes GetMaxBytes SetNumeric
    IsNumeric GetNumber SetNumber SetCursorPosition GetCursorPosition GetUTF8CursorPosition HighlightText
    SetTextInsets GetTextInsets SetTextColor GetTextColor SetFont GetFont SetFontObject GetFontObject SetJustifyH
    GetJustifyH SetJustifyV GetJustifyV SetSpacing GetSpacing SetShadowColor GetShadowColor SetShadowOffset
    GetShadowOffset SetPassword IsPassword SetBlinkSpeed GetBlinkSpeed SetHistoryLines GetHistoryLines
    AddHistoryLine ClearHistory SetAltArrowKeyMode GetAltArrowKeyMode SetCountInvisibleLetters
    IsCountInvisibleLetters SetEnabled Enable Disable IsEnabled SetIndentedWordWrap GetIndentedWordWrap
    GetNumLetters GetInputLanguage ToggleInputLanguage SetSecureText SetSecurityDisablePaste
    SetSecurityDisableSetText SetVisibleTextByteLimit GetVisibleTextByteLimit IsInIMECompositionMode
    SetTextHeight]]),
}
-- The mixin a template adds (a CreateFrame template may be a comma list).
local TEMPLATE_API = {
  BackdropTemplate = Set([[SetBackdrop GetBackdrop SetBackdropColor GetBackdropColor SetBackdropBorderColor
    GetBackdropBorderColor ApplyBackdrop ClearBackdrop HasBackdropInfo SetupTextureCoordinates SetBorderBlendMode
    GetEdgeSize OnBackdropLoaded OnBackdropSizeChanged SetupPieceVisuals]]),
}
local HELPERS = { RunScript = true }   -- mock-only, for tests

local Region
local methods = {}
function methods:SetSize(w, h) self.w, self.h = w, h end
function methods:SetWidth(w) self.w = w end
function methods:SetHeight(h) self.h = h end
function methods:GetHeight() return self.h or 0 end
function methods:GetWidth() return self.w or 0 end
function methods:SetPoint(...)
  self.points[#self.points+1] = { ... }
  local p = self.parent
  if p and p.counters then p.counters.SetPoint = (p.counters.SetPoint or 0) + 1 end
end
function methods:ClearAllPoints() self.points = {} end
function methods:SetColorTexture(...) self.color = { ... } end
function methods:SetTexture(t) self.tex = t end
function methods:SetText(t) self.text = t end
function methods:GetText() return self.text end
function methods:SetFormattedText(f, ...) self.text = string.format(f, ...) end
function methods:SetTextColor(...) self.textColor = { ... } end
function methods:Show() self.shown = true; if self.scripts and self.scripts.OnShow then self.scripts.OnShow(self) end end
function methods:Hide() self.shown = false; if self.scripts and self.scripts.OnHide then self.scripts.OnHide(self) end end
function methods:IsShown() return self.shown ~= false end
function methods:SetShown(b) self.shown = b and true or false end
function methods:GetUnboundedStringWidth() local t = self.text or ""; t = t:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""); return #t * 6 end
function methods:GetStringWidth() return self:GetUnboundedStringWidth() end
function methods:GetName() return self.name end
function methods:GetParent() return self.parent end
function methods:SetParent(p) self.parent = p end
-- frames
function methods:RegisterEvent(e) self.events[e] = true end
function methods:UnregisterEvent(e) self.events[e] = nil end
function methods:RegisterUnitEvent(e, u) self.events[e] = u end
function methods:SetScript(k, fn) self.scripts[k] = fn end
function methods:GetScript(k) return self.scripts[k] end
function methods:HookScript(k, fn) self.hooks[k] = self.hooks[k] or {}; table.insert(self.hooks[k], fn) end
function methods:RunScript(k, ...)
  if self.scripts[k] then self.scripts[k](self, ...) end
  for _, h in ipairs(self.hooks[k] or {}) do h(self, ...) end
end
function methods:CreateTexture() self.counters.CreateTexture = (self.counters.CreateTexture or 0) + 1; return Region(self, "Texture") end
function methods:CreateFontString() self.counters.CreateFontString = (self.counters.CreateFontString or 0) + 1; return Region(self, "FontString") end
function methods:SetAttribute(k, v) self.counters.SetAttribute = (self.counters.SetAttribute or 0) + 1; self.attributes[k] = v end
function methods:GetAttribute(k) return self.attributes[k] end
function methods:SetChecked(b) self.checked = b and true or false end
function methods:GetChecked() return self.checked end
function methods:SetEnabled(b) self.enabled = b and true or false end
function methods:IsEnabled() return self.enabled ~= false end
function methods:SetScrollChild(c) self.scrollChild = c end
function methods:GetFrameLevel() return 1 end

local NOOP = function() end
local function Lookup(t, k)
  if type(k) ~= "string" or not k:match("^%u") then return nil end
  local api = API[rawget(t, "kind")]
  if api and not api[k] and not HELPERS[k] then
    local allowed = false
    for tpl in tostring(rawget(t, "template") or ""):gmatch("[^,%s]+") do
      if TEMPLATE_API[tpl] and TEMPLATE_API[tpl][k] then allowed = true end
    end
    if not allowed then return nil end
  end
  return methods[k] or NOOP
end
local regionMeta = { __index = Lookup }
function Region(parent, kind)
  return setmetatable({ parent = parent, kind = kind, points = {}, shown = true }, regionMeta)
end

function CreateFrame(kind, name, parent, template)
  local f = Region(parent, kind)
  f.name, f.template = name, template
  f.scripts, f.hooks, f.events, f.attributes, f.counters = {}, {}, {}, {}, {}
  allFrames[#allFrames+1] = f
  if name then _G[name] = f end
  return f
end

function Fire(event, ...)
  for _, f in ipairs(allFrames) do
    if f.events[event] and f.scripts.OnEvent then
      local u = f.events[event]
      if u == true or u == (...) then f.scripts.OnEvent(f, event, ...) end
    end
  end
end

function hooksecurefunc(a, b, c)
  if type(a) == "table" then
    local orig = a[b]
    a[b] = function(...) local r = { orig(...) }; c(...); return unpack(r) end
  else
    local orig = _G[a]
    _G[a] = function(...) local r = { orig(...) }; b(...); return unpack(r) end
  end
end

---------------------------------------------------------------------------
-- Timers: After and NewTicker (an After chain re-armed after each callback,
-- as Blizzard's C_TimerAugment does, so a ticker and a timer due together
-- run in creation order). The clock moves only through Step(sec), in 0.05 s
-- ticks that each run what is due in due order, then what that queued with
-- no delay, and Advance(sec), which runs what is due now and then jumps: a
-- timer inside the jump fires at the next Step or Flush, late. Flush() runs
-- what is due at the current time without moving the clock (the zero-delay
-- row refresh); a 1 s debounce or a 30 s beat only fires when Step has
-- reached its time.
---------------------------------------------------------------------------
timers, tickers = {}, {}
local timerSeq = 0
C_Timer = {
  After = function(d, fn) timerSeq = timerSeq + 1; timers[#timers+1] = { at = GetTime() + d, fn = fn, seq = timerSeq } end,
  NewTicker = function(d, fn)
    local t = { d = d, fn = fn, cancelled = false }
    function t:Cancel() self.cancelled = true end
    local function tick()
      if t.cancelled then return end
      t.fn(t)
      if not t.cancelled then C_Timer.After(d, tick) end
    end
    C_Timer.After(d, tick)
    tickers[#tickers+1] = t
    return t
  end,
}
local function RunDue()
  local now = GetTime()
  for _ = 1, 20 do   -- a due timer may queue another one with no delay
    local due, keep = {}, {}
    for _, e in ipairs(timers) do if e.at <= now + EPS then due[#due+1] = e else keep[#keep+1] = e end end
    if #due == 0 then return end
    table.sort(due, function(a, b) if a.at ~= b.at then return a.at < b.at end return a.seq < b.seq end)
    timers = keep
    for _, e in ipairs(due) do e.fn() end
  end
end
function Flush() RunDue() end
function Advance(sec)
  RunDue()
  nowTicks = nowTicks + Ticks(sec)
end
function Step(sec)
  for _ = 1, Ticks(sec) do nowTicks = nowTicks + 1; RunDue() end
end
function LiveTickers() local n = 0; for _, t in ipairs(tickers) do if not t.cancelled then n = n + 1 end end return n end

---------------------------------------------------------------------------
-- Game state
---------------------------------------------------------------------------
local state = {
  group = {},                                   -- unit tokens of the others: { "party1", "party2" }
  full = { player = "Han Jaconelli", party1 = "Pri Cuthbridge", party2 = "Vf Pr", party3 = "Ab Cd", party4 = "Ef Gh" },
  class = { player = "WARLOCK", party1 = "PRIEST", party2 = "WARLOCK", party3 = "WARLOCK", party4 = "WARLOCK" },
  guids = { player = "Player-4620-AAA", party1 = "Player-4620-BBB", party2 = "Player-4620-CCC" },
  combat = false, dead = {}, ghost = {}, taxi = false, afk = false, resting = false, moving = false,
  speedSecret = false, level = 12, xp = 300, xpMax = 1000, exhaustion = 0, zone = "Durotar", subzone = "Razor Hill",
  near = {}, leader = "player", lockdown = false, hardcore = false, token = "tok",
  dur = { [5] = { 50, 100 }, [7] = { 80, 100 } },
  bags = {}, items = {}, bindings = {}, selfRes = {},
}
_G.state = state

function UnitName(u) local n = state.full[u]; return n and n:match("^(%S+)") or nil, n and n:match("%s(.+)$") or nil end
function GetUnitName(u) return state.full[u] end
function UnitGUID(u) return state.guids[u] end
function UnitClass(u) local c = state.class[u]; return c and (c:sub(1,1) .. c:sub(2):lower()) or nil, c end
function UnitExists(u) return state.full[u] ~= nil end
function UnitLevel(u) return u == "player" and state.level or 10 end
function UnitXP() return state.xp end
function UnitXPMax() return state.xpMax end
function GetXPExhaustion() return state.exhaustion end
function IsResting() return state.resting end
function GetZoneText() return state.zone end
function GetRealZoneText() return state.zone end
function GetSubZoneText() return state.subzone end
function UnitIsDeadOrGhost(u) return state.dead[u] or state.ghost[u] or false end
function UnitIsGhost(u) return state.ghost[u] or false end
function UnitIsDead(u) return state.dead[u] or false end
function UnitOnTaxi() return state.taxi end
function UnitIsAFK() return state.afk end
function UnitAffectingCombat(u) return state.combat and (u == "player" or state.unitCombat) or false end
function UnitIsConnected() return true end
function UnitIsGroupLeader(u) return u == state.leader end
function IsPlayerMoving() if state.speedSecret then return MakeSecret("boolean") end return state.moving end
function GetUnitSpeed() if state.speedSecret then return MakeSecret("number") end return state.moving and 7 or 0, 7, 7, 4.7 end
function CheckInteractDistance(u, idx) local n = state.near[u]; if n == nil then return true end if type(n) == "table" then return n[idx] end return n end
function InCombatLockdown() return state.combat end
function IsInGroup() return #state.group > 0 end
function IsInRaid() return false end
function GetNumSubgroupMembers() return #state.group end
function GetInventoryItemDurability(slot) local d = state.dur[slot] if d then return d[1], d[2] end end
function GetBuildInfo() return "1.60.1", "70205", "Oct 1 2026", 16001 end
WOW_PROJECT_ID, LE_EXPANSION_LEVEL_CURRENT = 18, 0
UNKNOWN = "Unknown"
RAID_CLASS_COLORS = { WARLOCK = { r = 0.53, g = 0.53, b = 0.93 }, PRIEST = { r = 1, g = 1, b = 1 } }
SOUNDKIT = { RAID_WARNING = 8959, GM_CHAT_WARNING = 1, TELL_MESSAGE = 2 }
sounds, warnings, flashes = {}, {}, 0
function PlaySound(id) sounds[#sounds+1] = id end
RaidWarningFrame = {}
ChatTypeInfo = { RAID_WARNING = { r = 1, g = 0.3, b = 0 } }
function RaidNotice_AddMessage(_, text) warnings[#warnings+1] = text end
function FlashClientIcon() flashes = flashes + 1 end
function GetBindingKey(action) return state.bindings[action] end
function IsModifierKeyDown() return false end
UIParent = CreateFrame("Frame")
SlashCmdList = {}
C_AddOns = { GetAddOnMetadata = function(_, k) if k == "Version" then return "0.1.0" end end }
C_EventUtils = { IsEventValid = function(e) return e ~= "BOGUS" end }
C_ChatInfo = {
  RegisterAddonMessagePrefix = function() return 0 end,
  SendAddonMessage = function() return 0 end,
  InChatMessagingLockdown = function() return state.lockdown end,
}
C_GameRules = {
  IsHardcoreActive = function() if state.hardcore == "secret" then return MakeSecret("boolean") end return state.hardcore end,
  IsGameRuleActive = function() return state.hardcore == true end,
}
Enum = {
  SendAddonMessageResult = { Success = 0 },
  GameRule = { HardcoreRuleset = 5 },
  ItemClass = { Consumable = 0, Projectile = 6, Reagent = 5, Miscellaneous = 15 },
  ItemConsumableSubclass = { Generic = 0, Potion = 1, Fooddrink = 5, Bandage = 7 },
  TooltipDataType = { Item = 0 },
}
C_Secrets = {}
C_Spell = { GetSpellName = function(id) return state.spells and state.spells[id] end }
-- Bags: state.bags[bag] = { [slot] = { itemID = n, stackCount = n, isBound = b, isLocked = b }, n = numSlots, family = 0 }
C_Container = {
  GetContainerNumSlots = function(bag) local b = state.bags[bag]; return b and b.n or 0 end,
  GetContainerNumFreeSlots = function(bag)
    local b = state.bags[bag]; if not b then return 0, 0 end
    local used = 0; for _ in pairs(b) do end
    for s = 1, b.n do if b[s] then used = used + 1 end end
    return b.n - used, b.family or 0
  end,
  GetContainerItemInfo = function(bag, slot) local b = state.bags[bag]; return b and b[slot] or nil end,
}
-- Items: state.items[id] = { name, class, sub, spell, count, bankCount }
C_Item = {
  GetItemInfoInstant = function(id)
    if type(id) == "string" then
      local n = id:match("item:(%d+)"); if n then id = tonumber(n) else
        for k, it in pairs(state.items) do if it.name == id then id = k end end end
    end
    local it = state.items[id]; if not it then return nil end
    return id, "item:" .. id, 1, 1, 1, it.class, it.sub
  end,
  GetItemInfo = function(id) local it = state.items[id]; return it and it.name end,
  GetItemSpell = function(id) local it = state.items[id]; return it and it.spell end,
  GetItemCount = function(id, bank) local it = state.items[id]; if not it then return 0 end return (it.count or 0) + (bank and (it.bankCount or 0) or 0) end,
}
C_DeathInfo = { GetSelfResurrectOptions = function() return state.selfRes end }
calls = {}
function RepopMe() calls[#calls+1] = "RepopMe"; if not state.repopBlocked then state.dead.player = nil; state.ghost.player = true end end
function RetrieveCorpse() calls[#calls+1] = "RetrieveCorpse"; if not state.retrieveBlocked then state.ghost.player = nil end end
function AcceptResurrect() calls[#calls+1] = "AcceptResurrect" end
function GetCorpseRecoveryDelay() return state.recoveryDelay or 0 end
GameTooltip = { lines = {}, shows = 0 }
function GameTooltip:SetOwner() end
function GameTooltip:SetText(t) self.lines[#self.lines+1] = t end
function GameTooltip:AddLine(t) self.lines[#self.lines+1] = t end
function GameTooltip:Show() self.shows = self.shows + 1 end
function GameTooltip:Hide() self.lines = {} end
function GameTooltip:ClearLines() self.lines = {} end
GameTooltip_Hide = function() GameTooltip:Hide() end
settingsCategories = {}
Settings = {
  RegisterCanvasLayoutCategory = function(frame, name) local c = { ID = "cat-" .. name, frame = frame, name = name }; function c:GetID() return self.ID end; settingsCategories[#settingsCategories+1] = c; return c end,
  RegisterAddOnCategory = function() end,
  RegisterCanvasLayoutSubcategory = function(parent, frame, name) local c = { ID = "sub-" .. name, frame = frame, name = name, parent = parent }; function c:GetID() return self.ID end; settingsCategories[#settingsCategories+1] = c; return c end,
  OpenToCategory = function(id) openedCategory = id end,
}
printed = {}
function print(...) local t = {} for i = 1, select("#", ...) do t[#t+1] = tostring((select(i, ...))) end printed[#printed+1] = table.concat(t, " ") if not QUIET then io.write(table.concat(t, " "), "\n") end end

---------------------------------------------------------------------------
-- Fake Mama-forever, shaped like the real one where MamaPlus touches it.
---------------------------------------------------------------------------
local MF = { prefix = "Mama: ", version = "1.1.0", messageHandlers = {}, commands = {}, commandOrder = {},
  roster = {}, online = {}, faction = "Horde", myName = nil, log = {} }
_G.MamaForever = MF
mamaPrinted, mamaSent = {}, {}

function MF:Print(msg, ...)
  if select("#", ...) > 0 then msg = msg:format(...) end
  mamaPrinted[#mamaPrinted+1] = msg
  print(self.prefix .. msg)
end
function MF:Debug(msg, ...)
  if select("#", ...) > 0 then msg = msg:format(...) end
  self.log[#self.log+1] = "[debug] " .. msg
  if self.db and self.db.debug then print("Mama debug: " .. msg) end
end
local mfListeners = {}
function MF:Listen(name, fn) mfListeners[name] = mfListeners[name] or {}; table.insert(mfListeners[name], fn) end
function MF:Fire(name, ...) for _, fn in ipairs(mfListeners[name] or {}) do fn(self, ...) end end
local mfFrame = CreateFrame("Frame")
local mfHandlers = {}
function MF:On(event, fn)
  if not mfHandlers[event] then mfHandlers[event] = {}; mfFrame:RegisterEvent(event) end
  table.insert(mfHandlers[event], fn)
end
mfFrame:SetScript("OnEvent", function(_, event, ...) for _, fn in ipairs(mfHandlers[event]) do fn(MF, ...) end end)
function MF:AddCommand(name, fn, help) self.commands[name] = { fn = fn, help = help }; table.insert(self.commandOrder, name) end
function MF:FullName(unit) return state.full[unit] end
function MF:GroupUnits() local u = {}; for _, t in ipairs(state.group) do u[#u+1] = t end; return u end
function MF:RefreshRoster()
  wipe(self.roster)
  for _, u in ipairs(self:GroupUnits()) do local n = self:FullName(u); if n then self.roster[n] = u end end
  self:Fire("TEAM_CHANGED")
end
function MF:GetLead()
  local lead = self.db.lead
  if lead and (lead == self.myName or self.roster[lead]) then return lead end
  for _, u in ipairs(self:GroupUnits()) do if UnitIsGroupLeader(u) then return self:FullName(u) end end
  return nil
end
function MF:SlotOf(name) for s, n in pairs(self.db.slots) do if n == name then return s end end end
function MF:Disabled() return self.db and self.myName and self.db.disabled[self.myName] or false end
function MF:Token() return state.token end
function MF:StatsOf(name) return state.stats and state.stats[name] end
function MF.MatsFor(_, partner, manual) local out = {}; for _, m in ipairs(state.mats or {}) do out[#out+1] = m end; return out end
-- Sends are recorded at once (the deterministic #mamaSent counts depend on
-- it); the real Mama queues them 0.25 s apart and signs each into
-- team:payload:nonce:ts:sig (Comm.lua:89-92: 6 + 4 + 10 + 16 bytes and four
-- colons, 40 in all) for a 255-byte addon message.
local WIRE_ENVELOPE, WIRE_LIMIT = 40, 255
local function record(kind, payload, to)
  assert(type(payload) == "string", "payload is not a string")
  payload:byte(1, #payload) -- a secret part would have failed the concat already; keep the real client's shape
  assert(#payload + WIRE_ENVELOPE <= WIRE_LIMIT, "wire message too long: " .. #payload .. " B payload + "
    .. WIRE_ENVELOPE .. " B Mama envelope > " .. WIRE_LIMIT)
  mamaSent[#mamaSent+1] = { kind = kind, payload = payload, to = to }
end
function MF:SendGroup(payload) if not state.token or not IsInGroup() then return end record("group", payload) end
function MF:SendWhisper(to, payload) if not state.token or to == self.myName then return end record("whisper", payload, to) end
function MF:SendTeam(payload, onlineOnly)
  local anyGrouped = false
  for _, name in pairs(self.db.slots) do
    if name ~= self.myName then
      if self.roster[name] then anyGrouped = true
      elseif self.online[name] or not onlineOnly then self:SendWhisper(name, payload) end
    end
  end
  if anyGrouped then self:SendGroup(payload) end
end
-- Status window rows, as Status.lua makes them (secure buttons, lazily, out of combat).
local rows = {}
MamaStatusFrame = CreateFrame("Frame", "MamaForeverStatus")
MamaStatusFrame.header = { text = Region(nil, "FontString") }
local function GetRow(i)
  if rows[i] then return rows[i] end
  local b = CreateFrame("Button", "MamaForeverStatusRow" .. i, MamaStatusFrame, "SecureActionButtonTemplate")
  b:SetAttribute("type1", "target")
  b.mark = b:CreateFontString(); b.slotText = b:CreateFontString(); b.bags = b:CreateFontString(); b.name = b:CreateFontString()
  b.name:SetPoint("LEFT", 28, 0); b.name:SetPoint("RIGHT", b.bags, "LEFT", -4, 0)
  b.counters = {} -- creation above does not count
  b.slot = i
  b:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine(("Slot %d: %s"):format(self.slot, self.fullName or "(not seen yet)"))
    GameTooltip:Show()
  end)
  rows[i] = b
  return b
end
MF.rowsRefreshed = 0
function MF:RefreshStatus()
  if InCombatLockdown() then self.pendingRefresh = true return end
  self.rowsRefreshed = self.rowsRefreshed + 1
  local n = 0
  for s in pairs(self.db.slots) do if s > n then n = s end end
  local lead = self:GetLead()
  for i = 1, n do
    local name = self.db.slots[i]
    local row = GetRow(i)
    row.fullName, row.unit = name, name and self.roster[name]
    row:SetAttribute("unit", row.unit or (name == self.myName and "player") or nil)
    row.name:SetText((name or "?") .. (name and name == lead and " |cFFFFD100*|r" or ""))
  end
  self:RefreshStats()
end
function MF:RefreshStats() for _, row in pairs(rows) do row.bags:SetText("12") end end
MF:On("PLAYER_REGEN_ENABLED", function(self) if self.pendingRefresh then self.pendingRefresh = false; self:RefreshStatus() end end)
-- As the real Mama: the roster rebuild fires TEAM_CHANGED (one refresh) and
-- GROUP_ROSTER_UPDATE refreshes again (Status.lua:343-348).
MF:On("GROUP_ROSTER_UPDATE", function(self) self:RefreshRoster(); self:RefreshStatus() end)
MF:On("ADDON_LOADED", function(self, name)
  if name ~= "Mama" then return end
  self.db = { slot = 1, slots = {}, disabled = {}, debug = false, lead = false, stats = {}, showStatus = true }
end)
MF:On("PLAYER_LOGIN", function(self)
  self.myName = self:FullName("player")
  self.db.slotsBy = self.db.slotsBy or {}
  self.db.slotsBy[self.faction] = self.db.slotsBy[self.faction] or { [1] = "Han Jaconelli", [2] = "Pri Cuthbridge", [3] = "Vf Pr" }
  self.db.slots = self.db.slotsBy[self.faction] -- a new table, like the real Mama.lua:142
  self:Fire("LOGIN")
end)
MF:Listen("LOGIN", function(self)
  self.category = Settings.RegisterCanvasLayoutCategory({}, "Mama-forever")
  self:RefreshStatus()   -- Mama's Status.lua makes its frame and refreshes at LOGIN, grouped or not
end)
MF:Listen("TEAM_CHANGED", function(self) self:RefreshStatus() end)

-- Deliver a verified team message to this client as Mama would.
function Deliver(sender, payload)
  local kind, rest = payload:match("^(%a);(.*)$")
  local h = kind and MF.messageHandlers[kind]
  if h then h(MF, sender, rest) end
end

-- Login helper for tests: loads saved vars, logs in, optionally groups, and
-- lets the zero-delay timers and the 1 s change debounce run (time moves 2 s).
-- T_LOGIN is the LOGIN time: beats run at T_LOGIN + FIRST_BEAT + k * BEAT
-- (a test with its own login sets it the same way).
T_LOGIN = nil
function Login(group)
  Fire("ADDON_LOADED", "Mama"); Fire("ADDON_LOADED", "MamaPlus")
  T_LOGIN = GetTime()
  Fire("PLAYER_LOGIN")
  Step(0.5)
  if group then state.group = group; Fire("GROUP_ROSTER_UPDATE"); Step(1.5) end
end

-- Load the foundation files in TOC order with the (addonName, ns) vararg.
-- Feature modules are loaded by the test that exercises them (LoadModule),
-- or all at once with LoadAll(), so a test sees only the modules it names.
local FOUNDATION = { ["Core.lua"] = true, ["Alert.lua"] = true, ["Rows.lua"] = true, ["Status.lua"] = true,
  ["Options.lua"] = true }
local ns = {}
local loadedFiles, tocFiles = {}, {}
for line in io.lines(ADDON .. "MamaPlus.toc") do
  if line:match("%.lua$") then tocFiles[#tocFiles+1] = line end
end
_G.ns = ns

function LoadModule(file)
  if loadedFiles[file] then return end
  local chunk = assert(loadfile(ADDON .. file))
  chunk("MamaPlus", ns)
  loadedFiles[file] = true
end
for _, file in ipairs(tocFiles) do if FOUNDATION[file] then LoadModule(file) end end
function LoadAll() for _, file in ipairs(tocFiles) do LoadModule(file) end end

-- The next heartbeat time after now (Status.lua: FIRST_BEAT after LOGIN,
-- then every BEAT), and a step onto that beat (it fires) and 3 s past it:
-- the following 27 s hold no beat and no send gap, so H counts are exact.
function NextBeat()
  local S = ns.Status
  local t, b = GetTime(), (T_LOGIN or 1000) + (S.FIRST_BEAT or 8)
  while b <= t do b = b + S.BEAT end
  return b
end
function PastBeat() Step(NextBeat() - GetTime()); Step(3) end

-- Payloads MamaPlus handed to Mama, filtered by sub-kind.
function Sent(sub)
  local out = {}
  for _, s in ipairs(mamaSent) do
    local k = s.payload:match("^x;(%w+)")
    if not sub or k == sub then out[#out+1] = s end
  end
  return out
end
function LastSent(sub) local l = Sent(sub); return l[#l] end
