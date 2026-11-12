-- ProfessionProfit: Disenchant scan: search the AH for gear that's worth more
-- disenchanted than it costs to buy. Profit = the expected enchanting
-- materials at AH prices after the cut (as the Shuffle column) minus the
-- cheapest buyout.

local ADDON, ns = ...
local API, GREY, msg, log = ns.API, ns.GREY, ns.msg, ns.log
local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
local RequestLoadItemDataByID = (C_Item and C_Item.RequestLoadItemDataByID) or function() end
local db
ns.onInit(function(saved) db = saved end)

local ROWS, ROW = 16, 18
local STALL = 10 -- seconds without AH results before a scan settles for what it has
local win, scan
local results, listed = {}, 0

------------------------------------------------------------------------------
-- Pricing the browse results
------------------------------------------------------------------------------

-- Fill `results` with the profitable items in a browse list, best first.
-- Returns how many items are still loading their data.
local function priceResults(list)
  wipe(results)
  listed = 0
  local pending = 0
  for _, entry in ipairs(list) do
    local id = entry.itemKey and entry.itemKey.itemID
    if id and entry.minPrice and entry.minPrice > 0 then
      listed = listed + 1
      local value, missing = API.DisenchantValue(id)
      if value then
        local profit = math.floor(value * (1 - API.AH_CUT) - entry.minPrice + 0.5)
        if profit > 0 then
          local name, _, quality = GetItemInfo(id)
          results[#results + 1] = {
            itemID = id, browse = entry, name = name or ("item " .. id), quality = quality,
            price = entry.minPrice, qty = entry.totalQuantity or 1, value = value * (1 - API.AH_CUT),
            profit = profit, incomplete = missing > 0,
          }
        end
      elseif missing == "loading" then
        pending = pending + 1
        RequestLoadItemDataByID(id)
      end
    end
  end
  table.sort(results, function(a, b) return a.profit > b.profit end)
  return pending
end

------------------------------------------------------------------------------
-- The window
------------------------------------------------------------------------------

local updateWindow, startScan, stopScan

-- Buying lives in DisenchantBuy.lua. It updates scan rows as it buys down
-- the price, through these.
ns.deScanUpdate = function() if updateWindow then updateWindow() end end
ns.deScanRemove = function(r)
  for i, x in ipairs(results) do
    if x == r then table.remove(results, i) break end
  end
end
ns.deScanSort = function() table.sort(results, function(a, b) return a.profit > b.profit end) end

local function rowTooltip(row)
  local r = row.result
  if not r then return end
  GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
  GameTooltip:SetItemByID(r.itemID)
  GameTooltip:AddLine(" ")
  GameTooltip:AddDoubleLine("Cheapest buyout", API.Money(r.price), 0.8, 0.8, 0.8, 1, 1, 1)
  local _, _, yields = API.DisenchantValue(r.itemID)
  for _, y in ipairs(yields or {}) do
    if y.chance > 0 then
      local range = y.min == y.max and tostring(y.min) or (y.min .. "-" .. y.max)
      GameTooltip:AddDoubleLine(("  %s %s (%d%%)"):format(range, ns.itemName(y.id) or API.DE_MATS[y.id] or y.id,
        math.floor(y.chance * 100 + 0.5)), y.unit and API.Money(y.unit) .. " ea" or "no price", 0.8, 0.8, 0.8, 1, 1, 1)
    end
  end
  GameTooltip:AddDoubleLine("Disenchanted, after AH cut", API.Money(r.value), 0.8, 0.8, 0.8, 1, 1, 1)
  GameTooltip:AddDoubleLine("Profit", API.Money(r.profit) .. (r.incomplete and " *" or ""), 1, 1, 1, 0.2, 1, 0.2)
  if r.incomplete then GameTooltip:AddLine("* a material has no price, so this is low.", 0.6, 0.6, 0.6, true) end
  GameTooltip:AddLine(" ")
  if r.bought then GameTooltip:AddDoubleLine("Bought", r.bought, 0.8, 0.8, 0.8, 1, 1, 1) end
  GameTooltip:AddLine(r.planned and "Click: take it off the buy list." or "Click: add it to the buy list (in the Disenchant planner).", 0.6, 0.6, 0.6, true)
  GameTooltip:AddLine("Right-click: queue one you already own to disenchant at this price.", 0.6, 0.6, 0.6, true)
  GameTooltip:Show()
end

local function rowClick(row, button)
  local r = row.result
  if not r then return end
  if button == "RightButton" then
    ns.queueDisenchantItem(r.itemID, r.name, 1, r.price, r.profit)
    msg(("Queued %s to disenchant (projected %s)."):format(r.name, API.Money(r.profit)))
    return
  end
  if r.planned then ns.removeFromBuyList(r) else ns.addToBuyList(r) end
end

