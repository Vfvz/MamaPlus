local addonName, ns = ...

-- Keys: seven secure buttons for key bindings that act on the pressed
-- window only: target the lead, target team slot 1-5, stop following.
-- Macro buttons in Mama's Actions.lua shape, rebuilt from Mama's slots and
-- roster on TEAM_CHANGED, PLAYER_ENTERING_WORLD and after combat, written
-- only when the text differs and never in combat (a pending flag defers the
-- write to PLAYER_REGEN_ENABLED). "/target <unit>" for a grouped member,
-- "/target player" for ourselves and for the lead when we lead or the lead
-- is not grouped, "" for an empty or ungrouped slot (that key prints "slot N
-- is not in the group" once per 5 s), "/follow player" to stop following.
-- The client loads Bindings.xml on its own (it must NOT be in the TOC); the
-- labels below name its entries in the Key Bindings window.

local Keys = {}
ns.Keys = Keys

local IsSecret = ns.IsSecret
local DEAD_GAP = 5                                  -- seconds between "not in the group" lines per key
local LEAD, STOP = "MamaPlusTargetLead", "MamaPlusStopFollow"
local NAMES, slotOf = { LEAD }, {}                  -- button names in binding order; name -> slot number
for n = 1, 5 do
  NAMES[#NAMES + 1] = "MamaPlusTarget" .. n
  slotOf["MamaPlusTarget" .. n] = n
end
NAMES[#NAMES + 1] = STOP

BINDING_HEADER_MAMAPLUS = "Mama-forever Plus"
_G["BINDING_NAME_CLICK MamaPlusTargetLead:LeftButton"] = "Target lead"
for n = 1, 5 do _G["BINDING_NAME_CLICK MamaPlusTarget" .. n .. ":LeftButton"] = "Target slot " .. n end
_G["BINDING_NAME_CLICK MamaPlusStopFollow:LeftButton"] = "Stop following"

local buttons = {}                                  -- name -> button, made at LOGIN
local warned = {}                                   -- name -> GetTime() of the last dead-key line
local pending = false                               -- a refresh waits for combat to end

local function Action(name) return "CLICK " .. name .. ":LeftButton" end

-- Unit token of a grouped team member, plain or nil.
local function Unit(name)
  return ns.PlainOfType(ns.UnitOf(name), "string", nil)
end

-- The macro text a button should carry now.
local function TextFor(name)
  if name == STOP then return "/follow player" end
  if name == LEAD then return "/target " .. (Unit(ns.LeadName()) or "player") end
  local member = ns.Slots()[slotOf[name]]
  if member == nil then return "" end
  if member == ns.MyName() then return "/target player" end
  local unit = Unit(member)
  return unit and ("/target " .. unit) or ""
end

local function MakeButton(name)
  local b = CreateFrame("Button", name, UIParent, "SecureActionButtonTemplate")
  b:SetAttribute("type", "macro")
  b:SetAttribute("useOnKeyDown", false)
  b:RegisterForClicks("AnyUp", "AnyDown")
  b:HookScript("PreClick", function(btn, button, down)
    local text = btn:GetAttribute("macrotext")
    ns.Debug(name, "pressed", button, down, text)
    if IsSecret(down) or down or IsSecret(text) or text ~= "" then return end
    local now = GetTime()
    if warned[name] and now - warned[name] < DEAD_GAP then return end
    warned[name] = now
    ns.Print("slot " .. tostring(slotOf[name]) .. " is not in the group")
  end)
  return b
end

-- Rebuilds every button's text, writing only what differs; in combat it
-- sets the pending flag and runs again at PLAYER_REGEN_ENABLED.
function Keys.Refresh()
  if not next(buttons) then return end
  if InCombatLockdown() then pending = true return end
  pending = false
  local changed = 0
  for _, name in ipairs(NAMES) do
    local b, text = buttons[name], TextFor(name)
    if b:GetAttribute("macrotext") ~= text then
      b:SetAttribute("macrotext", text)
      changed = changed + 1
    end
  end
  if changed > 0 then ns.Debug("keys refreshed:", changed, "changed, lead", tostring(ns.LeadName())) end
end

ns.Listen("LOGIN", function()
  ns.RunOutOfCombat("keys", function()
    for _, name in ipairs(NAMES) do buttons[name] = MakeButton(name) end
    Keys.Refresh()
  end)
end)
ns.Listen("TEAM_CHANGED", Keys.Refresh)
ns.On("PLAYER_ENTERING_WORLD", Keys.Refresh)
ns.On("PLAYER_REGEN_ENABLED", function() if pending then Keys.Refresh() end end)

-- "key" or "unbound" for a button, "error or missing" / "<secret>" when the API misbehaves.
local function BoundKey(name)
  local ok, key = ns.Try(GetBindingKey, Action(name))
  if not ok then return "error or missing" end
  if IsSecret(key) then return "<secret " .. type(key) .. ">" end
  return key ~= nil and tostring(key) or "unbound"
end

ns.AddCommand("keys", "show the key and macro text behind each MamaPlus binding", function()
  if not next(buttons) then ns.Print("keys: buttons are not made yet") return end
  for _, name in ipairs(NAMES) do
    local text = buttons[name]:GetAttribute("macrotext")
    ns.Print(string.format("%s [%s]: %s", name, BoundKey(name), text == "" and "(empty: slot not in the group)" or text))
  end
  if pending then ns.Print("keys: refresh waits for combat to end") end
end)

-- Lines for /mama plus probe keys (design probes K1-K5): returned, and
-- appended to the table given as the argument when there is one.
ns.AddProbe("keys", function(out)
  local lines = {}
  for _, name in ipairs(NAMES) do
    local b = buttons[name]
    lines[#lines + 1] = string.format("GetBindingKey(%s): %s; macrotext: %s", Action(name), BoundKey(name),
      b and tostring(b:GetAttribute("macrotext")) or "no button")
  end
  lines[#lines + 1] = "pending refresh: " .. tostring(pending)
  if type(out) == "table" then for _, l in ipairs(lines) do out[#out + 1] = l end end
  return lines
end)
