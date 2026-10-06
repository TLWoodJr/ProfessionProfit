-- ProfessionProfit: The Profit tab: the recipe table with cost, price and profit, and its controls.

local ADDON, ns = ...
local ROW_HEIGHT, API, RED, GREY, GREEN, DIFFICULTY_COLORS = ns.ROW_HEIGHT, ns.API, ns.RED, ns.GREY, ns.GREEN, ns.DIFFICULTY_COLORS
local log, professionInfo, expandAll, isBoP, ownedAuctions, evaluate = ns.log, ns.professionInfo, ns.expandAll, ns.isBoP, ns.ownedAuctions, ns.evaluate
local readRecipes, openRecipeInUI, closeHost, updateScanButton, startScan = ns.readRecipes, ns.openRecipeInUI, ns.closeHost, ns.updateScanButton, ns.startScan
local db
ns.onInit(function(saved) db = saved end)

local panel, refresh -- the Profit panel (createPanel) and its refresh, defined below


------------------------------------------------------------------------------
-- Table UI
------------------------------------------------------------------------------

local COLUMNS = {
  { key = "name",   title = "Recipe",    width = nil, justify = "LEFT" },
  { key = "cost",   title = "Cost",      width = 95,  justify = "RIGHT" },
  { key = "sell",   title = "Sells for", width = 95,  justify = "RIGHT" },
  { key = "profit", title = "Profit",    width = 95,  justify = "RIGHT" },
  { key = "margin", title = "Margin",    width = 60,  justify = "RIGHT" },
  { key = "stock",  title = "Stock",     width = 45,  justify = "RIGHT" },
  { key = "queue",  title = "",          width = 22,  justify = "CENTER", noSort = true },
}

local SORT_VALUE = {
  name = function(r) return r.name end,
  stock = function(r) return r.stock end,
  cost = function(r) return r.cost end,
  sell = function(r) return r.sell end,
  profit = function(r) return r.profit end,
  margin = function(r) return r.margin end,
}

local function sortRecipes(list)
  if not SORT_VALUE[db.sortKey] then db.sortKey, db.sortDesc = "profit", true end -- e.g. old "Can make" sort
  local getter, desc = SORT_VALUE[db.sortKey], db.sortDesc
  table.sort(list, function(a, b)
    local va, vb = getter(a), getter(b)
    if va == nil and vb == nil then return a.name < b.name end
    if va == nil then return false end   -- unknown values always last
    if vb == nil then return true end
    if va == vb then return a.name < b.name end
    if desc then return va > vb end
    return va < vb
  end)
end

local function layoutColumns(parent, row)
  local right = -4
  for i = #COLUMNS, 2, -1 do
    local col = COLUMNS[i]
    row.cells[col.key]:ClearAllPoints()
    row.cells[col.key]:SetPoint("RIGHT", row, "RIGHT", right, 0)
    row.cells[col.key]:SetWidth(col.width)
    right = right - col.width - 6
  end
  row.cells.name:ClearAllPoints()
  row.cells.name:SetPoint("LEFT", row, "LEFT", 4, 0)
  row.cells.name:SetPoint("RIGHT", row, "RIGHT", right, 0)
end