local function createRow(parent, i)
  local row = CreateFrame("Button", nil, parent)
  row:SetHeight(ROW)
  row:SetPoint("TOPLEFT", 0, -(i - 1) * ROW)
  row:SetPoint("RIGHT")
  row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
  local function cell(width, justify)
    local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetJustifyH(justify)
    fs:SetWordWrap(false)
    if width then fs:SetWidth(width) end
    return fs
  end
  row.profit = cell(70, "RIGHT")
  row.profit:SetPoint("RIGHT", -2, 0)
  row.value = cell(70, "RIGHT")
  row.value:SetPoint("RIGHT", row.profit, "LEFT", -6, 0)
  row.price = cell(70, "RIGHT")
  row.price:SetPoint("RIGHT", row.value, "LEFT", -6, 0)
  row.name = cell(nil, "LEFT")
  row.name:SetPoint("LEFT", 4, 0)
  row.name:SetPoint("RIGHT", row.price, "LEFT", -6, 0)
  row:SetScript("OnEnter", rowTooltip)
  row:SetScript("OnLeave", GameTooltip_Hide)
  row:SetScript("OnClick", rowClick)
  return row
end

local function createWindow()
  win = CreateFrame("Frame", "ProfessionProfitDisenchantScan", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
  win:Hide()
  win:SetSize(400, 92 + ROWS * ROW)
  win:SetFrameStrata("HIGH")
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
  local close = CreateFrame("Button", nil, win, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", -2, -2)
  local title = win:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  title:SetPoint("TOPLEFT", 14, -12)
  title:SetText("Disenchant Scan")

  win.button = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
  win.button:SetSize(80, 22)
  win.button:SetPoint("TOPRIGHT", -32, -8)
  win.button:SetScript("OnClick", function() if scan then stopScan() else startScan() end end)
  local plan = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
  plan:SetSize(70, 22)
  plan:SetPoint("RIGHT", win.button, "LEFT", -4, 0)
  plan:SetText("Planner")
  plan:SetScript("OnClick", function() ns.toggleDisenchantPlanner() end)

  local header = CreateFrame("Frame", nil, win)
  header:SetPoint("TOPLEFT", 10, -38)
  header:SetPoint("RIGHT", -30, 0)
  header:SetHeight(16)
  local function head(text, x)
    local fs = header:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetPoint("RIGHT", header, "RIGHT", x, 0)
    fs:SetText(text)
  end
  head("Profit", -2)
  head("DE value", -78)
  head("Buyout", -154)
  local item = header:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  item:SetPoint("LEFT", 4, 0)
  item:SetText("Item")

  local scroll = CreateFrame("ScrollFrame", "ProfessionProfitDisenchantScanScroll", win, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -2)
  scroll:SetPoint("RIGHT", -30, 0)
  scroll:SetHeight(ROWS * ROW)
  win.content = CreateFrame("Frame", nil, scroll)
  win.content:SetSize(1, 1)
  scroll:SetScrollChild(win.content)
  scroll:SetScript("OnSizeChanged", function(_, width) win.content:SetWidth(width) end)
  win.rows = {}

  win.status = win:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  win.status:SetPoint("BOTTOMLEFT", 14, 12)
  win.status:SetPoint("RIGHT", -14, 0)
  win.status:SetJustifyH("LEFT")
  win.status:SetWordWrap(true)

  win:SetScript("OnHide", function() if scan then stopScan() end end)
end

updateWindow = function()
  if not win then return end
  win.button:SetText(scan and "Stop" or "Scan")
  win.content:SetHeight(math.max(#results * ROW, 1))
  for i, r in ipairs(results) do
    local row = win.rows[i] or createRow(win.content, i)
    win.rows[i] = row
    row.result = r
    local color = r.quality and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[r.quality]
    local name = (color and color.hex or "") .. r.name .. "|r"
    if r.planned then name = "|cffffd100+|r " .. name end
    if r.bought then name = name .. " |cff40ff40bought " .. r.bought .. "|r" end
    row.name:SetText(name)
    row.price:SetText(API.Money(r.price))
    row.value:SetText(API.Money(r.value))
    row.profit:SetText("|cff33ff33" .. API.Money(r.profit) .. "|r" .. (r.incomplete and "|cffff6666*|r" or ""))
    row:Show()
  end
  for i = #results + 1, #win.rows do
    win.rows[i]:Hide()
    win.rows[i].result = nil
  end
  if scan and scan.phase == "mats" then
    win.status:SetText(("Pricing enchanting materials %d/%d..."):format(scan.matsDone or 0, scan.matsTotal or 0))
  elseif scan then
    win.status:SetText(("Scanning uncommon and better weapons and armor: %d loaded..."):format(scan.loaded or 0))
  elseif scan == nil and win.done then
    win.status:SetText(("%d of %d listed items are worth more disenchanted. Click one to add it to the buy list.")
      :format(#results, listed))
  else
    win.status:SetText("Scan the AH for gear that's worth more disenchanted than its buyout.")
  end
end

------------------------------------------------------------------------------
-- Scanning: one browse search for uncommon+ weapons and armor, loading
-- every page of results, then pricing them.
------------------------------------------------------------------------------

local sending = false

local function query()
  local F, Q, C = Enum.AuctionHouseFilter, Enum.AuctionHouseSortOrder, Enum.ItemClass
  return {
    searchString = "",
    sorts = { { sortOrder = Q.Price, reverseSort = false } },
    filters = { F.UncommonQuality, F.RareQuality, F.EpicQuality },
    itemClassFilters = { { classID = C and C.Weapon or 2 }, { classID = C and C.Armor or 4 } },
  }
end

local function ready()
  return not C_AuctionHouse.IsThrottledMessageSystemReady or C_AuctionHouse.IsThrottledMessageSystemReady()
end

local function finish(reason)
  local mine = scan
  if not mine then return end
  scan = nil
  if mine.phase == "mats" and API.IsQuickScanning() then API.CancelQuickScan() updateWindow() return end -- no gear loaded yet
  local list = C_AuctionHouse.GetBrowseResults() or {}
  local function price(tries)
    local pending = priceResults(list)
    if pending > 0 and tries < 6 then
      C_Timer.After(0.5, function() price(tries + 1) end)
    end
    win.done = true
    updateWindow()
  end
  price(0)
  log("disenchant scan", reason, #list, "results")
end

-- Ask for the next page (or finish when every page is in).
local function step()
  local mine = scan
  if not mine then return end
  mine.last = GetTime()
  mine.loaded = #(C_AuctionHouse.GetBrowseResults() or {})
  updateWindow()
  if C_AuctionHouse.HasFullBrowseResults() then finish("done") return end
  if ready() then C_AuctionHouse.RequestMoreBrowseResults() end
end

startScan = function()
  if not (AuctionHouseFrame and AuctionHouseFrame:IsShown()) then msg("Open the auction house first.") return end
  if API.IsScanningBooks() or (API.IsQuickScanning and API.IsQuickScanning()) then
    msg("Another AH scan is running - try again when it's done.")
    return
  end
  if not win then createWindow() end
  win:Show()
  wipe(results)
  win.done = nil
  scan = { last = GetTime(), loaded = 0, sent = false, phase = "mats" }
  local mine = scan
  local function send()
    if scan ~= mine then return end
    mine.phase = "gear"
    if not ready() then C_Timer.After(0.25, send) return end
    sending = true
    C_AuctionHouse.SendBrowseQuery(query())
    sending = false
    scan.sent, scan.last = true, GetTime()
  end
  -- First the enchanting materials (fresh prices for the disenchant values),
  -- then the gear.
  local mats = {}
  for id in pairs(API.DE_MATS) do mats[#mats + 1] = id end
  local count = API.QuickScan(mats, {
    onProgress = function(n, total)
      if scan ~= mine then return end
      mine.last, mine.matsDone, mine.matsTotal = GetTime(), n, total
      updateWindow()
    end,
    onDone = function() send() end,
  })
  if not count or count == 0 then send() end
  -- Settle for what's loaded when results stop coming.
  local function watch()
    if scan ~= mine then return end
    if GetTime() - mine.last > STALL then finish("stalled") return end
    C_Timer.After(1, watch)
  end
  C_Timer.After(1, watch)
  updateWindow()
end

stopScan = function()
  finish("stopped")
end

-- Another search replaces ours: price what we have.
if C_AuctionHouse and C_AuctionHouse.SendBrowseQuery then
  hooksecurefunc(C_AuctionHouse, "SendBrowseQuery", function()
    if not sending and scan and scan.sent then finish("replaced") end
  end)
end

local function toggleWindow()
  if not win then createWindow() end
  if win:IsShown() then win:Hide() return end
  win:ClearAllPoints()
  if ns.panel and ns.panel:IsVisible() then
    win:SetPoint("TOPLEFT", ns.panel, "TOPRIGHT", 4, 0)
  elseif AuctionHouseFrame and AuctionHouseFrame:IsShown() then
    win:SetPoint("TOPLEFT", AuctionHouseFrame, "TOPRIGHT", 4, 0)
  else
    win:SetPoint("CENTER")
  end
  win:Show()
  updateWindow()
end
ns.toggleDisenchantScan = toggleWindow
ns.startDisenchantScan = function()
  if not win or not win:IsShown() then toggleWindow() end
  startScan()
end

local events = CreateFrame("Frame")
for _, event in ipairs({ "AUCTION_HOUSE_CLOSED", "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED",
  "AUCTION_HOUSE_BROWSE_RESULTS_ADDED", "AUCTION_HOUSE_THROTTLED_SYSTEM_READY" }) do
  pcall(events.RegisterEvent, events, event)
end
events:SetScript("OnEvent", function(_, event)
  if not db then return end
  if event == "AUCTION_HOUSE_CLOSED" then
    if scan then finish("closed") end
  elseif scan and scan.sent then
    step() -- results arrived, or the AH can take the next request
  end
end)
