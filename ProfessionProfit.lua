-- ProfessionProfit: a "Profit" tab under the profession window listing every
-- learned recipe with reagent cost, sale price and profit. While the auction
-- house is open it searches the AH for all reagents and crafted items.
--
-- Prices come from Auctionator through LibCraftProfit-1.0 (shared with
-- RecipeProfit), and Scan AH searches through Auctionator too, so the
-- numbers always match Auctionator's.
--
-- Two profession UIs are supported:
--   modern:  ProfessionsFrame + C_TradeSkillUI (WoW Forever: one window, K)
--   classic: TradeSkillFrame + GetTradeSkillInfo() etc.
-- Diagnostics go to DevLog when it's installed (/devlog to view).

local ADDON = ...
local ROW_HEIGHT = 18

local API = LibStub("LibCraftProfit-1.0")
local db

local RED, GREY, GREEN = "|cffff6666", "|cffa0a0a0", "|cff33ff33"

local DIFFICULTY_COLORS = {
  optimal = { 1, 0.5, 0.25 }, medium = { 1, 1, 0 }, easy = { 0.25, 0.75, 0.25 }, trivial = { 0.55, 0.55, 0.55 },
}

local function msg(text)
  DEFAULT_CHAT_FRAME:AddMessage("|cffffd100ProfessionProfit:|r " .. text)
end

local function log(...)
  if DevLog then DevLog.Log(ADDON, ...) end
end

local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
local RequestLoadItemDataByID = (C_Item and C_Item.RequestLoadItemDataByID) or function() end

local function idFromLink(link)
  return link and tonumber(link:match("item:(%d+)"))
end

local function nameFromLink(link)
  return link and link:match("%[(.-)%]")
end

local function ahOpen()
  return (AuctionHouseFrame and AuctionHouseFrame:IsShown()) or (AuctionFrame and AuctionFrame:IsShown())
end

------------------------------------------------------------------------------
-- Reading learned recipes
------------------------------------------------------------------------------

-- Modern when the client ships the retail Professions UI (loaded on demand
-- the first time you press K), even before that window exists.
local modernCached
local function isModern()
  if modernCached ~= nil then return modernCached end
  if not (C_TradeSkillUI and C_TradeSkillUI.GetAllRecipeIDs) then
    modernCached = false
    return false
  end
  if ProfessionsFrame then
    modernCached = true
    return true
  end
  local getInfo = (C_AddOns and C_AddOns.GetAddOnInfo) or GetAddOnInfo
  local ok, name, _, _, loadable, reason = pcall(getInfo, "Blizzard_Professions")
  modernCached = ok and name ~= nil and reason ~= "MISSING"
  return modernCached
end

-- Blizzard's profession window (nil until it exists).
local function baseHost()
  if isModern() then return ProfessionsFrame end
  return TradeSkillFrame
end

-- Skillet replaces Blizzard's window with its own SkilletFrame.
local function skilletShown()
  return SkilletFrame ~= nil and SkilletFrame:IsShown()
end

-- The window our tab and panel attach to right now.
local function hostFrame()
  if skilletShown() then return SkilletFrame end
  return baseHost()
end

local function hostShown()
  if skilletShown() then return true end
  local host = baseHost()
  return host and host:IsShown()
end

-- name, rank, maxRank of the open profession
local lastProfession -- { name, rank, max }: the overview page reports no profession

local function professionInfo(strict)
  if isModern() then
    for _, getter in ipairs({ "GetChildProfessionInfo", "GetBaseProfessionInfo" }) do
      local fn = C_TradeSkillUI[getter]
      local ok, info = pcall(fn or error)
      if ok and type(info) == "table" and info.professionName and info.professionName ~= "" then
        lastProfession = { info.professionName, info.skillLevel, info.maxSkillLevel }
        return info.professionName, info.skillLevel, info.maxSkillLevel
      end
    end
    if lastProfession and not strict then return unpack(lastProfession) end
    return nil
  end
  local name, rank, maxRank = GetTradeSkillLine and GetTradeSkillLine()
  if name and name ~= "" and name ~= "UNKNOWN" then return name, rank, maxRank end
end

local function professionName()
  return (professionInfo())
end

-- Classic only: expand collapsed categories so every learned recipe is listed.
local function expandAll()
  if not isModern() and ExpandTradeSkillSubClass then pcall(ExpandTradeSkillSubClass, 0) end
end

local itemNamePending = false
local function itemName(itemID)
  local name = itemID and GetItemInfo(itemID)
  if not name and itemID then
    RequestLoadItemDataByID(itemID)
    itemNamePending = true
  end
  return name
end

-- Bind on pickup: can't be sold on the AH. Unknown until the item's data
-- has loaded (the table refreshes when it arrives).
local BIND_ON_PICKUP = (Enum and Enum.ItemBind and Enum.ItemBind.OnAcquire) or 1
local function isBoP(itemID)
  if not itemID then return false end
  local name, _, _, _, _, _, _, _, _, _, _, _, _, bindType = GetItemInfo(itemID)
  if not name then
    RequestLoadItemDataByID(itemID)
    itemNamePending = true
    return false
  end
  return bindType == BIND_ON_PICKUP
end

local MODERN_DIFFICULTY = { [0] = "optimal", [1] = "medium", [2] = "easy", [3] = "trivial" }

