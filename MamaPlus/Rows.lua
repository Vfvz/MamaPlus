local addonName, ns = ...

-- Icon strip on Mama's status rows (MamaForeverStatusRow<i>). Feature
-- files register providers: fn(name, out) appends entries
--   { kind, text, r, g, b, tip, prio }
-- for the member called name (text "" = tooltip line only). The strip sits
-- left of Mama's bag number; the name yields to it, and entries that do not
-- fit stay in the tooltip. Rows are secure buttons: our regions are created
-- once per row, out of combat only (Mama's RefreshStatus returns early in
-- combat and runs again after it); in combat only text, colour, show and
-- hide change. Secure attributes are never touched.

local Rows = {}
ns.Rows = Rows

local MF = ns.MF
local NAME_LEFT, NAME_SPACE, MAX_STRIP, GAP = 28, 154, 84, 3 -- Mama rows are 210 px wide
local CHAR_W = 6                                             -- GameFontHighlightSmall estimate
local MAX_ROWS = 40

ns.AddDefaults({ rowIcons = true })
ns.AddOption({ key = "rowIcons", label = "Icons on the Mama status rows", section = "Team rows", type = "toggle",
  tip = "Dead, AFK, idle, durability, supplies, follow state and more, left of the bag count. Hover a row for details.",
  onChange = function() Rows.Refresh() end })

local providers, reported = {}, {}
function Rows.AddProvider(fn) providers[#providers + 1] = fn end

-- A provider that raises is reported once, then skipped.
local function RunProvider(fn, name, out)
  if reported[fn] then return end
  local ok, err = pcall(fn, name, out)
  if not ok then
    reported[fn] = true
    ns.Report("MamaPlus row provider failed: " .. tostring(err))
  end
end

Rows.flashUntil = {}
function Rows.IsFlashing(name)
  local t = name and Rows.flashUntil[name]
  return t ~= nil and GetTime() < t
end

function Rows.Flash(name, secs)
  if not name then return end
  Rows.flashUntil[name] = GetTime() + (secs or 3)
  Rows.Refresh()
  ns.After((secs or 3) + 0.1, Rows.Refresh)
end

local function Color(e)
  return string.format("|cff%02x%02x%02x%s|r", math.floor((e[3] or 1) * 255 + 0.5),
    math.floor((e[4] or 1) * 255 + 0.5), math.floor((e[5] or 1) * 255 + 0.5), e[2])
end

-- Entries for one member, sorted by priority (lower first, then registration order).
function Rows.Entries(name)
  local out = {}
  if not name then return out end
  for _, fn in ipairs(providers) do RunProvider(fn, name, out) end
  for i, e in ipairs(out) do e.order = i end
  table.sort(out, function(a, b)
    local pa, pb = a[7] or 50, b[7] or 50
    if pa ~= pb then return pa < pb end
    return a.order < b.order
  end)
  return out
end

local function TextWidth(fs, text)
  if fs and fs.GetUnboundedStringWidth then
    local w = ns.PlainNumber(fs:GetUnboundedStringWidth())
    if w then return w end
  end
  text = (text or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
  return #text * CHAR_W
end

-- Decoration, once per row, out of combat only.
local function Decorate(row)
  if row.plus then return true end
  if InCombatLockdown() then return false end
  row.plus = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  row.plus:SetPoint("RIGHT", row.bags, "LEFT", -GAP, 0)
  row.plus:SetJustifyH("RIGHT")
  row.plus:SetWordWrap(false)
  row.name:ClearAllPoints()
  row.name:SetPoint("LEFT", NAME_LEFT, 0)
  row.name:SetPoint("RIGHT", row.plus, "LEFT", -2, 0)
  row.name:SetWordWrap(false)
  row.flash = row:CreateTexture(nil, "ARTWORK")
  row.flash:SetAllPoints()
  row.flash:SetColorTexture(1, 0.1, 0.1, 0.35)
  row.flash:Hide()
  if not row.plusHooked then
    row.plusHooked = true
    row:HookScript("OnEnter", function(self)
      local entries = self.plusEntries
      if not entries or #entries == 0 or not GameTooltip then return end
      for _, e in ipairs(entries) do
        if e[6] then
          GameTooltip:AddLine(((e[2] ~= "" and e[2] .. ": ") or "") .. e[6], e[3] or 1, e[4] or 1, e[5] or 1, true)
        end
      end
      GameTooltip:Show()
    end)
  end
  return true
end

local function Fill(row)
  local name = row.fullName
  if name and Rows.IsFlashing(name) then row.flash:Show() else row.flash:Hide() end
  if not name or not ns.OptionOn("rowIcons") then
    row.plusEntries = nil
    row.plus:SetText("")
    return
  end
  local entries = Rows.Entries(name)
  row.plusEntries = entries
  local nameText = row.name.GetText and row.name:GetText() or name
  local budget = NAME_SPACE - TextWidth(row.name, nameText) - 4
  if budget < 0 then budget = 0 end
  if budget > MAX_STRIP then budget = MAX_STRIP end
  local parts, used = {}, 0
  for _, e in ipairs(entries) do
    if e[2] ~= "" then
      local w = #e[2] * CHAR_W + (#parts > 0 and GAP or 0)
      if used + w <= budget then
        parts[#parts + 1] = Color(e)
        used = used + w
      end
    end
  end
  row.plus:SetText(table.concat(parts, " "))
end

-- Walk Mama's rows. Undecorated rows in combat are skipped (they get
-- decorated when Mama refreshes after combat).
function Rows.Apply()
  for i = 1, MAX_ROWS do
    local row = _G["MamaForeverStatusRow" .. i]
    if not row then break end
    if Decorate(row) then Fill(row) end
  end
end

local queued = false
function Rows.Refresh()
  if queued then return end
  queued = true
  ns.After(0, function()
    queued = false
    Rows.Apply()
  end)
end

if MF and hooksecurefunc and MF.RefreshStatus then
  hooksecurefunc(MF, "RefreshStatus", function() Rows.Apply() end)
end

-- Self test: a TEST icon and a flash on our own row for 3 seconds.
ns.testUntil = 0
Rows.AddProvider(function(name, out)
  if name == ns.MyName() and GetTime() < ns.testUntil then
    out[#out + 1] = { "test", "TEST", 1, 1, 1, "alert check", 99 }
  end
end)
ns.AddCommand("test", "sound, warning, flash and a TEST icon on your own row", function()
  ns.testUntil = GetTime() + 3
  ns.Alert.Fire("MamaPlus test: alerts work on this window", ns.MyName(), 3)
  ns.After(3.1, Rows.Refresh)
end)
ns.AddCommand("icons", "icons [on|off] - icons on the Mama rows", function(rest)
  rest = (rest or ""):lower()
  if rest == "on" or rest == "off" then ns.SetOption("rowIcons", rest == "on") end
  ns.Print("row icons", ns.OptionOn("rowIcons") and "on" or "off")
end)
