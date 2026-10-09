-- Tests for Options.lua: grouping, Snap/StepValue, registration as a
-- "Plus" subcategory of Mama's category at LOGIN (and the top-level,
-- nil fallbacks), lazy layout two per row, the toggle and -/+ number
-- controls through ns.SetOption, enabledWhen greying with the note, the
-- scroll host for tall content, options added after the first show and
-- Open deferred in combat.
dofile("tests/mock.lua")
local function check(c, m) if not c then error("ASSERT: " .. m, 2) end end
local errors = {}
function geterrorhandler() return function(err) errors[#errors + 1] = tostring(err) end end

local O = ns.Options
-- Options registered before login, like feature files do.
ns.AddDefaults({ tHard = true, tNum = 2, tOdd = 1 })
local hardOn = false
ns.AddOption({ key = "tHard", label = "Auto-release", section = "Death", type = "toggle", tip = "release after a countdown",
  enabledWhen = function() return hardOn end, note = "click Release once on this build first" })
ns.AddOption({ key = "tNum", label = "Seconds", section = "Death", type = "number", min = 1, max = 3, step = 0.5, tip = "how long" })
ns.AddOption({ key = "tOdd", label = "Odd", section = "Death", type = "colour" })
ns.AddOption({ key = "tSecretWhen", label = "Secret gate", section = "Death", enabledWhen = function() return MakeSecret("boolean") end })
ns.AddOption({ key = "tRaises", label = "Raising gate", section = "Death", enabledWhen = function() error("x") end })
ns.AddOption({ key = "tNoSection", label = "No section" })
ns.AddOption({ key = 5 })                       -- ignored: no string key
ns.AddOption("junk")                            -- ignored: not a table

---------------------------------------------------------------------------
-- Groups: sections in first-seen order, entries in registration order
---------------------------------------------------------------------------
local groups = O.Groups()
local names, byName, at = {}, {}, {}
for i, g in ipairs(groups) do names[i] = g.name; byName[g.name] = g; at[g.name] = i end
local function keys(g) local t = {}; for i, e in ipairs(g.entries) do t[i] = e.key end return table.concat(t, ",") end
check(#groups == 4 and byName["This window"] and byName["Team rows"] and byName.Death and byName.General,
  "sections: " .. table.concat(names, ","))
-- The foundation's sections come first (seen at load), then the ones feature files add, "General" last.
check(at["This window"] < at.Death and at["Team rows"] < at.Death and at.General == #groups, "section order: " .. table.concat(names, ","))
check(keys(byName["This window"]):find("debug", 1, true) and keys(byName["Team rows"]):find("rowIcons", 1, true)
  and keys(byName["Team rows"]):find("durWarn", 1, true), "built-in entries: " .. keys(byName["This window"]) .. " / " .. keys(byName["Team rows"]))
check(keys(byName.Death) == "tHard,tNum,tOdd,tSecretWhen,tRaises", "Death entries in registration order: " .. keys(byName.Death))
check(keys(byName.General) == "tNoSection", "General entries: " .. keys(byName.General))

---------------------------------------------------------------------------
-- Snap / CurrentNumber / StepValue
---------------------------------------------------------------------------
local numSpec = { key = "tNum", min = 1, max = 3, step = 0.5 }
check(O.Snap(numSpec, 0.1 + 0.2 + 1) == 1.3, "rounding to the step's decimals")
check(O.Snap(numSpec, 3.5) == 3 and O.Snap(numSpec, 0) == 1, "clamp")
check(O.Snap({ step = 5 }, 27.6) == 28, "whole-number step rounds to whole numbers")
check(O.Snap({}, 2.4) == 2 and O.Snap({ step = -1 }, 3.6) == 4, "missing/bad step treated as 1")
check(1 / O.Snap({ min = -1 }, -0.00001) > 0, "negative zero")
check(O.Snap({ step = 0.05, min = 0.5, max = 2 }, 0.5 + 0.05) == 0.55, "two-decimal step")
local v, plain = O.CurrentNumber(numSpec)
check(v == 2 and plain == false, "CurrentNumber before the db: the default")
check(O.CurrentNumber({ key = "nothing", min = 4 }) == 4 and O.CurrentNumber({ key = "nothing" }) == 0, "CurrentNumber falls back to min, then 0")
check(O.StepValue(numSpec, 1) == 2.5 and O.StepValue(numSpec, -1) == 1.5, "StepValue")

---------------------------------------------------------------------------
-- Registration at LOGIN: "Plus" under Mama's category
---------------------------------------------------------------------------
check(O.mode == nil and O.panel == nil, "registered before LOGIN")
Login()
check(O.mode == "sub" and O.Register() == "sub", "subcategory mode: " .. tostring(O.mode))
local cat = settingsCategories[#settingsCategories]
check(cat == O.category and cat.ID == "sub-Plus" and cat.parent == MamaForever.category and cat.frame == O.panel
  and cat.name == "Plus", "subcategory registration")
check(#settingsCategories == 2, "categories registered: " .. #settingsCategories)
check(O.panel.name == "Mama-forever: Plus" and O.panel.shown == false and O.panel.content == nil, "panel built lazily")
check(ns.commands.options, "options command")

---------------------------------------------------------------------------
-- First show: layout, two controls per row, headers
---------------------------------------------------------------------------
O.panel.h = 600   -- the canvas has a size when shown; this content fits, no scroll host
O.panel:Show()
local c = O.panel.content
check(c and c.parent == O.panel and c.placed and not O.panel.scroll and c.inScroll == nil, "content placed without a scroll host")
check(c.count == #ns.optionSpecs and c.height > 0 and c.h == c.height, "layout count/height")
local function rowFor(key)
  for spec, r in pairs(c.rows) do if r and spec.key == key then return r end end
end
local function pointOf(r) local pt = r.points[#r.points]; return pt[4], pt[5] end
-- Placement relative to a row's own size: the second control of a row sits one
-- column width to the right at the same y, the next row one row height lower.
local colW, rowH = rowFor("rowIcons").w, rowFor("rowIcons").h
check(colW > 0 and rowH > 0, "row size")
local x1, y1 = pointOf(rowFor("rowIcons"))
local x2, y2 = pointOf(rowFor("durWarn"))
check(x2 == x1 + colW and y1 == y2, string.format("two per row: %s,%s %s,%s", x1, y1, x2, y2))
local xh, yh = pointOf(rowFor("tHard"))
local xn, yn = pointOf(rowFor("tNum"))
local xs, ys = pointOf(rowFor("tSecretWhen"))
check(xh == x1 and xn == x1 + colW and yh == yn and xs == x1 and ys == yh - rowH, "wrap after two")
local oddSpec
for _, spec in ipairs(ns.optionSpecs) do if spec.key == "tOdd" then oddSpec = spec end end
check(rowFor("tOdd") == nil and c.rows[oddSpec] == false, "unsupported type got a control")
check(rowFor("tNoSection") and rowFor("debug") and #c.headers == 0, "controls")
local hy = {}
for _, name in ipairs({ "This window", "Team rows", "Death", "General" }) do
  check(c.headers[name] and c.headers[name].text == name, "header " .. name)
  hy[#hy + 1] = select(2, pointOf(c.headers[name]))
end
check(hy[1] == 0 and hy[1] > hy[2] and hy[2] > hy[3] and hy[3] > hy[4], "header order")

---------------------------------------------------------------------------
-- Toggle: click -> ns.SetOption, refreshed from elsewhere, secret-safe
---------------------------------------------------------------------------
local function clickCheck(cb) cb:SetChecked(not cb:GetChecked()); cb:RunScript("OnClick") end
local function click(b) b:RunScript("OnClick") end
local ri = rowFor("rowIcons")
check(ri.check.checked == true and ri.check.template == "UICheckButtonTemplate" and ri.label.text == "Icons on the Mama status rows"
  and ri.check.enabled ~= false and ri.label.textColor[1] == 1, "rowIcons control")
clickCheck(ri.check)
check(ns.db.rowIcons == false and ri.check.checked == false, "toggle off through SetOption")
clickCheck(ri.check)
check(ns.db.rowIcons == true and ri.check.checked == true, "toggle on")
ns.SetOption("rowIcons", false); check(ri.check.checked == false, "control not refreshed by SetOption")
ns.SetOption("rowIcons", true); check(ri.check.checked == true, "control not refreshed back")
ns.db.rowIcons = MakeSecret("boolean"); O.Refresh(); check(ri.check.checked == false, "secret value shown as checked")
ns.db.rowIcons = true; O.Refresh()
GameTooltip:Hide()
local shows = GameTooltip.shows
ri.check:RunScript("OnEnter")
check(GameTooltip.lines[1] == "Icons on the Mama status rows" and GameTooltip.lines[2]:find("Hover a row", 1, true)
  and #GameTooltip.lines == 2 and GameTooltip.shows == shows + 1, "toggle tooltip: " .. table.concat(GameTooltip.lines, " / "))
ri.check:RunScript("OnLeave"); check(#GameTooltip.lines == 0, "tooltip not hidden")

---------------------------------------------------------------------------
-- Number: -/+ step, clamp, snap, buttons disabled at the bounds
---------------------------------------------------------------------------
local dw = rowFor("durWarn")
check(dw.value.text == "25" and dw.minus.text == "-" and dw.plus.text == "+" and dw.label.text == "Durability icon below this percent"
  and dw.minus.template == "UIPanelButtonTemplate", "durWarn control")
click(dw.plus); check(ns.db.durWarn == 30 and dw.value.text == "30", "plus")
click(dw.minus); click(dw.minus); check(ns.db.durWarn == 20 and dw.value.text == "20", "minus")
ns.db.durWarn = 23; O.Refresh(); click(dw.plus); check(ns.db.durWarn == 28, "step from an off-grid value (rounded, not snapped)")
ns.db.durWarn = 98; O.Refresh(); click(dw.plus)
check(ns.db.durWarn == 100 and dw.value.text == "100" and dw.plus.enabled == false and dw.minus.enabled == true, "clamp at max")
click(dw.plus); check(ns.db.durWarn == 100, "plus past max")
ns.db.durWarn = 2; O.Refresh(); click(dw.minus)
check(ns.db.durWarn == 0 and dw.minus.enabled == false and dw.plus.enabled == true and dw.value.text == "0", "clamp at min")
ns.SetOption("durWarn", 25)
check(dw.value.text == "25" and dw.plus.enabled and dw.minus.enabled, "refreshed by SetOption")
local tn = rowFor("tNum")
check(tn.value.text == "2", "tNum text")
click(tn.plus); check(ns.db.tNum == 2.5 and tn.value.text == "2.5", "half step")
click(tn.plus); click(tn.plus); check(ns.db.tNum == 3 and tn.plus.enabled == false, "half step clamp")
for _ = 1, 5 do click(tn.minus) end
check(ns.db.tNum == 1 and tn.minus.enabled == false and tn.value.text == "1", "half step min")
ns.db.tNum = MakeSecret("number"); O.Refresh()
check(tn.value.text == "?" and tn.plus.enabled and tn.minus.enabled, "secret value shows ?")
click(tn.plus); check(ns.db.tNum == 2.5, "step from a secret value starts at the default")
shows = GameTooltip.shows
tn.plus:RunScript("OnEnter")
check(GameTooltip.lines[1] == "Seconds" and GameTooltip.lines[2] == "how long" and GameTooltip.shows == shows + 1, "number button tooltip")
tn.plus:RunScript("OnLeave"); tn:RunScript("OnEnter")
check(GameTooltip.lines[2] == "how long", "number row tooltip"); tn:RunScript("OnLeave")
dw.plus:RunScript("OnEnter"); check(#GameTooltip.lines == 0, "tooltip for a control without tip")

---------------------------------------------------------------------------
-- enabledWhen: greyed, click refused with the note, tooltip note
---------------------------------------------------------------------------
local th = rowFor("tHard")
check(th.check.checked == false and th.check.enabled == false and th.label.textColor[1] == 0.5, "greyed toggle")
check(ns.db.tHard == true, "db value changed by greying")
th.check:SetChecked(true); click(th.check)
check(ns.db.tHard == true and th.check.checked == false and mamaPrinted[#mamaPrinted]:find("click Release once on this build first", 1, true),
  "greyed click not refused with the note")
shows = GameTooltip.shows
th.check:RunScript("OnEnter")
check(#GameTooltip.lines == 3 and GameTooltip.lines[1] == "Auto-release" and GameTooltip.lines[2] == "release after a countdown"
  and GameTooltip.lines[3] == "click Release once on this build first" and GameTooltip.shows == shows + 1,
  "greyed tooltip: " .. table.concat(GameTooltip.lines, " / "))
th.check:RunScript("OnLeave")
hardOn = true; O.Refresh()
check(th.check.checked == true and th.check.enabled == true and th.label.textColor[1] == 1, "enabled toggle shows the value")
th.check:RunScript("OnEnter"); check(#GameTooltip.lines == 2, "note shown while enabled"); th.check:RunScript("OnLeave")
clickCheck(th.check); check(ns.db.tHard == false, "enabled toggle click")
ns.SetOption("tHard", true)
check(rowFor("tSecretWhen").check.enabled == false and rowFor("tRaises").check.enabled == false, "secret/raising enabledWhen not greyed")
local dr = rowFor("debug")
shows = GameTooltip.shows
dr.check:RunScript("OnEnter"); check(GameTooltip.shows == shows and #GameTooltip.lines == 0, "tooltip without tip or note")

---------------------------------------------------------------------------
-- Options added after the first show appear on the next show; tall content
-- gets a scroll host
---------------------------------------------------------------------------
ns.AddOption({ key = "tLate", label = "Late", section = "Team rows", type = "toggle" })
check(rowFor("tLate") == nil, "late option laid out before a show")
O.panel:Hide(); O.panel:Show()
check(rowFor("tLate") and c.count == #ns.optionSpecs and O.panel.content == c, "late option not laid out on show")
local xl, yl = pointOf(rowFor("tLate"))
check(xl == 8 and yl == y1 - 26, "late option position")
check(not O.panel.scroll and c.parent == O.panel, "scroll host for short content")
for i = 1, 40 do ns.AddOption({ key = "tBulk" .. i, label = "Bulk " .. i, section = "Bulk" }) end
O.panel:Hide(); O.panel:Show()
check(c.height > 600 - 48 - 16, "content not taller than the panel")
check(O.panel.scroll and O.panel.scroll.template == "UIPanelScrollFrameTemplate" and c.inScroll and c.parent == O.panel.scroll
  and O.panel.scroll.scrollChild == c, "scroll host for tall content")
local scroll = O.panel.scroll
O.panel:Hide(); O.panel:Show()
check(O.panel.scroll == scroll and c.parent == scroll, "re-show changed the scroll host")
check(rowFor("tBulk40") and select(2, pointOf(rowFor("tBulk40"))) < yl, "bulk rows laid out")

---------------------------------------------------------------------------
-- Open: now, deferred in combat, missing API
---------------------------------------------------------------------------
openedCategory = nil
ns.RunCommand("options")
check(openedCategory == "sub-Plus", "OpenToCategory id: " .. tostring(openedCategory))
openedCategory = nil
state.combat = true
O.Open()
check(openedCategory == nil and mamaPrinted[#mamaPrinted]:find("will open after combat", 1, true), "open in combat")
state.combat = false
Fire("PLAYER_REGEN_ENABLED")
check(openedCategory == "sub-Plus", "deferred open did not run")
local open = Settings.OpenToCategory
Settings.OpenToCategory = nil; openedCategory = nil
O.Open(); check(openedCategory == nil and mamaPrinted[#mamaPrinted]:find("no settings panel", 1, true), "missing OpenToCategory")
Settings.OpenToCategory = function() error("nope") end
O.Open()   -- contained
Settings.OpenToCategory = open

---------------------------------------------------------------------------
-- Fallbacks: reset the cached mode and register again as other clients
-- would (no subcategory API, a raising or nil or secret result, no Mama
-- category, no API at all, no Settings)
---------------------------------------------------------------------------
local subReg, catReg, addReg = Settings.RegisterCanvasLayoutSubcategory, Settings.RegisterCanvasLayoutCategory, Settings.RegisterAddOnCategory
local mfCat = MamaForever.category
local function reregister() O.mode, O.category = nil, nil; return O.Register() end
Settings.RegisterCanvasLayoutSubcategory = nil
check(reregister() == "top" and O.category.ID == "cat-MamaPlus" and O.category.frame == O.panel and O.category.name == "MamaPlus",
  "top-level fallback without the subcategory API")
check(O.Register() == "top" and O.mode == "top", "mode cached")
Settings.RegisterCanvasLayoutSubcategory = function() error("no parent") end
check(reregister() == "top", "fallback when the subcategory call raises")
Settings.RegisterCanvasLayoutSubcategory = function() return nil end
check(reregister() == "top", "fallback when the subcategory call returns nil")
Settings.RegisterCanvasLayoutSubcategory = function() return MakeSecret("table") end
check(reregister() == "top", "fallback when the category is secret")
Settings.RegisterCanvasLayoutSubcategory = subReg
MamaForever.category = nil
check(reregister() == "top", "fallback without Mama's category")
Settings.RegisterCanvasLayoutCategory = nil
check(reregister() == nil, "no category API at all")
openedCategory = nil
O.Open(); check(openedCategory == nil and mamaPrinted[#mamaPrinted]:find("no settings panel", 1, true), "Open without a category")
Settings.RegisterCanvasLayoutCategory = catReg
Settings.RegisterAddOnCategory = function() error("x") end
check(reregister() == nil, "RegisterAddOnCategory raising")
Settings.RegisterAddOnCategory = addReg
local S = Settings
Settings = nil
check(reregister() == nil, "no Settings")
Settings = S
MamaForever.category = mfCat
check(reregister() == "sub" and O.category.ID == "sub-Plus", "back to the subcategory")
openedCategory = nil; O.Open(); check(openedCategory == "sub-Plus", "open after re-registration")

---------------------------------------------------------------------------
-- A panel shown before the canvas gave it a height (0) gets the scroll host
-- at once, without an error, and keeps it once a height arrives (Fit's
-- scroll-vs-place choice is made once)
---------------------------------------------------------------------------
local firstPanel = O.panel
O.panel, O.mode, O.category = nil, nil, nil
check(O.Register() == "sub" and O.panel ~= firstPanel, "second panel")
local p2 = O.panel
check(p2.h == nil and p2:GetHeight() == 0 and p2.content == nil, "fresh panel without a height")
p2:Show()
local c2 = p2.content
check(c2 and p2.scroll and p2.scroll.template == "UIPanelScrollFrameTemplate" and c2.inScroll == true and c2.parent == p2.scroll
  and p2.scroll.scrollChild == c2 and not c2.placed and c2.count == #ns.optionSpecs, "zero-height canvas: scroll host")
check(#errors == 0, "zero-height show raised: " .. table.concat(errors, " | "))
local scroll2 = p2.scroll
p2.h = 5000   -- tall enough to place the content directly, had the choice not been made
p2:Hide(); p2:Show()
check(p2.scroll == scroll2 and c2.parent == scroll2 and c2.inScroll == true and not c2.placed, "scroll host dropped once a height arrived")
check(rowFor("durWarn").value.text == "25", "first panel's controls still refreshed")

check(#errors == 0, "unexpected handler errors: " .. table.concat(errors, " | "))
print("OPTIONS TESTS PASSED")
