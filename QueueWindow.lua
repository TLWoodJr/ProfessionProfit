-- ProfessionProfit: Craft queue window: entries, missing reagents, shopping list and Save Restock.

local ADDON, ns = ...
local API, RED, GREY, GREEN, msg, log = ns.API, ns.RED, ns.GREY, ns.GREEN, ns.msg, ns.log
local ahOpen, hostFrame, professionInfo, itemName, stockOf, tabs = ns.ahOpen, ns.hostFrame, ns.professionInfo, ns.itemName, ns.stockOf, ns.tabs
local craftQueue, computeQueue, setQueueTarget, bagCount, inOpenProfession, craftableNow = ns.craftQueue, ns.computeQueue, ns.setQueueTarget, ns.bagCount, ns.inOpenProfession, ns.craftableNow
local queueShopping, firstCraftable, refresh, updatePopup, createPopup, earned = ns.queueShopping, ns.firstCraftable, ns.refresh, ns.updatePopup, ns.createPopup, ns.earned
local craftButtonClicked, recompileQueue = ns.craftButtonClicked, ns.recompileQueue
local db
ns.onInit(function(saved) db = saved end)

-- Defined below; other files call them through ns.
local updateQueueWindow, showQueueWindow
local showReagentWindow, placeReagentWindow -- the reagent window hangs off this one

------------------------------------------------------------------------------
-- Craft Queue window
------------------------------------------------------------------------------

local queueWin
local QROW = 18
local QROWS = 14

local SHOPPING_LIST_NAME = "ProfessionProfit Queue"

