-- ProfessionProfit: Buying gear to disenchant, for the Disenchant planner.
--
-- Click items in the Disenchant Scan to put them on the buy list. Buying
-- works on the first item on the list, one listing per press of Buy:
--
--   searching  an item search is out; Buy waits for its answer
--   ready      the cheapest listing is known; Buy places a buyout on it
--   buying     waiting for the AH to confirm or refuse the purchase
--
-- One search gives every listing; each purchase (or refusal) steps on to
-- the next cheapest one without searching again, so Buy can be pressed
-- straight away. The item is searched again only when those listings run
-- out and the answer wasn't complete, or the AH didn't answer a purchase.
-- It comes off the list when its cheapest listing no longer makes a profit.
--
-- This never opens the AH's own Buy page for the item: with that page open,
-- the AH silently drops every other purchase.

local ADDON, ns = ...
local API, GREY, msg, log = ns.API, ns.GREY, ns.msg, ns.log
local db
ns.onInit(function(saved) db = saved end)

local SEARCH_TIMEOUT = 5 -- seconds without a usable answer before searching again
local BUY_TIMEOUT = 4    -- seconds without an answer to a purchase
local PRICE_SORT = { { sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false } }

local list = {} -- picked scan results, in order. r.maxPrice: dearest buyout that still profits
-- The first item's state: { r, phase, seq, auctionID, price, listings, ladder, full, staleTries, buyToken }
local cur
-- Listings bought or refused this AH visit. An answer right after a purchase
-- can come from the AH's cache and still include them.
local gone = {}
local seq = 0

local function ahOpen() return AuctionHouseFrame and AuctionHouseFrame:IsShown() end
local function ahReady()
  return not C_AuctionHouse.IsThrottledMessageSystemReady or C_AuctionHouse.IsThrottledMessageSystemReady()
end

local function changed()
  if ns.deScanUpdate then ns.deScanUpdate() end
  if ns.updateDisenchantPlanner then ns.updateDisenchantPlanner() end
end

local function sameKey(a, b)
  return a and b and a.itemID == b.itemID and (a.itemLevel or 0) == (b.itemLevel or 0)
    and (a.itemSuffix or 0) == (b.itemSuffix or 0)
end

------------------------------------------------------------------------------
-- Searching
------------------------------------------------------------------------------

local search -- forward

-- Search the current item. Each search has a number, so a timer or answer
-- left over from an earlier one does nothing.
search = function()
  if not cur then return end
  if not ahOpen() then cur.phase = "idle" changed() return end
  seq = seq + 1
  local mine = seq
  cur.phase, cur.seq, cur.auctionID = "searching", mine, nil
  local function send()
    if not (cur and cur.seq == mine and cur.phase == "searching") then return end
    if not ahOpen() then cur.phase = "idle" changed() return end
    if not ahReady() then C_Timer.After(0.25, send) return end
    C_AuctionHouse.SendSearchQuery(cur.r.browse.itemKey, PRICE_SORT, false)
    -- No usable answer: ask again.
    C_Timer.After(SEARCH_TIMEOUT, function()
      if cur and cur.seq == mine and cur.phase == "searching" then
        log("no answer to the item search for", cur.r.name, "- searching again")
        search()
      end
    end)
  end
  send()
  changed()
end