local function showRecipeTooltip(row)
  local recipe = row.recipe
  if not recipe then return end
  GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
  if recipe.link and not recipe.isEnchant then
    GameTooltip:SetHyperlink(recipe.link)
    GameTooltip:AddLine(" ")
  else
    GameTooltip:AddLine(recipe.name, 1, 1, 1)
  end
  GameTooltip:AddLine("Profit breakdown", 1, 0.82, 0)
  for _, reagent in ipairs(recipe.reagents) do
    local left = "  " .. reagent.count .. "x " .. (reagent.name or "?")
    local right
    if reagent.stale then
      right = API.Money(reagent.price * reagent.count) .. RED .. " " .. API.StaleText(reagent.stale) .. "|r"
    elseif reagent.price then
      right = API.Money(reagent.price * reagent.count)
      if reagent.count > 1 then right = right .. GREY .. " (" .. API.Money(reagent.price) .. " ea)|r" end
      if reagent.src == "vendor" then right = right .. GREY .. " vendor|r" end
    else
      right = RED .. "no price|r"
    end
    GameTooltip:AddDoubleLine(left, right, 0.85, 0.85, 0.85, 1, 1, 1)
  end
  local cost = API.Money(recipe.cost)
  if recipe.missing > 0 then cost = cost .. RED .. " +" .. recipe.missing .. " unpriced|r" end
  GameTooltip:AddDoubleLine("Reagent cost", cost, 1, 1, 1, 1, 1, 1)
  if recipe.isEnchant then
    GameTooltip:AddLine("Enchant: not sold on the AH.", 0.6, 0.6, 0.6)
  elseif recipe.sell then
    local each = recipe.made > 1 and (" x" .. recipe.made) or ""
    GameTooltip:AddDoubleLine("Sells for" .. each, API.Money(recipe.sell * recipe.made), 1, 1, 1, 1, 1, 1)
    GameTooltip:AddDoubleLine("After 5% AH cut", API.Money(recipe.sell * recipe.made * (1 - API.AH_CUT)), 0.85, 0.85, 0.85, 1, 1, 1)
    local good = recipe.profit >= 0
    GameTooltip:AddDoubleLine("Profit", API.Money(recipe.profit), 1, 1, 1, good and 0.2 or 1, good and 1 or 0.3, 0.2)
  else
    GameTooltip:AddDoubleLine("Sells for", RED .. "no price|r", 1, 1, 1, 1, 1, 1)
  end
  if recipe.productStale then
    GameTooltip:AddLine(("The crafted item's price is %s - Scan AH to update it."):format(API.StaleText(recipe.productStale)),
      1, 0.5, 0.5, true)
  end
  if recipe.staleCount > 0 then
    GameTooltip:AddLine("Some reagent prices are old - Scan AH to update them.", 1, 0.5, 0.5, true)
  end
  if recipe.stock then
    local owned = ownedAuctions()
    GameTooltip:AddDoubleLine("In stock", ("%d  |cffa0a0a0(bags %d, bank %d, on AH %d)|r"):format(
      recipe.stock, recipe.stockBags, recipe.stockBank, recipe.stockAH), 1, 1, 1, 1, 1, 1)
    if not owned then
      GameTooltip:AddLine("Your auctions are counted once you open the AH's Auctions tab.", 0.6, 0.6, 0.6, true)
    elseif time() - owned.time > 3600 then
      GameTooltip:AddLine(("Auction count from %s ago."):format(SecondsToTime and SecondsToTime(time() - owned.time) or "a while"), 0.6, 0.6, 0.6, true)
    end
  end
  GameTooltip:AddLine("Click to open this recipe.", 0.6, 0.6, 0.6)
  if recipe.recipeID then
    GameTooltip:AddLine("Right-click (or +) to add to the craft queue.", 0.6, 0.6, 0.6)
  end
  GameTooltip:Show()
end -- defined with the tabs below

local function selectRecipe(recipe)
  openRecipeInUI(recipe)
  ns.showRecipesTab()
end

