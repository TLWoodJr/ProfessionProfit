-- ProfessionProfit: Reagent window: which reagents the queue crafts, and the + (queue one recipe) view.

local ADDON, ns = ...
local API, RED, GREY, GREEN, msg, log = ns.API, ns.RED, ns.GREY, ns.GREEN, ns.msg, ns.log
local hostShown, evaluate, readRecipes, craftQueue, queuedCount, queueTarget = ns.hostShown, ns.evaluate, ns.readRecipes, ns.craftQueue, ns.queuedCount, ns.queueTarget
local setQueueTarget, craftsToQueue, recipeDef, planDerived, dropSub, subTree = ns.setQueueTarget, ns.craftsToQueue, ns.recipeDef, ns.planDerived, ns.dropSub, ns.subTree
local effectivelyIncluded, chosenSubs, queueOrdered, refresh = ns.effectivelyIncluded, ns.chosenSubs, ns.queueOrdered, ns.refresh
local applyChoices, mergeTrees, recommend, craftEffect, shoppingCost, withSubs = ns.applyChoices, ns.mergeTrees, ns.recommend, ns.craftEffect, ns.shoppingCost, ns.withSubs
local db
ns.onInit(function(saved) db = saved end)

------------------------------------------------------------------------------
-- Reagent window, under the craft queue window and shown with it. It lists
-- the craftable reagents of what's queued (each once), ticked when the queue
-- crafts them; Update applies your ticks to the queue. Ticks are also
-- remembered per reagent for what you queue next. + on a row switches it to
-- that one recipe until you Queue or go Back.
------------------------------------------------------------------------------

local popup -- the window (createPopup)
local DOCK_ROWS = 10 -- reagent rows shown; any more still count (as ticked)

local function rememberChoice(entry)
  db.reagentChoices = db.reagentChoices or {}
  -- Not "a and b or nil": an untick is false, which that would turn into nil.
  if entry.include ~= entry.ruleInclude then
    db.reagentChoices[entry.sub.recipeID] = entry.include
  else
    db.reagentChoices[entry.sub.recipeID] = nil
  end
end

-- Priced recipes of the open profession by product: the Profit table's when
-- it's open, else read here (cached for a second on the reagent window).
local function liveByProduct()
  if ns.panel and ns.panel:IsVisible() and ns.panel.byProduct then return ns.panel.byProduct end
  if not hostShown() then return {} end
  local cache = popup and popup.live
  if not cache or GetTime() - cache.t > 1 then
    cache = { t = GetTime(), map = {} }
    for _, recipe in ipairs(readRecipes()) do
      evaluate(recipe)
      if recipe.productID then cache.map[recipe.productID] = recipe end
    end
    if popup then popup.live = cache end
  end
  return cache.map
end

-- Update: every queued item whose reagents lead to this one now crafts it
-- (ticked) or buys it (unticked).
local function applyChoiceToQueue(entry)
  local id = entry.sub.recipeID
  if not entry.include then
    dropSub(id)
    return
  end
  local byProduct = liveByProduct()
  local def = recipeDef(entry.sub)
  for _, main in ipairs(craftQueue()) do
    local recipe = main.productID and byProduct[main.productID]
    if recipe then
      for _, sub in ipairs(subTree(recipe, main.count, byProduct)) do
        if sub.sub.recipeID == id then
          main.subs = main.subs or {}
          main.subs[id] = def
          break
        end
      end
    end
  end
end

local function popupCrafts()
  local n = tonumber(popup.qty:GetText()) or 1
  return math.max(1, math.min(n, 999))
end

-- One line per reagent: name, what crafting it does to the shopping list,
-- crafts to queue. Hover for the numbers.
local function reagentVerdict(effect)
  if effect.unknown then return RED .. "cost unknown|r" end
  if effect.short then return RED .. "not enough on AH|r" end
  if effect.needed then return GREEN .. "not on AH|r" end
  if effect.saving > 0 then return GREEN .. "saves " .. API.Money(effect.saving) .. "|r" end
  if effect.saving < 0 then return RED .. "loses " .. API.Money(-effect.saving) .. "|r" end
  return GREY .. "no change|r"
