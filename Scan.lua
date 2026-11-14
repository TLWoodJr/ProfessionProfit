-- ProfessionProfit: Scan AH: search the AH (through Auctionator) for the open profession's items.

local ADDON, ns = ...
local API, GREY, msg, log, ahOpen, professionName = ns.API, ns.GREY, ns.msg, ns.log, ns.ahOpen, ns.professionName
local expandAll, readRecipes = ns.expandAll, ns.readRecipes
local db
ns.onInit(function(saved) db = saved end)

-- Every crafted item, reagent and material the crafted items disenchant
-- into (for the Shuffle column) to search for: { id, name }.
local function scanItems(recipes)
  local items, mats = {}, {}
  for _, recipe in ipairs(recipes) do
    if recipe.productID then
      items[#items + 1] = { id = recipe.productID, name = recipe.productName }
      for _, y in ipairs(API.DisenchantYields(recipe.productID) or {}) do
        if y.chance > 0 and not mats[y.id] then
          mats[y.id] = true
          items[#items + 1] = { id = y.id, name = ns.itemName(y.id) or API.DE_MATS[y.id] }
        end
      end
    end
    for _, reagent in ipairs(recipe.reagents) do
      if reagent.id then items[#items + 1] = { id = reagent.id, name = reagent.name } end
    end
  end
  -- Reagents your other professions or characters can craft: their reagents
  -- too (any depth), to price crafting them.
  local known, seen, done = ns.withKnown({}), {}, {}
  for _, item in ipairs(items) do seen[item.id] = true end
  local i = 1
  while i <= #items do
    local sub = known[items[i].id]
    if sub and not done[sub.recipeID] then
      done[sub.recipeID] = true
      for _, reagent in ipairs(sub.reagents) do
        if not seen[reagent.id] then
          seen[reagent.id] = true
          items[#items + 1] = { id = reagent.id, name = reagent.name or ns.itemName(reagent.id) }
        end
      end
    end
    i = i + 1
  end
  return items
end

local function setStatus(text)
  if ns.panel then ns.panel.status:SetText(text or "") end
end


-- Last completed scan per character + profession, saved across sessions.
local function scanKey(prof)
  return (UnitName("player") or "?") .. "-" .. (GetRealmName and GetRealmName() or "?") .. ":" .. prof
end

local function lastScanTime(prof)
  db.lastScan = db.lastScan or {}
  return db.lastScan[scanKey(prof)]
end

-- Is the crafted item missing from the AH right now? Auctionator didn't
-- see it today, though this profession was scanned today. False when it
-- can't tell (not scanned today, or the price source doesn't say when it
-- last saw an item - TSM).
local function today(t) return date("%Y%m%d", t) == date("%Y%m%d") end
local function notListed(recipe)
  local id = recipe.productID
  if not id or recipe.isEnchant then return false end
  local source = API.ActiveSource()
  if not (source and source.hasAge) then return false end
  local prof = professionName()
  local last = prof and lastScanTime(prof)
  if not (last and today(last)) then return false end
  return API.PriceAge(id) ~= 0
end
ns.notListed = notListed

local function markScanned(prof)
  db.lastScan = db.lastScan or {}
  db.lastScan[scanKey(prof)] = time()
end

local function updateScanButton()
  if not ns.panel then return end
  ns.panel.scanButton:SetText("Scan AH")
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
ns.updateScanButton = updateScanButton

-- Scan AH button: one Auctionator multi-search for every reagent and
-- crafted item of the open profession. Auctionator stores the prices and
-- the table updates as they come in.
local function startScan(retries)
  if not ahOpen() then
    msg("Open the auction house first.")
    return
  end
  local source = API.ActiveSource()
  if source and source.key ~= "auctionator" then
    msg(("Prices come from %s, which Scan AH can't update (it searches through Auctionator). Update TSM's prices with TSM itself, or pick Auctionator with the cog at the bottom left."):format(source.name))
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
  local count, reason = API.Search(scanItems(recipes), { force = true, caller = ADDON, noVendor = ns.priceOpts().noVendor })
  log("scan", prof, count or 0, reason or "")
  if not count then
    msg(reason)
  else
    markScanned(prof)
    if count > 0 then
      msg(("Searching %d item(s) in Auctionator's Shopping tab - the table updates as results come in."):format(count))
    end
  end
  updateScanButton()
end
ns.startScan = startScan
