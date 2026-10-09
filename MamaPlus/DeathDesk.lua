local addonName, ns = ...

-- Death desk: on Mama's lead window, a plain frame under the status window
-- listing who is dead or a ghost (from the heartbeat field R, or a guarded
-- UnitIsDeadOrGhost for grouped members without MamaPlus) with how long,
-- auto-release countdowns, corpse and spirit-healer range and resurrection
-- offers; a footer naming who is alive and able to resurrect (heartbeat
-- class and level: Priest 10, Paladin 12, Shaman 12, Druid 20 with Rebirth
-- in combat only); the title WIPE when every grouped member is down; and a
-- [Cancel auto-release] button sending "x;R;c" (which only suppresses).
-- The lead alert "deathAlert" coalesces a burst of deaths into one line
-- ("Team wipe: 4 dead", "slot 2 Name died", "2 died: ...") and never
-- re-fires for dead -> ghost. Row icons: G (ghost, grey), RES (offer,
-- green), plus a tooltip line while dead. Nothing here acts on anyone.

local Desk = {}
ns.DeathDesk = Desk

local Death = ns.Death
local COALESCE, WIDTH, LINE_H = 3, 210, 12
Desk.since, Desk.down = {}, {}   -- name -> GetTime() first seen down; name -> true while down
local pendingDeaths, flushQueued, frame, ticker = {}, false, nil, nil

local function Age(since)
  local s = since and math.max(0, math.floor(GetTime() - since)) or 0
  return string.format("%d:%02d", math.floor(s / 60), s % 60)
end