end

local function reagentRowTooltip(row)
  local entry, d, effect = row.entry, row.plan, row.effect
  if not entry then return end
  GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
  GameTooltip:AddLine(entry.reagent.name or "?")
  if d then
    GameTooltip:AddDoubleLine("Need / have", ("%d / %d"):format(d.need, d.have), 0.8, 0.8, 0.8, 1, 1, 1)
    GameTooltip:AddDoubleLine("Crafts to queue", d.count, 0.8, 0.8, 0.8, 1, 1, 1)
  end
  if row.queuedNow and row.queuedNow > 0 then
    GameTooltip:AddDoubleLine("Already queued", row.queuedNow, 0.8, 0.8, 0.8, 1, 1, 1)
  end
  if effect then
    GameTooltip:AddDoubleLine("Shopping list if crafted", API.Money(effect.craft), 0.8, 0.8, 0.8, 1, 1, 1)
    GameTooltip:AddDoubleLine("Shopping list if bought", API.Money(effect.buy), 0.8, 0.8, 0.8, 1, 1, 1)
    if effect.short then GameTooltip:AddLine("Crafting it needs more of a reagent than the AH lists.", 1, 0.4, 0.4, true) end
    if effect.unknown then GameTooltip:AddLine("Crafting it needs a reagent with no price.", 1, 0.4, 0.4, true) end
    if effect.needed then GameTooltip:AddLine("It has no current AH price, so crafting is the way to get it.", 0.6, 0.6, 0.6, true) end
  end
  if entry.unitCraft then GameTooltip:AddDoubleLine("Craft cost (one)", API.Money(entry.unitCraft) .. " ea", 0.6, 0.6, 0.6, 0.8, 0.8, 0.8) end
  if entry.canBuy then GameTooltip:AddDoubleLine("Buy price (one)", API.Money(entry.buy) .. " ea", 0.6, 0.6, 0.6, 0.8, 0.8, 0.8) end
  GameTooltip:AddLine("Shopping list costs count every reagent of the queue at the amount needed, from the order book.", 0.6, 0.6, 0.6, true)
  if entry.include ~= entry.ruleInclude then
    GameTooltip:AddLine("Your choice (remembered) - the rule would " .. (entry.ruleInclude and "craft" or "buy") .. " it.", 0.6, 0.6, 0.6, true)
  end
  if not row.active and entry.include then GameTooltip:AddLine("A reagent above it is unticked.", 0.6, 0.6, 0.6, true) end
  GameTooltip:Show()
end

-- Header lines move up in the preview (no quantity row there).
-- In the reagent list the profit line is on the queue window instead.
local function layoutPopup(batch)
  local top = batch and -20 or 24
  popup.profit:SetShown(not batch)
  popup.inQueue:ClearAllPoints()
  popup.inQueue:SetPoint("TOPLEFT", 14, batch and -34 or -58)
  popup.inQueue:SetPoint("RIGHT", -14, 0)
  popup.profit:ClearAllPoints()
  popup.profit:SetPoint("TOPLEFT", 14, -52 - top)
  popup.profit:SetPoint("RIGHT", -14, 0)
  popup.subHeader:ClearAllPoints()
  popup.subHeader:SetPoint("TOPLEFT", 14, -72 - top)
  for i, row in ipairs(popup.subRows) do
    row:ClearAllPoints()
    row:SetPoint("TOPLEFT", 10, -88 - top - (i - 1) * 20)
    row:SetPoint("RIGHT", -12, 0)
  end
  return 88 + top
end

