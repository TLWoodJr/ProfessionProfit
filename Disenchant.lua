-- ProfessionProfit: Disenchanting: the disenchant queue, the Disenchant
-- button on the Profit tab, and a pop-up with what each disenchant made.
--
-- Queue a recipe with "Disenchant" ticked (+ on a row) and what it makes goes
-- in the disenchant queue with its projected profit: what the expected
-- materials sell for after the AH cut, minus what the item cost to craft.
-- Each disenchant of a queued item then counts its realized profit - the
-- materials you actually got, at today's prices - against that projection.
-- The expected materials and prices come from LibCraftProfit.

local ADDON, ns = ...
local API, RED, GREY, GREEN, msg, log, charKey = ns.API, ns.RED, ns.GREY, ns.GREEN, ns.msg, ns.log, ns.charKey
local db
ns.onInit(function(saved) db = saved end)

local DISENCHANT = API.DISENCHANT_SPELL
local LOOT_WINDOW = 6 -- seconds from a finished Disenchant to its loot

local function spellName()
  return (C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(DISENCHANT))
    or (GetSpellInfo and GetSpellInfo(DISENCHANT)) or "Disenchant"
end

local function isEnchanter()
  if IsPlayerSpell and IsPlayerSpell(DISENCHANT) then return true end
  if GetProfessions and GetProfessionInfo then
    local p1, p2 = GetProfessions()
    for _, index in ipairs({ p1 or 0, p2 or 0 }) do
      if index > 0 and select(7, GetProfessionInfo(index)) == API.ENCHANTING_SKILL_LINE then return true end
    end
  end
  return false
end
ns.isEnchanter = isEnchanter

local function lastBag() return NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS or 4 end

------------------------------------------------------------------------------
-- The queue: { itemID, name, count, cost (each), projected (profit each) },
-- one for all your characters: craft on one, mail to your enchanter and
-- disenchant there. The run: what's been disenchanted from it since it was
-- last empty - casts, realized and projected profit, casts with unpriced
-- materials. db.deHeld[charKey] = { [itemID] = count in bags } of queued
-- items, as each character last saw them.
------------------------------------------------------------------------------

local NEW_RUN = function() return { casts = 0, realized = 0, projected = 0, unpriced = 0 } end