local function createRow(parent, index)
  local row = CreateFrame("Button", nil, parent)
  row:SetHeight(ROW_HEIGHT)
  row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -(index - 1) * ROW_HEIGHT)
  row:SetPoint("RIGHT", parent, "RIGHT")
  local hl = row:CreateTexture(nil, "HIGHLIGHT")
  hl:SetAllPoints()
  hl:SetColorTexture(1, 1, 1, 0.08)
  if index % 2 == 0 then
    local stripe = row:CreateTexture(nil, "BACKGROUND")
    stripe:SetAllPoints()
    stripe:SetColorTexture(1, 1, 1, 0.03)
  end
  row.cells = {}
  for _, col in ipairs(COLUMNS) do
    local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetJustifyH(col.justify)
    fs:SetWordWrap(false)
    row.cells[col.key] = fs
  end
  layoutColumns(parent, row)

  -- Per-row "+" button: add this recipe to the craft queue.
  local plus = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
  plus:SetSize(20, 16)
  plus:SetPoint("CENTER", row.cells.queue, "CENTER")
  plus:SetText("+")
  plus:SetScript("OnClick", function() if row.recipe then ns.openQueuePopup(row.recipe) end end)
  plus:SetScript("OnEnter", function(self)
    local recipe = row.recipe
    if not recipe then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine("Queue " .. recipe.name .. "...", 1, 1, 1)
    GameTooltip:AddLine("Opens a window to choose how many crafts and which craftable reagents to queue too.", 0.6, 0.6, 0.6, true)
    GameTooltip:Show()
  end)
  plus:SetScript("OnLeave", GameTooltip_Hide)
  row.queueButton = plus

  row:SetScript("OnEnter", showRecipeTooltip)
  row:SetScript("OnLeave", GameTooltip_Hide)
  row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  row:SetScript("OnClick", function(self, button)
    if not self.recipe then return end
    if button == "RightButton" then
      ns.openQueuePopup(self.recipe)
    else
      selectRecipe(self.recipe)
    end
  end)
  return row
end

local function fillRow(row, recipe)
  row.recipe = recipe
  row.queueButton:SetShown(recipe.recipeID ~= nil)
  local c = row.cells
  c.name:SetText(recipe.name .. (recipe.made > 1 and (GREY .. " x" .. recipe.made .. "|r") or ""))
  c.name:SetTextColor(unpack(DIFFICULTY_COLORS[recipe.difficulty] or { 1, 1, 1 }))
  if recipe.stock == nil then
    c.stock:SetText(GREY .. "-|r")
  else
    c.stock:SetText(recipe.stock > 0 and recipe.stock or (GREY .. "0|r"))
  end

  local cost = API.Money(recipe.cost)
  if recipe.missing > 0 then cost = cost .. RED .. " +" .. recipe.missing .. "?|r" end
  c.cost:SetText(cost)

  if recipe.isEnchant then
    c.sell:SetText(GREY .. "enchant|r")
  elseif recipe.sell then
    c.sell:SetText(recipe.productStale and (GREY .. API.Money(recipe.sell * recipe.made) .. "|r") or API.Money(recipe.sell * recipe.made))
  else
    c.sell:SetText(RED .. "no price|r")
  end

  if recipe.profit then
    local text = API.Money(recipe.profit) .. (recipe.incomplete and (RED .. "*|r") or "")
    c.profit:SetText(text)
    c.profit:SetTextColor(recipe.profit >= 0 and 0.2 or 1, recipe.profit >= 0 and 1 or 0.3, 0.2)
    c.margin:SetText(recipe.margin and ((recipe.margin >= 0 and GREEN or RED) .. math.floor(recipe.margin * 100 + 0.5) .. "%|r") or "")
  else
    c.profit:SetText(GREY .. "-|r")
    c.profit:SetTextColor(1, 1, 1)
    c.margin:SetText("")
  end
  row:Show()
end

-- Table filters: never bind-on-pickup items, then "Profitable only", minimum profit per craft (copper) and
-- minimum margin (%). Any of them hides recipes without a known profit.
local function passesFilters(recipe)
  if isBoP(recipe.productID) then return false end
  if db.hideIncomplete and (recipe.incomplete or not recipe.profit) then return false end
  local minProfit, minMargin = db.minProfit, db.minMargin
  if not (db.profitableOnly or minProfit or minMargin) then return true end
  if not recipe.profit then return false end
  if db.profitableOnly and recipe.profit <= 0 then return false end
  if minProfit and recipe.profit < minProfit then return false end
  if minMargin and (not recipe.margin or recipe.margin * 100 < minMargin) then return false end
  return true
