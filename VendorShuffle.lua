-- ProfessionProfit: Vendor shuffle window. For the queued items marked V
-- (sell to a vendor), the whole plan start to finish - buy the reagents (AH
-- and vendor), craft the reagents, craft the items, sell them to a vendor -
-- and a price walkup: a waterfall from what the reagents cost to what the
-- vendor pays, ending at the profit. Numbers come from ns.vendorShufflePlan.

local ADDON, ns = ...
local API, RED, GREY, GREEN, msg = ns.API, ns.RED, ns.GREY, ns.GREEN, ns.msg
local db
ns.onInit(function(saved) db = saved end)

local WIDTH = 480
local LINE = 16
local SCROLL_HEIGHT = 300
local BAR_WIDTH = 140
local GOLD = "|cffffd100"

local win

local function money(copper) return API.Money(copper) end
local function signed(copper)
  if copper > 0 then return GREEN .. "+|r" .. money(copper) end
  return money(copper)
end

------------------------------------------------------------------------------
-- The plan (scrolling list of steps)
------------------------------------------------------------------------------

local function getLine(i)
  local line = win.lines[i]
  if line then return line end
  line = CreateFrame("Frame", nil, win.content)
  line:SetHeight(LINE)
  line:SetPoint("TOPLEFT", 0, -(i - 1) * LINE)
  line:SetPoint("RIGHT")
  line.left = line:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  line.left:SetPoint("LEFT", 4, 0)
  line.left:SetWidth(210)
  line.left:SetJustifyH("LEFT")
  line.left:SetWordWrap(false)
  line.mid = line:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  line.mid:SetPoint("LEFT", 218, 0)
  line.mid:SetWidth(120)
  line.mid:SetJustifyH("LEFT")
  line.mid:SetWordWrap(false)
  line.right = line:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  line.right:SetPoint("RIGHT", -4, 0)
  line.right:SetJustifyH("RIGHT")
  line.right:SetWordWrap(false)
  win.lines[i] = line
  return line
end

