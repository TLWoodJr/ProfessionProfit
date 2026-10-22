-- ProfessionProfit: Restocking window: view, edit and clear restock targets.

local ADDON, ns = ...
local msg, refresh = ns.msg, ns.refresh
local db
ns.onInit(function(saved) db = saved end)

local toggleTargetsWindow -- (true) only refreshes the window

------------------------------------------------------------------------------
-- Restocking window: view, edit and clear the remembered restock targets
------------------------------------------------------------------------------

do
  local win
  local TROW, TROWS = 20, 12

  -- Older targets were saved as just a number: look up the recipe's name.
  local function targetName(id, t)
    if type(t) == "table" and t.name then return t.name end
    local info = C_TradeSkillUI and C_TradeSkillUI.GetRecipeInfo and C_TradeSkillUI.GetRecipeInfo(id)
    return info and info.name or ("recipe " .. id)
  end

  local function sortedTargets()
    local list = {}
    for id, t in pairs(db.queueTargets or {}) do
      list[#list + 1] = { id = id, name = targetName(id, t), n = type(t) == "table" and t.n or t }
    end
    table.sort(list, function(a, b) return a.name < b.name end)
    return list
  end

  local update
  local function setTarget(id, n)
    local t = db.queueTargets and db.queueTargets[id]
    if not t then return end
    if not n or n < 1 then
      db.queueTargets[id] = nil
    elseif type(t) == "table" then
      t.n = n
    else
      db.queueTargets[id] = n
    end
    update()
    if refresh then refresh() end
  end

  local function createRow(i)
    local row = CreateFrame("Frame", nil, win.content)
    row:SetHeight(TROW)
    row:SetPoint("TOPLEFT", 0, -(i - 1) * TROW)
    row:SetPoint("RIGHT")
    row.remove = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    row.remove:SetSize(18, 16)
    row.remove:SetPoint("RIGHT")
    row.remove:SetText("x")
    row.remove:SetScript("OnClick", function() if row.id then setTarget(row.id, nil) end end)
    row.box = CreateFrame("EditBox", nil, row, "InputBoxTemplate")
    row.box:SetSize(40, 18)
    row.box:SetPoint("RIGHT", row.remove, "LEFT", -8, 0)
    row.box:SetAutoFocus(false)
    row.box:SetNumeric(true)
    row.box:SetMaxLetters(4)
    row.box:SetJustifyH("RIGHT")
    local function save(self)
      if row.id then setTarget(row.id, tonumber(self:GetText())) end
      self:ClearFocus()
    end
    row.box:SetScript("OnEnterPressed", save)
    row.box:SetScript("OnEditFocusLost", save)
    row.box:SetScript("OnEscapePressed", function(self) self:SetText(tostring(row.n or "")) self:ClearFocus() end)
    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.name:SetPoint("LEFT", 4, 0)
    row.name:SetPoint("RIGHT", row.box, "LEFT", -10, 0)
    row.name:SetJustifyH("LEFT")
    row.name:SetWordWrap(false)
    return row
  end

  update = function()
    if not win or not win:IsShown() then return end
    local list = sortedTargets()
    win.content:SetHeight(math.max(#list * TROW, 1))
    for i, t in ipairs(list) do
      local row = win.rows[i] or createRow(i)
      win.rows[i] = row
      row.id, row.n = t.id, t.n
      row.name:SetText(t.name)
      if not row.box:HasFocus() then row.box:SetText(tostring(t.n)) end
      row:Show()
    end
    for i = #list + 1, #win.rows do
      win.rows[i]:Hide()
      win.rows[i].id = nil
    end
    win.empty:SetShown(#list == 0)
  end

  local function create()
    win = CreateFrame("Frame", "ProfessionProfitRestockWindow", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    win:SetSize(320, 112 + TROWS * TROW)
    win:SetPoint("CENTER")
    win:SetFrameStrata("DIALOG")
    win:SetToplevel(true)
    win:SetClampedToScreen(true)
    win:EnableMouse(true)
    win:SetMovable(true)
    win:RegisterForDrag("LeftButton")
    win:SetScript("OnDragStart", win.StartMoving)
    win:SetScript("OnDragStop", win.StopMovingOrSizing)
    if win.SetBackdrop then
      win:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 16, insets = { left = 4, right = 4, top = 4, bottom = 4 },
      })
      win:SetBackdropColor(0.07, 0.06, 0.05, 0.97)
      win:SetBackdropBorderColor(0.6, 0.5, 0.3, 1)
    end
    tinsert(UISpecialFrames, "ProfessionProfitRestockWindow") -- Esc closes it
    local close = CreateFrame("Button", nil, win, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -2, -2)

    local title = win:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", 14, -12)
    title:SetText("Restocking")
    local hint = win:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("TOPLEFT", 14, -30)
    hint:SetPoint("RIGHT", -14, 0)
    hint:SetJustifyH("LEFT")
    hint:SetText("Queueing tops each item up to its target. Edit a number and press Enter; 0 or x removes it.")

    local scroll = CreateFrame("ScrollFrame", "ProfessionProfitRestockScroll", win, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 10, -72)
    scroll:SetPoint("RIGHT", -30, 0)
    scroll:SetHeight(TROWS * TROW)
    win.content = CreateFrame("Frame", nil, scroll)
    win.content:SetSize(1, 1)
    scroll:SetScrollChild(win.content)
    scroll:SetScript("OnSizeChanged", function(_, width) win.content:SetWidth(width) end)
    win.rows = {}
    win.empty = win:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    win.empty:SetPoint("TOP", scroll, "TOP", 0, -20)
    win.empty:SetText("No restock targets. Use Save Restock in the craft queue, or \"Restock to\" after clicking + on a recipe.")

    local clear = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
    clear:SetSize(80, 22)
    clear:SetPoint("BOTTOMRIGHT", -12, 12)
    clear:SetText("Clear")
    clear:SetScript("OnClick", function()
      if not IsShiftKeyDown() then
        msg("Shift-click Clear to forget every restock target.")
        return
      end
      db.queueTargets = {}
      msg("Restock targets cleared.")
      update()
      if refresh then refresh() end
    end)
    clear:SetScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_TOP")
      GameTooltip:AddLine("Clear all targets")
      GameTooltip:AddLine("Shift-click to forget every restock target. Use Restock then fills everything to Qty.", 1, 1, 1, true)
      GameTooltip:Show()
    end)
    clear:SetScript("OnLeave", GameTooltip_Hide)

    win:SetScript("OnShow", update)
    win:Hide()
  end

  toggleTargetsWindow = function(refreshOnly)
    if refreshOnly then
      if win then update() end
      return
    end
    if not win then create() end
    win:SetShown(not win:IsShown())
  end
  ns.toggleTargetsWindow = toggleTargetsWindow
end