-- The listings we can buy, cheapest first: { { auctionID, price }, ... }.
-- Also returns whether any already-bought one showed.
local function readListings(itemKey)
  local listings, stale = {}, false
  for i = 1, C_AuctionHouse.GetNumItemSearchResults(itemKey) or 0 do
    local info = C_AuctionHouse.GetItemSearchResultInfo(itemKey, i)
    if info and gone[info.auctionID] then
      stale = true
    elseif info and info.buyoutAmount and not info.containsOwnerItem and (info.quantity or 1) == 1 then
      listings[#listings + 1] = { auctionID = info.auctionID, price = info.buyoutAmount }
    end
  end
  table.sort(listings, function(a, b) return a.price < b.price end)
  return listings, stale
end

-- Group listings by price: { { price, count }, ... } cheapest first.
local function ladderOf(listings)
  local ladder = {}
  for _, l in ipairs(listings) do
    local last = ladder[#ladder]
    if last and last.price == l.price then last.count = last.count + 1
    else ladder[#ladder + 1] = { price = l.price, count = 1 } end
  end
  return ladder
end

local removeFromBuyList -- forward

-- Point Buy at the cheapest listing left, with no search: when none are
-- left, search again only if the answer may have had more.
local function useNext()
  local r = cur.r
  local best = cur.listings[1]
  if not best and not cur.full then search() return end
  cur.ladder = ladderOf(cur.listings)

  -- Keep the scan row on the current cheapest price.
  if best then
    r.price, r.profit = best.price, math.floor(r.value - best.price + 0.5)
    if r.profit > 0 then ns.deScanSort() else ns.deScanRemove(r) end
  else
    ns.deScanRemove(r)
  end

  if not best or best.price > r.maxPrice then
    local why = best and ("cheapest is now " .. API.Money(best.price)) or "none listed"
    msg(("No more %s at a profit (%s%s)."):format(r.name, why, r.bought and (", bought " .. r.bought) or ""))
    removeFromBuyList(r)
    return
  end
  cur.phase, cur.auctionID, cur.price = "ready", best.auctionID, best.price
  changed()
end

-- Our search's answer, or (while ready) any other answer for the item -
-- the AH's own list, another addon - which keeps the listings live for free.
local function onItemResults(itemKey)
  if not (cur and sameKey(itemKey, cur.r.browse.itemKey)) then return end
  if cur.phase ~= "searching" and cur.phase ~= "ready" then return end
  local count = C_AuctionHouse.GetNumItemSearchResults(itemKey) or 0
  local full = C_AuctionHouse.HasFullItemSearchResults and C_AuctionHouse.HasFullItemSearchResults(itemKey)
  -- An empty answer that isn't complete is a search still loading, not "none listed".
  if count == 0 and not full then return end
  local listings, stale = readListings(itemKey)
  log("item results for", cur.r.name, cur.phase, count, "results, full", full or false, "cheapest",
    listings[1] and listings[1].price or "none", "already bought seen", stale)
  -- While ready, only take an answer that shows something to buy.
  if cur.phase == "ready" and not listings[1] then return end

  -- Only listings already bought: probably the AH's cache. Ask again.
  if not listings[1] and stale and (cur.staleTries or 0) < 3 then
    cur.staleTries = (cur.staleTries or 0) + 1
    local mine = cur.seq
    C_Timer.After(1, function() if cur and cur.seq == mine then search() end end)
    return
  end
  cur.staleTries = nil
  cur.listings, cur.full = listings, full and true or false
  useNext()
end

------------------------------------------------------------------------------
-- The buy list
------------------------------------------------------------------------------

-- Make the first item on the list the current one (searching it), unless it already is.
local function startNext()
  local r = list[1]
  if not r then cur = nil changed() return end
  if cur and cur.r == r and cur.phase ~= "idle" then return end
  cur = { r = r }
  search()
end

removeFromBuyList = function(r)
  for i, x in ipairs(list) do
    if x == r then table.remove(list, i) break end
  end
  r.planned = nil
  if cur and cur.r == r then cur = nil end
  startNext()
  changed()
end
ns.removeFromBuyList = removeFromBuyList

ns.addToBuyList = function(r)
  if r.planned then return end
  r.planned = true
  r.maxPrice = math.ceil(r.value) - 1
  list[#list + 1] = r
  if ns.showDisenchantPlanner then ns.showDisenchantPlanner() end
  startNext()
  changed()
end

-- Buy this one now: put it on the list (if it isn't) at the top, so the
-- planner shows its listings and Buy works on it. Not mid-purchase: the
-- AH's answer belongs to the item being bought.
ns.focusBuy = function(r)
  if cur and cur.phase == "buying" and cur.r ~= r then
    msg("Waiting for the AH to answer the last Buy - click again in a moment.")
    return
  end
  if not r.planned then
    r.planned = true
    r.maxPrice = math.ceil(r.value) - 1
  else
    for i, x in ipairs(list) do
      if x == r then table.remove(list, i) break end
    end
  end
  table.insert(list, 1, r)
  if ns.showDisenchantPlanner then ns.showDisenchantPlanner() end
  startNext()
  changed()
end

------------------------------------------------------------------------------
-- Buying
------------------------------------------------------------------------------

local function settle(outcome, detail)
  if not (cur and cur.phase == "buying") then return end
  local r, id, price = cur.r, cur.auctionID, cur.price
  log("buy", outcome, r.name, id, detail or "")
  cur.buyToken = nil
  if outcome == "bought" or outcome == "refused" then
    gone[id] = true
    if cur.listings[1] and cur.listings[1].auctionID == id then table.remove(cur.listings, 1) end
    if outcome == "bought" then
      r.bought = (r.bought or 0) + 1
      ns.queueDisenchantItem(r.itemID, r.name, 1, price, math.floor(r.value - price + 0.5))
    else
      msg(("The auction house refused that %s (error %s) - on to the next one."):format(r.name, tostring(detail)))
    end
    useNext() -- the next cheapest listing, no search
  elseif outcome == "dropped" then
    -- Never reached the AH: the same listing is still there.
    msg("The auction house dropped the purchase - press Buy again.")
    cur.phase = "ready"
    changed()
  else
    -- It may still have gone through: look again before buying more.
    msg(("No answer from the auction house for %s - checking its listings again."):format(r.name))
    search()
  end
end

-- Buy the current listing. Needs a key press or click (the AH requires it).
ns.buyNext = function()
  log("Buy pressed:", cur and cur.r.name or "nothing", "phase", cur and cur.phase or "-",
    "auction", cur and cur.auctionID or "-", "AH ready", ahReady())
  if not cur then return end
  if cur.phase == "searching" then msg("Still looking up " .. cur.r.name .. " listings.") return end
  if cur.phase == "buying" then msg("Still waiting for the AH to answer the last Buy.") return end
  if cur.phase ~= "ready" then return end
  if GetMoney() < cur.price then msg("Not enough gold for " .. cur.r.name .. ".") return end
  -- A purchase sent while the AH is busy is lost, and it can't be retried
  -- without another press.
  if not ahReady() then msg("The auction house is busy - press Buy again in a moment.") return end
  -- Each purchase has its own token: with no search between buys, an old
  -- purchase's timeout must not settle a newer one.
  local token = {}
  cur.phase, cur.buyT, cur.buyToken = "buying", GetTime(), token
  C_AuctionHouse.PlaceBid(cur.auctionID, cur.price)
  C_Timer.After(BUY_TIMEOUT, function()
    if cur and cur.buyToken == token and cur.phase == "buying" then settle("no answer") end
  end)
  changed()
end

------------------------------------------------------------------------------
-- For the planner
------------------------------------------------------------------------------

-- The buy list, and the item being bought.
ns.buyList = function() return list, cur and cur.r end

-- The current item's listings by price: { { price, count }, ... }, and
-- whether every listing is in (else there may be more at the last price).
ns.buyLadder = function()
  if not (cur and cur.ladder) then return nil end
  return cur.ladder, cur.full, cur.r
end

-- A status line for the planner: text, whether Buy can be pressed.
ns.buyStatus = function()
  if #list == 0 then return "", false end
  if not ahOpen() then return GREY .. "Open the auction house to buy.|r", false end
  if not cur then return "", false end
  local name = cur.r.name
  if cur.phase == "searching" then return GREY .. "Looking up " .. name .. "...|r", false end
  if cur.phase == "buying" then return GREY .. "Buying " .. name .. "...|r", false end
  if cur.phase ~= "ready" then return "", false end
  return ("%s for %s, |cff40ff40+%s|r"):format(name, API.Money(cur.price),
    API.Money(math.floor(cur.r.value - cur.price + 0.5))), true
end

------------------------------------------------------------------------------
-- Events
------------------------------------------------------------------------------

local WON = ERR_AUCTION_WON_S and ("^" .. ERR_AUCTION_WON_S:gsub("([%(%)%.%-%+%[%]])", "%%%1"):gsub("%%s", "(.+)") .. "$")

local events = CreateFrame("Frame")
for _, event in ipairs({ "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED", "ITEM_SEARCH_RESULTS_UPDATED",
  "ITEM_SEARCH_RESULTS_ADDED", "AUCTION_HOUSE_PURCHASE_COMPLETED", "AUCTION_HOUSE_SHOW_ERROR",
  "AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED", "CHAT_MSG_SYSTEM" }) do
  pcall(events.RegisterEvent, events, event)
end
events:SetScript("OnEvent", function(_, event, arg)
  if not db then return end
  if event == "AUCTION_HOUSE_SHOW" then
    C_Timer.After(1, startNext) -- pick the buy list up again
  elseif event == "AUCTION_HOUSE_CLOSED" then
    if cur then cur.phase = "idle" end
    wipe(gone)
    changed()
  elseif event == "ITEM_SEARCH_RESULTS_UPDATED" or event == "ITEM_SEARCH_RESULTS_ADDED" then
    if type(arg) == "table" then onItemResults(arg) end
  elseif event == "AUCTION_HOUSE_PURCHASE_COMPLETED" then
    if cur and cur.phase == "buying" and (arg == nil or arg == cur.auctionID) then settle("bought") end
  elseif event == "CHAT_MSG_SYSTEM" then
    -- "You won an auction for X", in case the purchase event is missing.
    local name = WON and type(arg) == "string" and arg:match(WON)
    if name and cur and cur.phase == "buying" and name == cur.r.name then settle("bought") end
  elseif event == "AUCTION_HOUSE_SHOW_ERROR" then
    settle("refused", arg)
  elseif event == "AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED" then
    log("AH dropped a message", cur and cur.phase or "-")
    settle("dropped")
  end
end)