-- Fills the list from rows: { left, mid, right, header = true }.
local function showLines(rows)
  for i, row in ipairs(rows) do
    local line = getLine(i)
    line.left:SetFontObject(row.header and "GameFontNormal" or "GameFontHighlightSmall")
    line.left:SetWidth(row.header and 300 or 210)
    line.left:SetText(row.left or "")
    line.mid:SetText(row.mid or "")
    line.right:SetText(row.right or "")
    line:Show()
  end
  for i = #rows + 1, #win.lines do win.lines[i]:Hide() end
  win.content:SetHeight(math.max(#rows * LINE, 1))
end

local function planRows(plan)
  local rows = {}
  local function add(left, mid, right) rows[#rows + 1] = { left = left, mid = mid, right = right } end
  local function header(text, right)
    if #rows > 0 then add() end
    rows[#rows + 1] = { header = true, left = text, right = right }
  end

  header("1. Buy reagents", plan.vendorCost > 0 and (GREY .. "AH|r " .. money(plan.ahCost) .. GREY .. "  vendor|r "
    .. money(plan.vendorCost)) or money(plan.ahCost))
  if #plan.buys == 0 then add(GREY .. "Nothing to buy.|r") end
  for _, buy in ipairs(plan.buys) do
    local left = buy.count .. "x " .. buy.name
    if buy.have > 0 then left = left .. GREY .. (" (have %d)|r"):format(math.min(buy.have, buy.count)) end
    local mid = buy.unit and ((buy.src == "vendor" and "vendor " or "AH ") .. money(buy.unit) .. " ea") or ""
    add(left, GREY .. mid .. "|r", buy.total and money(buy.total) or (RED .. "no price|r"))
  end

  header("2. Craft reagents", plan.saving ~= 0 and (plan.saving > 0
    and (GREEN .. "saves " .. money(plan.saving) .. "|r") or (RED .. "costs " .. money(-plan.saving) .. " more|r")) or nil)
  if #plan.reagentCrafts == 0 then
    add(GREY .. (db.skipReagentCrafts and "Off (Craft reagents is unticked) - every reagent is bought."
      or "None - every reagent is bought.") .. "|r")
  end
  for _, entry in ipairs(plan.reagentCrafts) do
    add(("  "):rep((entry.depth or 1) - 1) .. entry.count .. "x " .. entry.name,
      GREY .. "makes " .. entry.count * (entry.made or 1) .. "|r",
      GREY .. "for " .. table.concat(entry.usedBy or {}, ", ") .. "|r")
  end

  header("3. Craft")
  for _, main in ipairs(plan.mains) do
    local progress
    if main.done then
      progress = (main.done >= main.count and GREEN or GOLD) .. ("done %d/%d"):format(main.done, main.count) .. "|r"
    end
    add(main.count .. "x " .. main.name, GREY .. "makes " .. main.count * (main.made or 1) .. "|r", progress)
  end

  header("4. Sell to a vendor", money(plan.salesTotal))
  for _, sale in ipairs(plan.sales) do
    add(sale.units .. "x " .. sale.name, sale.unit and (GREY .. money(sale.unit) .. " ea|r") or "",
      sale.total and money(sale.total) or (RED .. "vendor won't buy|r"))
  end
  return rows
end

------------------------------------------------------------------------------
-- Locking: the plan you commit to. A plain copy of the plan, saved per
-- character in db.vendorShuffleLock, shown instead of the live plan until
-- you Replan, with progress counted against it.
------------------------------------------------------------------------------

-- A plain copy of ns.vendorShufflePlan()'s plan (no queue entries in it).
local function snapshot(plan)
  local copy = {
    time = time(), ahCost = plan.ahCost, vendorCost = plan.vendorCost, unpriced = plan.unpriced,
    salesTotal = plan.salesTotal, unsold = plan.unsold, net = plan.net, outOfPocket = plan.outOfPocket,
    saving = plan.saving, ahNet = plan.ahNet, incomplete = plan.incomplete,
    buys = {}, reagentCrafts = {}, mains = {}, sales = {},
  }
  for i, b in ipairs(plan.buys) do
    copy.buys[i] = { id = b.id, name = b.name, count = b.count, have = b.have, src = b.src, unit = b.unit, total = b.total }
  end
  for i, e in ipairs(plan.reagentCrafts) do
    local usedBy = {}
    for j, name in ipairs(e.usedBy or {}) do usedBy[j] = name end
    copy.reagentCrafts[i] = { recipeID = e.recipeID, name = e.name, count = e.count, made = e.made, depth = e.depth, usedBy = usedBy }
  end
  for i, m in ipairs(plan.mains) do
    copy.mains[i] = { recipeID = m.recipeID, productID = m.productID, name = m.name, count = m.count, made = m.made }
  end
  for i, s in ipairs(plan.sales) do
    copy.sales[i] = { name = s.entry.productID and ns.itemName(s.entry.productID) or s.entry.name,
      units = s.units, unit = s.unit, total = s.total }
  end
  copy.seconds, copy.secondsGuessed = ns.queueSeconds(copy.reagentCrafts)
  local mainSeconds, mainGuessed = ns.queueSeconds(copy.mains)
  copy.seconds, copy.secondsGuessed = copy.seconds + mainSeconds, copy.secondsGuessed or mainGuessed
  return copy
end

-- Crafting time still ahead for the marked items (the live plan): seconds, guessed.
local function secondsLeft()
  local plan = ns.vendorShufflePlan()
  local reagents, g1 = ns.queueSeconds(plan.reagentCrafts)
  local mains, g2 = ns.queueSeconds(plan.mains)
  return reagents + mains, g1 or g2
end

local function lockStore()
  db.vendorShuffleLock = db.vendorShuffleLock or {}
  return db.vendorShuffleLock
end

local function getLock() return db and lockStore()[ns.charKey()] end

-- Lock the current plan (unless one is locked already). quiet: no chat.
local function lockPlan(quiet)
  if getLock() then return end
  local plan = ns.vendorShufflePlan()
  if #plan.mains == 0 then return end
  local lock = snapshot(plan)
  for _, main in ipairs(lock.mains) do main.done = 0 end -- progress shows on a locked plan only
  lockStore()[ns.charKey()] = lock
  if not quiet then msg("Vendor shuffle plan locked - the overview stays as it is now. Replan to update it.") end
  if ns.updateVendorShuffle then ns.updateVendorShuffle() end
end
ns.lockVendorShuffle = lockPlan

local function unlockPlan()
  if not getLock() then return end
  lockStore()[ns.charKey()] = nil
  if ns.updateVendorShuffle then ns.updateVendorShuffle() end
end
ns.unlockVendorShuffle = unlockPlan

-- What vendor-marked crafts made, per character (itemID -> true): Sell all
-- sells these even after their queue entry is used up.
local function toSellStore()
  db.vendorToSell = db.vendorToSell or {}
  local key = ns.charKey()
  db.vendorToSell[key] = db.vendorToSell[key] or {}
  return db.vendorToSell[key]
end

-- A queued vendor item was crafted (Crafting.lua): count it on the plan.
function ns.vendorShuffleCrafted(recipeID, productID)
  if productID then toSellStore()[productID] = true end
  local lock = getLock()
  if not lock then return end
  for _, main in ipairs(lock.mains) do
    if main.recipeID == recipeID then
      main.done = (main.done or 0) + 1
      return
    end
  end
end

-- Progress against a locked plan: done / total crafts, and whether the
-- queue no longer matches what's left of the plan (stale) or every planned
-- craft is done (complete).
local function trackLock(lock)
  local current = {}
  for _, main in ipairs(ns.craftQueue()) do
    if main.vendor then current[main.recipeID] = (current[main.recipeID] or 0) + main.count end
  end
  local stale, complete, done, total = false, true, 0, 0
  local planned = {}
  for _, main in ipairs(lock.mains) do
    planned[main.recipeID] = true
    main.done = main.done or 0
    if (current[main.recipeID] or 0) ~= math.max(main.count - main.done, 0) then stale = true end
    if main.done < main.count then complete = false end
    done, total = done + math.min(main.done, main.count), total + main.count
  end
  for recipeID in pairs(current) do
    if not planned[recipeID] then stale = true end
  end
  return stale, complete, done, total
end

------------------------------------------------------------------------------
-- Sell all: at a merchant, sells everything in your bags that a vendor-marked
-- craft makes (marked in the queue, on the locked plan, or crafted while
-- marked). Items another queued craft uses as a reagent are kept.
------------------------------------------------------------------------------

local GetNumSlots = (C_Container and C_Container.GetContainerNumSlots) or GetContainerNumSlots
local UseContainerItem = (C_Container and C_Container.UseContainerItem) or UseContainerItem
local SELL_INTERVAL = 0.2

local function merchantOpen() return MerchantFrame and MerchantFrame:IsShown() end

local function slotInfo(bag, slot)
  if C_Container and C_Container.GetContainerItemInfo then
    local info = C_Container.GetContainerItemInfo(bag, slot)
    if info then return info.itemID, info.stackCount or 1, info.isLocked, info.hasNoValue end
    return
  end
  local _, count, locked, _, _, _, link, _, noValue, itemID = GetContainerItemInfo(bag, slot)
  return itemID or ns.idFromLink(link), count or 1, locked, noValue
end

-- itemID -> true for what's to be sold; itemID -> true for what's kept as a reagent.
local function sellIDs()
  local ids, kept = {}, {}
  for id in pairs(toSellStore()) do ids[id] = true end
  local lock = getLock()
  for _, main in ipairs(lock and lock.mains or {}) do
    if main.productID then ids[main.productID] = true end
  end
  for _, entry in ipairs(ns.craftQueue()) do
    if entry.vendor and entry.productID then ids[entry.productID] = true end
  end
  for _, entry in ipairs(ns.craftQueue()) do
    for _, reagent in ipairs(entry.reagents or {}) do
      if ids[reagent.id] then ids[reagent.id], kept[reagent.id] = nil, true end
    end
  end
  return ids, kept
end

-- The bag slots to sell: { bag, slot, id, count }, the vendor total, and
-- itemID -> { name, count, total } for the confirmation.
local function sellSlots()
  local ids, kept = sellIDs()
  local slots, total, byItem = {}, 0, {}
  for bag = 0, NUM_BAG_SLOTS or 4 do
    for slot = 1, GetNumSlots(bag) or 0 do
      local id, count, locked, noValue = slotInfo(bag, slot)
      if id and ids[id] and not locked and not noValue then
        local unit = API.VendorSellPrice(id) or 0
        if unit > 0 then
          slots[#slots + 1] = { bag, slot, id, count }
          total = total + unit * count
          local item = byItem[id] or { name = ns.itemName(id) or ("item " .. id), count = 0, total = 0 }
          item.count, item.total = item.count + count, item.total + unit * count
          byItem[id] = item
        end
      end
    end
  end
  return slots, total, byItem, kept
end

local selling -- { slots, next, startMoney } while selling

local function finishSelling(reason)
  if not selling then return end
  local earned = GetMoney() - selling.startMoney
  msg(("Sold to the vendor: %s%s."):format(money(math.max(earned, 0)), reason and (" (" .. reason .. ")") or ""))
  selling = nil
  -- Forget crafted items once none are left in your bags.
  local store = toSellStore()
  for id in pairs(store) do
    if (ns.GetItemCount(id, false) or 0) == 0 then store[id] = nil end
  end
  if ns.updateVendorShuffle then ns.updateVendorShuffle() end
end

local function sellNext()
  if not selling then return end
  if not merchantOpen() then return finishSelling("the merchant closed") end
  local s = selling.slots[selling.next]
  if not s then
    -- Let the last sale's gold arrive before adding it up.
    return C_Timer.After(0.5, function() finishSelling() end)
  end
  selling.next = selling.next + 1
  local id, _, locked = slotInfo(s[1], s[2])
  if id == s[3] and not locked then UseContainerItem(s[1], s[2]) end
  C_Timer.After(SELL_INTERVAL, sellNext)
end

local function sellAll()
  if selling then return end
  if not merchantOpen() then msg("Open a merchant to sell.") return end
  local slots, total, byItem, kept = sellSlots()
  local keptNames = {}
  for id in pairs(kept) do
    if (ns.GetItemCount(id, false) or 0) > 0 then keptNames[#keptNames + 1] = ns.itemName(id) or ("item " .. id) end
  end
  if #slots == 0 then
    msg("Nothing to sell: none of what the vendor-marked crafts make is in your bags."
      .. (#keptNames > 0 and (" Kept as reagents: " .. table.concat(keptNames, ", ") .. ".") or ""))
    return
  end
  local lines = {}
  for _, item in pairs(byItem) do
    lines[#lines + 1] = ("%dx %s  %s"):format(item.count, item.name, money(item.total))
  end
  table.sort(lines)
  StaticPopupDialogs.PROFESSIONPROFIT_VENDOR_SELL = StaticPopupDialogs.PROFESSIONPROFIT_VENDOR_SELL or {
    text = "%s", button1 = SELL_ALL or "Sell", button2 = CANCEL or "Cancel",
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
  }
  StaticPopupDialogs.PROFESSIONPROFIT_VENDOR_SELL.OnAccept = function()
    if selling or not merchantOpen() then return end
    ns.log("vendor sell", #slots, "stacks", money(total))
    selling = { slots = slots, next = 1, startMoney = GetMoney() }
    sellNext()
  end
  local text = ("ProfessionProfit: sell to the vendor?\n\n%s\n\nTotal: %s"):format(table.concat(lines, "\n"), money(total))
  if #slots > 12 then
    text = text .. "\n" .. GREY .. "Only the last 12 stacks can be bought back.|r"
  end
  if #keptNames > 0 then
    text = text .. "\n" .. GREY .. "Kept as reagents for the queue: " .. table.concat(keptNames, ", ") .. "|r"
  end
  StaticPopup_Show("PROFESSIONPROFIT_VENDOR_SELL", text)
end

-- Merchant opened or closed (Events.lua).
function ns.vendorMerchantChanged()
  if not merchantOpen() then
    if StaticPopup_Hide then StaticPopup_Hide("PROFESSIONPROFIT_VENDOR_SELL") end
    if selling then finishSelling("the merchant closed") end
  end
  if win and win.sellButton then win.sellButton:SetEnabled(merchantOpen() and true or false) end
end

------------------------------------------------------------------------------
-- The price walkup (waterfall)
------------------------------------------------------------------------------

local function createWalkRow(parent, i)
  local row = CreateFrame("Frame", nil, parent)
  row:SetHeight(18)
  row:SetPoint("TOPLEFT", 0, -22 - (i - 1) * 20)
  row:SetPoint("RIGHT")
  row.label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  row.label:SetPoint("LEFT", 4, 0)
  row.label:SetWidth(100)
  row.label:SetJustifyH("LEFT")
  row.track = CreateFrame("Frame", nil, row)
  row.track:SetPoint("LEFT", 108, 0)
  row.track:SetSize(BAR_WIDTH, 14)
  local bg = row.track:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  bg:SetColorTexture(1, 1, 1, 0.04)
  row.bar = row.track:CreateTexture(nil, "ARTWORK")
  row.bar:SetHeight(14)
  row.zero = row.track:CreateTexture(nil, "OVERLAY")
  row.zero:SetSize(1, 18)
  row.zero:SetColorTexture(1, 1, 1, 0.35)
  row.delta = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  row.delta:SetPoint("LEFT", row.track, "RIGHT", 6, 0)
  row.delta:SetWidth(100)
  row.delta:SetJustifyH("RIGHT")
  row.running = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  row.running:SetPoint("RIGHT", -4, 0)
  row.running:SetWidth(100)
  row.running:SetJustifyH("RIGHT")
  return row
end

-- steps: { label, from, to, kind = "cost" | "income" | "total" }
local function showWalk(steps)
  local lo, hi = 0, 0
  for _, s in ipairs(steps) do
    lo, hi = math.min(lo, s.from, s.to), math.max(hi, s.from, s.to)
  end
  local span = hi - lo
  local function x(v) return span > 0 and (v - lo) / span * BAR_WIDTH or 0 end
  for i, s in ipairs(steps) do
    local row = win.walkRows[i] or createWalkRow(win.walk, i)
    win.walkRows[i] = row
    row.label:SetText(s.kind == "total" and (GOLD .. s.label .. "|r") or s.label)
    local left, right = x(math.min(s.from, s.to)), x(math.max(s.from, s.to))
    row.bar:ClearAllPoints()
    row.bar:SetPoint("LEFT", row.track, "LEFT", left, 0)
    row.bar:SetWidth(math.max(right - left, 1))
    if s.kind == "cost" then row.bar:SetColorTexture(0.85, 0.3, 0.25, 0.9)
    elseif s.kind == "income" then row.bar:SetColorTexture(0.25, 0.8, 0.3, 0.9)
    elseif s.to >= 0 then row.bar:SetColorTexture(1, 0.82, 0, 0.95)
    else row.bar:SetColorTexture(1, 0.3, 0.3, 0.95) end
    row.zero:ClearAllPoints()
    row.zero:SetPoint("CENTER", row.track, "LEFT", x(0), 0)
    local delta = s.to - s.from
    row.delta:SetText(s.kind == "total" and "" or signed(delta))
    row.running:SetText(s.kind == "total" and ((s.to >= 0 and GREEN or RED) .. money(s.to) .. "|r") or (GREY .. money(s.to) .. "|r"))
    row:Show()
  end
  for i = #steps + 1, #win.walkRows do win.walkRows[i]:Hide() end
end

------------------------------------------------------------------------------
-- Window
------------------------------------------------------------------------------

local function update()
  if not (win and win:IsShown()) then return end
  local lock = getLock()
  local plan = lock or snapshot(ns.vendorShufflePlan())
  local n = #plan.mains
  local status
  if lock then
    local stale, complete, done, total = trackLock(lock)
    status = GOLD .. "Locked " .. date("%H:%M", lock.time) .. "|r" .. GREY .. (" - %d of %d crafts done"):format(done, total) .. "|r"
    if complete then status = GREEN .. "Done|r" .. GREY .. (" - all %d crafts from the plan locked at %s."):format(total, date("%H:%M", lock.time)) .. "|r" end
    if stale then status = status .. "  " .. RED .. "The queue has changed - Replan to update.|r" end
    win.lockButton:SetText("Replan")
  else
    status = n == 0 and (GREY .. "Nothing marked to sell to a vendor.|r")
      or (GREY .. ("Planning: %d item%s - locks when you press Craft all%s|r"):format(n, n == 1 and "" or "s",
        plan.incomplete and (" - " .. RED .. "some prices missing|r") or ""))
    win.lockButton:SetText("Lock plan")
  end
  win.subtitle:SetText(status)
  win.lockButton:SetEnabled(lock ~= nil or n > 0)
  win.empty:SetShown(n == 0)
  if n == 0 then
    showLines({})
    showWalk({})
    win.summary:SetText("")
    return
  end
  showLines(planRows(plan))

  local after = -plan.ahCost
  local steps = { { label = "AH reagents", from = 0, to = after, kind = "cost" } }
  if plan.vendorCost > 0 then
    steps[#steps + 1] = { label = "Vendor reagents", from = after, to = after - plan.vendorCost, kind = "cost" }
    after = after - plan.vendorCost
  end
  steps[#steps + 1] = { label = "Vendor sale", from = after, to = after + plan.salesTotal, kind = "income" }
  steps[#steps + 1] = { label = "Profit", from = 0, to = plan.net, kind = "total" }
  showWalk(steps)

  local cost = plan.ahCost + plan.vendorCost
  local crafts = 0
  for _, main in ipairs(plan.mains) do crafts = crafts + main.count end
  local parts = {}
  if cost > 0 then parts[#parts + 1] = ("Margin %d%%"):format(math.floor(plan.net / cost * 100 + 0.5)) end
  if crafts > 0 then parts[#parts + 1] = money(math.floor(plan.net / crafts)) .. " per craft" end
  parts[#parts + 1] = "cash needed " .. money(plan.outOfPocket) .. (plan.outOfPocket < cost and (GREY .. " (you own the rest)|r") or "")
  local lines = { table.concat(parts, GREY .. "  |  |r") }
  local function duration(seconds, guessed) return (guessed and "~" or "") .. ns.formatDuration(seconds) end
  -- Gold per hour of crafting (the locked plan's numbers once it's locked).
  local seconds = plan.seconds or 0
  if seconds > 0 then
    local perHour = math.floor(plan.net * 3600 / seconds)
    lines[#lines + 1] = "Gold/hour: " .. ((perHour >= 0 and GREEN or RED) .. money(perHour) .. "|r")
      .. GREY .. (plan.secondsGuessed and " (estimated - timed crafts make it exact)" or " of crafting") .. "|r"
  end
  if lock then
    local left, guessed = secondsLeft()
    lines[#lines + 1] = "Crafting time: " .. duration(seconds, lock.secondsGuessed) .. " planned"
      .. (left > 0 and (GREY .. ", " .. duration(left, guessed) .. " left|r") or "")
  else
    local reagentCrafts = 0
    for _, e in ipairs(plan.reagentCrafts) do reagentCrafts = reagentCrafts + e.count end
    lines[#lines + 1] = "Crafting time: " .. duration(seconds, plan.secondsGuessed)
      .. GREY .. (" (%d reagent crafts, %d crafts)|r"):format(reagentCrafts, crafts)
  end
  if plan.ahNet then
    local better = plan.net - plan.ahNet
    lines[#lines + 1] = ("Selling these on the AH instead: %s %s"):format(money(plan.ahNet),
      better >= 0 and (GREEN .. "(vendor is " .. money(better) .. " better)|r")
        or (RED .. "(AH is " .. money(-better) .. " better)|r"))
  end
  if plan.incomplete then
    local missing = {}
    if plan.unpriced > 0 then missing[#missing + 1] = plan.unpriced .. " reagent(s) have no price" end
    if plan.unsold > 0 then missing[#missing + 1] = plan.unsold .. " item(s) a vendor won't buy" end
    lines[#lines + 1] = RED .. "* " .. table.concat(missing, ", ") .. " - left out of the totals.|r"
  end
  win.summary:SetText(table.concat(lines, "\n"))
end
ns.updateVendorShuffle = update

local function place()
  win:ClearAllPoints()
  if ns.queueWin and ns.queueWin:IsShown() then
    win:SetPoint("TOPLEFT", ns.queueWin, "TOPRIGHT", 4, 0)
  else
    win:SetPoint("CENTER")
  end
end

local function create()
  win = CreateFrame("Frame", "ProfessionProfitVendorShuffle", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
  win:Hide()
  win:SetSize(WIDTH, 52 + SCROLL_HEIGHT + 240)
  win:SetFrameStrata("HIGH")
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
  tinsert(UISpecialFrames, "ProfessionProfitVendorShuffle") -- Esc closes it
  local close = CreateFrame("Button", nil, win, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", -2, -2)

  local title = win:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  title:SetPoint("TOPLEFT", 14, -12)
  title:SetText("Vendor shuffle")
  win.subtitle = win:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  win.subtitle:SetPoint("TOPLEFT", 14, -30)
  win.subtitle:SetPoint("RIGHT", -30, 0)
  win.subtitle:SetJustifyH("LEFT")
  win.subtitle:SetWordWrap(false)

  local scroll = CreateFrame("ScrollFrame", "ProfessionProfitVendorShuffleScroll", win, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", 10, -50)
  scroll:SetPoint("RIGHT", -30, 0)
  scroll:SetHeight(SCROLL_HEIGHT)
  win.content = CreateFrame("Frame", nil, scroll)
  win.content:SetSize(WIDTH - 40, 1)
  scroll:SetScrollChild(win.content)
  scroll:SetScript("OnSizeChanged", function(_, width) win.content:SetWidth(width) end)
  win.lines = {}
  win.empty = win:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  win.empty:SetPoint("TOP", scroll, "TOP", 0, -30)
  win.empty:SetWidth(WIDTH - 80)
  win.empty:SetText("Click the V on a queued item to sell what it makes to a vendor. Its plan and profit show here.")

  -- The walkup, always in view under the plan.
  win.walk = CreateFrame("Frame", nil, win)
  win.walk:SetPoint("TOPLEFT", scroll, "BOTTOMLEFT", 0, -10)
  win.walk:SetPoint("RIGHT", -12, 0)
  win.walk:SetHeight(110)
  local divider = win.walk:CreateTexture(nil, "ARTWORK")
  divider:SetPoint("TOPLEFT", 0, 4)
  divider:SetPoint("TOPRIGHT", 0, 4)
  divider:SetHeight(1)
  divider:SetColorTexture(0.6, 0.5, 0.3, 0.6)
  local walkTitle = win.walk:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  walkTitle:SetPoint("TOPLEFT", 4, -4)
  walkTitle:SetText("Price walkup")
  local deltaHead = win.walk:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  deltaHead:SetPoint("TOPRIGHT", -108, -6)
  deltaHead:SetText("Change")
  local runningHead = win.walk:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  runningHead:SetPoint("TOPRIGHT", -4, -6)
  runningHead:SetText("Running total")
  win.walkRows = {}
  local walkHover = CreateFrame("Frame", nil, win.walk)
  walkHover:SetAllPoints()
  walkHover:EnableMouse(true)
  walkHover:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine("Price walkup")
    GameTooltip:AddLine("Starts at nothing, takes off what the reagents cost on the AH and from vendors, then adds what the vendor pays for everything crafted. Where it ends is the profit.", 1, 1, 1, true)
    GameTooltip:AddLine("Reagents you already own count at what they'd cost to buy, like the queue's Profit line. Cash needed is what you'd actually spend. Reagents you craft cost what their own reagents cost (in step 1).", 0.7, 0.7, 0.7, true)
    GameTooltip:Show()
  end)
  walkHover:SetScript("OnLeave", GameTooltip_Hide)

  win.summary = win:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  win.summary:SetPoint("TOPLEFT", win.walk, "BOTTOMLEFT", 4, -6)
  win.summary:SetPoint("RIGHT", -14, 0)
  win.summary:SetJustifyH("LEFT")
  win.summary:SetJustifyV("TOP")
  win.summary:SetSpacing(3)

  -- Fill bags: set the marked items' counts to what your bags and gold hold.
  local fill = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
  fill:SetSize(100, 22)
  fill:SetPoint("BOTTOMRIGHT", -12, 12)
  fill:SetText("Fill bags")
  fill:SetScript("OnClick", function()
    local result, err = ns.fillBagsForVendor()
    if not result then msg(err) return end
    if getLock() then
      unlockPlan()
      msg("New counts - the locked plan was replaced by a live one.")
    end
    local parts, none = {}, {}
    for _, item in ipairs(result.items) do
      if item.count > 0 then parts[#parts + 1] = item.count .. "x " .. item.name else none[#none + 1] = item.name end
    end
    if #parts == 0 then
      msg(("No room for even one craft (%d free bag slots, %s)."):format(result.free, money(GetMoney())))
    else
      msg(("Fill bags: %s - %d of %d free slots, costs %s%s."):format(table.concat(parts, ", "), result.slots, result.free,
        money(result.cost), result.limit and (" (stopped by " .. result.limit .. ")") or ""))
    end
    if #none > 0 then msg("No room for: " .. table.concat(none, ", ") .. " (counts left as they were).") end
    if ns.updateQueueWindow then ns.updateQueueWindow() end
    update()
  end)
  fill:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:AddLine("Fill bags")
    GameTooltip:AddLine("Sets the counts of the items marked V to as many crafts as fit in your free bag slots and your gold.", 1, 1, 1, true)
    GameTooltip:AddLine("It follows your bags through the crafts: the reagents you buy or take from the bank come in, and as you craft, used-up reagents free their slots for what you make. The fullest your bags get has to fit, so nothing overflows. Several marked items share the space. Only general bags count, and the rest of the queue isn't counted.", 0.7, 0.7, 0.7, true)
    GameTooltip:Show()
  end)
  fill:SetScript("OnLeave", GameTooltip_Hide)

  -- Lock plan / Replan.
  win.lockButton = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
  win.lockButton:SetSize(100, 22)
  win.lockButton:SetPoint("RIGHT", fill, "LEFT", -4, 0)
  win.lockButton:SetScript("OnClick", function()
    if getLock() then
      unlockPlan()
      msg("Vendor shuffle: back to the live plan.")
    else
      lockPlan()
    end
  end)
  win.lockButton:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    if getLock() then
      GameTooltip:AddLine("Replan")
      GameTooltip:AddLine("Drops the locked plan and shows the live one again: today's prices and what's left in the queue.", 1, 1, 1, true)
    else
      GameTooltip:AddLine("Lock plan")
      GameTooltip:AddLine("Keeps this plan as the result you're committing to: the steps and the walkup stay as they are, and Craft shows how many are done. Craft all locks it for you.", 1, 1, 1, true)
    end
    GameTooltip:Show()
  end)
  win.lockButton:SetScript("OnLeave", GameTooltip_Hide)

  -- Sell all: at a merchant, what the marked crafts made.
  win.sellButton = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
  win.sellButton:SetSize(100, 22)
  win.sellButton:SetPoint("RIGHT", win.lockButton, "LEFT", -4, 0)
  win.sellButton:SetText("Sell all")
  win.sellButton:SetMotionScriptsWhileDisabled(true)
  win.sellButton:SetScript("OnClick", sellAll)
  win.sellButton:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:AddLine("Sell all")
    GameTooltip:AddLine("At a merchant, sells everything in your bags made by the crafts marked V, after you confirm the total.", 1, 1, 1, true)
    GameTooltip:AddLine("That's what the queue, the locked plan and your marked crafts so far make. Items another queued craft uses as a reagent are kept, and nothing else in your bags is touched.", 0.7, 0.7, 0.7, true)
    if not merchantOpen() then GameTooltip:AddLine("Open a merchant first.", 1, 0.4, 0.4) end
    GameTooltip:Show()
  end)
  win.sellButton:SetScript("OnLeave", GameTooltip_Hide)

  win:SetScript("OnShow", function()
    ns.vendorMerchantChanged()
    update()
  end)
end

local function toggleVendorShuffle()
  if not win then create() end
  if win:IsShown() then win:Hide() return end
  place()
  win:Show()
end
ns.toggleVendorShuffle = toggleVendorShuffle