-- "dead 0:42, auto-release 12 s" / "ghost 1:03, corpse near, res offered"; nil while alive.
function Desk.Describe(name, info)
  if info.state ~= "d" and info.state ~= "g" then return nil end
  local parts = { (info.state == "d" and "dead " or "ghost ") .. Age(info.me and Death.me.diedAt or Desk.since[name]) }
  if info.state == "g" then
    parts[#parts + 1] = info.corpse and "corpse near" or "corpse far"
    if info.spirit then parts[#parts + 1] = "spirit healer near" end
  end
  local server = Death.ServerNow()
  if info.endTime and server and info.endTime > server then
    parts[#parts + 1] = string.format("auto-release %d s", info.endTime - server)
  end
  if info.offer then parts[#parts + 1] = "res offered" end
  return table.concat(parts, ", ")
end

-- Team names in slot order, with their slots.
function Desk.Names()
  local slots, names = {}, {}
  for slot in pairs(ns.Slots()) do slots[#slots + 1] = slot end
  table.sort(slots)
  for _, slot in ipairs(slots) do names[#names + 1] = ns.Slots()[slot] end
  return names, slots
end

-- Alive members who can resurrect, from the heartbeat class and level.
function Desk.Resers()
  local out = {}
  for _, name in ipairs(Desk.Names()) do
    local info = Death.StateOf(name)
    if info and info.state == "a" then
      local class, level
      if info.me then
        class = ns.MyClass()
        local ok, l = ns.Try(UnitLevel, "player")
        level = ok and ns.PlainNumber(l) or nil
      else
        class = ns.Status.Field(name, "k")
        level = tonumber(ns.Status.Field(name, "l"))
      end
      local need = class and Death.CAN_RES[class]
      if need and level and level >= need then
        out[#out + 1] = name .. " (" .. class:sub(1, 1) .. class:sub(2):lower()
          .. (class == "DRUID" and ", Rebirth: combat only" or "") .. ")"
      end
    end
  end
  return out
end

function Desk.Footer()
  local resers = Desk.Resers()
  if #resers == 0 then return "nobody alive can resurrect: corpse run" end
  return "Can res: " .. table.concat(resers, ", ")
end

---------------------------------------------------------------------------
-- Frame
---------------------------------------------------------------------------
local function Make()
  if frame then return end
  frame = CreateFrame("Frame", "MamaPlusDeathDesk", UIParent, "BackdropTemplate")
  Desk.frame = frame
  frame:SetSize(WIDTH, 60)
  if frame.SetBackdrop then
    frame:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
    frame:SetBackdropColor(0, 0, 0, 0.6)
    frame:SetBackdropBorderColor(0.6, 0, 0, 1)
  end
  if MamaForeverStatus then
    frame:SetPoint("TOP", MamaForeverStatus, "BOTTOM", 0, -2)
  else
    frame:SetPoint("TOP", UIParent, "TOP", 0, -300)
  end
  local function Text(template)
    local fs = frame:CreateFontString(nil, "OVERLAY", template)
    fs:SetWidth(WIDTH - 12)
    fs:SetJustifyH("LEFT")
    return fs
  end
  frame.title = Text("GameFontNormalSmall")
  frame.title:SetPoint("TOPLEFT", 6, -4)
  frame.body = Text("GameFontHighlightSmall")
  frame.body:SetPoint("TOPLEFT", 6, -20)
  frame.footer = Text("GameFontHighlightSmall")
  frame.footer:SetPoint("TOPLEFT", frame.body, "BOTTOMLEFT", 0, -4)
  frame.cancel = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  frame.cancel:SetSize(130, 20)
  frame.cancel:SetPoint("BOTTOM", 0, 3)
  frame.cancel:SetText("Cancel auto-release")
  frame.cancel:SetScript("OnClick", Death.CancelAll)
  frame:Hide()
end

-- Rows, counts and the frame; returns whether the desk is shown.
function Desk.Update()
  local names, slots = Desk.Names()
  local rows, down, grouped, anyEnd = {}, 0, 0, false
  local server = Death.ServerNow()
  for i, name in ipairs(names) do
    local unit = name == ns.MyName() and "player" or ns.UnitOf(name)
    local info = Death.StateOf(name)
    local text
    if info then
      text = Desk.Describe(name, info)
      if info.endTime and server and info.endTime > server then anyEnd = true end
    elseif unit then
      local ok, v = ns.Try(UnitIsDeadOrGhost, unit)
      if ok and ns.PlainTrue(v) then text = "? (no MamaPlus)" end
    end
    if unit then
      grouped = grouped + 1
      if text then down = down + 1 end
    end
    if text then rows[#rows + 1] = slots[i] .. " " .. name .. " " .. text end
  end
  Desk.rows, Desk.downCount, Desk.wipe = rows, down, grouped > 0 and down >= grouped
  local show = #rows > 0 and ns.IsLead() and ns.OptionOn("deathDesk")
  if frame then
    if show then
      frame.title:SetText(Desk.wipe and "|cffff4040WIPE|r" or "Deaths")
      frame.body:SetText(table.concat(rows, "\n"))
      frame.footer:SetText(Desk.Footer())
      frame.cancel:SetShown(anyEnd)
      frame:SetHeight(38 + LINE_H * #rows + (anyEnd and 24 or 4))
      -- Follow Mama's wheel-resized status window (plain frame: safe in combat).
      local s = MamaForeverStatus and ns.PlainNumber(MamaForeverStatus:GetScale())
      if s and s ~= frame:GetScale() then frame:SetScale(s) end
      frame:Show()
    else
      frame:Hide()
    end
  end
  if show and not ticker then
    ticker = ns.Ticker(1, Desk.Update)
  elseif not show and ticker then
    ticker:Cancel()
    ticker = nil
  end
  return show
end

-- Lines for /mama plus death (any window).
function Desk.Lines()
  Desk.Update()
  local lines = { Desk.wipe and "WIPE" or (#Desk.rows == 0 and "deaths: none" or "deaths:") }
  for _, r in ipairs(Desk.rows) do lines[#lines + 1] = "  " .. r end
  lines[#lines + 1] = Desk.Footer()
  return lines
end

---------------------------------------------------------------------------
-- Alerts (coalesced) and refresh triggers
---------------------------------------------------------------------------
local function Flush()
  flushQueued = false
  local names = pendingDeaths
  pendingDeaths = {}
  if #names == 0 then return end
  Desk.Update()
  local text
  if Desk.wipe then
    text = "Team wipe: " .. Desk.downCount .. " dead"
  elseif #names == 1 then
    text = ns.Who(names[1]) .. " died"
  else
    text = #names .. " died: " .. table.concat(names, ", ")
  end
  ns.LeadAlert("deathAlert", text, names[1])
end

ns.Listen("HEARTBEAT", function(sender)
  local info = Death.StateOf(sender)
  local down = info ~= nil and (info.state == "d" or info.state == "g")
  if down and not Desk.down[sender] then
    Desk.since[sender] = GetTime()
    pendingDeaths[#pendingDeaths + 1] = sender
    if not flushQueued then
      flushQueued = true
      ns.After(COALESCE, Flush)
    end
  elseif not down then
    Desk.since[sender] = nil
  end
  Desk.down[sender] = down or nil
  Desk.Update()
end)

ns.Listen("TEAM_CHANGED", function()
  for name in pairs(Desk.down) do
    if not ns.Status.records[name] then Desk.down[name], Desk.since[name] = nil, nil end
  end
  Desk.Update()
end)
ns.Listen("DEATH_CHANGED", Desk.Update)
ns.Listen("LOGIN", function()
  Make()
  Desk.Update()
end)

---------------------------------------------------------------------------
-- Row icons
---------------------------------------------------------------------------
ns.Rows.AddProvider(function(name, out)
  local info = Death.StateOf(name)
  if not info then return end
  if info.state == "g" then
    out[#out + 1] = { "ghost", "G", 0.6, 0.6, 0.6, Desk.Describe(name, info), 3 }
  elseif info.state == "d" then
    out[#out + 1] = { "death", "", 1, 0.3, 0.3, Desk.Describe(name, info), 3 }
  end
  if info.offer then out[#out + 1] = { "res", "RES", 0.3, 1, 0.3, "resurrection offered", 9 } end
end)
