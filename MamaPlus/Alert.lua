local addonName, ns = ...

-- Alerts on this window: a sound, a raid-warning line, a red chat line and
-- a flash of the member's row. LeadAlert adds the two gates every lead-side
-- alert shares: this window is Mama's lead of a group, and the option is on.

local Alert = {}
ns.Alert = Alert

local FLASH_TIME = 3
Alert.FLASH_TIME = FLASH_TIME

-- text: what happened; name: the team member's full name (flashes its row); secs: flash length.
function Alert.Fire(text, name, secs)
  Alert.last = text
  if PlaySound and SOUNDKIT and SOUNDKIT.RAID_WARNING then
    pcall(PlaySound, SOUNDKIT.RAID_WARNING, "Master")
  end
  local shown = false
  if RaidNotice_AddMessage and RaidWarningFrame then
    local color = ChatTypeInfo and ChatTypeInfo.RAID_WARNING or { r = 1, g = 0.3, b = 0.1 }
    shown = pcall(RaidNotice_AddMessage, RaidWarningFrame, text, color)
  end
  ns.Print("|cffff4040" .. text .. "|r")
  if name and ns.Rows and ns.Rows.Flash then ns.Rows.Flash(name, secs or FLASH_TIME) end
  return shown
end

-- Only on Mama's lead, only when ns.db[optionKey] is on. Returns true when it fired.
function Alert.Lead(optionKey, text, name, secs)
  if optionKey and not ns.OptionOn(optionKey) then return false end
  if not ns.IsLead() then return false end
  Alert.Fire(text, name, secs)
  return true
end

setmetatable(Alert, { __call = function(_, ...) return Alert.Fire(...) end })
ns.LeadAlert = Alert.Lead
