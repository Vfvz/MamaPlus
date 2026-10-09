local addonName, ns = ...

-- Options: a "Plus" page under Mama-forever in the game's Settings panel,
-- built from ns.optionSpecs (ns.AddOption). Sections in first-seen order,
-- entries in registration order, two controls per row like Mama's own
-- pages. Content is built on first show so files that load after this one
-- still appear. Every change goes through ns.SetOption. Falls back to a
-- top-level "MamaPlus" category when Mama's category is missing.

local Options = {}
ns.Options = Options

local MF = ns.MF
local IsSecret = ns.IsSecret

local PAGE_NAME = "Plus"
local COL_W = 300        -- one control column
local LABEL_W = 200      -- label part of a number control
local ROW_H = 26
local HEADER_H = 24
local SECTION_GAP = 8
local INDENT = 8

local contents = {}

function Options.Groups()
  local groups, byName = {}, {}
  for _, spec in ipairs(ns.optionSpecs) do
    if type(spec) == "table" and type(spec.key) == "string" then
      local name = type(spec.section) == "string" and spec.section ~= "" and spec.section or "General"
      local group = byName[name]
      if not group then
        group = { name = name, entries = {} }
        byName[name] = group
        groups[#groups + 1] = group
      end
      group.entries[#group.entries + 1] = spec
    end
  end
  return groups
end

---------------------------------------------------------------------------
-- Numbers
---------------------------------------------------------------------------
local function Num(v, fallback) return ns.PlainOfType(v, "number", fallback) end

local function Step(spec)
  local step = Num(spec.step, 1)
  if step <= 0 then step = 1 end
  return step
end

local function Decimals(step)
  local s = string.format("%.6f", step):gsub("0+$", "")
  local dot = s:find(".", 1, true)
  return dot and (#s - dot) or 0
end

function Options.Snap(spec, v)
  v = tonumber(string.format("%." .. Decimals(Step(spec)) .. "f", v)) or v
  local lo, hi = Num(spec.min, nil), Num(spec.max, nil)
  if lo and v < lo then v = lo end
  if hi and v > hi then v = hi end
  if v == 0 then v = 0 end
  return v
end

function Options.CurrentNumber(spec)
  local v = Num(ns.db and ns.db[spec.key], nil)
  if v ~= nil then return v, true end
  return Num(ns.defaults[spec.key], nil) or Num(spec.min, 0), false
end

function Options.StepValue(spec, dir)
  local current = Options.CurrentNumber(spec)
  return Options.Snap(spec, current + dir * Step(spec))
end

local function FormatNumber(v)
  local s = string.format("%.4f", v):gsub("0+$", ""):gsub("%.$", "")
  return s
end

-- A toggle may be greyed by its enabledWhen; the note says why.
local function Enabled(spec)
  if type(spec.enabledWhen) ~= "function" then return true end
  local ok, v = pcall(spec.enabledWhen)
  return ok and ns.PlainTrue(v)
end

---------------------------------------------------------------------------
-- Controls
---------------------------------------------------------------------------
local function ShowTip(owner, spec)
  if not GameTooltip then return end
  local tip = type(spec.tip) == "string" and spec.tip or nil
  local note = not Enabled(spec) and type(spec.note) == "string" and spec.note or nil
  if not tip and not note then return end
  GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
  GameTooltip:SetText(spec.label or spec.key, 1, 1, 1)
  if tip then GameTooltip:AddLine(tip, 1, 0.82, 0, true) end
  if note then GameTooltip:AddLine(note, 1, 0.3, 0.3, true) end
  GameTooltip:Show()
end

local function HideTip()
  if GameTooltip then GameTooltip:Hide() end
end

local function Label(parent, text, template)
  local fs = parent:CreateFontString(nil, "OVERLAY", template or "GameFontHighlight")
  fs:SetJustifyH("LEFT")
  fs:SetWordWrap(false)
  fs:SetText(text)
  return fs
end

local function NewRow(content, spec)
  local row = CreateFrame("Frame", nil, content)
  row:SetSize(COL_W, ROW_H)
  row.spec = spec
  return row
end

local function CreateToggle(content, spec)
  local row = NewRow(content, spec)
  local check = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
  check:SetSize(24, 24)
  check:SetPoint("LEFT", row, "LEFT", 0, 0)
  row.label = Label(row, spec.label or spec.key)
  row.label:SetPoint("LEFT", check, "RIGHT", 4, 0)
  row.label:SetWidth(COL_W - 32)
  check:SetHitRectInsets(0, -(COL_W - 32), 0, 0)
  check:SetScript("OnClick", function(self)
    if not Enabled(spec) then
      self:SetChecked(false)
      if spec.note then ns.Print(spec.note) end
      return
    end
    ns.SetOption(spec.key, self:GetChecked() and true or false)
    Options.Refresh()
  end)
  check:SetScript("OnEnter", function(self) ShowTip(self, spec) end)
  check:SetScript("OnLeave", HideTip)
  row.check = check
  row.update = function()
    local v = ns.db and ns.db[spec.key]
    if IsSecret(v) then v = nil end
    local on = Enabled(spec)
    check:SetChecked(on and v and true or false)
    if check.SetEnabled then check:SetEnabled(on) end
    if on then row.label:SetTextColor(1, 1, 1) else row.label:SetTextColor(0.5, 0.5, 0.5) end
  end
  return row
end

local function CreateNumber(content, spec)
  local row = NewRow(content, spec)
  row:EnableMouse(true)
  row:SetScript("OnEnter", function(self) ShowTip(self, spec) end)
  row:SetScript("OnLeave", HideTip)
  row.label = Label(row, spec.label or spec.key)
  row.label:SetPoint("LEFT", row, "LEFT", 4, 0)
  row.label:SetWidth(LABEL_W - 8)
  local function StepButton(text, dir)
    local b = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    b:SetSize(22, 20)
    b:SetText(text)
    b:SetScript("OnClick", function()
      ns.SetOption(spec.key, Options.StepValue(spec, dir))
      Options.Refresh()
    end)
    b:SetScript("OnEnter", function(self) ShowTip(self, spec) end)
    b:SetScript("OnLeave", HideTip)
    return b
  end
  row.minus = StepButton("-", -1)
  row.minus:SetPoint("LEFT", row, "LEFT", LABEL_W, 0)
  row.value = Label(row, "")
  row.value:SetWidth(44)
  row.value:SetJustifyH("CENTER")
  row.value:SetPoint("LEFT", row.minus, "RIGHT", 2, 0)
  row.plus = StepButton("+", 1)
  row.plus:SetPoint("LEFT", row.value, "RIGHT", 2, 0)
  row.update = function()
    local v, plain = Options.CurrentNumber(spec)
    row.value:SetText(plain and FormatNumber(v) or "?")
    local lo, hi = Num(spec.min, nil), Num(spec.max, nil)
    row.minus:SetEnabled(not (plain and lo and v <= lo))
    row.plus:SetEnabled(not (plain and hi and v >= hi))
  end
  return row
end

local function CreateControl(content, spec)
  if spec.type == "number" then return CreateNumber(content, spec) end
  if spec.type == "toggle" or spec.type == nil then return CreateToggle(content, spec) end
  ns.Debug("options: unsupported option type", tostring(spec.type), "for", spec.key)
  return nil
end

local function CreateHeader(content, name)
  local header = Label(content, name, "GameFontNormal")
  header.line = content:CreateTexture(nil, "ARTWORK")
  header.line:SetSize(COL_W * 2 - 4, 1)
  header.line:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -3)
  header.line:SetColorTexture(1, 1, 1, 0.15)
  return header
end

---------------------------------------------------------------------------
-- Layout: two controls per row within a section.
---------------------------------------------------------------------------
local function Layout(content)
  local y = 0
  for _, group in ipairs(Options.Groups()) do
    local header = content.headers[group.name]
    if not header then
      header = CreateHeader(content, group.name)
      content.headers[group.name] = header
    end
    header:ClearAllPoints()
    header:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -y)
    y = y + HEADER_H
    local col = 0
    for _, spec in ipairs(group.entries) do
      local row = content.rows[spec]
      if row == nil then
        row = CreateControl(content, spec) or false
        content.rows[spec] = row
      end
      if row then
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", content, "TOPLEFT", INDENT + col * COL_W, -y)
        col = col + 1
        if col == 2 then col = 0; y = y + ROW_H end
      end
    end
    if col == 1 then y = y + ROW_H end
    y = y + SECTION_GAP
  end
  content.height = y
  content:SetHeight(math.max(y, 1))
  content.count = #ns.optionSpecs
end

local function RefreshContent(content)
  for _, row in pairs(content.rows) do
    if row then row.update() end
  end
end

function Options.Refresh()
  for _, content in ipairs(contents) do RefreshContent(content) end
end

-- Scroll host only when the content is taller than the panel.
local function Fit(host)
  local content = host.content
  if not host.scroll then
    local avail = Num(host:GetHeight(), 0) - host.top - host.bottom
    if avail > 0 and content.height <= avail then
      if not content.placed then
        content:SetParent(host)
        content:ClearAllPoints()
        content:SetPoint("TOPLEFT", host, "TOPLEFT", host.padX, -host.top)
        content.placed = true
      end
      return
    end
    local scroll = CreateFrame("ScrollFrame", nil, host, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", host, "TOPLEFT", host.padX, -host.top)
    scroll:SetPoint("BOTTOMRIGHT", host, "BOTTOMRIGHT", -(host.padX + 22), host.bottom)
    scroll.scrollBarHideable = true
    host.scroll = scroll
  end
  if content.inScroll then return end
  content:SetParent(host.scroll)
  content:ClearAllPoints()
  host.scroll:SetScrollChild(content)
  content.inScroll = true
end

local function OnHostShow(host)
  local content = host.content
  if not content then
    content = CreateFrame("Frame", nil, host)
    content:SetWidth(COL_W * 2)
    content.headers, content.rows, content.count = {}, {}, -1
    host.content = content
    contents[#contents + 1] = content
  end
  if content.count ~= #ns.optionSpecs then Layout(content) end
  Fit(host)
  RefreshContent(content)
end
Options.OnHostShow = OnHostShow

---------------------------------------------------------------------------
-- The panel and its registration
---------------------------------------------------------------------------
local function CreatePanel(title)
  local panel = CreateFrame("Frame")
  panel.name = title
  panel:Hide()
  local head = Label(panel, title, "GameFontNormalLarge")
  head:SetPoint("TOPLEFT", panel, "TOPLEFT", 16, -16)
  local sub = Label(panel, "|cff888888MamaPlus " .. ns.Version() .. "   /mama plus options|r", "GameFontHighlightSmall")
  sub:SetPoint("BOTTOMLEFT", head, "BOTTOMRIGHT", 8, 1)
  panel.padX, panel.top, panel.bottom = 16, 48, 16
  panel:SetScript("OnShow", OnHostShow)
  return panel
end

-- Returns "sub" (page under Mama-forever), "top" (own category) or nil.
function Options.Register()
  if Options.mode then return Options.mode end
  if not Settings then return nil end
  Options.panel = Options.panel or CreatePanel("Mama-forever: Plus")
  if MF and MF.category and Settings.RegisterCanvasLayoutSubcategory then
    local ok, cat = pcall(Settings.RegisterCanvasLayoutSubcategory, MF.category, Options.panel, PAGE_NAME)
    if ok and not IsSecret(cat) and cat ~= nil then
      Options.category, Options.mode = cat, "sub"
      return "sub"
    end
    ns.Debug("Settings.RegisterCanvasLayoutSubcategory failed:", cat)
  end
  if Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory then
    local ok, cat = pcall(Settings.RegisterCanvasLayoutCategory, Options.panel, "MamaPlus")
    if ok and not IsSecret(cat) and cat ~= nil then
      local added, err = pcall(Settings.RegisterAddOnCategory, cat)
      if added then
        Options.category, Options.mode = cat, "top"
        return "top"
      end
      ns.Debug("Settings.RegisterAddOnCategory failed:", err)
    end
  end
  return nil
end

ns.Listen("LOGIN", function() Options.Register() end)

local function CategoryID(cat)
  if type(cat) ~= "table" then return cat end
  if type(cat.GetID) == "function" then
    local ok, id = pcall(cat.GetID, cat)
    if ok and not IsSecret(id) and id ~= nil then return id end
  end
  local id = cat.ID
  if not IsSecret(id) and id ~= nil then return id end
  return cat
end

function Options.Open()
  if not Options.Register() or not (Settings and Settings.OpenToCategory) then
    ns.Print("no settings panel on this client: use /mama plus commands instead")
    return
  end
  local ran = ns.RunOutOfCombat("plusoptions", function()
    local ok, err = pcall(Settings.OpenToCategory, CategoryID(Options.category))
    if not ok then ns.Debug("Settings.OpenToCategory failed:", err) end
  end)
  if not ran then ns.Print("the settings panel will open after combat") end
end

ns.AddCommand("options", "open the MamaPlus settings page", Options.Open)