-- Older saves kept a queue and a run per character: merge them.
ns.onInit(function(saved)
  local old = saved.deQueue
  if type(old) == "table" and type(next(old)) == "string" then -- keyed by character
    local merged = {}
    for _, list in pairs(old) do
      for _, e in ipairs(list) do
        local into
        for _, m in ipairs(merged) do if m.itemID == e.itemID then into = m break end end
        if into then
          local total = into.count + e.count
          into.cost = (into.cost * into.count + e.cost * e.count) / total
          into.projected = (into.projected * into.count + e.projected * e.count) / total
          into.count = total
        else
          merged[#merged + 1] = e
        end
      end
    end
    saved.deQueue = merged
  end
  local run = saved.deRun
  if type(run) == "table" and run.casts == nil then
    local sum = NEW_RUN()
    for _, r in pairs(run) do
      if type(r) == "table" then
        for k in pairs(sum) do sum[k] = sum[k] + (r[k] or 0) end
      end
    end
    saved.deRun = sum
  end
end)

local function deQueue()
  db.deQueue = db.deQueue or {}
  return db.deQueue
end
ns.deQueue = deQueue

local function deRun()
  db.deRun = db.deRun or NEW_RUN()
  return db.deRun
end
ns.deRun = deRun

-- Save how many of each queued item this character has in its bags.
local function recordHeld()
  db.deHeld = db.deHeld or {}
  local held = {}
  for _, e in ipairs(deQueue()) do
    local n = ns.bagCount(e.itemID)
    if n > 0 then held[e.itemID] = n end
  end
  db.deHeld[charKey()] = next(held) and held or nil
end

-- Your other characters holding a queued item: { { name, count }, ... },
-- most first, and how many that is.
local function heldElsewhere(itemID)
  local list, total, me = {}, 0, charKey()
  for key, held in pairs(db.deHeld or {}) do
    local n = key ~= me and held[itemID]
    if n and n > 0 then
      list[#list + 1] = { name = ns.crafterName(key), count = n }
      total = total + n
    end
  end
  table.sort(list, function(a, b) return a.count > b.count end)
  return list, total
end
ns.deHeldElsewhere = heldElsewhere

-- Where a queued item is, for a row: "here/queued" coloured (green: all
-- here, yellow: some, red: none) and the other characters holding some.
local function whereText(e)
  local have = ns.bagCount(e.itemID)
  local color = have >= e.count and "|cff40ff40" or have > 0 and "|cffffd933" or "|cffff6666"
  local text = ("%s%d/%d|r"):format(color, math.min(have, e.count), e.count)
  local others = heldElsewhere(e.itemID)
  local parts = {}
  for i, o in ipairs(others) do
    if i > 2 then parts[#parts + 1] = "..." break end
    parts[#parts + 1] = o.name .. " " .. o.count
  end
  return text, #parts > 0 and (GREY .. "(" .. table.concat(parts, ", ") .. ")|r") or nil
end
ns.deWhereText = whereText

-- Tooltip lines: where a queued item is across your characters.
local function addWhereLines(e)
  local have = ns.bagCount(e.itemID)
  GameTooltip:AddDoubleLine("In your bags", have, 0.8, 0.8, 0.8, 1, 1, 1)
  local others, elsewhere = heldElsewhere(e.itemID)
  for _, o in ipairs(others) do
    GameTooltip:AddDoubleLine("On " .. o.name, o.count, 0.8, 0.8, 0.8, 1, 1, 1)
  end
  local unseen = e.count - have - elsewhere
  if unseen > 0 then
    GameTooltip:AddDoubleLine("Not in anyone's bags", unseen, 0.8, 0.8, 0.8, 1, 0.4, 0.4)
    GameTooltip:AddLine("Still to craft, or in the mail.", 0.6, 0.6, 0.6, true)
  end
  if #others > 0 then
    GameTooltip:AddLine("Other characters' bags as of when they last logged in.", 0.6, 0.6, 0.6, true)
  end
end
ns.deAddWhereLines = addWhereLines

local function changed()
  if ns.updateDisenchantButton then ns.updateDisenchantButton() end
  if ns.updateQueueWindow then ns.updateQueueWindow() end
end

-- Queue `count` of an item for disenchanting, at cost and projected profit each.
local function queueDisenchantItem(itemID, name, count, cost, projected)
  if not itemID or count <= 0 then return end
  local queue = deQueue()
  if #queue == 0 then db.deRun = nil end -- a new run
  local entry
  for _, e in ipairs(queue) do if e.itemID == itemID then entry = e break end end
  if entry then
    -- Averaged over what's queued.
    local total = entry.count + count
    entry.cost = (entry.cost * entry.count + cost * count) / total
    entry.projected = (entry.projected * entry.count + projected * count) / total
    entry.count = total
  else
    queue[#queue + 1] = { itemID = itemID, name = name, count = count, cost = cost, projected = projected }
  end
  log("disenchant queued", name, count)
  recordHeld()
  changed()
end
ns.queueDisenchantItem = queueDisenchantItem

-- Queue `count` of what an evaluated recipe makes for disenchanting.
local function queueDisenchant(recipe, count)
  if not (recipe.productID and recipe.shuffleProfit) or count <= 0 then return end
  local made = recipe.made or 1
  queueDisenchantItem(recipe.productID, recipe.productName or recipe.name, count, recipe.cost / made, recipe.shuffleProfit / made)
end
ns.queueDisenchant = queueDisenchant

-- Change a queued item's count (the queue window's - / + / x).
local function changeDisenchant(entry, delta)
  entry.count = entry.count + delta
  if entry.count <= 0 then
    for i, e in ipairs(deQueue()) do if e == entry then table.remove(deQueue(), i) break end end
    -- Done with it: forget who holds it.
    for _, held in pairs(db.deHeld or {}) do held[entry.itemID] = nil end
  end
  recordHeld()
  changed()
end
ns.changeDisenchant = changeDisenchant

-- Empty the queue (Shift-click Clear in the queue window).
local function clearDisenchant()
  wipe(deQueue())
  db.deHeld = nil
  changed()
end
ns.clearDisenchant = clearDisenchant

local function queuedEntry(itemID)
  for _, e in ipairs(deQueue()) do
    if e.itemID == itemID then return e end
  end
end

-- The next queued item in your bags: bag, slot, entry; and how many queued
-- items are in your bags in all.
local function nextDisenchant()
  local first, inBags = nil, 0
  local queue = deQueue()
  if #queue == 0 then return nil, nil, nil, 0 end
  for bag = 0, lastBag() do
    for slot = 1, C_Container.GetContainerNumSlots(bag) do
      local info = C_Container.GetContainerItemInfo(bag, slot)
      local entry = info and queuedEntry(info.itemID)
      if entry and not info.isLocked then
        inBags = inBags + 1
        first = first or { bag, slot, entry }
      end
    end
  end
  if first then return first[1], first[2], first[3], inBags end
  return nil, nil, nil, 0
end

-- Projected profit of everything still queued, and how many items that is.
local function projectedLeft()
  local total, count = 0, 0
  for _, e in ipairs(deQueue()) do
    total, count = total + e.projected * e.count, count + e.count
  end
  return total, count
end
ns.deProjectedLeft = projectedLeft

------------------------------------------------------------------------------
-- The Disenchant button: a secure button (spells need a real click or key
-- press) that disenchants the next queued item in your bags. It sits at the
-- top of the Profit tab for enchanters; its key binding works anywhere.
------------------------------------------------------------------------------

local target -- { itemID, t }: what the last click disenchants

local function preClick(self)
  if InCombatLockdown() then return end
  local bag, slot, entry = nextDisenchant()
  -- A bag slot, never an item name: a name would also match equipped gear.
  self:SetAttribute("macrotext", bag and ("/cast [nocombat] %s\n/use [nocombat] %d %d"):format(spellName(), bag, slot) or nil)
  target = entry and { itemID = entry.itemID, t = GetTime() } or nil
end

local function buttonTooltip(self)
  GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
  GameTooltip:AddLine("Disenchant")
  local queue = deQueue()
  if #queue == 0 then
    GameTooltip:AddLine("Nothing queued to disenchant. Tick Disenchant when you queue a recipe with +, or buy from the Disenchant Scan.", 1, 1, 1, true)
  else
    local bag, slot = nextDisenchant()
    if bag then
      GameTooltip:AddDoubleLine("Next", C_Container.GetContainerItemLink(bag, slot) or "?", 0.8, 0.8, 0.8, 1, 1, 1)
    else
      GameTooltip:AddLine("None of the queued items are in your bags yet.", 1, 0.4, 0.4, true)
    end
    for _, e in ipairs(queue) do
      GameTooltip:AddDoubleLine(("%dx %s"):format(e.count, e.name or "?"), API.Money(e.projected) .. " ea",
        0.85, 0.85, 0.85, 1, 1, 1)
    end
    local projected = projectedLeft()
    GameTooltip:AddDoubleLine("Projected profit", API.Money(projected), 1, 1, 1, 1, 1, 1)
  end
  local run = deRun()
  if run.casts > 0 then
    GameTooltip:AddDoubleLine(("Disenchanted %d"):format(run.casts),
      API.Money(run.realized) .. GREY .. " (projected " .. API.Money(run.projected) .. ")|r", 1, 1, 1, 1, 1, 1)
  end
  GameTooltip:AddLine("Projected: expected materials at AH prices after the 5% cut, minus what the item cost. Realized: the materials you got.", 0.6, 0.6, 0.6, true)
  GameTooltip:AddLine("Bind a key: Key Bindings > AddOns > Disenchant next queued item.", 0.6, 0.6, 0.6, true)
  GameTooltip:Show()
end

-- A secure button (spells need a real click or key press) that disenchants
-- the next queued item in your bags. A child of UIParent: a secure frame
-- can't be anchored to our windows, so it's placed at screen coordinates.
local function newButton(name)
  local b = CreateFrame("Button", name, UIParent, "SecureActionButtonTemplate,UIPanelButtonTemplate")
  b:SetSize(190, 22)
  b:Hide()
  b:RegisterForClicks("AnyUp", "AnyDown") -- the template picks down or up from ActionButtonUseKeyDown
  b:SetAttribute("type", "macro")
  b:SetScript("PreClick", preClick)
  b:SetScript("OnEnter", buttonTooltip)
  b:SetScript("OnLeave", GameTooltip_Hide)
  return b
end

-- On the Profit tab (right of its title), and on the Disenchant planner.
local button = newButton("ProfessionProfitDisenchantButton")
local plannerButton = newButton("ProfessionProfitDisenchantPlannerButton")
button:SetWidth(150) -- fits between the Profit tab's title and its filters
_G["BINDING_NAME_CLICK ProfessionProfitDisenchantButton:LeftButton"] = "Disenchant next queued item"

local planner -- the Disenchant planner window (below)

local function updateDisenchantButton()
  local projected, count = projectedLeft()
  local _, _, _, inBags = nextDisenchant()
  local text = "Disenchant"
  if count > 0 then
    local color = projected >= 0 and GREEN or RED
    text = ("Disenchant %d  %s%s%s|r"):format(inBags, color, projected >= 0 and "+" or "",
      (API.Money(projected):gsub("|r", "|r" .. color)))
  end
  button:SetText(text)
  plannerButton:SetText(text)
  if not InCombatLockdown() then
    local panel = ns.panel
    button:SetShown(panel ~= nil and panel:IsVisible() and isEnchanter())
    plannerButton:SetShown(planner ~= nil and planner:IsVisible() and isEnchanter())
  end
  if planner and planner:IsVisible() and planner.update then planner.update() end
end
ns.updateDisenchantButton = updateDisenchantButton

-- Put a secure button at a region's screen position: its point at the
-- region's relPoint (LEFT, RIGHT or CENTER, vertically centred), dx along.
local function placeAt(btn, region, point, relPoint, dx)
  if InCombatLockdown() then return end
  local l, r, t, b = region:GetLeft(), region:GetRight(), region:GetTop(), region:GetBottom()
  if not (l and r and t and b) then return end
  local x = relPoint == "RIGHT" and r or relPoint == "LEFT" and l or (l + r) / 2
  local scale = region:GetEffectiveScale() / UIParent:GetEffectiveScale()
  x, b = math.floor((x + (dx or 0)) * scale + 0.5), math.floor((t + b) / 2 * scale + 0.5)
  if btn.placedX == x and btn.placedY == b then return end
  btn.placedX, btn.placedY = x, b
  btn:ClearAllPoints()
  btn:SetPoint(point, UIParent, "BOTTOMLEFT", x, b)
end

-- Keep btn on a window: placed when it shows or moves, above it.
local function follow(btn, win, place)
  local function sync()
    if InCombatLockdown() then return end
    btn.placedX = nil
    place()
    btn:SetFrameStrata(win:GetFrameStrata())
    btn:SetFrameLevel(win:GetFrameLevel() + 20)
    updateDisenchantButton()
  end
  win:HookScript("OnShow", sync)
  win:HookScript("OnHide", sync)
  -- Follow the window if it's dragged (BlizzMove and the like).
  local elapsed = 0
  win:HookScript("OnUpdate", function(_, dt)
    elapsed = elapsed + dt
    if elapsed < 0.2 then return end
    elapsed = 0
    place()
  end)
  sync()
end

local function attachDisenchantButton(panel)
  follow(button, panel, function() placeAt(button, panel.title, "LEFT", "RIGHT", 10) end)
end
ns.attachDisenchantButton = attachDisenchantButton

------------------------------------------------------------------------------
-- The Disenchant planner. To buy: items picked from the Disenchant Scan,
-- bought one listing per press of Buy (DisenchantScan.lua does the buying).
-- To disenchant: what's queued, how many are in your bags, the projected
-- profit, and a Disenchant button. Opens by itself when a queued item
-- arrives in your bags (bought, crafted or from the mail).
------------------------------------------------------------------------------

local BROWS, PROWS, LROWS, PROW = 4, 6, 6, 16

local function createPlanner()
  planner = CreateFrame("Frame", "ProfessionProfitDisenchantPlanner", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
  planner:Hide()
  planner:SetSize(320, 228 + (BROWS + PROWS + LROWS) * PROW)
  planner:SetFrameStrata("HIGH")
  planner:SetClampedToScreen(true)
  planner:EnableMouse(true)
  planner:SetMovable(true)
  planner:RegisterForDrag("LeftButton")
  planner:SetScript("OnDragStart", planner.StartMoving)
  planner:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local point, _, _, x, y = self:GetPoint(1)
    db.plannerPos = { point, x, y }
  end)
  if db.plannerPos then
    planner:SetPoint(db.plannerPos[1], UIParent, db.plannerPos[1], db.plannerPos[2], db.plannerPos[3])
  else
    planner:SetPoint("CENTER", 300, 0)
  end
  if planner.SetBackdrop then
    planner:SetBackdrop({
      bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
      edgeSize = 16, insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    planner:SetBackdropColor(0.07, 0.06, 0.05, 0.97)
    planner:SetBackdropBorderColor(0.6, 0.5, 0.3, 1)
  end
  local close = CreateFrame("Button", nil, planner, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", -2, -2)
  local title = planner:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  title:SetPoint("TOPLEFT", 14, -12)
  title:SetText("Disenchant Planner")

  local y = -34
  local function header(text)
    local fs = planner:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetPoint("TOPLEFT", 14, y)
    fs:SetText(text)
    y = y - 16
    return fs
  end
  local function makeRow(onRightClick, onEnter)
    local row = CreateFrame("Button", nil, planner)
    row:SetHeight(PROW)
    row:SetPoint("TOPLEFT", 12, y)
    row:SetPoint("RIGHT", -12, 0)
    y = y - PROW
    row:RegisterForClicks("RightButtonUp")
    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    row.left = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.left:SetPoint("LEFT", 2, 0)
    row.left:SetJustifyH("LEFT")
    row.left:SetWordWrap(false)
    row.right = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.right:SetPoint("RIGHT", -2, 0)
    row.left:SetPoint("RIGHT", row.right, "LEFT", -6, 0)
    row:SetScript("OnClick", function(self) if self.item then onRightClick(self.item) end end)
    row:SetScript("OnEnter", function(self) if self.item then onEnter(self, self.item) end end)
    row:SetScript("OnLeave", GameTooltip_Hide)
    return row
  end

  -- To buy
  header("To buy")
  planner.buyRows = {}
  for i = 1, BROWS do
    planner.buyRows[i] = makeRow(function(r) ns.removeFromBuyList(r) end, function(self, r)
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:SetItemByID(r.itemID)
      GameTooltip:AddLine(" ")
      GameTooltip:AddDoubleLine("Disenchanted, after AH cut", API.Money(r.value), 0.8, 0.8, 0.8, 1, 1, 1)
      if r.bought then GameTooltip:AddDoubleLine("Bought", r.bought, 0.8, 0.8, 0.8, 1, 1, 1) end
      GameTooltip:AddLine("Buy keeps buying its cheapest listing while that makes a profit.", 0.6, 0.6, 0.6, true)
      GameTooltip:AddLine("Right-click: take it off the list.", 0.6, 0.6, 0.6)
      GameTooltip:Show()
    end)
  end
  planner.buyMore = planner:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  planner.buyMore:SetPoint("TOPLEFT", 14, y - 2)
  y = y - 16
  planner.buyButton = CreateFrame("Button", nil, planner, "UIPanelButtonTemplate")
  planner.buyButton:SetSize(70, 22)
  planner.buyButton:SetPoint("TOPRIGHT", -12, y)
  planner.buyButton:SetText("Buy")
  planner.buyButton:SetScript("OnClick", function() ns.buyNext() end)
  planner.buyText = planner:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  planner.buyText:SetPoint("LEFT", planner, "TOPLEFT", 14, y - 11)
  planner.buyText:SetPoint("RIGHT", planner.buyButton, "LEFT", -8, 0)
  planner.buyText:SetJustifyH("LEFT")
  planner.buyText:SetWordWrap(false)
  y = y - 28
  -- The item being bought: its listings by price, cheapest first, updated
  -- with every purchase - how many Buy can still take and what comes next.
  planner.listHeader = header("Listings")
  planner.listRows = {}
  for i = 1, LROWS do
    local row = CreateFrame("Frame", nil, planner)
    row:SetHeight(PROW)
    row:SetPoint("TOPLEFT", 12, y)
    row:SetPoint("RIGHT", -12, 0)
    y = y - PROW
    local function cell(justify, width)
      local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      fs:SetJustifyH(justify)
      fs:SetWordWrap(false)
      if width then fs:SetWidth(width) end
      return fs
    end
    row.profit = cell("RIGHT", 90)
    row.profit:SetPoint("RIGHT", -2, 0)
    row.count = cell("RIGHT", 40)
    row.count:SetPoint("RIGHT", row.profit, "LEFT", -6, 0)
    row.price = cell("LEFT")
    row.price:SetPoint("LEFT", 2, 0)
    row.price:SetPoint("RIGHT", row.count, "LEFT", -6, 0)
    planner.listRows[i] = row
  end
  y = y - 6

  -- To disenchant
  header("To disenchant")
  planner.rows = {}
  for i = 1, PROWS do
    planner.rows[i] = makeRow(function(e) changeDisenchant(e, -1) end, function(self, e)
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:SetItemByID(e.itemID)
      GameTooltip:AddLine(" ")
      GameTooltip:AddDoubleLine("Cost", API.Money(e.cost) .. " ea", 0.8, 0.8, 0.8, 1, 1, 1)
      GameTooltip:AddDoubleLine("Projected profit", API.Money(e.projected) .. " ea", 0.8, 0.8, 0.8, 1, 1, 1)
      GameTooltip:AddLine(" ")
      addWhereLines(e)
      GameTooltip:AddLine("Right-click: remove one from the plan.", 0.6, 0.6, 0.6)
      GameTooltip:Show()
    end)
  end
  planner.more = planner:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  planner.more:SetPoint("TOPLEFT", 14, y - 2)

  planner.summary = planner:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  planner.summary:SetPoint("BOTTOMLEFT", 14, 44)
  planner.summary:SetPoint("RIGHT", -14, 0)
  planner.summary:SetJustifyH("LEFT")
  planner.summary:SetWordWrap(true)

  -- Where the (secure) Disenchant button goes.
  planner.slot = CreateFrame("Frame", nil, planner)
  planner.slot:SetSize(190, 22)
  planner.slot:SetPoint("BOTTOM", 0, 14)

  planner.update = function()
    -- To buy
    local list, current = ns.buyList()
    for i, row in ipairs(planner.buyRows) do
      local r = list[i]
      row.item = r
      if r then
        local mark = r == current and "|cffffd100>|r " or ""
        row.left:SetText(mark .. r.name .. (r.bought and (" |cff40ff40bought " .. r.bought .. "|r") or ""))
        row.right:SetText(GREY .. "up to|r " .. API.Money(r.maxPrice))
        row:Show()
      else
        row:Hide()
      end
    end
    planner.buyMore:SetText(#list > BROWS and ("+%d more"):format(#list - BROWS)
      or (#list == 0 and "Click items in the Disenchant Scan to add them." or ""))
    local text, canBuy = ns.buyStatus()
    planner.buyText:SetText(text)
    planner.buyButton:SetEnabled(canBuy)
    -- Listings of the item being bought: green while that price still
    -- profits; ">" marks the price Buy takes next.
    local ladder, full, r = ns.buyLadder()
    planner.listHeader:SetText(current and ("Listings: " .. current.name) or "Listings")
    for i, row in ipairs(planner.listRows) do
      local step = ladder and ladder[i]
      if i == LROWS and ladder and #ladder > LROWS then
        local rest = 0
        for j = LROWS, #ladder do rest = rest + ladder[j].count end
        row.price:SetText(GREY .. ("+%d more at %s and up"):format(rest, API.Money(ladder[LROWS].price)) .. "|r")
        row.count:SetText("")
        row.profit:SetText("")
        row:Show()
      elseif step then
        local each = math.floor(r.value - step.price + 0.5)
        local good = step.price <= r.maxPrice
        row.price:SetText((i == 1 and "|cffffd100>|r " or "   ") .. API.Money(step.price))
        row.count:SetText((good and "|cff40ff40" or GREY) .. "x" .. step.count .. ((not full and i == #ladder) and "+" or "") .. "|r")
        row.profit:SetText((good and "|cff40ff40+" or "|cffff6666") .. API.Money(each):gsub("|r", "|r" .. (good and "|cff40ff40" or "|cffff6666")) .. "|r")
        row:Show()
      elseif i == 1 then
        row.price:SetText(GREY .. (current and "Looking up listings..." or "Click an item in the Disenchant Scan to see its listings.") .. "|r")
        row.count:SetText("")
        row.profit:SetText("")
        row:Show()
      else
        row:Hide()
      end
    end

    -- To disenchant
    local queue = deQueue()
    for i, row in ipairs(planner.rows) do
      local e = queue[i]
      row.item = e
      if e then
        local here, others = whereText(e)
        row.left:SetText(here .. "  " .. (e.name or ("item " .. e.itemID)) .. (others and ("  " .. others) or ""))
        row.right:SetText(API.Money(e.projected) .. GREY .. " ea|r")
        row:Show()
      else
        row:Hide()
      end
    end
    planner.more:SetText(#queue > PROWS and ("+%d more"):format(#queue - PROWS) or (#queue == 0 and "Nothing planned." or ""))
    local projected, count = projectedLeft()
    local run = deRun()
    local summary = count > 0 and ("%d to go, projected %s"):format(count, API.Money(projected)) or "All done."
    if run.casts > 0 then
      summary = summary .. ("\nDone %d: %s %s(projected %s)|r"):format(run.casts, API.Money(run.realized), GREY,
        API.Money(run.projected))
    end
    if count > 0 and not isEnchanter() then
      summary = summary .. "\n" .. GREY .. "This character can't disenchant: mail them to your enchanter.|r"
    end
    planner.summary:SetText(summary)
  end
  follow(plannerButton, planner, function() placeAt(plannerButton, planner.slot, "CENTER", "CENTER", 0) end)
end

local function updatePlanner()
  if planner and planner:IsVisible() then planner.update() end
end
ns.updateDisenchantPlanner = updatePlanner

local function showPlanner()
  if InCombatLockdown() then return end -- its secure button can't be shown in combat
  if not planner then createPlanner() end
  planner:Show()
  planner.update()
end
ns.showDisenchantPlanner = showPlanner

local function togglePlanner()
  if planner and planner:IsShown() then planner:Hide() else showPlanner() end
end
ns.toggleDisenchantPlanner = togglePlanner

-- Queued items in your bags last time: a rise opens the planner.
local lastHeld
local function checkArrivals()
  local held, rose = {}, false
  for _, e in ipairs(deQueue()) do
    held[e.itemID] = ns.bagCount(e.itemID)
    if lastHeld and held[e.itemID] > (lastHeld[e.itemID] or 0) then rose = true end
  end
  lastHeld = held
  -- Only where they can be disenchanted: not while an alt crafts them.
  if rose and isEnchanter() and not (planner and planner:IsShown()) then showPlanner() end
end

------------------------------------------------------------------------------
-- Disenchants: a finished Disenchant cast, then a loot window of enchanting
-- materials. Clicks of the button say which item it was; otherwise it's the
-- queued item whose count in the bags went down.
------------------------------------------------------------------------------

local cast   -- { itemID, t, before }: a finished Disenchant waiting for its loot
local early  -- { mats, t }: loot that arrived before the cast finished
local before -- item counts in the bags when the cast started

-- Every item in your bags: { [itemID] = count }.
local function bagCounts()
  local counts = {}
  for bag = 0, lastBag() do
    for slot = 1, C_Container.GetContainerNumSlots(bag) do
      local info = C_Container.GetContainerItemInfo(bag, slot)
      if info and info.itemID then counts[info.itemID] = (counts[info.itemID] or 0) + (info.stackCount or 1) end
    end
  end
  return counts
end

local function lootMats()
  local n = GetNumLootItems and GetNumLootItems() or 0
  if n == 0 then return nil end
  local mats = {}
  for i = 1, n do
    local link = GetLootSlotLink(i)
    local id = link and tonumber(link:match("item:(%d+)"))
    if not API.IsEnchantingMat(id) then return nil end
    local _, _, quantity = GetLootSlotInfo(i)
    mats[id] = (mats[id] or 0) + ((type(quantity) == "number" and quantity > 0) and quantity or 1)
  end
  return mats
end

local function itemIcon(itemID)
  return itemID and ((C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(itemID)) or (GetItemIcon and GetItemIcon(itemID)))
end

local function finish(itemID, mats)
  local value, missing = API.MaterialsValue(mats)
  local net = value * (1 - API.AH_CUT)
  local entry = itemID and queuedEntry(itemID)
  local parts = {}
  for id, count in pairs(mats) do parts[#parts + 1] = count .. "x " .. (ns.itemName(id) or API.DE_MATS[id] or id) end
  log("disenchanted", itemID or "?", table.concat(parts, ", "), "worth", math.floor(value))
  local title = "Disenchanted " .. (itemID and ns.itemName(itemID) or "an item")
  if entry then
    local realized = math.floor(net - entry.cost + 0.5)
    local run = deRun()
    run.casts, run.realized, run.projected = run.casts + 1, run.realized + realized, run.projected + entry.projected
    if missing > 0 then run.unpriced = run.unpriced + 1 end
    changeDisenchant(entry, -1)
    if not db.deToastOff then
      ns.showToast("de:" .. itemID, title, itemIcon(itemID), realized,
        { incomplete = missing > 0, compare = entry.projected, compareLabel = "projected " })
    end
  elseif not db.deToastOff then
    -- Not queued: profit when one of your characters crafts it (materials
    -- after the cut, minus its craft cost), else just what the materials are worth.
    local recipe = itemID and ns.knownRecipeFor(itemID)
    if recipe and recipe.missing == 0 then
      local made = recipe.made or 1
      local realized = math.floor(net - recipe.cost / made + 0.5)
      local projected = recipe.shuffleProfit and recipe.shuffleProfit / made
      ns.showToast("de:" .. itemID, title, itemIcon(itemID), realized, {
        incomplete = missing > 0, compare = projected, compareLabel = "projected ",
        detail = not projected and (GREY .. "profit after its craft cost|r") or nil,
      })
    else
      ns.showToast("de:" .. (itemID or "?"), title, itemIcon(itemID) or itemIcon(next(mats)), math.floor(net + 0.5),
        { incomplete = missing > 0, detail = GREY .. "materials worth, after AH cut (craft cost unknown)|r" })
    end
  end
end

-- Which queued item went down since the cast started (bags update a moment
-- after the loot).
local function finishFromBags(snapshot, mats)
  C_Timer.After(0.6, function()
    local now, itemID = bagCounts(), nil
    for id, n in pairs(snapshot or {}) do
      if (now[id] or 0) < n and not API.IsEnchantingMat(id) then
        itemID = id
        if queuedEntry(id) then break end -- a queued one wins
      end
    end
    finish(itemID, mats)
  end)
end

local function onLoot()
  local mats = lootMats()
  if not mats then return end
  if cast and GetTime() - cast.t <= LOOT_WINDOW then
    local c = cast
    cast = nil
    if c.itemID then finish(c.itemID, mats) else finishFromBags(c.before, mats) end
  else
    early = { mats = mats, t = GetTime() }
  end
end

local events = CreateFrame("Frame")
for _, event in ipairs({ "UNIT_SPELLCAST_START", "UNIT_SPELLCAST_SUCCEEDED", "UNIT_SPELLCAST_FAILED",
  "UNIT_SPELLCAST_INTERRUPTED", "LOOT_READY", "LOOT_OPENED", "BAG_UPDATE_DELAYED", "PLAYER_REGEN_ENABLED",
  "SKILL_LINES_CHANGED", "PLAYER_ENTERING_WORLD" }) do
  pcall(events.RegisterEvent, events, event)
end
events:SetScript("OnEvent", function(_, event, unit, ...)
  if not db then return end
  if event == "LOOT_READY" or event == "LOOT_OPENED" then
    onLoot()
  elseif event == "PLAYER_ENTERING_WORLD" then
    recordHeld()
  elseif event == "BAG_UPDATE_DELAYED" or event == "PLAYER_REGEN_ENABLED" or event == "SKILL_LINES_CHANGED" then
    if event == "BAG_UPDATE_DELAYED" then
      recordHeld()
      checkArrivals()
    end
    updateDisenchantButton()
  elseif unit == "player" and select(2, ...) == DISENCHANT then
    if event == "UNIT_SPELLCAST_START" then
      before = bagCounts()
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
      local fromButton = target and GetTime() - target.t < 5 and target.itemID or nil
      target = nil
      cast = { itemID = fromButton, t = GetTime(), before = before or bagCounts() }
      before = nil
      -- The loot window can come first: use it now.
      if early and GetTime() - early.t <= 2 then
        local mats = early.mats
        early = nil
        local c = cast
        cast = nil
        if c.itemID then finish(c.itemID, mats) else finishFromBags(c.before, mats) end
      end
    else
      target, before = nil, nil
    end
  end
end)
