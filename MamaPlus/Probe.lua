local addonName, ns = ...

-- MamaPlus: companion to Mama-forever (WoW: Forever, Interface 16001).
-- Probe: "/mama plus probe [section]" prints "name: value" lines about this
-- client (build, secrets, API presence, events, Mama and limiter state,
-- plus every module's own ns.AddProbe section) through ns.Print and into a
-- copyable window, so a test session needs no /mama bug. "probe comms"
-- sends 40 addon messages on our own prefix and prints each result code to
-- find the addon-message throttle. Nothing here calls a protected or
-- world-changing function; every section runs in pcall.

local IsSecret = ns.IsSecret
local MF = ns.MF
local Probe = { running = nil }
ns.Probe = Probe

local PREFIX = "MAMAPLUSP"
local PRESENCE = { "C_Secrets", "C_EventUtils", "C_GameRules", "C_SettingsUtil", "C_Spell", "C_Item", "C_Container",
  "C_DeathInfo", "TooltipDataProcessor", "Settings.RegisterCanvasLayoutSubcategory",
  "C_ChatInfo.InChatMessagingLockdown", "Enum.SendAddonMessageResult", "IsPlayerMoving", "GetUnitSpeed",
  "FlashClientIcon", "GetBindingKey" }
local EVENTS = { "ADDON_ACTION_FORBIDDEN", "ADDON_ACTION_BLOCKED", "PLAYER_FLAGS_CHANGED", "AUTOFOLLOW_BEGIN",
  "UNIT_SPELLCAST_SENT" }

---------------------------------------------------------------------------
-- Rendering
---------------------------------------------------------------------------
local function Render(v)
  if IsSecret(v) then return "<secret " .. type(v) .. ">" end
  if v == nil then return "nil" end
  return tostring(v)
end

-- An API that may be missing or raise, as a probe value.
local function Call(fn, ...)
  if type(fn) ~= "function" then return "missing" end
  local ok, v = pcall(fn, ...)
  if not ok then return "error" end
  return v
end

-- _G value at a dotted path ("Settings.RegisterCanvasLayoutSubcategory").
local function Lookup(path)
  local v = _G
  for part in path:gmatch("[^.]+") do v = type(v) == "table" and v[part] or nil end
  return v
end

local function Strip(s)
  return (s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|T.-|t", ""):gsub("|H.-|h(.-)|h", "%1"))
end

---------------------------------------------------------------------------
-- Built-in section
---------------------------------------------------------------------------
ns.AddProbe("core", function(add)
  local version, build, bdate, iface = GetBuildInfo()
  add("build", Render(version) .. " " .. Render(build) .. " " .. Render(bdate))
  add("interface", iface)
  add("WOW_PROJECT_ID", WOW_PROJECT_ID)
  add("LE_EXPANSION_LEVEL_CURRENT", LE_EXPANSION_LEVEL_CURRENT)
  add("type(issecretvalue)", type(issecretvalue))
  add("UnitHealth(player)", Call(UnitHealth, "player"))
  add("UnitName(player)", Call(UnitName, "player"))
  add("UnitGUID(player)", Call(UnitGUID, "player"))
  for _, path in ipairs(PRESENCE) do add(path, type(Lookup(path))) end
  -- C_Secrets' member list on this build is unverified: only the no-argument
  -- Should* predicates are called; anything else is listed by type.
  if type(C_Secrets) == "table" then
    local names = {}
    for k in pairs(C_Secrets) do if type(k) == "string" then names[#names + 1] = k end end
    table.sort(names)
    for _, k in ipairs(names) do
      local v = C_Secrets[k]
      if type(v) == "function" and k:match("^Should") then
        add("C_Secrets." .. k .. "()", Call(v))
      else
        add("C_Secrets." .. k, type(v))
      end
    end
  end
  add("ns.IsHardcore()", ns.IsHardcore())
  add("ns.Moving()", ns.Moving())
  for _, event in ipairs(EVENTS) do add(event .. " valid", ns.EventIsValid(event)) end
  add("Mama version", MF and MF.version)
  add("slot", ns.MySlot())
  add("token", (MF and MF.Token and MF:Token()) and "yes" or "no")
  add("lead", Render(ns.LeadName()) .. (ns.IsLead() and " (this window)" or ""))
  add("comms", ns.commsOff and "OFF" or (ns.CanSend(false) and "on" or "off (no slot/token or disabled)"))
  local c = ns.comms
  add("messages", string.format("sent %d, replaced %d, held %d, secret parts %d, dropped %d, pending %d",
    c.sent, c.replaced, c.held, c.secret, c.dropped, ns.PendingCount()))
  add("blocked actions", ns.blocked.count .. (ns.blocked.last and (" (last " .. ns.blocked.last .. ")") or ""))
end)

---------------------------------------------------------------------------
-- Running sections. Each fn gets a callable table: out(name, value) adds a
-- rendered line; the other modules' out[#out + 1] = line and a returned
-- list of lines work too.
---------------------------------------------------------------------------
local function RunSection(section, lines)
  lines[#lines + 1] = "== " .. section .. " =="
  for _, fn in ipairs(ns.probes[section] or {}) do
    local out = setmetatable({}, { __call = function(t, name, value) t[#t + 1] = tostring(name) .. ": " .. Render(value) end })
    local ok, ret = pcall(fn, out)
    if not ok then
      out[#out + 1] = "error: " .. tostring(ret)
    elseif #out == 0 and type(ret) == "table" then
      out = ret
    end
    for _, l in ipairs(out) do lines[#lines + 1] = Strip(tostring(l)) end
  end
end

---------------------------------------------------------------------------
-- Window (TeamWatch Report.lua): one read-only EditBox in a scroll frame.
---------------------------------------------------------------------------
local function CreateWindow()
  local f = CreateFrame("Frame", "MamaPlusProbe", UIParent)
  f:SetSize(560, 420)
  f:SetPoint("CENTER")
  f:SetFrameStrata("DIALOG")
  f:SetMovable(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", f.StopMovingOrSizing)
  local bg = f:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  bg:SetColorTexture(0.05, 0.05, 0.05, 0.94)
  local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  title:SetPoint("TOPLEFT", 10, -8)
  title:SetText("MamaPlus probe: click the text, Ctrl+A, Ctrl+C")
  local close = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  close:SetSize(60, 20)
  close:SetPoint("TOPRIGHT", -6, -5)
  close:SetText("Close")
  close:SetScript("OnClick", function() f:Hide() end)
  local scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", 10, -32)
  scroll:SetPoint("BOTTOMRIGHT", -30, 10)
  local edit = CreateFrame("EditBox", nil, scroll)
  edit:SetMultiLine(true)
  edit:SetAutoFocus(false)
  edit:SetFontObject(ChatFontNormal or GameFontHighlightSmall)
  edit:SetWidth(510)
  edit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  -- Read-only: any typing restores the probe text.
  edit:SetScript("OnTextChanged", function(self, user)
    if user and f.text then self:SetText(f.text) self:HighlightText() end
  end)
  scroll:SetScrollChild(edit)
  f.edit = edit
  if type(UISpecialFrames) == "table" then tinsert(UISpecialFrames, "MamaPlusProbe") end
  return f
end

function Probe.Show(lines)
  Probe.window = Probe.window or CreateWindow()
  local f = Probe.window
  f.text = table.concat(lines, "\n")
  f.edit:SetText(f.text)
  f:Show()
  f.edit:SetFocus()
  f.edit:HighlightText()
end

-- Prints a line and adds it to the open window (the comms probe is async).
local function Emit(line)
  ns.Print(line)
  local f = Probe.window
  if not f then return end
  f.text = f.text .. "\n" .. line
  f.edit:SetText(f.text)
end

local function Header() return "MamaPlus probe " .. ns.Version() .. " " .. date("%Y-%m-%d %H:%M") end

function Probe.Run(sections)
  local lines = { Header() }
  for _, s in ipairs(sections) do RunSection(s, lines) end
  for _, l in ipairs(lines) do ns.Print(l) end
  Probe.Show(lines)
end

---------------------------------------------------------------------------
-- Comms: 20 PARTY messages at 0.25 s then 20 at 1 s on our own prefix,
-- each result code printed, the first non-Success one with its time.
-- Message i is due at (i + 1) * 0.25 s, then 5.25 + (i - 20) s; a 0.25 s
-- ticker sends what is due (catching up after a long frame).
---------------------------------------------------------------------------
local TOTAL = 40
local function Due(i) return i < 20 and (i + 1) * 0.25 or 5.25 + (i - 20) end

function Probe.Comms()
  if Probe.running then ns.Print("comms probe already running") return end
  -- Mama's per-character off switch means no addon messages in or out.
  if ns.Disabled() then ns.Print("comms probe: Mama is disabled on this character") return end
  if not ns.PlainTrue(IsInGroup()) then ns.Print("comms probe: not in a group") return end
  if not (C_ChatInfo and C_ChatInfo.SendAddonMessage) then ns.Print("comms probe: C_ChatInfo.SendAddonMessage missing") return end
  Probe.Show({ Header(), "== comms ==" })
  if not Probe.registered then
    Probe.registered = true
    Emit("RegisterAddonMessagePrefix(" .. PREFIX .. "): " .. Render(Call(C_ChatInfo.RegisterAddonMessagePrefix, PREFIX)))
  end
  local run = { n = 0, t0 = GetTime(), first = nil }
  Probe.running = run
  local success = ns.PlainOfType(Enum and Enum.SendAddonMessageResult and Enum.SendAddonMessageResult.Success, "number", 0)
  run.ticker = ns.Ticker(0.25, function()
    local now = GetTime() - run.t0
    while run.n < TOTAL and Due(run.n) <= now do
      run.n = run.n + 1
      local v = Call(C_ChatInfo.SendAddonMessage, PREFIX, "p;" .. run.n, "PARTY")
      local code, text = ns.PlainNumber(v), Render(v)
      if not run.first and code ~= success then run.first = { n = run.n, at = now, text = text } end
      Emit(string.format("comms %d/%d +%.2f s: %s", run.n, TOTAL, now, text))
    end
    if run.n < TOTAL then return end
    run.ticker:Cancel()
    Probe.running = nil
    local f = run.first
    Emit(string.format("comms probe done: %d sent in %.2f s; %s", run.n, now,
      f and string.format("first non-Success: %s at message %d (+%.2f s)", f.text, f.n, f.at) or "all Success"))
  end)
end

---------------------------------------------------------------------------
-- Command
---------------------------------------------------------------------------
local function Sections()
  local list = { "core" }
  for _, s in ipairs(ns.probeOrder) do if s ~= "core" then list[#list + 1] = s end end
  return list
end

ns.AddCommand("probe", "probe [section|comms] - client facts into chat and a copyable window; comms sends 40 test messages",
  function(rest)
    local section = (rest or ""):lower():match("^(%S*)")
    if section == "comms" then return Probe.Comms() end
    if section == "" then return Probe.Run(Sections()) end
    if ns.probes[section] then return Probe.Run({ section }) end
    ns.Print("unknown probe section: " .. section .. " (sections: " .. table.concat(Sections(), ", ") .. ", comms)")
  end)