local function updatePopup()
  local batch = popup.batch
  for _, widget in ipairs(popup.qtyWidgets) do widget:SetShown(not batch) end
  popup.queueButton:SetShown(not batch)
  popup.backButton:SetShown(not batch)
  popup.updateButton:SetEnabled(next(popup.changed) ~= nil)
  local rowsTop = layoutPopup(batch)
  -- mains offer every listed reagent recipe; on() says which are ticked.
  local mains, recipe, crafts = popup.mains, nil, nil
  if batch then
    local total = 0
    for _, step in ipairs(batch) do total = total + step.crafts end
    popup.title:SetText("Reagents for the queue")
    popup.inQueue:SetText(("%d queued item(s), %d craft(s)"):format(#batch, total))
  else
    recipe, crafts = popup.recipe, popupCrafts()
    popup.title:SetText("Queue: " .. recipe.name)
    popup.madeText:SetText(recipe.made > 1 and ("crafts (makes %d each)"):format(recipe.made) or "crafts")
    local target = queueTarget(recipe)
    popup.inQueue:SetText(("Already queued: %d"):format(queuedCount(recipe.recipeID)))
    if not popup.restockBox:HasFocus() then popup.restockBox:SetText(target and tostring(target) or "") end

    -- Plan this item alone to show how many of each reagent level it needs.
    local main = recipeDef(recipe)
    main.count, main.subs = crafts, {}
    for _, entry in ipairs(popup.subs) do main.subs[entry.sub.recipeID] = recipeDef(entry.sub) end
    mains = { main }
  end
  local listed = {}
  for _, entry in ipairs(popup.subs) do listed[entry.sub.recipeID] = entry end
  local function on(id)
    local entry = listed[id]
    if entry then return entry.include end
    return true -- another profession's reagent crafts in the queue stay as they are
  end
  local _, plan = planDerived(withSubs(mains, on))
  -- What all the ticked reagent crafts together do to the shopping list.
  local saving = not batch and shoppingCost(mains, function(id) return not listed[id] end) - shoppingCost(mains, on) or 0

  local rows = popup.subRows
  for i, entry in ipairs(popup.subs) do
    local active = effectivelyIncluded(popup.subs, i)
    local d = active and plan[entry.sub.recipeID]
    local row = rows[i]
    if row then
      local effect = craftEffect(mains, on, entry.sub.recipeID)
      row.entry, row.plan, row.active, row.effect = entry, d, active, effect
      row.queuedNow = queuedCount(entry.sub.recipeID)
      row.check:SetChecked(entry.include)
      row.check:ClearAllPoints()
      row.check:SetPoint("LEFT", (entry.depth - 1) * 12, 0)
      local name = (entry.depth > 1 and (GREY .. ">|r ") or "") .. (entry.reagent.name or "?")
      if entry.include and not active then name = GREY .. (entry.reagent.name or "?") .. "|r" end
      row.left:SetText(name)
      row.right:SetText(reagentVerdict(effect))
      row.count:SetText(d and d.count > 0 and ("x%d"):format(d.count) or (GREY .. "-|r"))
      row:Show()
    end
  end
  local shownRows = math.min(#popup.subs, #rows)
  for i = shownRows + 1, #rows do
    rows[i]:Hide()
    rows[i].entry = nil
  end
  local more = #popup.subs - shownRows
  popup.subHeader:SetText((#popup.subs == 0 and "No craftable reagents."
    or db.skipReagentCrafts and ("Reagents " .. RED .. "(crafting them is off)|r")
    or "Reagents to craft (ticked):")
    .. (more > 0 and (GREY .. ("  +%d more (by the rule)|r"):format(more)) or ""))

  local text
  if batch then
    text = nil
  elseif recipe.profit then
    text = ("Profit: %s ea, %s total"):format(API.Money(recipe.profit), API.Money(recipe.profit * crafts))
    if recipe.incomplete then text = text .. RED .. " *|r" end
  end
  if text then
    if saving > 0 then
      text = text .. ("  " .. GREEN .. "+%s from reagents|r"):format(API.Money(saving))
    elseif saving < 0 then
      text = text .. ("  " .. RED .. "-%s from reagents|r"):format(API.Money(-saving))
    end
    popup.profit:SetText(text)
  elseif not batch then
    popup.profit:SetText(GREY .. "Profit unknown (no AH price for the crafted item).|r")
  end
  popup:SetHeight(rowsTop + math.max(shownRows, 1) * 20 + 40)
  ns.placeReagentWindow()
end
ns.updatePopup = updatePopup

-- The queue window's profit line: the queued items' profit (as priced in
-- the Profit table, so the open profession's only, every reagent bought)
-- plus what the ticked reagent crafts do to the shopping list (listCost:
-- its cost as queued).
local function queueProfitLine(listCost)
  local queue = craftQueue()
  if #queue == 0 then return "" end
  local byProduct = liveByProduct()
  local total, priced, unpriced, incomplete = 0, 0, 0, false
  for _, main in ipairs(queue) do
    local recipe = main.productID and byProduct[main.productID]
    if recipe and recipe.recipeID == main.recipeID and recipe.profit then
      total, priced = total + recipe.profit * main.count, priced + 1
      incomplete = incomplete or recipe.incomplete
    else
      unpriced = unpriced + 1
    end
  end
  local saving = db.skipReagentCrafts and 0 or (shoppingCost(queue, function() return false end) - listCost)
  local text = "Profit: " .. (priced > 0 and API.Money(total + saving) or (GREY .. "unknown|r"))
  if incomplete then text = text .. RED .. " *|r" end
  if saving > 0 then
    text = text .. ("  " .. GREEN .. "(+%s from reagents)|r"):format(API.Money(saving))
  elseif saving < 0 then
    text = text .. ("  " .. RED .. "(-%s from reagents)|r"):format(API.Money(-saving))
  end
  if unpriced > 0 then text = text .. GREY .. (" %d unpriced"):format(unpriced) .. "|r" end
  return text
end
ns.queueProfitLine = queueProfitLine

local showBatch -- defined below

-- Its own window, hung under the craft queue window (placed by
-- placeReagentWindow) and shown with the Profit tab.
local function createPopup()
  popup = CreateFrame("Frame", "ProfessionProfitReagentWindow", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
  ns.popup = popup
  popup:SetSize(330, 140)
  popup:SetFrameStrata("HIGH")
  popup:SetClampedToScreen(true)
  popup:EnableMouse(true)
  if popup.SetBackdrop then
    popup:SetBackdrop({
      bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
      edgeSize = 16, insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    popup:SetBackdropColor(0.07, 0.06, 0.05, 0.97)
    popup:SetBackdropBorderColor(0.6, 0.5, 0.3, 1)
  end
  popup:Hide()

  local close = CreateFrame("Button", nil, popup, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", -2, -2)
  -- Stays closed until the queue window opens again (or + is used).
  close:SetScript("OnClick", function()
    popup.closed = true
    popup:Hide()
  end)

  popup.title = popup:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  popup.title:SetPoint("TOPLEFT", 14, -12)
  popup.title:SetPoint("RIGHT", -34, 0)
  popup.title:SetJustifyH("LEFT")
  popup.title:SetWordWrap(false)

  local minus = CreateFrame("Button", nil, popup, "UIPanelButtonTemplate")
  minus:SetSize(22, 20)
  minus:SetPoint("TOPLEFT", 14, -32)
  minus:SetText("-")
  popup.qty = CreateFrame("EditBox", nil, popup, "InputBoxTemplate")
  popup.qty:SetSize(40, 20)
  popup.qty:SetPoint("LEFT", minus, "RIGHT", 8, 0)
  popup.qty:SetAutoFocus(false)
  popup.qty:SetNumeric(true)
  popup.qty:SetMaxLetters(3)
  popup.qty:SetJustifyH("CENTER")
  local plus = CreateFrame("Button", nil, popup, "UIPanelButtonTemplate")
  plus:SetSize(22, 20)
  plus:SetPoint("LEFT", popup.qty, "RIGHT", 4, 0)
  plus:SetText("+")
  local function bump(delta)
    popup.qty:SetText(tostring(math.max(1, popupCrafts() + delta)))
    updatePopup()
  end
  minus:SetScript("OnClick", function() bump(IsShiftKeyDown() and -5 or -1) end)
  plus:SetScript("OnClick", function() bump(IsShiftKeyDown() and 5 or 1) end)
  popup.qty:SetScript("OnTextChanged", function(_, user) if user then updatePopup() end end)
  popup.qty:SetScript("OnEnterPressed", function(self) self:ClearFocus() popup.queueButton:Click() end)
  popup.qty:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  popup.madeText = popup:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  popup.madeText:SetPoint("LEFT", plus, "RIGHT", 8, 0)
  -- Restock target for this recipe (blank = none): saved on Enter.
  popup.restockBox = CreateFrame("EditBox", nil, popup, "InputBoxTemplate")
  popup.restockBox:SetSize(36, 20)
  popup.restockBox:SetPoint("TOPRIGHT", -16, -32)
  popup.restockBox:SetAutoFocus(false)
  popup.restockBox:SetNumeric(true)
  popup.restockBox:SetMaxLetters(4)
  popup.restockBox:SetJustifyH("RIGHT")
  local function saveRestock(self)
    self:ClearFocus()
    if not popup.recipe then return end
    setQueueTarget(popup.recipe, tonumber(self:GetText()))
    popup.qty:SetText(tostring(math.max(1, craftsToQueue(popup.recipe))))
    ns.toggleTargetsWindow(true)
    updatePopup()
  end
  popup.restockBox:SetScript("OnEnterPressed", saveRestock)
  popup.restockBox:SetScript("OnEditFocusLost", saveRestock)
  popup.restockBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  popup.restockBox:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:AddLine("Restock to")
    GameTooltip:AddLine("How many of this item you want to own. With Top up ticked, queueing tops it up to this instead of Qty. Blank or 0 removes it. All targets are listed in the Restocking window.", 1, 1, 1, true)
    GameTooltip:AddLine("Left blank, queueing more than one here sets it to that amount.", 0.7, 0.7, 0.7, true)
    GameTooltip:Show()
  end)
  popup.restockBox:SetScript("OnLeave", GameTooltip_Hide)
  local restockLabel = popup:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  restockLabel:SetPoint("RIGHT", popup.restockBox, "LEFT", -6, 0)
  restockLabel:SetText("Restock to")
  popup.qtyWidgets = { minus, popup.qty, plus, popup.madeText, popup.restockBox, restockLabel } -- hidden in the reagent list

  popup.inQueue = popup:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  popup.inQueue:SetJustifyH("LEFT")
  popup.inQueue:SetWordWrap(false)
  popup.profit = popup:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  popup.profit:SetJustifyH("LEFT")
  popup.profit:SetWordWrap(false)
  popup.subHeader = popup:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  popup.subHeader:SetJustifyH("LEFT")

  popup.subRows = {}
  for i = 1, DOCK_ROWS do
    local row = CreateFrame("Frame", nil, popup)
    row:SetHeight(20)
    row:EnableMouse(true)
    row:SetScript("OnEnter", reagentRowTooltip)
    row:SetScript("OnLeave", GameTooltip_Hide)
    row.check = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
    row.check:SetSize(20, 20)
    row.check:SetPoint("LEFT")
    row.check:SetScript("OnClick", function(self)
      local entry = popup.subs[i]
      if entry then
        entry.include = self:GetChecked() and true or false
        rememberChoice(entry)
        popup.changed[entry.sub.recipeID] = entry -- applied to the queue by Update
      end
      updatePopup()
    end)
    row.count = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.count:SetPoint("RIGHT")
    row.count:SetWidth(44)
    row.count:SetJustifyH("RIGHT")
    row.right = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.right:SetPoint("RIGHT", row.count, "LEFT", -6, 0)
    row.right:SetWidth(112)
    row.right:SetJustifyH("RIGHT")
    row.right:SetWordWrap(false)
    row.left = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.left:SetPoint("LEFT", row.check, "RIGHT", 2, 0)
    row.left:SetPoint("RIGHT", row.right, "LEFT", -4, 0)
    row.left:SetJustifyH("LEFT")
    row.left:SetWordWrap(false)
    popup.subRows[i] = row
  end

  popup.queueButton = CreateFrame("Button", nil, popup, "UIPanelButtonTemplate")
  popup.queueButton:SetSize(100, 22)
  popup.queueButton:SetPoint("BOTTOMRIGHT", -12, 12)
  popup.queueButton:SetText("Queue")
  popup.backButton = CreateFrame("Button", nil, popup, "UIPanelButtonTemplate")
  popup.backButton:SetSize(80, 22)
  popup.backButton:SetPoint("RIGHT", popup.queueButton, "LEFT", -6, 0)
  popup.backButton:SetText("Back")
  popup.backButton:SetScript("OnClick", function() showBatch() end)

  -- Ticks only change the queue when you press Update.
  popup.changed = {}
  popup.updateButton = CreateFrame("Button", nil, popup, "UIPanelButtonTemplate")
  popup.updateButton:SetSize(80, 22)
  popup.updateButton:SetPoint("BOTTOMLEFT", 12, 12)
  popup.updateButton:SetText("Update")
  popup.updateButton:SetScript("OnClick", function()
    for id, entry in pairs(popup.changed) do
      applyChoiceToQueue(entry)
      popup.changed[id] = nil
    end
    ns.updateQueueWindow()
    updatePopup()
  end)
  popup.updateButton:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:AddLine("Update the queue")
    GameTooltip:AddLine("Applies the reagents you've ticked or unticked to what's already queued: ticked ones get crafted, unticked ones go on the shopping list.", 1, 1, 1, true)
    GameTooltip:AddLine("Your ticks are remembered either way and used for anything you queue next.", 0.7, 0.7, 0.7, true)
    GameTooltip:Show()
  end)
  popup.updateButton:SetScript("OnLeave", GameTooltip_Hide)

  popup.queueButton:SetScript("OnClick", function()
    local recipe, crafts = popup.recipe, popupCrafts()
    -- Queueing more than one with no target set remembers that amount.
    if crafts > 1 and not queueTarget(recipe) and recipe.productID then
      setQueueTarget(recipe, crafts * recipe.made)
      msg(("Restock target for %s set to %d (change it in Restocking)."):format(recipe.name, crafts * recipe.made))
      ns.toggleTargetsWindow(true)
    end
    local done, failed = queueOrdered({ { recipe = recipe, crafts = crafts, subs = chosenSubs(popup.subs) } })
    if #done > 0 then msg("Queued: " .. table.concat(done, ", ")) end
    if #failed > 0 then msg("Not queued: " .. table.concat(failed, ", ")) end
    popup.recipe = nil
    showBatch() -- back to the queue's reagents
    if refresh then refresh() end
  end)
end
ns.createPopup = createPopup

-- What "Queue profitable" queues: every recipe shown in the table with a
-- positive, complete profit, Qty / restock-target crafts each.
local function profitableSteps()
  local steps, skippedIncomplete, skippedStock = {}, 0, 0
  for _, recipe in ipairs(ns.panel.shown or {}) do
    if recipe.profit and recipe.profit > 0 then
      if recipe.incomplete then
        skippedIncomplete = skippedIncomplete + 1
      else
        local n = craftsToQueue(recipe)
        if n <= 0 then
          skippedStock = skippedStock + 1
        else
          steps[#steps + 1] = { recipe = recipe, crafts = n }
        end
      end
    end
  end
  local skipped = ""
  if skippedIncomplete > 0 then skipped = skipped .. (", %d skipped (incomplete prices)"):format(skippedIncomplete) end
  if skippedStock > 0 then skipped = skipped .. (", %d already stocked"):format(skippedStock) end
  return steps, skipped
end

-- Show the queue's craftable reagents (open profession only), each once,
-- ticked when the queue crafts them - or as you've ticked them, until Update.
-- Hidden when the queue has none, or reagent crafting is off.
showBatch = function()
  if not popup then return end
  local byProduct = liveByProduct()
  local steps, others, queued = {}, {}, {}
  for _, main in ipairs(craftQueue()) do
    local recipe = main.productID and byProduct[main.productID]
    if recipe and recipe.recipeID == main.recipeID then
      for id in pairs(main.subs or {}) do queued[id] = true end
      steps[#steps + 1] = { recipe = recipe, crafts = main.count }
    else
      others[#others + 1] = main -- another profession: kept as queued
    end
  end
  local merged, mains = mergeTrees(steps, byProduct)
  for _, main in ipairs(others) do mains[#mains + 1] = main end
  recommend(merged, mains)
  for _, entry in ipairs(merged) do
    local id = entry.sub.recipeID
    entry.ruleInclude = entry.include
    entry.include = queued[id] or false
    if popup.changed[id] then entry.include = popup.changed[id].include end
  end
  popup.recipe, popup.batch, popup.subs, popup.mains = nil, steps, merged, mains
  -- Nothing to choose when the queue crafts no reagents ("Craft reagents" off).
  if #merged == 0 or popup.closed or db.skipReagentCrafts then
    popup:Hide()
    return
  end
  popup:Show()
  updatePopup()
end
ns.showBatch = showBatch

-- + on a row: the reagent window shows that recipe until you Queue or go Back.
local function openQueuePopup(recipe)
  if not recipe.recipeID then msg("Queueing needs the Professions (K) window.") return end
  if not popup then createPopup() end
  popup.recipe, popup.batch, popup.closed, popup.mains = recipe, nil, nil, nil
  local flat, mains = mergeTrees({ { recipe = recipe, crafts = math.max(1, craftsToQueue(recipe)) } })
  popup.subs = applyChoices(recommend(flat, mains))
  popup.qty:SetText(tostring(math.max(1, craftsToQueue(recipe))))
  popup:Show()
  updatePopup()
  log("queue popup", recipe.name, #popup.subs, "craftable reagents")
end
ns.openQueuePopup = openQueuePopup

-- Queue every profitable recipe in the table, crafting the reagents you've
-- chosen (or the craft-or-buy rule picks). Fine-tune them afterwards in the
-- reagent window.
local function queueProfitable()
  local steps, skipped = profitableSteps()
  if #steps == 0 then
    msg("Nothing to queue" .. skipped .. ".")
    return
  end
  -- Decided together: their reagents share order books.
  local merged, mains = mergeTrees(steps)
  local chosen = {}
  for _, sub in ipairs(chosenSubs(applyChoices(recommend(merged, mains)))) do chosen[sub.recipeID] = sub end
  for _, step in ipairs(steps) do
    step.subs = {}
    for id in pairs(step.tree) do
      if chosen[id] then step.subs[#step.subs + 1] = chosen[id] end
    end
  end
  local done, failed = queueOrdered(steps)
  local text = ("Queued %d recipe(s)%s."):format(#done, skipped)
  msg(text)
  if #failed > 0 then msg("Not queued: " .. table.concat(failed, ", ")) end
  log("queue profitable:", text, table.concat(done, ", "))
  if refresh then refresh() end
end
ns.queueProfitable = queueProfitable
