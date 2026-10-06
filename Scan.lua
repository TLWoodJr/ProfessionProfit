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
ns.startScan = startScan