end

function refresh()
  if not panel or not panel:IsVisible() then return end
  local prof, rank, maxRank = professionInfo()
  panel.title:SetText((prof or "Profession") .. " Profit" .. (rank and (GREY .. "  (" .. rank .. "/" .. maxRank .. ")|r") or ""))

  local recipes = readRecipes()
  log("refresh", prof, #recipes, "recipes")
  local shown = {}
  for _, recipe in ipairs(recipes) do
    evaluate(recipe)
    if passesFilters(recipe) then shown[#shown + 1] = recipe end
  end
  sortRecipes(shown)
  panel.shown = shown
  panel.byProduct = {}
  for _, recipe in ipairs(recipes) do
    if recipe.productID then panel.byProduct[recipe.productID] = recipe end
  end

  local content = panel.content
  content:SetHeight(math.max(#shown * ROW_HEIGHT, 1))
  for i, recipe in ipairs(shown) do
    panel.rows[i] = panel.rows[i] or createRow(content, i)
    fillRow(panel.rows[i], recipe)
  end
  for i = #shown + 1, #panel.rows do
    panel.rows[i]:Hide()
    panel.rows[i].recipe = nil
  end

  local profitable = 0
  for _, recipe in ipairs(recipes) do
    if recipe.profit and recipe.profit > 0 then profitable = profitable + 1 end
  end
  -- Keep the reagent panel's Queue profitable preview current.
  if ns.popup and ns.popup:IsShown() and not ns.popup.recipe then ns.showBatch() end -- prices may have changed
  panel.summary:SetText(("%d recipes, %d profitable.  %s* = incomplete (missing or week-old prices, hover for details)|r")
    :format(#recipes, profitable, GREY))

  for _, header in ipairs(panel.headers) do
    local arrow = ""
    if header.key == db.sortKey then arrow = db.sortDesc and " v" or " ^" end
    header.label:SetText(header.title .. arrow)
  end
  updateScanButton()
end
ns.refresh = refresh

local refreshPending
local function refreshSoon()
  if refreshPending or not panel or not panel:IsVisible() then return end
  refreshPending = true
  C_Timer.After(0.2, function() refreshPending = nil; refresh() end)
end
ns.refreshSoon = refreshSoon

-- Highest frame level used by anything inside the host window. Forever's
-- profession pages nest deeply, so a fixed offset above the host isn't enough.
local function maxDescendantLevel(frame, depth, ignore)
  local best = frame:GetFrameLevel()
  if (depth or 0) > 12 then return best end
  for _, child in ipairs({ frame:GetChildren() }) do
    if child ~= ignore and type(child) == "table" and child.GetFrameLevel then
      best = math.max(best, maxDescendantLevel(child, (depth or 0) + 1, ignore))
    end
  end
  return best
end

local STRATA = { "BACKGROUND", "LOW", "MEDIUM", "HIGH", "DIALOG", "FULLSCREEN", "FULLSCREEN_DIALOG" }

-- Some of Forever's profession widgets (skill bars) draw above everything
-- else in the window, so go one strata above the window, not just a level.
local function raiseAbove(host)
  if not panel then return end
  local hostStrata = host:GetFrameStrata()
  local strata = "HIGH"
  for i, name in ipairs(STRATA) do
    if name == hostStrata then strata = STRATA[math.min(i + 1, #STRATA)] end
  end
  local level = math.min(maxDescendantLevel(host, 0, panel) + 5, 9000)
  panel:SetFrameStrata(strata)
  panel:SetFrameLevel(level)
  log("panel raised: strata", strata, "level", level, "(host strata", hostStrata, ")")
end
ns.raiseAbove = raiseAbove

local function createPanel(host)
  panel = CreateFrame("Frame", "ProfessionProfitPanel", host, BackdropTemplateMixin and "BackdropTemplate" or nil)
  ns.panel = panel
  panel:SetAllPoints(host)
  panel:SetFrameLevel(host:GetFrameLevel() + 40)
  panel.host = host
  panel:EnableMouse(true)
  if panel.SetBackdrop then
    panel:SetBackdrop({
      bgFile = "Interface\\Buttons\\WHITE8X8",
      edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 16,
      insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    panel:SetBackdropColor(0.07, 0.06, 0.05, 0.98)
    panel:SetBackdropBorderColor(0.6, 0.5, 0.3, 1)
  end
  panel:Hide()

  local close = CreateFrame("Button", nil, panel, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", -2, -2)
  close:SetScript("OnClick", closeHost)

  panel.title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  panel.title:SetPoint("TOPLEFT", 16, -14)

  panel.scanButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
  panel.scanButton:SetSize(90, 22)
  panel.scanButton:SetPoint("TOPRIGHT", -36, -10)
  panel.scanButton:SetScript("OnClick", function()
    log("Scan AH clicked")
    startScan()
  end)
  -- If clicks never show up in DevLog, something is covering the button.
  panel.scanButton:HookScript("OnMouseDown", function() log("Scan AH mouse down") end)
  panel.scanButton:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:AddLine("Scan AH")
    GameTooltip:AddLine("Searches the AH for every reagent and crafted item of your learned recipes, through Auctionator (results show in its Shopping tab). Prices update as they come in.", 1, 1, 1, true)
    GameTooltip:AddLine("Vendor-sold reagents are skipped: their vendor price is always used.", 0.7, 0.7, 0.7, true)
    GameTooltip:Show()
  end)
  panel.scanButton:SetScript("OnLeave", GameTooltip_Hide)

  local onlyProfit = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
  onlyProfit:SetSize(22, 22)
  onlyProfit:SetPoint("RIGHT", panel.scanButton, "LEFT", -110, 0)
  onlyProfit:SetChecked(db.profitableOnly)
  onlyProfit:SetScript("OnClick", function(self) db.profitableOnly = self:GetChecked() and true or false; refresh() end)
  local onlyLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  onlyLabel:SetPoint("LEFT", onlyProfit, "RIGHT", 2, 0)
  onlyLabel:SetText("Profitable only")

  local showMissing = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
  showMissing:SetSize(22, 22)
  showMissing:SetPoint("TOPLEFT", onlyProfit, "BOTTOMLEFT", 0, 2)
  showMissing:SetChecked(not db.hideIncomplete)
  showMissing:SetScript("OnClick", function(self) db.hideIncomplete = not self:GetChecked() or nil; refresh() end)
  showMissing:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:AddLine("Missing prices")
    GameTooltip:AddLine("Unticked: hide recipes with incomplete prices (*) - a reagent or the crafted item has no AH price, or its price is more than a week old.", 1, 1, 1, true)
    GameTooltip:Show()
  end)
  showMissing:SetScript("OnLeave", GameTooltip_Hide)
  local missingLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  missingLabel:SetPoint("LEFT", showMissing, "RIGHT", 2, 0)
  missingLabel:SetText("Missing prices")

  -- Minimum profit (gold, decimals allowed) and margin (%) filters. Empty = off.
  local function filterBox(width, unit, get, set, tipTitle, tipText)
    local box = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
    box:SetSize(width, 20)
    box:SetAutoFocus(false)
    box:SetMaxLetters(6)
    box:SetJustifyH("RIGHT")
    box:SetText(get() or "")
    local unitLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    unitLabel:SetPoint("LEFT", box, "RIGHT", 2, 0)
    unitLabel:SetText(unit)
    local function apply(self)
      set(tonumber((self:GetText():gsub(",", "."))))
      self:SetText(get() or "")
      self:ClearFocus()
      refresh()
    end
    box:SetScript("OnEnterPressed", apply)
    box:SetScript("OnEditFocusLost", apply)
    box:SetScript("OnEscapePressed", function(self) self:SetText(get() or "") self:ClearFocus() end)
    box:SetScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
      GameTooltip:AddLine(tipTitle)
      GameTooltip:AddLine(tipText, 1, 1, 1, true)
      GameTooltip:AddLine("Leave empty for no limit. 'Queue profitable' only queues what the table shows.", 0.7, 0.7, 0.7, true)
      GameTooltip:Show()
    end)
    box:SetScript("OnLeave", GameTooltip_Hide)
    return box, unitLabel
  end
  local marginBox = filterBox(28, "%",
    function() return db.minMargin and tostring(db.minMargin) end,
    function(n) db.minMargin = n end,
    "Minimum margin", "Only show recipes whose profit is at least this % of their reagent cost.")
  marginBox:SetPoint("RIGHT", onlyProfit, "LEFT", -18, 0)
  local profitBox, gLabel = filterBox(36, "g",
    function() return db.minProfit and tostring(db.minProfit / 10000) end,
    function(n) db.minProfit = n and math.floor(n * 10000 + 0.5) or nil end,
    "Minimum profit", "Only show recipes that make at least this much gold per craft (after the AH cut). Decimals work: 0.5 = 50 silver.")
  profitBox:SetPoint("RIGHT", marginBox, "LEFT", -20, 0)
  local minLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  minLabel:SetPoint("RIGHT", profitBox, "LEFT", -8, 0)
  minLabel:SetText("Min")

  panel.status = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  panel.status:SetPoint("TOPLEFT", panel.title, "BOTTOMLEFT", 0, -6)
  panel.status:SetPoint("RIGHT", showMissing, "LEFT", -8, 0)
  panel.status:SetJustifyH("LEFT")

  -- Column headers (click to sort)
  local headerRow = CreateFrame("Frame", nil, panel)
  headerRow:SetPoint("TOPLEFT", 14, -54)
  headerRow:SetPoint("TOPRIGHT", -34, -54)
  headerRow:SetHeight(20)
  headerRow.cells = {}
  panel.headers = {}
  for _, col in ipairs(COLUMNS) do
    local button = CreateFrame("Button", nil, headerRow)
    button:SetHeight(20)
    local label = button:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetAllPoints()
    label:SetJustifyH(col.justify)
    button.label, button.key, button.title = label, col.key, col.title
    button:SetScript("OnClick", function()
      if col.noSort then return end
      if db.sortKey == col.key then db.sortDesc = not db.sortDesc
      else db.sortKey, db.sortDesc = col.key, col.key ~= "name" end
      refresh()
    end)
    headerRow.cells[col.key] = button
    panel.headers[#panel.headers + 1] = button
  end
  layoutColumns(headerRow, headerRow)
  local line = headerRow:CreateTexture(nil, "ARTWORK")
  line:SetColorTexture(0.6, 0.5, 0.3, 0.6)
  line:SetHeight(1)
  line:SetPoint("BOTTOMLEFT")
  line:SetPoint("BOTTOMRIGHT")

  local scroll = CreateFrame("ScrollFrame", "ProfessionProfitScroll", panel, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", headerRow, "BOTTOMLEFT", 0, -2)
  scroll:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -34, 32)
  panel.content = CreateFrame("Frame", nil, scroll)
  panel.content:SetSize(1, 1)
  scroll:SetScrollChild(panel.content)
  scroll:SetScript("OnSizeChanged", function(self, width) panel.content:SetWidth(width) end)
  panel.rows = {}

  -- Craft queue controls (bottom right)
  local queueBar = CreateFrame("Frame", nil, panel)
  queueBar:SetSize(424, 24)
  queueBar:SetPoint("BOTTOMRIGHT", -14, 6)
  panel.queueBar = queueBar

  local queueButton = CreateFrame("Button", nil, queueBar, "UIPanelButtonTemplate")
  queueButton:SetSize(120, 22)
  queueButton:SetPoint("RIGHT")
  queueButton:SetText("Queue profitable")
  queueButton:SetScript("OnClick", ns.queueProfitable)
  queueButton:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:AddLine("Queue profitable")
    GameTooltip:AddLine("Adds every recipe shown in the table (after your filters) with a positive profit to the craft queue (Qty crafts each), crafting the reagents you've chosen before (or the craft-or-buy rule picks). Adjust them afterwards in the reagent window under the queue. Recipes with incomplete prices (*) are skipped. Use + on a row to queue just that recipe.", 1, 1, 1, true)
    GameTooltip:AddLine("Top up off: Qty crafts of everything.", 0.7, 0.7, 0.7, true)
    GameTooltip:AddLine("Top up on: enough to own each item's Restocking target - or Qty if it has none - counting bags, bank, your auctions and what's already queued.", 0.7, 0.7, 0.7, true)
    GameTooltip:Show()
  end)
  queueButton:SetScript("OnLeave", GameTooltip_Hide)

  local topUpLabel = queueBar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  topUpLabel:SetPoint("RIGHT", queueButton, "LEFT", -8, 0)
  topUpLabel:SetText("Top up")
  local topUp = CreateFrame("CheckButton", nil, queueBar, "UICheckButtonTemplate")
  topUp:SetSize(22, 22)
  topUp:SetPoint("RIGHT", topUpLabel, "LEFT", -2, 0)
  topUp:SetChecked(db.queueTopUp)
  topUp:SetScript("OnClick", function(self) db.queueTopUp = self:GetChecked() and true or false end)

  local qtyBox = CreateFrame("EditBox", nil, queueBar, "InputBoxTemplate")
  qtyBox:SetSize(34, 20)
  qtyBox:SetPoint("RIGHT", topUp, "LEFT", -10, 0)
  qtyBox:SetAutoFocus(false)
  qtyBox:SetNumeric(true)
  qtyBox:SetMaxLetters(4)
  qtyBox:SetText(tostring(db.queueQty or 1))
  local function saveQty(self)
    local n = tonumber(self:GetText())
    if not n or n < 1 then n = 1 end
    db.queueQty = n
    self:SetText(tostring(n))
    self:ClearFocus()
  end
  qtyBox:SetScript("OnEnterPressed", saveQty)
  qtyBox:SetScript("OnEditFocusLost", saveQty)
  qtyBox:SetScript("OnEscapePressed", saveQty)
  local qtyLabel = queueBar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  qtyLabel:SetPoint("RIGHT", qtyBox, "LEFT", -8, 0)
  qtyLabel:SetText("Qty")

  local restock = CreateFrame("Button", nil, queueBar, "UIPanelButtonTemplate")
  restock:SetSize(84, 22)
  restock:SetPoint("RIGHT", qtyLabel, "LEFT", -10, 0)
  restock:SetText("Restocking")
  restock:SetScript("OnClick", function() ns.toggleTargetsWindow() end)
  restock:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:AddLine("Restocking")
    GameTooltip:AddLine("See and edit how many of each item Top up restocks to. Set new ones with \"Restock to\" after clicking + on a recipe.", 1, 1, 1, true)
    GameTooltip:Show()
  end)
  restock:SetScript("OnLeave", GameTooltip_Hide)

  panel.summary = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  panel.summary:SetPoint("BOTTOMLEFT", 16, 12)
  panel.summary:SetPoint("RIGHT", queueBar, "LEFT", -10, 0)
  panel.summary:SetJustifyH("LEFT")

  panel:SetScript("OnShow", function()
    raiseAbove(panel.host)
    queueBar:Show()
    panel.content:SetWidth(scroll:GetWidth())
    expandAll()
    refresh()
  end)
end
ns.createPanel = createPanel