local function readModernRecipes()
  local list = {}
  local ok, ids = pcall(C_TradeSkillUI.GetAllRecipeIDs)
  if not ok or type(ids) ~= "table" then
    log("GetAllRecipeIDs failed", ids)
    return list
  end
  local basicType = Enum and Enum.CraftingReagentType and Enum.CraftingReagentType.Basic
  for _, recipeID in ipairs(ids) do
    local info = C_TradeSkillUI.GetRecipeInfo(recipeID)
    if info and info.learned and not info.isDummyRecipe and not info.isGatheringRecipe and not info.isRecraft then
      local schematic = C_TradeSkillUI.GetRecipeSchematic(recipeID, false)
      local recipe = {
        key = recipeID, recipeID = recipeID, name = info.name or ("recipe " .. recipeID),
        difficulty = MODERN_DIFFICULTY[info.relativeDifficulty] or "trivial",
        numAvailable = info.numAvailable or 0, reagents = {},
        made = math.max(schematic and schematic.quantityMin or 1, 1),
        isEnchant = info.isEnchantingRecipe and true or false,
      }
      local outputID = schematic and schematic.outputItemID
      if not outputID and C_TradeSkillUI.GetRecipeOutputItemData then
        local okOut, out = pcall(C_TradeSkillUI.GetRecipeOutputItemData, recipeID)
        if okOut and out then
          outputID = out.itemID or idFromLink(out.hyperlink)
          recipe.link = out.hyperlink
        end
      end
      if outputID then
        recipe.isEnchant = false
        recipe.productID = outputID
        recipe.productName = itemName(outputID) or info.name
        recipe.link = recipe.link or ("item:" .. outputID)
      end
      for _, slot in ipairs(schematic and schematic.reagentSlotSchematics or {}) do
        local isBasic = basicType == nil or slot.reagentType == basicType
        local first = slot.reagents and slot.reagents[1]
        if isBasic and first and first.itemID then
          recipe.reagents[#recipe.reagents + 1] = {
            id = first.itemID, name = itemName(first.itemID), count = slot.quantityRequired or 1,
          }
        end
      end
      list[#list + 1] = recipe
    end
  end
  return list
end

local function readClassicRecipes()
  local list = {}
  if not GetNumTradeSkills then return list end
  for i = 1, GetNumTradeSkills() do
    local name, skillType, numAvailable = GetTradeSkillInfo(i)
    if name and skillType ~= "header" and skillType ~= "subheader" then
      local link = GetTradeSkillItemLink(i)
      local made = GetTradeSkillNumMade(i) or 1
      local recipe = {
        key = name, index = i, name = name, difficulty = skillType, numAvailable = numAvailable or 0,
        link = link, made = math.max(made, 1), reagents = {},
        isEnchant = link and link:find("enchant:", 1, true) ~= nil,
      }
      if not recipe.isEnchant then
        recipe.productID = idFromLink(link)
        recipe.productName = nameFromLink(link) or name
      end
      for r = 1, GetTradeSkillNumReagents(i) do
        local rName, _, count = GetTradeSkillReagentInfo(i, r)
        local rLink = GetTradeSkillReagentItemLink(i, r)
        recipe.reagents[#recipe.reagents + 1] = {
          name = rName or nameFromLink(rLink), id = idFromLink(rLink), count = count or 1,
        }
      end
      list[#list + 1] = recipe
    end
  end
  return list
end

local function readRecipes()
  if isModern() then return readModernRecipes() end
  return readClassicRecipes()
end

-- Recipe currently shown in the Professions window's details pane.
local function selectedModernRecipeID()
  local page = ProfessionsFrame and ProfessionsFrame.CraftingPage
  local form = page and page.SchematicForm
  if form and form.GetRecipeInfo then
    local ok, info = pcall(form.GetRecipeInfo, form)
    if ok and type(info) == "table" then return info.recipeID end
  end
end

-- Switch the Professions window to its recipe list (Forever can be showing
-- the profession overview page instead).
local function showModernRecipesPage()
  local frame = ProfessionsFrame
  if frame.SetTab and frame.recipesTabID then
    local current = frame.GetTab and frame:GetTab()
    if current ~= frame.recipesTabID then
      local ok, err = pcall(frame.SetTab, frame, frame.recipesTabID)
      log("SetTab(recipes)", ok and "ok" or err)
    end
  end
end

local function selectInRecipeList(recipeID)
  local list = ProfessionsFrame.CraftingPage and ProfessionsFrame.CraftingPage.RecipeList
  local info = C_TradeSkillUI.GetRecipeInfo(recipeID)
  if list and list.SelectRecipe and info then
    local ok, err = pcall(list.SelectRecipe, list, info, true)
    return ok, ok and "RecipeList:SelectRecipe" or tostring(err)
  end
  return false, "no RecipeList:SelectRecipe"
end

-- The recipe search box and "have materials"-style filters can hide the
-- recipe from the list, which makes selecting it silently fail.
local function clearRecipeFilters()
  local list = ProfessionsFrame.CraftingPage and ProfessionsFrame.CraftingPage.RecipeList
  local box = list and list.SearchBox
  if box and box.GetText and box:GetText() ~= "" then
    box:SetText("")
    log("cleared recipe search box")
  end
  if C_TradeSkillUI.SetRecipeItemNameFilter then pcall(C_TradeSkillUI.SetRecipeItemNameFilter, "") end
  if Professions and Professions.SetDefaultFilters then
    local ok, err = pcall(Professions.SetDefaultFilters)
    log("Professions.SetDefaultFilters", ok and "ok" or err)
  end
end

-- Try progressively stronger ways to open the recipe, checking each one.
local OPEN_STEPS = {
  function(id) return selectInRecipeList(id) end,
  function(id)
    clearRecipeFilters()
    return true, "cleared filters (retry next step)"
  end,
  function(id) return selectInRecipeList(id) end,
  function(id)
    local ok, err = pcall(C_TradeSkillUI.OpenRecipe, id)
    return ok, ok and "C_TradeSkillUI.OpenRecipe" or tostring(err)
  end,
}

local function openModernRecipe(recipe, step)
  step = step or 1
  local id = recipe.recipeID
  if step == 1 then
    log("open recipe", recipe.name, id, "currently selected:", selectedModernRecipeID() or "none")
    showModernRecipesPage()
  end
  local ok, how = OPEN_STEPS[step](id)
  log("  step", step, how, ok and "" or "(failed)")
  -- Without a way to read the selection, never escalate to clearing filters.
  local page = ProfessionsFrame.CraftingPage
  if not (page and page.SchematicForm and page.SchematicForm.GetRecipeInfo) then
    if not ok then pcall(C_TradeSkillUI.OpenRecipe, id) end
    log("  can't verify selection; stopping after step", step)
    return
  end
  -- The list rebuilds asynchronously, so check a moment later.
  C_Timer.After(step == 2 and 0.3 or 0.15, function()
    if selectedModernRecipeID() == id then
      log("  opened", recipe.name, "via step", step)
    elseif step < #OPEN_STEPS then
      openModernRecipe(recipe, step + 1)
    else
      log("  could not open", recipe.name, "- selected is", selectedModernRecipeID() or "none")
      msg(("Couldn't select %s in the recipe list."):format(recipe.name))
    end
  end)
end

local function openRecipeInUI(recipe)
  if skilletShown() and Skillet and Skillet.SetSelectedSkill and recipe.recipeID then
    local index = Skillet.data and Skillet.data.skillIndexLookup and Skillet.data.skillIndexLookup[recipe.recipeID]
    log("open recipe in Skillet", recipe.name, recipe.recipeID, "index", index or "none")
    if index then
      pcall(Skillet.SetSelectedSkill, Skillet, index)
      pcall(Skillet.UpdateTradeSkillWindow, Skillet)
    else
      msg(("%s isn't in Skillet's recipe list (check Skillet's filters)."):format(recipe.name))
    end
    return
  end
  if isModern() then
    openModernRecipe(recipe)
    return
  end
  -- Classic: indices shift when categories collapse, so look it up by name.
  for i = 1, GetNumTradeSkills() do
    local name, skillType = GetTradeSkillInfo(i)
    if name == recipe.name and skillType ~= "header" and skillType ~= "subheader" then
      if TradeSkillFrame_SetSelection then pcall(TradeSkillFrame_SetSelection, i) end
      if TradeSkillFrame_Update then pcall(TradeSkillFrame_Update) end
      break
    end
  end
end

local function closeHost()
  if skilletShown() then
    pcall(HideUIPanel, SkilletFrame)
    if SkilletFrame:IsShown() then SkilletFrame:Hide() end
  end
  if isModern() and C_TradeSkillUI.CloseTradeSkill then
    pcall(C_TradeSkillUI.CloseTradeSkill)
  end
  local host = hostFrame()
  if host and host:IsShown() then HideUIPanel(host) end
end

-- Everything useful for figuring out the profession UI on a new client.
local function logEnvironment(reason)
  log("---- environment (" .. reason .. ") ----")
  log("ProfessionsFrame:", ProfessionsFrame or "nil")
  log("TradeSkillFrame:", TradeSkillFrame or "nil")
  log("CraftFrame:", CraftFrame or "nil")
  log("mode:", isModern() and "modern" or "classic", "host:", hostFrame() or "nil")
  log("C_TradeSkillUI:", C_TradeSkillUI and "present" or "nil",
    "GetAllRecipeIDs:", C_TradeSkillUI and C_TradeSkillUI.GetAllRecipeIDs and "yes" or "no",
    "GetNumTradeSkills:", GetNumTradeSkills and "yes" or "no")
  if C_TradeSkillUI then
    for _, getter in ipairs({ "GetBaseProfessionInfo", "GetChildProfessionInfo" }) do
      local fn = C_TradeSkillUI[getter]
      if fn then
        local ok, info = pcall(fn)
        log(getter, ok and info or ("error: " .. tostring(info)))
      end
    end
    if C_TradeSkillUI.GetAllRecipeIDs then
      local ok, ids = pcall(C_TradeSkillUI.GetAllRecipeIDs)
      log("GetAllRecipeIDs count:", ok and type(ids) == "table" and #ids or tostring(ids))
      if ok and type(ids) == "table" and ids[1] then
        local learnedShown = 0
        for _, id in ipairs(ids) do
          local info = C_TradeSkillUI.GetRecipeInfo(id)
          if info and info.learned and learnedShown < 2 then
            learnedShown = learnedShown + 1
            log("sample recipe info", id, info)
            local okS, schematic = pcall(C_TradeSkillUI.GetRecipeSchematic, id, false)
            log("sample schematic", okS and schematic or ("error: " .. tostring(schematic)))
          end
        end
      end
    end
  end
  if GetTradeSkillLine then log("GetTradeSkillLine:", GetTradeSkillLine()) end
  if GetNumTradeSkills then log("GetNumTradeSkills:", GetNumTradeSkills()) end
  local recipes = readRecipes()
  log("readRecipes ->", #recipes, "recipes; profession:", professionInfo())
  if recipes[1] then log("first parsed recipe:", recipes[1]) end
end

------------------------------------------------------------------------------
-- Stock: crafted items you own (bags + bank + your active auctions)
------------------------------------------------------------------------------

local GetItemCount = (C_Item and C_Item.GetItemCount) or GetItemCount

local function charKey()
  return (UnitName("player") or "?") .. "-" .. (GetRealmName and GetRealmName() or "?")
end

-- Active auctions are only visible while the AH is open, so keep the last
-- known counts per character.
local function ownedAuctions()
  db.ownedAuctions = db.ownedAuctions or {}
  return db.ownedAuctions[charKey()]
end

local function recordOwnedAuctions()
  if not (C_AuctionHouse and C_AuctionHouse.GetNumOwnedAuctions) then return end
  local counts = {}
  local soldStatus = Enum and Enum.AuctionStatus and Enum.AuctionStatus.Sold or 1
  for i = 1, C_AuctionHouse.GetNumOwnedAuctions() do
    local info = C_AuctionHouse.GetOwnedAuctionInfo(i)
    if info and info.itemKey and info.status ~= soldStatus then
      local id = info.itemKey.itemID
      counts[id] = (counts[id] or 0) + (info.quantity or 1)
    end
  end
  db.ownedAuctions = db.ownedAuctions or {}
  db.ownedAuctions[charKey()] = { counts = counts, time = time() }
  log("owned auctions recorded:", C_AuctionHouse.GetNumOwnedAuctions(), "auctions")
end

-- total, bags, bank, onAH
local function stockOf(itemID)
  if not itemID or not GetItemCount then return 0, 0, 0, 0 end
  local bags = GetItemCount(itemID, false) or 0
  local all = GetItemCount(itemID, true) or bags
  local owned = ownedAuctions()
  local onAH = owned and owned.counts[itemID] or 0
  return all + onAH, bags, all - bags, onAH
end

------------------------------------------------------------------------------
-- Pricing (LibCraftProfit: Auctionator's prices, same rules as its "To Craft")
------------------------------------------------------------------------------

local function evaluate(recipe)
  API.Evaluate(recipe)
  if recipe.productID then
    recipe.stock, recipe.stockBags, recipe.stockBank, recipe.stockAH = stockOf(recipe.productID)
  else
    recipe.stock = nil
  end
end

------------------------------------------------------------------------------
-- AH scan of all learned recipes
------------------------------------------------------------------------------

local panel, refresh
local tabs = {}

-- Each profession's recipes are remembered (per character) whenever its
-- window is open, so the automatic scan can run when only the AH is open:
-- the game only lists a profession's recipes while that profession is open.
local rememberOpenProfession, rememberSoon

local function recipeCache()
  db.recipeCache = db.recipeCache or {}
  local key = charKey()
  db.recipeCache[key] = db.recipeCache[key] or {}
  return db.recipeCache[key]
end

local function cacheRecipes(prof, recipes)
  if not prof or #recipes == 0 then return end
  local entries = {}
  for _, recipe in ipairs(recipes) do
    local entry = { p = recipe.productID, pn = recipe.productName, r = {} }
    for _, reagent in ipairs(recipe.reagents) do
      entry.r[#entry.r + 1] = { id = reagent.id, n = reagent.name }
    end
    entries[#entries + 1] = entry
  end
  recipeCache()[prof] = { time = time(), recipes = entries }
end

-- Remember the open profession's recipes (only when the game reports which
-- profession is open, so the overview page never overwrites a cache).
rememberOpenProfession = function()
  if not hostShown() then return end
  local prof = professionInfo(true)
  if not prof then return end
  local recipes = readRecipes()
  if #recipes > 0 then
    cacheRecipes(prof, recipes)
    log("remembered", #recipes, "recipes for", prof)
  end
end

-- Every crafted item and reagent to search for: { id, name }.
local function scanItems(recipes)
  local items = {}
  for _, recipe in ipairs(recipes) do
    if recipe.productID then items[#items + 1] = { id = recipe.productID, name = recipe.productName } end
    for _, reagent in ipairs(recipe.reagents) do
      if reagent.id then items[#items + 1] = { id = reagent.id, name = reagent.name } end
    end
  end
  return items
end

local function setStatus(text)
  if panel then panel.status:SetText(text or "") end
end


-- Last completed scan per character + profession, saved across sessions.
local function scanKey(prof)
  return (UnitName("player") or "?") .. "-" .. (GetRealmName and GetRealmName() or "?") .. ":" .. prof
end

local function lastScanTime(prof)
  db.lastScan = db.lastScan or {}
  return db.lastScan[scanKey(prof)]
end

local function markScanned(prof)
  db.lastScan = db.lastScan or {}
  db.lastScan[scanKey(prof)] = time()
end

local function updateScanButton()
  if not panel then return end
  panel.scanButton:SetText("Scan AH")
  local prof = professionName()
  local last = prof and lastScanTime(prof)
  local text
  if last then
    local mins = math.floor((time() - last) / 60)
    text = "Last scan: " .. (mins < 1 and "just now" or mins < 120 and (mins .. " min ago") or date("%b %d %H:%M", last))
  else
    text = "Not scanned yet."
  end
  if not ahOpen() then text = text .. "  Open the auction house to scan." end
  setStatus(GREY .. text .. "|r")
end

-- Scan AH button: search the AH (through Auctionator) for every reagent and
-- crafted item of the open profession. The table refreshes as results arrive.
local function startScan(retries)
  if not ahOpen() then
    msg("Open the auction house first.")
    return
  end
  local prof = professionName() or "?"
  expandAll()
  local recipes = readRecipes()

  -- Item names load asynchronously and searches go by name; wait briefly.
  local unnamed = 0
  for _, recipe in ipairs(recipes) do
    for _, reagent in ipairs(recipe.reagents) do
      if not reagent.name then unnamed = unnamed + 1 end
    end
  end
  if unnamed > 0 and (retries or 0) < 6 then
    setStatus(("Loading item info (%d)..."):format(unnamed))
    C_Timer.After(0.5, function() startScan((retries or 0) + 1) end)
    return
  end
  cacheRecipes(prof, recipes)
  local count, reason = API.Search(scanItems(recipes), { force = true, caller = ADDON })
  log("scan", prof, count or 0, reason or "")
  if not count then
    msg(reason)
  elseif count == 0 then
    msg("Nothing to search: every reagent is sold by a vendor.")
  else
    markScanned(prof)
    msg(("Searching %d item(s) in Auctionator's Shopping tab - the table updates as results come in."):format(count))
  end
  updateScanButton()
end


local rememberPending = false
rememberSoon = function()
  if rememberPending then return end
  rememberPending = true
  C_Timer.After(1, function()
    rememberPending = false
    rememberOpenProfession()
  end)
end


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

------------------------------------------------------------------------------
-- Craft queue (our own, saved per character)
------------------------------------------------------------------------------

local updateQueueWindow, showQueueWindow -- defined with the queue window
local toggleTargetsWindow -- Restocking window; (true) only refreshes it

local function craftQueue()
  db.craftQueue = db.craftQueue or {}
  local key = charKey()
  db.craftQueue[key] = db.craftQueue[key] or {}
  return db.craftQueue[key]
end

local computeQueue -- defined below

-- Crafts of a recipe in the queue (including reagent crafts).
local function queuedCount(recipeID)
  local total = 0
  for _, entry in ipairs(computeQueue()) do
    if entry.recipeID == recipeID then total = total + entry.count end
  end
  return total
end

-- Restock targets: how many of an item you want to own - the single source
-- of truth for Top up. Set in the + view's "Restock to" box, or remembered
-- when you queue more than one there and the item has none; edited and
-- cleared in the Restocking window.
-- db.queueTargets[recipeID] = { n = target, name = recipe name, item = itemID }
-- (older saves are just the number).
local function queueTarget(recipe)
  local t = recipe.recipeID and db.queueTargets and db.queueTargets[recipe.recipeID]
  return type(t) == "table" and t.n or t
end

-- n < 1 or nil removes the target.
local function setQueueTarget(recipe, n)
  if not recipe.recipeID or not recipe.productID then return end
  db.queueTargets = db.queueTargets or {}
  if not n or n < 1 then
    db.queueTargets[recipe.recipeID] = nil
  else
    db.queueTargets[recipe.recipeID] = { n = n, name = recipe.name, item = recipe.productID }
  end
end

-- Number of crafts to queue for a recipe. Top up off: Qty crafts, targets
-- ignored. Top up on: enough to own its restock target (or Qty when it has
-- none), counting your stock (bags, bank, your auctions) and what's queued.
local function craftsToQueue(recipe)
  local qty = db.queueQty or 1
  if not db.queueTopUp then return qty end
  if not recipe.productID then return 0 end
  local need = (queueTarget(recipe) or qty) - (recipe.stock or 0) - queuedCount(recipe.recipeID) * recipe.made
  if need <= 0 then return 0 end
  return math.ceil(need / recipe.made)
end

local function bagCount(itemID)
  return (GetItemCount and GetItemCount(itemID, false)) or 0
end

-- Add crafts of a recipe (merged into an existing entry for that recipe).
-- Recipe IDs of the open profession (the game always lists these, even on
-- the overview page where it doesn't say which profession is open).
local openIDs, openIDsTime
local function openRecipeIDs()
  if not hostShown() or not isModern() then return {} end
  if openIDs and GetTime() - openIDsTime < 1 then return openIDs end
  local set = {}
  local ok, ids = pcall(C_TradeSkillUI.GetAllRecipeIDs)
  if ok and type(ids) == "table" then
    for _, id in ipairs(ids) do set[id] = true end
  end
  openIDs, openIDsTime = set, GetTime()
  return set
end

local function forgetOpenRecipeIDs()
  openIDs = nil
end

-- Profession name for a recipe, from the game if it can say, else the open
-- profession when the recipe belongs to it.
local function professionForRecipe(recipeID)
  if recipeID and C_TradeSkillUI and C_TradeSkillUI.GetTradeSkillLineForRecipe then
    local ok, _, name, _, parentName = pcall(C_TradeSkillUI.GetTradeSkillLineForRecipe, recipeID)
    if ok and type(parentName or name) == "string" and (parentName or name) ~= "" then return parentName or name end
  end
  if recipeID and openRecipeIDs()[recipeID] then return professionInfo(true) or professionName() end
end

-- Is this queue entry a recipe of the open profession? Fills in a missing
-- profession name while at it.
local function inOpenProfession(entry)
  if not openRecipeIDs()[entry.recipeID] then return false end
  if not entry.prof then entry.prof = professionForRecipe(entry.recipeID) end
  return true
end

local function recipeDef(recipe)
  local reagents = {}
  for _, reagent in ipairs(recipe.reagents) do
    reagents[#reagents + 1] = { id = reagent.id, n = reagent.name, c = reagent.count }
  end
  return {
    recipeID = recipe.recipeID, name = recipe.name,
    prof = professionForRecipe(recipe.recipeID) or professionInfo(true) or professionName(),
    productID = recipe.productID, made = recipe.made, reagents = reagents,
  }
end

-- Add crafts of a recipe (merged into an existing entry for that recipe).
-- subs: recipes of craftable reagents to craft instead of buy. Their crafts
-- aren't stored - computeQueue() works them out from what's in your bags.
local function queueAdd(recipe, crafts, subs)
  if not recipe.recipeID then return false, "only supported with the Professions (K) window" end
  if not crafts or crafts <= 0 then return false, "nothing to queue" end
  local queue = craftQueue()
  local entry
  for _, e in ipairs(queue) do
    if e.recipeID == recipe.recipeID then entry = e break end
  end
  if entry then
    entry.count = entry.count + crafts
  else
    entry = recipeDef(recipe)
    entry.count = crafts
    queue[#queue + 1] = entry
  end
  entry.subs = entry.subs or {}
  for _, sub in ipairs(subs or {}) do
    if sub.recipeID and sub.productID then entry.subs[sub.recipeID] = recipeDef(sub) end
  end
  return true
end

-- The queue as it should be crafted: reagent crafts first (live: needed by
-- the queued items, minus what's in your bags), then the queued items.
local MAX_DEPTH = 6

-- Work out reagent crafts for a set of queued items, through any depth
-- (Light Leather -> Medium Leather -> Heavy Leather -> item).
-- mains: { name, reagents, count, subs = { [recipeID] = def } } where subs
-- are the reagents chosen to be crafted. A reagent chosen anywhere in the
-- queue is crafted for every deeper level that uses it.
-- Returns derived entries (deepest first) and a map by recipeID.
local function planDerived(mains)
  local chosen = {} -- productID -> def
  for _, main in ipairs(mains) do
    for _, def in pairs(main.subs or {}) do
      if def.productID then chosen[def.productID] = def end
    end
  end

  local need, usedBy, depth = {}, {}, {}
  local function addUse(productID, amount, who)
    need[productID] = (need[productID] or 0) + amount
    local list = usedBy[productID]
    if not list then list = {} usedBy[productID] = list end
    if who and not list[who] then
      list[who] = true
      list[#list + 1] = who
    end
  end

  -- Level 1: what the queued items use directly (only reagents that item
  -- chose to craft).
  for _, main in ipairs(mains) do
    local mine = {}
    for _, def in pairs(main.subs or {}) do if def.productID then mine[def.productID] = true end end
    for _, reagent in ipairs(main.reagents) do
      if reagent.id and mine[reagent.id] then
        addUse(reagent.id, reagent.c * main.count, main.name)
        depth[reagent.id] = 1
      end
    end
  end
  -- Deeper levels: a chosen reagent of a chosen reagent, and so on.
  for _ = 1, MAX_DEPTH do
    local changed = false
    local snapshot = {}
    for productID, d in pairs(depth) do snapshot[productID] = d end
    for productID, d in pairs(snapshot) do
      for _, reagent in ipairs(chosen[productID].reagents) do
        if reagent.id and chosen[reagent.id] and d < MAX_DEPTH and (depth[reagent.id] or 0) < d + 1 then
          depth[reagent.id] = d + 1
          changed = true
        end
      end
    end
    if not changed then break end
  end

  local order = {}
  for productID in pairs(depth) do order[#order + 1] = productID end
  table.sort(order, function(a, b) return depth[a] < depth[b] end)

  -- Shallow to deep: each level's crafts add to the next level's need.
  local derived, list = {}, {}
  for _, productID in ipairs(order) do
    local def = chosen[productID]
    local d = {
      recipeID = def.recipeID, name = def.name, prof = def.prof, productID = productID, made = def.made or 1,
      reagents = def.reagents, auto = true, depth = depth[productID],
      need = need[productID] or 0, have = bagCount(productID), usedBy = usedBy[productID] or {},
    }
    d.count = math.max(0, math.ceil((d.need - d.have) / d.made))
    for _, reagent in ipairs(def.reagents) do
      if reagent.id and chosen[reagent.id] and depth[reagent.id] and depth[reagent.id] > d.depth then
        addUse(reagent.id, reagent.c * d.count, def.name)
      end
    end
    derived[def.recipeID] = d
    list[#list + 1] = d
  end
  -- Craft deepest first.
  table.sort(list, function(a, b) return a.depth > b.depth end)
  return list, derived
end

-- The queue as it should be crafted: reagent crafts first, deepest level
-- first (live: needed by the queue, minus what's in your bags), then the
-- queued items.
computeQueue = function()
  local queue = craftQueue()
  -- "Craft reagents" unticked in the queue window: buy every reagent.
  if db.skipReagentCrafts then
    local list = {}
    for _, main in ipairs(queue) do list[#list + 1] = main end
    return list, {}
  end
  local plan, derived = planDerived(queue)
  local list = {}
  for _, d in ipairs(plan) do
    if d.count > 0 then list[#list + 1] = d end
  end
  for _, main in ipairs(queue) do list[#list + 1] = main end
  return list, derived
end

-- Stop crafting a reagent for every queued item (buy it instead).
local function dropSub(subID)
  for _, main in ipairs(craftQueue()) do
    if main.subs then main.subs[subID] = nil end
  end
end

-- Craftable reagents of a recipe (made by another learned recipe of this
-- profession). Crafting one is "profitable" when its reagent cost per unit
-- is below what it costs to buy (vendor or AH - no AH cut, nothing is sold).
-- Reagents you can't buy at all (not on the AH) are always included.
-- Craftable reagents of a recipe (made by another learned recipe of this
-- profession), with the craft-or-buy decision: craft when its reagent cost
-- per unit is below what it costs to buy (vendor or AH - no AH cut, nothing
-- is sold), or when it can't be bought at all (not on the AH).
-- How many to craft is worked out later from your bags (computeQueue).
local function subReagents(recipe, crafts, byProduct)
  local list = {}
  byProduct = byProduct or (panel and panel.byProduct) or {}
  crafts = math.max(crafts or 1, 1)
  for _, reagent in ipairs(recipe.reagents) do
    local sub = reagent.id and byProduct[reagent.id]
    if sub and sub ~= recipe then
      local unitCraft = sub.missing == 0 and (sub.cost / sub.made) or nil
      local canBuy = reagent.price ~= nil and not reagent.stale
      local saving = (unitCraft and canBuy) and (reagent.price - unitCraft) or nil
      local include = (saving ~= nil and saving > 0) or (not canBuy and unitCraft ~= nil)
      local why
      if include then why = canBuy and "cheaper to craft" or "no current AH price"
      elseif unitCraft then why = "cheaper to buy"
      else why = "craft cost unknown" end
      list[#list + 1] = {
        reagent = reagent, sub = sub, unitCraft = unitCraft, buy = reagent.price, canBuy = canBuy,
        saving = saving, include = include, why = why,
      }
    end
  end
  return list
end

-- Crafts of the sub-recipe needed to make `crafts` of the main recipe,
-- after using what's already in your bags (minus earlier reservations).
-- All craftable reagents below a recipe, flattened with depth and parent:
-- { entry..., depth, parent = index of the entry that uses it }.
local function subTree(recipe, crafts, byProduct)
  local flat, seen = {}, {}
  local function walk(r, depth, parent)
    if depth > MAX_DEPTH then return end
    for _, entry in ipairs(subReagents(r, crafts, byProduct)) do
      if not seen[entry.sub.recipeID] then
        seen[entry.sub.recipeID] = true
        entry.depth, entry.parent = depth, parent
        flat[#flat + 1] = entry
        walk(entry.sub, depth + 1, #flat)
      end
    end
  end
  walk(recipe, 1, nil)
  return flat
end

-- Ticked, and everything above it is ticked too.
local function effectivelyIncluded(flat, index)
  local entry = flat[index]
  while entry do
    if not entry.include then return false end
    entry = entry.parent and flat[entry.parent]
  end
  return true
end

-- Recipes chosen for crafting in a subTree.
local function chosenSubs(flat)
  local list = {}
  for i, entry in ipairs(flat) do
    if effectivelyIncluded(flat, i) then list[#list + 1] = entry.sub end
  end
  return list
end

-- Queue a list of {recipe, crafts}, sub-reagents first.
-- Queue a list of {recipe, crafts, subs}.
local function queueOrdered(steps)
  local done, failed = {}, {}
  for _, step in ipairs(steps) do
    local ok, reason = queueAdd(step.recipe, step.crafts, step.subs)
    if ok then
      local text = step.crafts .. " x " .. step.recipe.name
      if step.subs and #step.subs > 0 then
        local names = {}
        for _, sub in ipairs(step.subs) do names[#names + 1] = sub.name end
        text = text .. " (crafting " .. table.concat(names, ", ") .. ")"
      end
      done[#done + 1] = text
    else
      failed[#failed + 1] = step.recipe.name .. " (" .. tostring(reason) .. ")"
    end
    log("queue", step.recipe.name, step.crafts, ok, reason or "")
  end
  if #done > 0 and showQueueWindow then showQueueWindow() end
  if updateQueueWindow then updateQueueWindow() end
  return done, failed
end

------------------------------------------------------------------------------
-- Reagent window, under the craft queue window and shown with it. It lists
-- the craftable reagents of what's queued (each once), ticked when the queue
-- crafts them; Update applies your ticks to the queue. Ticks are also
-- remembered per reagent for what you queue next. + on a row switches it to
-- that one recipe until you Queue or go Back.
------------------------------------------------------------------------------

local popup
local showReagentWindow, placeReagentWindow -- defined with the queue window
local DOCK_ROWS = 10 -- reagent rows shown; any more still count (as ticked)

-- Your tick overrides, per reagent recipe: kept only where they differ from
-- the craft-or-buy rule, so the rule still decides everything else.
local function applyChoices(flat)
  local choices = db.reagentChoices or {}
  for _, entry in ipairs(flat) do
    entry.ruleInclude = entry.include
    local choice = choices[entry.sub.recipeID]
    if choice ~= nil then entry.include = choice end
  end
  return flat
end

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
  if panel and panel:IsVisible() and panel.byProduct then return panel.byProduct end
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

-- Batch mode (Queue profitable): the steps to queue with the reagents ticked
-- in the combined list, each step getting the ones from its own reagent tree.
local function batchSteps()
  local chosen = {}
  for _, sub in ipairs(chosenSubs(popup.subs)) do chosen[sub.recipeID] = sub end
  local steps = {}
  for _, step in ipairs(popup.batch) do
    local subs = {}
    for id in pairs(step.tree) do
      if chosen[id] then subs[#subs + 1] = chosen[id] end
    end
    steps[#steps + 1] = { recipe = step.recipe, crafts = step.crafts, subs = subs }
  end
  return steps
end

-- One line per reagent: name, a short craft-or-buy verdict, crafts to queue.
-- Hover for the numbers.
local function reagentVerdict(entry)
  if not entry.unitCraft then return RED .. "cost unknown|r" end
  if not entry.canBuy then return RED .. "no AH price|r" end
  if entry.saving > 0 then return GREEN .. "saves " .. API.Money(entry.saving) .. "|r" end
  return RED .. "buy cheaper|r"
end

local function reagentRowTooltip(row)
  local entry, d = row.entry, row.plan
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
  if entry.unitCraft then GameTooltip:AddDoubleLine("Craft cost", API.Money(entry.unitCraft) .. " ea", 0.8, 0.8, 0.8, 1, 1, 1) end
  GameTooltip:AddDoubleLine("Buy price", entry.canBuy and (API.Money(entry.buy) .. " ea") or "no current AH price", 0.8, 0.8, 0.8, 1, 1, 1)
  if entry.saving then
    GameTooltip:AddDoubleLine(entry.saving > 0 and "Crafting saves" or "Buying saves", API.Money(math.abs(entry.saving)) .. " ea",
      0.8, 0.8, 0.8, 1, 1, 1)
  end
  if entry.include ~= entry.ruleInclude then
    GameTooltip:AddLine("Your choice (remembered) - the rule would " .. (entry.ruleInclude and "craft" or "buy") .. " it.", 0.6, 0.6, 0.6, true)
  end
  if not row.active and entry.include then GameTooltip:AddLine("A reagent above it is unticked.", 0.6, 0.6, 0.6, true) end
  GameTooltip:Show()
end

-- Header lines move up in the preview (no quantity row there).
local function layoutPopup(batch)
  local top = batch and 0 or 24
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
  local mains, recipe, crafts = {}, nil, nil
  if batch then
    local total = 0
    for _, step in ipairs(batch) do total = total + step.crafts end
    popup.title:SetText("Reagents for the queue")
    popup.inQueue:SetText(("%d queued item(s), %d craft(s)"):format(#batch, total))
    for _, step in ipairs(batchSteps()) do
      local main = recipeDef(step.recipe)
      main.count, main.subs = step.crafts, {}
      for _, sub in ipairs(step.subs) do main.subs[sub.recipeID] = recipeDef(sub) end
      mains[#mains + 1] = main
    end
  else
    recipe, crafts = popup.recipe, popupCrafts()
    popup.title:SetText("Queue: " .. recipe.name)
    popup.madeText:SetText(recipe.made > 1 and ("crafts (makes %d each)"):format(recipe.made) or "crafts")
    local target = queueTarget(recipe)
    popup.inQueue:SetText(("Already queued: %d"):format(queuedCount(recipe.recipeID)))
    if not popup.restockBox:HasFocus() then popup.restockBox:SetText(target and tostring(target) or "") end

    -- Plan this item alone to show how many of each reagent level it needs.
    local subsDefs = {}
    for _, sub in ipairs(chosenSubs(popup.subs)) do subsDefs[sub.recipeID] = recipeDef(sub) end
    local main = recipeDef(recipe)
    main.count, main.subs = crafts, subsDefs
    mains[1] = main
  end
  local _, plan = planDerived(mains)

  local saving, rows = 0, popup.subRows
  for i, entry in ipairs(popup.subs) do
    local active = effectivelyIncluded(popup.subs, i)
    local d = active and plan[entry.sub.recipeID]
    if d and entry.saving and entry.saving > 0 then
      saving = saving + entry.saving * math.min(d.need, d.count * d.made)
    end
    local row = rows[i]
    if row then
      row.entry, row.plan, row.active = entry, d, active
      row.queuedNow = queuedCount(entry.sub.recipeID)
      row.check:SetChecked(entry.include)
      row.check:ClearAllPoints()
      row.check:SetPoint("LEFT", (entry.depth - 1) * 12, 0)
      local name = (entry.depth > 1 and (GREY .. ">|r ") or "") .. (entry.reagent.name or "?")
      if entry.include and not active then name = GREY .. (entry.reagent.name or "?") .. "|r" end
      row.left:SetText(name)
      row.right:SetText(reagentVerdict(entry))
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
  if batch and #batch == 0 then
    text = nil
  elseif batch then
    local total = 0
    for _, step in ipairs(batch) do total = total + (step.recipe.profit or 0) * step.crafts end
    text = ("Profit: %s"):format(API.Money(total))
  elseif recipe.profit then
    text = ("Profit: %s ea, %s total"):format(API.Money(recipe.profit), API.Money(recipe.profit * crafts))
    if recipe.incomplete then text = text .. RED .. " *|r" end
  end
  if text then
    if saving > 0 then text = text .. ("  " .. GREEN .. "+%s from reagents|r"):format(API.Money(saving)) end
    popup.profit:SetText(text)
  elseif batch then
    popup.profit:SetText("")
  else
    popup.profit:SetText(GREY .. "Profit unknown (no AH price for the crafted item).|r")
  end
  popup:SetHeight(rowsTop + math.max(shownRows, 1) * 20 + 40)
  placeReagentWindow()
end

local showBatch -- defined below

-- Its own window, hung under the craft queue window (placed by
-- placeReagentWindow) and shown with the Profit tab.
local function createPopup()
  popup = CreateFrame("Frame", "ProfessionProfitReagentWindow", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
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
    toggleTargetsWindow(true)
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
    row.right:SetWidth(96)
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
    updateQueueWindow()
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
      toggleTargetsWindow(true)
    end
    local done, failed = queueOrdered({ { recipe = recipe, crafts = crafts, subs = chosenSubs(popup.subs) } })
    if #done > 0 then msg("Queued: " .. table.concat(done, ", ")) end
    if #failed > 0 then msg("Not queued: " .. table.concat(failed, ", ")) end
    popup.recipe = nil
    showBatch() -- back to the queue's reagents
    if refresh then refresh() end
  end)
end

-- What "Queue profitable" queues: every recipe shown in the table with a
-- positive, complete profit, Qty / restock-target crafts each.
local function profitableSteps()
  local steps, skippedIncomplete, skippedStock = {}, 0, 0
  for _, recipe in ipairs(panel.shown or {}) do
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
  local steps, merged, indexOf, queued = {}, {}, {}, {}
  for _, main in ipairs(craftQueue()) do
    local recipe = main.productID and byProduct[main.productID]
    if recipe and recipe.recipeID == main.recipeID then
      for id in pairs(main.subs or {}) do queued[id] = true end
      local step = { recipe = recipe, crafts = main.count, tree = {} }
      steps[#steps + 1] = step
      local map = {}
      for i, entry in ipairs(subTree(recipe, main.count, byProduct)) do
        local id = entry.sub.recipeID
        step.tree[id] = true
        if not indexOf[id] then
          entry.parent = entry.parent and map[entry.parent]
          merged[#merged + 1] = entry
          indexOf[id] = #merged
        end
        map[i] = indexOf[id]
      end
    end
  end
  for _, entry in ipairs(merged) do
    local id = entry.sub.recipeID
    entry.ruleInclude = entry.include
    entry.include = queued[id] or false
    if popup.changed[id] then entry.include = popup.changed[id].include end
  end
  popup.recipe, popup.batch, popup.subs = nil, steps, merged
  -- Nothing to choose when the queue crafts no reagents ("Craft reagents" off).
  if #merged == 0 or popup.closed or db.skipReagentCrafts then
    popup:Hide()
    return
  end
  popup:Show()
  updatePopup()
end

-- + on a row: the reagent window shows that recipe until you Queue or go Back.
local function openQueuePopup(recipe)
  if not recipe.recipeID then msg("Queueing needs the Professions (K) window.") return end
  if not popup then createPopup() end
  popup.recipe, popup.batch, popup.closed = recipe, nil, nil
  popup.subs = applyChoices(subTree(recipe, craftsToQueue(recipe)))
  popup.qty:SetText(tostring(math.max(1, craftsToQueue(recipe))))
  popup:Show()
  updatePopup()
  log("queue popup", recipe.name, #popup.subs, "craftable reagents")
end

-- Queue every profitable recipe in the table, crafting the reagents you've
-- chosen (or the craft-or-buy rule picks). Fine-tune them afterwards in the
-- reagent window.
local function queueProfitable()
  local steps, skipped = profitableSteps()
  if #steps == 0 then
    msg("Nothing to queue" .. skipped .. ".")
    return
  end
  for _, step in ipairs(steps) do
    step.subs = chosenSubs(applyChoices(subTree(step.recipe, step.crafts)))
  end
  local done, failed = queueOrdered(steps)
  local text = ("Queued %d recipe(s)%s."):format(#done, skipped)
  msg(text)
  if #failed > 0 then msg("Not queued: " .. table.concat(failed, ", ")) end
  log("queue profitable:", text, table.concat(done, ", "))
  if refresh then refresh() end
end

------------------------------------------------------------------------------
-- Craft Queue window
------------------------------------------------------------------------------

local queueWin
local QROW = 18
local QROWS = 14

-- How many of a queue entry can be crafted right now (its profession must
-- be the one open).
local function craftableNow(entry)
  if not hostShown() or not inOpenProfession(entry) then return 0 end
  if C_TradeSkillUI.GetCraftableCount then
    local ok, n = pcall(C_TradeSkillUI.GetCraftableCount, entry.recipeID)
    if ok and type(n) == "number" then return n end
  end
  local info = C_TradeSkillUI.GetRecipeInfo(entry.recipeID)
  return info and info.numAvailable or 0
end

-- Reagents still missing for the whole queue: needs minus bags/bank minus
-- what earlier queue entries will craft. Returns list, estimated cost.
local function queueShopping()
  local need, produced, names = {}, {}, {}
  for _, entry in ipairs(computeQueue()) do
    for _, reagent in ipairs(entry.reagents) do
      if reagent.id then
        need[reagent.id] = (need[reagent.id] or 0) + reagent.c * entry.count
        names[reagent.id] = names[reagent.id] or reagent.n
      end
    end
    if entry.productID then
      produced[entry.productID] = (produced[entry.productID] or 0) + (entry.made or 1) * entry.count
    end
  end
  local list, cost, unpriced = {}, 0, 0
  for id, n in pairs(need) do
    local bags = bagCount(id)
    local short = n - bags - (produced[id] or 0)
    if short > 0 then
      local bank = math.max(0, ((GetItemCount and GetItemCount(id, true)) or bags) - bags)
      local buy = math.max(0, short - bank)
      local price = API.BuyPrice(id)
      if buy > 0 then
        if price then cost = cost + price * buy else unpriced = unpriced + 1 end
      end
      list[#list + 1] = { id = id, name = names[id] or itemName(id) or ("item " .. id), count = short,
        bank = math.min(bank, short), buy = buy, price = price }
    end
  end
  table.sort(list, function(a, b) return a.name < b.name end)
  return list, cost, unpriced
end

local function firstCraftable()
  for index, entry in ipairs(computeQueue()) do
    local n = craftableNow(entry)
    if n > 0 then return entry, index, math.min(n, entry.count) end
  end
end

------------------------------------------------------------------------------
-- Processing the whole queue
------------------------------------------------------------------------------
-- One click crafts the whole list: each step crafts the full count of the
-- first craftable entry (reagent crafts come first). When a step finishes we
-- wait for the bags to update, recount the queue (so freshly crafted reagents
-- are used) and start the next step. If the game won't start a craft without
-- a click, the button turns into "Continue" and each click runs one step.

local crafting   -- current step: { recipeID, left, auto, name, started, lastProgress }
local processing -- { steps, needClick } while "Craft all" is running
-- Since "Craft all" was last started: profit of the queued items crafted
-- (total), and what crafting reagents saved over buying them (saved).
local earned = { total = 0, crafts = 0, unpriced = 0, saved = 0, reagents = 0 }

local STEP_START_TIMEOUT = 2.5  -- no cast start by then: the game wants a click
local STEP_IDLE_TIMEOUT = 5     -- no progress by then: the step ended early

local startStep

local function stopProcessing(reason)
  local wasRunning = processing ~= nil
  processing, crafting = nil, nil
  if reason and wasRunning then msg(reason) end
  if updateQueueWindow then updateQueueWindow() end
end

local function nothingCraftableReason(queue)
  if #queue == 0 then return "Craft queue finished." end
  local here = 0
  for _, e in ipairs(queue) do if inOpenProfession(e) then here = here + 1 end end
  if here == 0 then
    return ("Nothing left for this profession. Still queued: %s."):format(queue[1].prof or "another profession")
  end
  return "Done for now - what's left needs reagents (see Missing in the queue window)."
end

-- The game ignores crafts an addon starts without a click / key press.
-- Once we've seen that, stop trying and ask for the press straight away.
local function waitForPress()
  if not processing then return end
  processing.needClick = true
  if SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON then PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON) end
  if updateQueueWindow then updateQueueWindow() end
end

local function scheduleNextStep(delay)
  if not processing then return end
  -- Bags update a moment after the last cast; recount after that.
  C_Timer.After(delay or 0.8, function()
    if not processing or crafting then return end
    if db.craftNeedsClick then
      if firstCraftable() then waitForPress() else startStep(false) end
    else
      startStep(false)
    end
  end)
end

-- Watch a running step: if crafting stops early (out of mats, moved...)
-- without a failure event, move on.
local function watchStep(step)
  C_Timer.After(1, function()
    if crafting ~= step then return end
    if GetTime() - step.lastProgress > (step.started and STEP_IDLE_TIMEOUT or STEP_START_TIMEOUT) then
      if not step.started and processing then
        -- The game ignored a craft we started without a click.
        log("step didn't start:", step.name, step.fromClick and "(from a click!)" or "(auto - needs a click)")
        crafting = nil
        if not step.fromClick then
          if not db.craftNeedsClick then
            msg("The game needs a click or key press to start each step - press Continue, or bind a key: Key Bindings > AddOns > ProfessionProfit.")
          end
          db.craftNeedsClick = true
        end
        waitForPress()
      else
        log("step idle, moving on:", step.name, "left", step.left)
        crafting = nil
        scheduleNextStep(0.2)
      end
      return
    end
    watchStep(step)
  end)
end

startStep = function(fromClick)
  if not processing then return end
  processing.needClick = false
  if not hostShown() then stopProcessing("Stopped: the profession window was closed.") return end
  local entry, _, n = firstCraftable()
  if not entry then
    stopProcessing(nothingCraftableReason(computeQueue()))
    return
  end
  local ok, err = pcall(C_TradeSkillUI.CraftRecipe, entry.recipeID, n)
  log("step", processing.steps + 1, entry.name, entry.recipeID, "x" .. n, fromClick and "(click)" or "(auto)", ok and "ok" or err)
  if not ok then
    stopProcessing("Couldn't craft " .. entry.name .. ": " .. tostring(err))
    return
  end
  processing.steps = processing.steps + 1
  crafting = { recipeID = entry.recipeID, left = n, auto = entry.auto, name = entry.name,
    started = false, lastProgress = GetTime(), fromClick = fromClick }
  watchStep(crafting)
  if updateQueueWindow then updateQueueWindow() end
end

-- The queue window's main button.
local function craftButtonClicked()
  if processing and not processing.needClick then
    stopProcessing("Stopped.")
    return
  end
  if processing and processing.needClick then
    startStep(true)
    return
  end
  local queue = computeQueue()
  if #queue == 0 then msg("The craft queue is empty.") return end
  if not hostShown() then msg("Open the profession window (K) to craft.") return end
  if not firstCraftable() then
    msg(nothingCraftableReason(queue))
    return
  end
  processing = { steps = 0 }
  earned.total, earned.crafts, earned.unpriced, earned.saved, earned.reagents = 0, 0, 0, 0, 0
  startStep(true)
end

-- Key binding "Craft next queue step": starts or continues, never stops.
function ProfessionProfit_CraftNext()
  if processing and not processing.needClick then return end -- a step is running
  craftButtonClicked()
end
BINDING_HEADER_PROFESSIONPROFIT = "ProfessionProfit"
BINDING_NAME_PROFESSIONPROFIT_CRAFTNEXT = "Craft next queue step"

local function onCraftStarted(spellID)
  if crafting and crafting.recipeID == spellID then
    if not crafting.fromClick and db.craftNeedsClick then db.craftNeedsClick = false end
    crafting.started = true
    crafting.lastProgress = GetTime()
  end
end

local function onCraftStopped(spellID, why)
  if crafting and crafting.recipeID == spellID and processing then
    stopProcessing(("Stopped: %s was %s."):format(crafting.name, why))
  end
end

-- One cast finished: count it off the queue. Reagent crafts need no
-- bookkeeping - the new items in your bags lower their count by themselves.
-- Returns "queued" for a queued item, "reagent" for a reagent craft.
local function onCraftSucceeded(spellID)
  local isReagentCraft, stepDone, counted
  if crafting and crafting.recipeID == spellID then
    isReagentCraft = crafting.auto
    crafting.started = true
    crafting.lastProgress = GetTime()
    crafting.left = crafting.left - 1
    if crafting.left <= 0 then
      crafting = nil
      stepDone = true
    end
  else
    local _, derived = computeQueue()
    isReagentCraft = derived[spellID] ~= nil and derived[spellID].count > 0
  end
  if not isReagentCraft then
    local queue = craftQueue()
    for index, entry in ipairs(queue) do
      if entry.recipeID == spellID then
        entry.count = entry.count - 1
        if entry.count <= 0 then table.remove(queue, index) end
        log("crafted", entry.name, "left", math.max(entry.count, 0))
        counted = "queued"
        break
      end
    end
  end
  -- Bags update a moment after the cast; recount then.
  C_Timer.After(0.3, function()
    if updateQueueWindow then updateQueueWindow() end
    if refresh then refresh() end
  end)
  if stepDone then scheduleNextStep() end
  return counted or (isReagentCraft and "reagent") or nil
end

-- Re-decide which reagents to craft for everything queued in the open
-- profession, from current bags and prices (the queue's Refresh button).
local function recompileQueue()
  local prof = professionInfo(true)
  if not prof or not hostShown() then
    msg("Open a profession (K) to refresh its crafted reagents.")
    return
  end
  local byProduct, byID = {}, {}
  for _, recipe in ipairs(readRecipes()) do
    evaluate(recipe)
    if recipe.productID then byProduct[recipe.productID] = recipe end
    if recipe.recipeID then byID[recipe.recipeID] = recipe end
  end
  local crafting, buying, done, other = {}, {}, 0, {}
  for _, main in ipairs(craftQueue()) do
    local recipe = inOpenProfession(main) and byID[main.recipeID]
    if recipe then
      done = done + 1
      local fresh = recipeDef(recipe)
      main.reagents, main.made, main.productID = fresh.reagents, fresh.made, fresh.productID
      main.subs = {}
      local flat = subTree(recipe, main.count, byProduct)
      for i, entry in ipairs(flat) do
        if effectivelyIncluded(flat, i) then
          main.subs[entry.sub.recipeID] = recipeDef(entry.sub)
          crafting[entry.sub.name] = entry.why
        elseif not crafting[entry.sub.name] then
          buying[entry.sub.name] = entry.include and "level above is bought" or entry.why
        end
      end
    elseif not inOpenProfession(main) then
      other[main.prof or "another profession"] = true
    end
  end
  local function describe(t)
    local parts = {}
    for name, why in pairs(t) do parts[#parts + 1] = name .. " (" .. why .. ")" end
    table.sort(parts)
    return #parts > 0 and table.concat(parts, ", ") or "none"
  end
  msg(("Refreshed %d queued %s item(s). Crafting: %s. Not crafting: %s."):format(done, prof, describe(crafting), describe(buying)))
  local others = {}
  for name in pairs(other) do others[#others + 1] = name end
  if #others > 0 then msg("Open " .. table.concat(others, ", ") .. " to refresh those entries too.") end
  log("recompile", prof, done, describe(crafting), "| buy:", describe(buying))
  updateQueueWindow()
end

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
  if processing and processing.needClick then
    local key = GetBindingKey and GetBindingKey("PROFESSIONPROFIT_CRAFTNEXT")
    queueWin.craftButton:SetText(key and ("Continue (" .. key .. ")") or "Continue")
    queueWin.nextText:SetText(entry and ("Next: |cffffffff%s|r x%d"):format(entry.name, count) or "")
  elseif processing then
    queueWin.craftButton:SetText(("Stop (step %d)"):format(processing.steps))
    queueWin.nextText:SetText(crafting and ("Crafting: |cffffffff%s|r, %d left"):format(crafting.name, crafting.left)
      or "Recounting reagents...")
  elseif entry then
    queueWin.craftButton:SetText("Craft all")
    queueWin.nextText:SetText(("Next: |cffffffff%s|r x%d"):format(entry.name, count))
  else
    queueWin.craftButton:SetText("Craft all")
    queueWin.nextText:SetText(#queue == 0 and "" or "|cffff6666Nothing craftable in this profession.|r")
  end
  queueWin.craftButton:Enable() -- clicking explains why when nothing is craftable
  if popup and not popup.recipe then showBatch() end
end

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
    toggleTargetsWindow(true)
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
    if popup then popup.closed = nil end
    updateQueueWindow()
    showReagentWindow()
  end)
  queueWin:SetScript("OnHide", function() if popup then popup:Hide() end end)
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

local function toggleQueueWindow()
  if queueWin and queueWin:IsShown() then
    queueWin:Hide()
  else
    showQueueWindow()
  end
end

-- The reagent window hangs under the queue window - above it when there's
-- no room below, or in its place while it's closed.
placeReagentWindow = function()
  if not popup then return end
  if not queueWin then createQueueWindow() end
  if queueWin:GetNumPoints() == 0 then placeQueueWindow() end
  popup:ClearAllPoints()
  local bottom = queueWin:GetBottom()
  if not queueWin:IsShown() then
    -- (+ before anything is queued) sit where the queue window would be.
    popup:SetPoint("TOPLEFT", queueWin, "TOPLEFT")
    popup:SetPoint("TOPRIGHT", queueWin, "TOPRIGHT")
  elseif bottom and bottom - popup:GetHeight() < 0 then
    popup:SetPoint("BOTTOMLEFT", queueWin, "TOPLEFT", 0, 2)
    popup:SetPoint("BOTTOMRIGHT", queueWin, "TOPRIGHT", 0, 2)
  else
    popup:SetPoint("TOPLEFT", queueWin, "BOTTOMLEFT", 0, -2)
    popup:SetPoint("TOPRIGHT", queueWin, "BOTTOMRIGHT", 0, -2)
  end
end

-- Shown with the queue window, when the queue has craftable reagents (or
-- while + has it showing one recipe).
showReagentWindow = function()
  if not (queueWin and queueWin:IsShown()) then return end
  if not popup then createPopup() end
  if popup.recipe then
    popup:Show()
    updatePopup()
  else
    showBatch()
  end
end

local function syncQueueWindow()
  updateQueueWindow()
end

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
      GameTooltip:AddLine("Shift-click to forget every restock target. Top up then fills everything to Qty.", 1, 1, 1, true)
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
end

local function showRecipesTab() end -- defined with the tabs below

local function selectRecipe(recipe)
  openRecipeInUI(recipe)
  showRecipesTab()
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
  plus:SetScript("OnClick", function() if row.recipe then openQueuePopup(row.recipe) end end)
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
      openQueuePopup(self.recipe)
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
  if popup and popup:IsShown() and not popup.recipe then showBatch() end -- prices may have changed
  panel.summary:SetText(("%d recipes, %d profitable.  %s* = incomplete (missing or week-old prices, hover for details)|r")
    :format(#recipes, profitable, GREY))

  for _, header in ipairs(panel.headers) do
    local arrow = ""
    if header.key == db.sortKey then arrow = db.sortDesc and " v" or " ^" end
    header.label:SetText(header.title .. arrow)
  end
  updateScanButton()
end

local refreshPending
local function refreshSoon()
  if refreshPending or not panel or not panel:IsVisible() then return end
  refreshPending = true
  C_Timer.After(0.2, function() refreshPending = nil; refresh() end)
end

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

local function createPanel(host)
  panel = CreateFrame("Frame", "ProfessionProfitPanel", host, BackdropTemplateMixin and "BackdropTemplate" or nil)
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
  queueButton:SetScript("OnClick", queueProfitable)
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
  restock:SetScript("OnClick", function() toggleTargetsWindow() end)
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

------------------------------------------------------------------------------
-- Tabs under the profession window
------------------------------------------------------------------------------

local built = false
local lastError

-- Plain buttons styled like the rest of this UI. Blizzard's tab templates
-- differ between clients and can fail silently, so don't depend on them.
local function createTab(host, text)
  local tab = CreateFrame("Button", nil, host, "UIPanelButtonTemplate")
  tab:SetSize(100, 24)
  tab:SetText(text)
  tab:SetFrameLevel(host:GetFrameLevel() + 45)
  return tab
end

local function selectTab(id)
  for i = 1, 2 do
    -- Highlight the active tab by locking it pushed/disabled-looking.
    if tabs[i] then tabs[i]:SetEnabled(i ~= id) end
  end
  panel:SetShown(id == 2)
end

showRecipesTab = function() selectTab(1) end

-- Move the panel and tabs onto a profession window (Blizzard's or Skillet's).
local function attachTo(host)
  if not panel or not host or panel.host == host then return end
  log("attaching to", host)
  panel.host = host
  panel:SetParent(host)
  panel:ClearAllPoints()
  panel:SetAllPoints(host)
  for i, tab in ipairs(tabs) do
    tab:SetParent(host)
    tab:SetFrameLevel(host:GetFrameLevel() + 45)
    tab:ClearAllPoints()
    if i == 1 then
      tab:SetPoint("TOPLEFT", host, "BOTTOMLEFT", 16, -2)
    else
      tab:SetPoint("LEFT", tabs[i - 1], "RIGHT", 4, 0)
    end
  end
  if panel:IsShown() then raiseAbove(host) end
end

local skilletHooked = false
local function hookSkillet()
  if skilletHooked or not SkilletFrame then return end
  skilletHooked = true
  SkilletFrame:HookScript("OnShow", function()
    log("SkilletFrame OnShow")
    attachTo(SkilletFrame)
    C_Timer.After(0.3, syncQueueWindow)
    refreshSoon()
    rememberSoon()
  end)
  SkilletFrame:HookScript("OnHide", function()
    local base = baseHost()
    if base and base:IsShown() then attachTo(base) end
  end)
  if SkilletFrame:IsShown() then attachTo(SkilletFrame) end
end

-- The overview page (no profession picked) has no recipes to price: hide
-- Recipes / Profit there, closing Profit if it's open. The recipe list lives
-- on ProfessionsFrame.CraftingPage, which the overview hides; switching back
-- to the overview may not change what the game reports as the profession.
-- Checked a moment after the window changes (the game updates a bit late).
local function updateTabsForOverview()
  C_Timer.After(0.2, function()
    if not (tabs[1] and isModern() and hostShown()) then return end
    local page = ProfessionsFrame and ProfessionsFrame.CraftingPage
    local overview = (page and not page:IsShown()) or not professionInfo(true)
    if overview == tabs.overview then return end
    tabs.overview = overview
    local shown = {}
    for _, child in ipairs({ ProfessionsFrame:GetChildren() }) do
      if child:IsShown() and child ~= panel then shown[#shown + 1] = child:GetDebugName() end
    end
    log("overview:", overview, "craftingPage shown:", page and page:IsShown(), "profession:",
      professionInfo(true) or "none", "| shown:", table.concat(shown, ", "))
    tabs[1]:SetShown(not overview)
    tabs[2]:SetShown(not overview)
    if overview and panel and panel:IsShown() then selectTab(1) end
  end)
end

local baseHooked = false
local function hookBase()
  local base = baseHost()
  if baseHooked or not base then return end
  baseHooked = true
  base:HookScript("OnShow", function()
    log("host OnShow")
    -- Skillet hides Blizzard's window as soon as it opens; stay on Skillet.
    if not skilletShown() then attachTo(base) end
    refreshSoon()
    updateTabsForOverview()
    C_Timer.After(0.3, syncQueueWindow)
  end)
  base:HookScript("OnHide", function()
    tabs.overview = nil
    C_Timer.After(0, syncQueueWindow)
  end)
  -- Switching between a profession and the overview swaps this page.
  local page = base.CraftingPage
  if page then
    page:HookScript("OnShow", updateTabsForOverview)
    page:HookScript("OnHide", updateTabsForOverview)
  end
end

local function buildUI()
  local host = baseHost() or (SkilletFrame ~= nil and SkilletFrame) or nil
  if built or not host then return end
  built = true
  log("building UI on", host)
  createPanel(host)
  tabs[1] = createTab(host, "Recipes")
  tabs[2] = createTab(host, "Profit")
  tabs[1]:SetPoint("TOPLEFT", host, "BOTTOMLEFT", 16, -2)
  tabs[2]:SetPoint("LEFT", tabs[1], "RIGHT", 4, 0)
  tabs[3] = createTab(host, "Queue")
  tabs[3]:SetPoint("TOPRIGHT", host, "BOTTOMRIGHT", -16, -2)
  tabs[1]:SetScript("OnClick", function() selectTab(1) end)
  tabs[2]:SetScript("OnClick", function() selectTab(2) end)
  tabs[3]:SetScript("OnClick", toggleQueueWindow)
  updateQueueWindow()
  if not isModern() and TradeSkillFrame_Update then hooksecurefunc("TradeSkillFrame_Update", refreshSoon) end
  hookBase()
  hookSkillet()
  selectTab(1)
  log("UI built; tab1:", tabs[1], "tab2:", tabs[2])
end

local function createTabs(reason)
  if built then hookBase() hookSkillet() return end
  if not hostFrame() then return end
  local ok, err = xpcall(buildUI, function(e) return tostring(e) .. "\n" .. (debugstack and debugstack(2) or "") end)
  if ok then
    logEnvironment("UI built after " .. tostring(reason))
  else
    lastError = err
    log("buildUI error:", err)
    msg(RED .. "failed to add the Profit tab:|r " .. tostring(err):match("^[^\n]*"))
  end
end

------------------------------------------------------------------------------
-- Toasts: an achievement-style pop-up with the profit of what you just
-- crafted, or the gold you just took from the mailbox. Repeats of the same
-- thing (casts of one recipe, letters in one mail run) add up in one toast.
------------------------------------------------------------------------------

local TOAST_HOLD = 4 -- seconds shown after the last cast
local toast, craftLookup

-- Learned recipes of the open profession by recipe ID (modern) or name
-- (classic, matched against the cast's spell name). Rebuilt when the list changes.
local function recipeForSpell(spellID)
  if not hostShown() then return nil end
  if not craftLookup then
    craftLookup = {}
    for _, recipe in ipairs(readRecipes()) do
      craftLookup[recipe.recipeID or recipe.name] = recipe
    end
  end
  if isModern() then return craftLookup[spellID] end
  local name = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(spellID)
  if not name and GetSpellInfo then name = GetSpellInfo(spellID) end
  return name and craftLookup[name]
end

local function createToast()
  toast = CreateFrame("Frame", "ProfessionProfitCraftToast", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
  toast:SetSize(300, 64)
  toast:SetPoint("BOTTOM", UIParent, "BOTTOM", 0, 200)
  toast:SetFrameStrata("HIGH")
  toast:Hide()
  if toast.SetBackdrop then
    toast:SetBackdrop({
      bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
      edgeSize = 16, insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    toast:SetBackdropColor(0.07, 0.06, 0.05, 0.92)
    toast:SetBackdropBorderColor(1, 0.82, 0, 1)
  end

  toast.icon = toast:CreateTexture(nil, "ARTWORK")
  toast.icon:SetSize(42, 42)
  toast.icon:SetPoint("LEFT", 11, 0)

  toast.title = toast:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  toast.title:SetPoint("TOPLEFT", toast.icon, "TOPRIGHT", 10, -1)
  toast.title:SetPoint("RIGHT", -10, 0)
  toast.title:SetJustifyH("LEFT")

  toast.amount = toast:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
  toast.amount:SetPoint("TOPLEFT", toast.title, "BOTTOMLEFT", 0, -3)
  toast.amount:SetPoint("RIGHT", -10, 0)
  toast.amount:SetJustifyH("LEFT")

  toast.detail = toast:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  toast.detail:SetPoint("TOPLEFT", toast.amount, "BOTTOMLEFT", 0, -2)
  toast.detail:SetPoint("RIGHT", -10, 0)
  toast.detail:SetJustifyH("LEFT")

  -- Fade in, hold, fade out. Restarted (from fully shown) by each cast.
  toast.anim = toast:CreateAnimationGroup()
  local fadeIn = toast.anim:CreateAnimation("Alpha")
  fadeIn:SetFromAlpha(0)
  fadeIn:SetToAlpha(1)
  fadeIn:SetDuration(0.25)
  fadeIn:SetOrder(1)
  local fadeOut = toast.anim:CreateAnimation("Alpha")
  fadeOut:SetFromAlpha(1)
  fadeOut:SetToAlpha(0)
  fadeOut:SetStartDelay(TOAST_HOLD)
  fadeOut:SetDuration(1)
  fadeOut:SetOrder(2)
  toast.fadeIn = fadeIn
  toast.anim:SetScript("OnFinished", function() toast:Hide(); toast.key = nil end)
end

-- opts: incomplete (price has gaps), detail (small line; default: the amount
-- per repeat, or profit/loss).
local function showToast(key, title, icon, amount, opts)
  opts = opts or {}
  if not toast then createToast() end
  local again = toast:IsShown() and toast.key == key
  toast.casts = again and toast.casts + 1 or 1
  toast.total = (again and toast.total or 0) + amount
  toast.key = key

  local good = toast.total >= 0
  toast.icon:SetTexture(icon or 134400) -- question mark
  toast.title:SetText(toast.casts > 1 and ("%s x%d"):format(title, toast.casts) or title)
  toast.amount:SetText((good and "+" or "") .. API.Money(toast.total) .. (opts.incomplete and (RED .. " *|r") or ""))
  toast.amount:SetTextColor(good and 0.2 or 1, good and 1 or 0.3, 0.2)
  toast.detail:SetText(opts.detail or (toast.casts > 1 and (API.Money(amount) .. (opts.each or " per craft"))
    or opts.label or (good and "profit" or "loss")))
  toast:SetBackdropBorderColor(good and 1 or 0.8, good and 0.82 or 0.2, good and 0 or 0.2, 1)

  toast.anim:Stop()
  toast.fadeIn:SetDuration(again and 0 or 0.25)
  toast:SetAlpha(1)
  toast:Show()
  toast.anim:Play()
  if not again and good and SOUNDKIT and SOUNDKIT.LOOT_WINDOW_COIN_SOUND then
    PlaySound(SOUNDKIT.LOOT_WINDOW_COIN_SOUND)
  end
end

-- kind: "queued" (profit goes to the queue's total), "reagent" (a reagent for
-- the queue: counts what it saved over buying it - no AH cut, it isn't sold).
local function craftToast(spellID, kind)
  local recipe = recipeForSpell(spellID)
  if recipe and recipe.productID then evaluate(recipe) end
  local amount, opts = recipe and recipe.profit, { incomplete = recipe and recipe.incomplete }
  if kind == "reagent" then
    local buy = recipe and recipe.productID and API.BuyPrice(recipe.productID)
    amount = (buy and recipe.missing == 0) and (buy * recipe.made - recipe.cost) or nil
    opts = { label = amount and (amount >= 0 and "saved vs buying" or "more than buying"), each = " saved per craft" }
    if amount then earned.saved, earned.reagents = earned.saved + amount, earned.reagents + 1 end
  elseif kind == "queued" then
    if amount then
      earned.total, earned.crafts = earned.total + amount, earned.crafts + 1
    else
      earned.unpriced = earned.unpriced + 1
    end
  end
  if db.craftToastOff or not amount then return end -- no price for the product
  local icon = C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(recipe.productID)
  if not icon and GetItemIcon then icon = GetItemIcon(recipe.productID) end
  showToast(recipe.recipeID or recipe.name, "Crafted " .. (recipe.productName or recipe.name), icon, amount, opts)
end

-- Mail: gold gained just after a letter's money was taken (by hand, Open
-- All or a mail addon - they all go through these two functions). Anything
-- else, like looting coins, doesn't show a toast.
local MAIL_TAKE_WINDOW = 5 -- seconds for the gold to arrive after taking it
local mailOpen, lastMoney, mailSubject, mailTakeTime

local function noteMailSubject(index)
  if not GetInboxHeaderInfo or type(index) ~= "number" then return end
  local _, _, _, subject, money = GetInboxHeaderInfo(index)
  if money and money > 0 then mailSubject, mailTakeTime = subject, GetTime() end
end
if TakeInboxMoney then hooksecurefunc("TakeInboxMoney", noteMailSubject) end
if AutoLootMailItem then hooksecurefunc("AutoLootMailItem", noteMailSubject) end

local function mailMoneyChanged()
  local money = GetMoney()
  local gained = lastMoney and money - lastMoney
  lastMoney = money
  if not mailOpen or not gained or gained <= 0 or db.mailToastOff then return end
  if not mailTakeTime or GetTime() - mailTakeTime > MAIL_TAKE_WINDOW then return end
  showToast("mail", "Collected mail", 133784, gained, -- coin icon
    { detail = mailSubject or "gold from the mailbox" })
  mailSubject = nil
end

------------------------------------------------------------------------------
-- Events
------------------------------------------------------------------------------

local frame = CreateFrame("Frame")
-- Event names differ between client versions (WoW Forever has no
-- TRADE_SKILL_UPDATE), so register each one only if this client knows it.
for _, event in ipairs({ "ADDON_LOADED", "PLAYER_LOGIN", "TRADE_SKILL_SHOW", "TRADE_SKILL_UPDATE", "TRADE_SKILL_LIST_UPDATE",
  "TRADE_SKILL_DATA_SOURCE_CHANGED", "TRADE_SKILL_CLOSE", "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED",
  "BAG_UPDATE_DELAYED", "GET_ITEM_INFO_RECEIVED", "OWNED_AUCTIONS_UPDATED",
  "PLAYERBANKSLOTS_CHANGED", "BANKFRAME_OPENED", "UNIT_SPELLCAST_SUCCEEDED",
  "UNIT_SPELLCAST_START", "UNIT_SPELLCAST_INTERRUPTED", "UNIT_SPELLCAST_FAILED",
  "MAIL_SHOW", "MAIL_CLOSED", "PLAYER_MONEY", "TRAINER_SHOW", "TRAINER_CLOSED" }) do
  pcall(frame.RegisterEvent, frame, event)
end

frame:SetScript("OnEvent", function(_, event, arg, ...)
  if event == "UNIT_SPELLCAST_SUCCEEDED" or event == "UNIT_SPELLCAST_START"
      or event == "UNIT_SPELLCAST_INTERRUPTED" or event == "UNIT_SPELLCAST_FAILED" then
    if arg ~= "player" or not db then return end
    local spellID = select(2, ...)
    if event == "UNIT_SPELLCAST_SUCCEEDED" then
      craftToast(spellID, onCraftSucceeded(spellID))
    elseif event == "UNIT_SPELLCAST_START" then onCraftStarted(spellID)
    elseif event == "UNIT_SPELLCAST_INTERRUPTED" then onCraftStopped(spellID, "interrupted")
    else onCraftStopped(spellID, "not crafted (failed)") end
    return
  end
  if event ~= "BAG_UPDATE_DELAYED" and event ~= "GET_ITEM_INFO_RECEIVED" and event ~= "PLAYER_MONEY" then log("event", event, arg) end
  if event == "ADDON_LOADED" then
    if arg == ADDON then
      ProfessionProfitDB = ProfessionProfitDB or {}
      db = ProfessionProfitDB
      db.sortKey = db.sortKey or "profit"
      if db.sortDesc == nil then db.sortDesc = true end
      API.RegisterCallback(ADDON, "PricesUpdated", function()
        refreshSoon()
        if updateQueueWindow then updateQueueWindow() end
      end)
      db.queueQty = db.queueQty or 1
      -- Top up starts ticked every session; unticking it lasts until /reload.
      db.queueTopUp, db.topUpDefaulted = true, nil
    end
    -- The profession window may come from an addon with a different name on
    -- this client, so check after every addon load.
    if db then createTabs("ADDON_LOADED " .. tostring(arg)) end
    return
  end
  if not db then return end

  if event == "PLAYER_MONEY" then
    mailMoneyChanged()
    return
  elseif event == "MAIL_SHOW" then
    mailOpen, lastMoney, mailSubject, mailTakeTime = true, GetMoney(), nil, nil
    return
  elseif event == "MAIL_CLOSED" then
    mailOpen = false
    return
  end

  -- The table sits a strata above the profession window, so it would cover a
  -- trainer opened next to it: show Recipes while training, then switch back.
  if event == "TRAINER_SHOW" then
    log("trainer opened; profit table visible:", panel and panel:IsVisible() or false)
    if panel and panel:IsShown() then
      panel.trainerHid = true
      selectTab(1)
    end
    return
  elseif event == "TRAINER_CLOSED" then
    if panel and panel.trainerHid then
      panel.trainerHid = nil
      selectTab(2)
    end
    return
  end

  if event == "PLAYER_LOGIN" then
    log("login: modern UI =", isModern(), "ProfessionsFrame =", ProfessionsFrame or "nil", "TradeSkillFrame =", TradeSkillFrame or "nil")
    createTabs("PLAYER_LOGIN")
  elseif event == "GET_ITEM_INFO_RECEIVED" then
    if itemNamePending then
      itemNamePending = false
      refreshSoon()
    end
  elseif event == "TRADE_SKILL_SHOW" then
    -- Blizzard may create the window after this event reaches us.
    createTabs("TRADE_SKILL_SHOW")
    C_Timer.After(0, function()
      createTabs("TRADE_SKILL_SHOW+0")
      rememberSoon()
      if not built then logEnvironment("profession opened but no host frame") end
      refreshSoon()
    end)
  elseif event == "TRADE_SKILL_UPDATE" or event == "TRADE_SKILL_LIST_UPDATE"
      or event == "TRADE_SKILL_DATA_SOURCE_CHANGED" or event == "BAG_UPDATE_DELAYED" then
    if event ~= "BAG_UPDATE_DELAYED" then
      forgetOpenRecipeIDs()
      craftLookup = nil
      updateTabsForOverview()
    end
    refreshSoon()
    if updateQueueWindow then updateQueueWindow() end
    if event ~= "BAG_UPDATE_DELAYED" then rememberSoon() end
  elseif event == "TRADE_SKILL_CLOSE" then
    craftLookup = nil
    if processing then stopProcessing("Stopped: the profession window was closed.") end
    C_Timer.After(0, syncQueueWindow)
  elseif event == "OWNED_AUCTIONS_UPDATED" then
    recordOwnedAuctions()
    refreshSoon()
  elseif event == "PLAYERBANKSLOTS_CHANGED" or event == "BANKFRAME_OPENED" then
    refreshSoon()
  elseif event == "AUCTION_HOUSE_SHOW" then
    -- Nothing is sent to the AH here: scans only run from the Profit tab, and
    -- your auctions are read when the AH's own Auctions tab loads them.
    if panel then updateScanButton() end
  elseif event == "AUCTION_HOUSE_CLOSED" then
    if panel then updateScanButton() end
  end
end)

SLASH_PROFESSIONPROFIT1 = "/pprofit"
SLASH_PROFESSIONPROFIT2 = "/pp"
SlashCmdList.PROFESSIONPROFIT = function(input)
  local cmd = (input or ""):match("^%s*(%S*)"):lower()
  if cmd == "scan" then
    startScan()
  elseif cmd == "queue" then
    toggleQueueWindow()
  elseif cmd == "reagents" then
    if popup then popup.closed = nil end
    if queueWin and queueWin:IsShown() then showReagentWindow() else msg("Open the craft queue to see its reagents.") end
  elseif cmd == "toast" then
    local arg = (input or ""):match("^%s*%S+%s+(%S+)")
    arg = arg and arg:lower()
    if arg == "test" then
      showToast("test", "Crafted Test Item", nil, 12345)
    elseif arg == "mail" then
      db.mailToastOff = not db.mailToastOff or nil
      msg("mail gold pop-up " .. (db.mailToastOff and "off." or "on."))
    else
      db.craftToastOff = not db.craftToastOff or nil
      msg("craft profit pop-up " .. (db.craftToastOff and "off." or "on."))
    end
  elseif cmd == "debug" then
    createTabs("/pp debug")
    logEnvironment("/pp debug")
    log("tabs built:", built, "last error:", lastError or "none")
    if DevLog then
      DevLog.Show()
      msg("diagnostics written to DevLog. /reload to save them to disk.")
    else
      msg("install/enable the DevLog addon to see diagnostics.")
    end
  else
    msg("commands:")
    print("  /pp scan - scan AH prices for the open profession")
    print("  /pp queue - show/hide the craft queue")
    print("  /pp reagents - show the queue's reagent window again after closing it")
    print("  /pp toast - turn the craft profit pop-up on/off (/pp toast test to preview)")
    print("  /pp toast mail - turn the mail gold pop-up on/off")
    print("  /pp debug - show diagnostics if the Profit tab is missing")
  end
end
