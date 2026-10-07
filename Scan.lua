-- ProfessionProfit: Scan AH: search the AH (through Auctionator) for the open profession's items.

local ADDON, ns = ...
local API, GREY, msg, log, ahOpen, professionName = ns.API, ns.GREY, ns.msg, ns.log, ns.ahOpen, ns.professionName
local expandAll, readRecipes = ns.expandAll, ns.readRecipes
local db
ns.onInit(function(saved) db = saved end)

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

local function markScanned(prof)
  db.lastScan = db.lastScan or {}
  db.lastScan[scanKey(prof)] = time()
end

local function updateScanButton()
  if not ns.panel then return end
  if API.IsScanningBooks() then return end -- the scan's progress shows instead
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

-- Step 2: one Auctionator multi-search for everything, so its price
-- database (sell prices, and the fallback for items without an order book)
-- is current too.
local function searchAuctionator(prof, items)
  local count, reason = API.Search(items, { force = true, caller = ADDON })
  log("scan", prof, count or 0, reason or "")
  if not count then
    msg(reason)
  elseif count > 0 then
    msg(("Searching %d item(s) in Auctionator's Shopping tab - the table updates as results come in."):format(count))
  end
  updateScanButton()
end

-- Scan AH button. Step 1: the order book (every listing) of each reagent
-- and stackable crafted item, so costs are what the amount you need really
-- costs, and undercuts show. Then step 2 above. Clicking again stops it.
local function startScan(retries)
  if API.IsScanningBooks() then
    API.CancelBookScan()
    return
  end
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
  local items = scanItems(recipes)
  local ids = {}
  for _, item in ipairs(items) do ids[#ids + 1] = item.id end
  local count, reason = API.ScanBooks(ids, {
    onProgress = function(done, total)
      if ns.panel then ns.panel.scanButton:SetText("Stop") end
      setStatus(("Reading order books %d/%d..."):format(done, total))
      if ns.refreshSoon then ns.refreshSoon() end
    end,
    onDone = function(why, done, total)
      log("order books", why, done, "/", total)
      if why == "done" then
        markScanned(prof)
        searchAuctionator(prof, items)
      else
        msg(("Order book scan %s after %d of %d items."):format(why == "closed" and "stopped (AH closed)" or "stopped", done, total))
        updateScanButton()
      end
      if ns.refreshSoon then ns.refreshSoon() end
    end,
  })
  log("scan", prof, "order books:", count or 0, reason or "")
  if not count then
    msg(reason)
    updateScanButton()
    return
  end
  if count == 0 then
    markScanned(prof)
    searchAuctionator(prof, items)
    return
  end
  if ns.panel then ns.panel.scanButton:SetText("Stop") end
  setStatus(("Reading order books 0/%d..."):format(count))
  msg(("Reading the order books of %d item(s), then searching everything in Auctionator."):format(count))
end
ns.startScan = startScan