-- Send the queue's missing reagents to an Auctionator shopping list
-- (exact-name searches with quantities). Vendor-sold reagents are included
-- too (they're often on the AH); chat notes their vendor price to compare.
-- Show Auctionator's Shopping tab and search a list, the way its own
-- MultiSearch API does (tab click + ListSearchRequested). Internal API, so
-- everything is checked and guarded.
local function searchShoppingList(name)
  local shopping = Auctionator and Auctionator.Shopping
  local manager, events = shopping and shopping.ListManager, shopping and shopping.Tab and shopping.Tab.Events
  if not (ahOpen() and AuctionatorTabs_Shopping and manager and events and Auctionator.EventBus) then return false end
  local ok, err = pcall(function()
    local list = manager:GetByName(name)
    if not list then error("list not found") end
    AuctionatorTabs_Shopping:Click()
    Auctionator.EventBus:RegisterSource(searchShoppingList, "ProfessionProfit shopping list")
      :Fire(searchShoppingList, events.ListSearchRequested, list)
      :UnregisterSource(searchShoppingList)
  end)
  log("shopping list search", ok and "started" or err)
  return ok
end

local function makeShoppingList()
  local aucAPI = Auctionator and Auctionator.API and Auctionator.API.v1
  if not (aucAPI and aucAPI.CreateShoppingList and aucAPI.ConvertToSearchString) then
    msg("Auctionator isn't loaded.")
    return
  end
  local missing = queueShopping()
  if #missing == 0 then
    msg("Nothing to buy - you have every reagent for the queue.")
    return
  end
  local searches, vendor, bankItems = {}, {}, {}
  for _, item in ipairs(missing) do
    local price, src = API.BuyPrice(item.id)
    if src == "vendor" then
      vendor[#vendor + 1] = ("%s (%s ea)"):format(item.name, API.Money(price))
    end
    if item.bank > 0 then bankItems[#bankItems + 1] = item.bank .. "x " .. item.name end
    if item.buy > 0 then
      local ok, search = pcall(aucAPI.ConvertToSearchString, ADDON,
        { searchString = item.name, isExact = true, quantity = item.buy })
      if ok and search then searches[#searches + 1] = search end
    end
  end
  if #searches > 0 then
    local ok, err = pcall(aucAPI.CreateShoppingList, ADDON, SHOPPING_LIST_NAME, searches)
    log("shopping list", #searches, "items", ok and "ok" or err)
    if ok then
      local searching = searchShoppingList(SHOPPING_LIST_NAME)
      msg(("Auctionator shopping list '%s' created with %d item(s)%s."):format(SHOPPING_LIST_NAME, #searches,
        searching and " - searching now" or ahOpen() and "" or " - open the AH to search it"))
    else
      msg("Couldn't create the shopping list: " .. tostring(err))
    end
  end
  if #vendor > 0 then msg("Also sold by vendors: " .. table.concat(vendor, ", ")) end
  if #bankItems > 0 then msg("Take from your bank: " .. table.concat(bankItems, ", ")) end
  if #searches == 0 and #bankItems > 0 then msg("Nothing to buy - the rest is in your bank.") end
end

local function queueRowTooltip(row)
  local entry = row.entry
  if not entry then return end
  GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
  GameTooltip:AddLine(entry.name, 1, 1, 1)
  GameTooltip:AddDoubleLine("Queued", entry.count .. " craft(s)", 0.8, 0.8, 0.8, 1, 1, 1)
  if entry.auto then
    GameTooltip:AddLine(("Reagent for: %s"):format(table.concat(entry.usedBy, ", ")), 0.8, 0.8, 0.8, true)
    GameTooltip:AddLine(("Need %d, have %d in bags -> %d craft(s). Updates as your bags change."):format(
      entry.need, entry.have, entry.count), 0.6, 0.6, 0.6, true)
    GameTooltip:AddLine("To buy it instead, untick it in the reagent window and press Update.", 0.6, 0.6, 0.6, true)
  end
  GameTooltip:AddDoubleLine("Profession", entry.prof or "?", 0.8, 0.8, 0.8, 1, 1, 1)
  if inOpenProfession(entry) then
    GameTooltip:AddDoubleLine("Can craft now", craftableNow(entry), 0.8, 0.8, 0.8, 1, 1, 1)
  end
  GameTooltip:AddLine(" ")
  for _, reagent in ipairs(entry.reagents) do
    local need = reagent.c * entry.count
    local have = reagent.id and bagCount(reagent.id) or 0
    GameTooltip:AddDoubleLine(("%dx %s"):format(need, reagent.n or itemName(reagent.id) or "?"),
      ("have %d"):format(have), 0.85, 0.85, 0.85, have >= need and 0.2 or 1, have >= need and 1 or 0.4, 0.3)
  end
  GameTooltip:AddLine(" ")
  GameTooltip:AddLine("- / + change the count, x removes it. Shift for 5.", 0.6, 0.6, 0.6, true)
  GameTooltip:Show()
end

local function createQueueRow(parent, i)
  local row = CreateFrame("Frame", nil, parent)
  row:SetHeight(QROW)
  row:SetPoint("TOPLEFT", 0, -(i - 1) * QROW)
  row:SetPoint("RIGHT")
  row:EnableMouse(true)
  local hl = row:CreateTexture(nil, "HIGHLIGHT")
  hl:SetAllPoints()
  hl:SetColorTexture(1, 1, 1, 0.08)
  local function smallButton(text, xOffset, onClick)
    local b = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    b:SetSize(18, 16)
    b:SetPoint("RIGHT", xOffset, 0)
    b:SetText(text)
    b:SetScript("OnClick", function() if row.entry then onClick(row.entry, IsShiftKeyDown() and 5 or 1) end end)
    return b
  end
  local function change(entry, delta)
    entry.count = entry.count + delta
    if entry.count <= 0 then
      for index, e in ipairs(craftQueue()) do if e == entry then table.remove(craftQueue(), index) break end end
    end
    updateQueueWindow()
  end
  row.removeButton = smallButton("x", 0, function(entry) change(entry, -entry.count) end)
  row.plusButton = smallButton("+", -20, function(entry, step) change(entry, step) end)
  row.minusButton = smallButton("-", -40, function(entry, step) change(entry, -step) end)
  row.count = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  row.count:SetPoint("RIGHT", -64, 0)
  row.count:SetWidth(36)
  row.count:SetJustifyH("RIGHT")
  row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  row.name:SetPoint("LEFT", 4, 0)
  row.name:SetPoint("RIGHT", row.count, "LEFT", -4, 0)
  row.name:SetJustifyH("LEFT")
  row.name:SetWordWrap(false)
  row:SetScript("OnEnter", queueRowTooltip)
  row:SetScript("OnLeave", GameTooltip_Hide)
  return row
end

updateQueueWindow = function()
  local queue = computeQueue()
  if tabs and tabs[3] then tabs[3]:SetText(("Queue (%d)"):format(#queue)) end
  if not queueWin or not queueWin:IsShown() then return end
  queueWin.title:SetText(("Craft Queue (%d)"):format(#queue))
  local prof = professionInfo(true)
  queueWin.content:SetHeight(math.max(#queue * QROW, 1))
  for i, entry in ipairs(queue) do
    local row = queueWin.rows[i] or createQueueRow(queueWin.content, i)
    queueWin.rows[i] = row
    row.entry = entry
    -- Reagent crafts are counted automatically and chosen in the reagent
    -- window: no -/+/x for them.
    row.plusButton:SetShown(not entry.auto)
    row.minusButton:SetShown(not entry.auto)
    row.removeButton:SetShown(not entry.auto)
    local text = entry.auto and (("  "):rep(entry.depth or 1) .. entry.name .. " |cffa0a0a0(reagent)|r") or entry.name
    local n = craftableNow(entry)
    if not inOpenProfession(entry) then
      row.name:SetTextColor(0.55, 0.55, 0.55)
      text = text .. " |cff808080(" .. (entry.prof or "other profession") .. ")|r"
    elseif n >= entry.count then
      row.name:SetTextColor(0.25, 1, 0.25)
    elseif n > 0 then
      row.name:SetTextColor(1, 0.85, 0.2)
      text = text .. (" |cffa0a0a0(%d now)|r"):format(n)
    else
      row.name:SetTextColor(1, 0.4, 0.4)
    end
    row.name:SetText(text)
    row.count:SetText("x" .. entry.count)
    row:Show()
  end
  for i = #queue + 1, #queueWin.rows do
    queueWin.rows[i]:Hide()
    queueWin.rows[i].entry = nil
  end
  queueWin.empty:SetShown(#queue == 0)

  local missing, cost, unpriced = queueShopping()
  queueWin.missingList = missing
  if #missing == 0 then
    queueWin.missing:SetText(#queue > 0 and "|cff33ff33You have every reagent for the queue.|r" or "")
  else
    local parts = {}
    for i, item in ipairs(missing) do
      if i > 6 then parts[#parts + 1] = ("+%d more"):format(#missing - 6) break end
      parts[#parts + 1] = item.count .. "x " .. item.name .. (item.bank > 0 and ("|cffa0a0a0 (" .. item.bank .. " in bank)|r") or "")
    end
    queueWin.missing:SetText(("|cffff6666Missing:|r %s  |cffa0a0a0(about %s%s)|r"):format(table.concat(parts, ", "),
      API.Money(cost), unpriced > 0 and (", " .. unpriced .. " unpriced") or ""))
  end

  local made = earned.crafts + earned.unpriced
  if made + earned.reagents > 0 then
    local sum = earned.total + earned.saved
    local parts = {}
    if made > 0 then parts[#parts + 1] = ("%d craft%s"):format(made, made == 1 and "" or "s") end
    if earned.reagents > 0 then
      parts[#parts + 1] = ("%s%s|r%s on reagents"):format(earned.saved >= 0 and "+" or RED, API.Money(earned.saved),
        GREY)
    end
    queueWin.earned:SetText(("Made: %s%s|r  %s(%s)|r"):format(sum >= 0 and GREEN .. "+" or RED, API.Money(sum),
      GREY, table.concat(parts, ", ")))
  else
    queueWin.earned:SetText("")
  end

  local canSave = false
  for _, e in ipairs(craftQueue()) do
    if e.recipeID and e.productID and e.count > 0 then canSave = true break end
  end
  queueWin.saveButton:SetShown(canSave)

  local entry, _, count = firstCraftable()
  if ns.processing and ns.processing.needClick then
    local key = GetBindingKey and GetBindingKey("PROFESSIONPROFIT_CRAFTNEXT")
    queueWin.craftButton:SetText(key and ("Continue (" .. key .. ")") or "Continue")
    queueWin.nextText:SetText(entry and ("Next: |cffffffff%s|r x%d"):format(entry.name, count) or "")
  elseif ns.processing then
    queueWin.craftButton:SetText(("Stop (step %d)"):format(ns.processing.steps))
    queueWin.nextText:SetText(ns.crafting and ("Crafting: |cffffffff%s|r, %d left"):format(ns.crafting.name, ns.crafting.left)
      or "Recounting reagents...")
  elseif entry then
    queueWin.craftButton:SetText("Craft all")
    queueWin.nextText:SetText(("Next: |cffffffff%s|r x%d"):format(entry.name, count))
  else
    queueWin.craftButton:SetText("Craft all")
    queueWin.nextText:SetText(#queue == 0 and "" or "|cffff6666Nothing craftable in this profession.|r")
  end
  queueWin.craftButton:Enable() -- clicking explains why when nothing is craftable
  if ns.popup and not ns.popup.recipe then ns.showBatch() end
end
ns.updateQueueWindow = updateQueueWindow

local function placeQueueWindow()
  queueWin:ClearAllPoints()
  local pos = db.queueWinPos
  if pos then
    queueWin:SetPoint(pos[1], UIParent, pos[1], pos[2], pos[3])
  else
    local host = hostFrame()
    if host then
      -- Leave room for Forever's profession buttons on the window's right edge.
      queueWin:SetPoint("TOPLEFT", host, "TOPRIGHT", 48, 0)
    else
      queueWin:SetPoint("CENTER")
    end
  end
end

local function createQueueWindow()
  queueWin = CreateFrame("Frame", "ProfessionProfitQueueWindow", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
  ns.queueWin = queueWin
  queueWin:SetSize(330, 192 + QROWS * QROW)
  queueWin:SetFrameStrata("HIGH")
  queueWin:SetClampedToScreen(true)
  queueWin:EnableMouse(true)
  queueWin:SetMovable(true)
  queueWin:RegisterForDrag("LeftButton")
  queueWin:SetScript("OnDragStart", queueWin.StartMoving)
  queueWin:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local point, _, _, x, y = self:GetPoint(1)
    db.queueWinPos = { point, x, y }
  end)
  if queueWin.SetBackdrop then
    queueWin:SetBackdrop({
      bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
      edgeSize = 16, insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    queueWin:SetBackdropColor(0.07, 0.06, 0.05, 0.97)
    queueWin:SetBackdropBorderColor(0.6, 0.5, 0.3, 1)
  end

  local close = CreateFrame("Button", nil, queueWin, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", -2, -2)
  close:SetScript("OnClick", function() queueWin:Hide() end)
  queueWin.title = queueWin:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  queueWin.title:SetPoint("TOPLEFT", 14, -12)

  local subLabel = queueWin:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  subLabel:SetPoint("TOPRIGHT", -36, -13)
  subLabel:SetText("Craft reagents")
  local subCheck = CreateFrame("CheckButton", nil, queueWin, "UICheckButtonTemplate")
  subCheck:SetSize(20, 20)
  subCheck:SetPoint("RIGHT", subLabel, "LEFT", -2, 0)
  subCheck:SetChecked(not db.skipReagentCrafts)
  subCheck:SetScript("OnClick", function(self)
    db.skipReagentCrafts = not self:GetChecked()
    msg(db.skipReagentCrafts and "Reagent crafting off: the queue only crafts the items you queued and buys every reagent."
      or "Reagent crafting on.")
    updateQueueWindow()
  end)
  subCheck:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:AddLine("Craft reagents")
    GameTooltip:AddLine("Ticked: craftable reagents chosen when queueing (or by Refresh) are crafted first.", 1, 1, 1, true)
    GameTooltip:AddLine("Unticked: skip all sub-crafting - every reagent goes on the Missing / shopping list. Your choices are kept for when you tick it again.", 0.7, 0.7, 0.7, true)
    GameTooltip:Show()
  end)
  subCheck:SetScript("OnLeave", GameTooltip_Hide)

  local scroll = CreateFrame("ScrollFrame", "ProfessionProfitQueueScroll", queueWin, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", 10, -34)
  scroll:SetPoint("RIGHT", -30, 0)
  scroll:SetHeight(QROWS * QROW)
  queueWin.content = CreateFrame("Frame", nil, scroll)
  queueWin.content:SetSize(1, 1)
  scroll:SetScrollChild(queueWin.content)
  scroll:SetScript("OnSizeChanged", function(_, width) queueWin.content:SetWidth(width) end)
  queueWin.rows = {}
  queueWin.empty = queueWin:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  queueWin.empty:SetPoint("TOP", scroll, "TOP", 0, -20)
  queueWin.empty:SetText("Nothing queued. Use + in the Profit table.")

  queueWin.missing = queueWin:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  queueWin.missing:SetPoint("TOPLEFT", scroll, "BOTTOMLEFT", 2, -8)
  queueWin.missing:SetPoint("RIGHT", -12, 0)
  queueWin.missing:SetHeight(42)
  queueWin.missing:SetJustifyH("LEFT")
  queueWin.missing:SetJustifyV("TOP")
  local missingHover = CreateFrame("Frame", nil, queueWin)
  missingHover:SetAllPoints(queueWin.missing)
  missingHover:EnableMouse(true)
  missingHover:SetScript("OnEnter", function(self)
    local list = queueWin.missingList or {}
    if #list == 0 then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine("Missing reagents", 1, 0.82, 0)
    for _, item in ipairs(list) do
      local left = item.count .. "x " .. item.name .. (item.bank > 0 and ("  |cffa0a0a0" .. item.bank .. " in bank|r") or "")
      local right = item.buy == 0 and "|cffa0a0a0from bank|r" or (item.price and API.Money(item.price * item.buy) or "no price")
      GameTooltip:AddDoubleLine(left, right, 1, 1, 1, 1, 1, 1)
    end
    GameTooltip:AddLine("Counts what's in your bags; the bank is noted separately.", 0.6, 0.6, 0.6, true)
    GameTooltip:Show()
  end)
  missingHover:SetScript("OnLeave", GameTooltip_Hide)

  local shop = CreateFrame("Button", nil, queueWin, "UIPanelButtonTemplate")
  shop:SetSize(110, 22)
  shop:SetPoint("BOTTOMRIGHT", -12, 40)
  shop:SetText("Shopping list")
  shop:SetScript("OnClick", makeShoppingList)
  shop:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine("Auctionator shopping list")
    GameTooltip:AddLine(("Puts the missing reagents (with quantities) into the Auctionator shopping list '%s' and searches it if the AH is open. Chat also notes which ones vendors sell, and for how much."):format(SHOPPING_LIST_NAME), 1, 1, 1, true)
    GameTooltip:Show()
  end)
  shop:SetScript("OnLeave", GameTooltip_Hide)
  queueWin.shopButton = shop

  -- Save what you'll own once the queue is crafted as restock targets.
  local save = CreateFrame("Button", nil, queueWin, "UIPanelButtonTemplate")
  save:SetSize(100, 22)
  save:SetPoint("RIGHT", shop, "LEFT", -4, 0)
  save:SetText("Save Restock")
  save:SetScript("OnClick", function()
    local saved = 0
    for _, entry in ipairs(craftQueue()) do
      if entry.recipeID and entry.productID and entry.count > 0 then
        setQueueTarget(entry, stockOf(entry.productID) + entry.count * (entry.made or 1))
        saved = saved + 1
      end
    end
    msg(("Saved %d restock target(s) - edit them in Restocking."):format(saved))
    ns.toggleTargetsWindow(true)
    if refresh then refresh() end
  end)
  save:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:AddLine("Save Restock")
    GameTooltip:AddLine("Saves a restock target for every queued item: what you own now (bags, bank, your auctions) plus what's queued - your total once it's crafted. Replaces existing targets for these items.", 1, 1, 1, true)
    GameTooltip:AddLine("Edit or remove them in Restocking (Profit tab).", 0.7, 0.7, 0.7, true)
    GameTooltip:Show()
  end)
  save:SetScript("OnLeave", GameTooltip_Hide)
  queueWin.saveButton = save

  queueWin.earned = queueWin:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  queueWin.earned:SetPoint("BOTTOMLEFT", 14, 92)
  queueWin.earned:SetPoint("RIGHT", -12, 0)
  queueWin.earned:SetJustifyH("LEFT")
  queueWin.earned:SetWordWrap(false)
  local earnedHover = CreateFrame("Frame", nil, queueWin)
  earnedHover:SetAllPoints(queueWin.earned)
  earnedHover:EnableMouse(true)
  earnedHover:SetScript("OnEnter", function(self)
    if earned.crafts + earned.unpriced + earned.reagents == 0 then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine("Made this run")
    GameTooltip:AddDoubleLine(("Queued items (%d)"):format(earned.crafts), API.Money(earned.total), 1, 1, 1, 1, 1, 1)
    if earned.unpriced > 0 then
      GameTooltip:AddDoubleLine("Unpriced items", earned.unpriced, 0.6, 0.6, 0.6, 0.6, 0.6, 0.6)
    end
    GameTooltip:AddDoubleLine(("Reagents crafted (%d)"):format(earned.reagents), API.Money(earned.saved), 1, 1, 1, 1, 1, 1)
    GameTooltip:AddLine("Items: AH price after the 5% cut, minus reagent cost. Reagents: what buying them would have cost, minus the cost of crafting them (no AH cut - you're not selling them).", 0.6, 0.6, 0.6, true)
    GameTooltip:AddLine("Resets when you press Craft all.", 0.6, 0.6, 0.6, true)
    GameTooltip:Show()
  end)
  earnedHover:SetScript("OnLeave", GameTooltip_Hide)

  queueWin.nextText = queueWin:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  queueWin.nextText:SetPoint("BOTTOMLEFT", 14, 70)
  queueWin.nextText:SetPoint("RIGHT", -12, 0)
  queueWin.nextText:SetJustifyH("LEFT")
  queueWin.nextText:SetWordWrap(false)

  queueWin.craftButton = CreateFrame("Button", "ProfessionProfitCraftButton", queueWin, "UIPanelButtonTemplate")
  queueWin.craftButton:SetPoint("BOTTOMLEFT", 12, 12)
  queueWin.craftButton:SetPoint("RIGHT", -180, 0)
  queueWin.craftButton:SetHeight(24)
  queueWin.craftButton:SetScript("OnClick", craftButtonClicked)
  local clear = CreateFrame("Button", nil, queueWin, "UIPanelButtonTemplate")
  clear:SetSize(78, 24)
  clear:SetPoint("BOTTOMRIGHT", -12, 12)
  local refreshButton = CreateFrame("Button", nil, queueWin, "UIPanelButtonTemplate")
  refreshButton:SetSize(78, 24)
  refreshButton:SetPoint("RIGHT", clear, "LEFT", -4, 0)
  refreshButton:SetText("Refresh")
  refreshButton:SetScript("OnClick", recompileQueue)
  refreshButton:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:AddLine("Refresh crafted reagents")
    GameTooltip:AddLine("Re-decides which reagents to craft for everything queued in the open profession, using current prices, then recounts them against your bags.", 1, 1, 1, true)
    GameTooltip:AddLine("Craft when it's cheaper to craft than to buy, or when it isn't on the AH.", 0.7, 0.7, 0.7, true)
    GameTooltip:Show()
  end)
  refreshButton:SetScript("OnLeave", GameTooltip_Hide)
  clear:SetText("Clear")
  clear:SetScript("OnClick", function()
    if IsShiftKeyDown() then
      wipe(craftQueue())
      updateQueueWindow()
    else
      msg("Shift-click Clear to empty the queue.")
    end
  end)

  queueWin:SetScript("OnShow", function()
    if ns.popup then ns.popup.closed = nil end
    updateQueueWindow()
    showReagentWindow()
  end)
  queueWin:SetScript("OnHide", function() if ns.popup then ns.popup:Hide() end end)
  queueWin:Hide()
end

-- Opened only by the Queue tab or queueing something, and only closed by you
-- (X or the Queue tab) - it stays open when the profession window closes.
showQueueWindow = function()
  if not queueWin then createQueueWindow() end
  if not queueWin:IsShown() then placeQueueWindow() end
  queueWin:Show()
  updateQueueWindow()
end
ns.showQueueWindow = showQueueWindow

local function toggleQueueWindow()
  if queueWin and queueWin:IsShown() then
    queueWin:Hide()
  else
    showQueueWindow()
  end
end
ns.toggleQueueWindow = toggleQueueWindow

-- The reagent window hangs under the queue window - above it when there's
-- no room below, or in its place while it's closed.
placeReagentWindow = function()
  if not ns.popup then return end
  if not queueWin then createQueueWindow() end
  if queueWin:GetNumPoints() == 0 then placeQueueWindow() end
  ns.popup:ClearAllPoints()
  local bottom = queueWin:GetBottom()
  if not queueWin:IsShown() then
    -- (+ before anything is queued) sit where the queue window would be.
    ns.popup:SetPoint("TOPLEFT", queueWin, "TOPLEFT")
    ns.popup:SetPoint("TOPRIGHT", queueWin, "TOPRIGHT")
  elseif bottom and bottom - ns.popup:GetHeight() < 0 then
    ns.popup:SetPoint("BOTTOMLEFT", queueWin, "TOPLEFT", 0, 2)
    ns.popup:SetPoint("BOTTOMRIGHT", queueWin, "TOPRIGHT", 0, 2)
  else
    ns.popup:SetPoint("TOPLEFT", queueWin, "BOTTOMLEFT", 0, -2)
    ns.popup:SetPoint("TOPRIGHT", queueWin, "BOTTOMRIGHT", 0, -2)
  end
end
ns.placeReagentWindow = placeReagentWindow

-- Shown with the queue window, when the queue has craftable reagents (or
-- while + has it showing one recipe).
showReagentWindow = function()
  if not (queueWin and queueWin:IsShown()) then return end
  if not ns.popup then createPopup() end
  if ns.popup.recipe then
    ns.popup:Show()
    updatePopup()
  else
    ns.showBatch()
  end
end
ns.showReagentWindow = showReagentWindow

local function syncQueueWindow()
  updateQueueWindow()
end
ns.syncQueueWindow = syncQueueWindow
