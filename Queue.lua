-- ProfessionProfit: The craft queue: saved entries, restock targets and reagent-craft planning.

local ADDON, ns = ...
local API, log, isModern, hostShown, professionInfo, professionName = ns.API, ns.log, ns.isModern, ns.hostShown, ns.professionInfo, ns.professionName
local itemName, GetItemCount, charKey, priceOpts = ns.itemName, ns.GetItemCount, ns.charKey, ns.priceOpts
local db
ns.onInit(function(saved) db = saved end)

local function craftQueue()
  db.craftQueue = db.craftQueue or {}
  local key = charKey()
  db.craftQueue[key] = db.craftQueue[key] or {}
  return db.craftQueue[key]
end
ns.craftQueue = craftQueue

local computeQueue -- defined below

-- Crafts of a recipe in the queue (including reagent crafts).
local function queuedCount(recipeID)
  local total = 0
  for _, entry in ipairs(computeQueue()) do
    if entry.recipeID == recipeID then total = total + entry.count end
  end
  return total
end
ns.queuedCount = queuedCount

-- Restock targets: how many of an item you want to own - the single source
-- of truth for Use Restock. Set in the + view's "Restock to" box, or remembered
-- when you queue more than one there and the item has none; edited and
-- cleared in the Restocking window.
-- db.queueTargets[recipeID] = { n = target, name = recipe name, item = itemID }
-- (older saves are just the number).
local function queueTarget(recipe)
  local t = recipe.recipeID and db.queueTargets and db.queueTargets[recipe.recipeID]
  return type(t) == "table" and t.n or t
end
ns.queueTarget = queueTarget

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
ns.setQueueTarget = setQueueTarget

-- Number of crafts to queue for a recipe. Use Restock off: Qty crafts, targets
-- ignored. Use Restock on: enough to own its restock target (or Qty when it has
-- none), counting your stock (bags, bank, your auctions) and what's queued.
local function craftsToQueue(recipe)
  local qty = db.queueQty or 1
  if not db.queueTopUp then return qty end
  if not recipe.productID then return 0 end
  local need = (queueTarget(recipe) or qty) - (recipe.stock or 0) - queuedCount(recipe.recipeID) * recipe.made
  if need <= 0 then return 0 end
  return math.ceil(need / recipe.made)
end
ns.craftsToQueue = craftsToQueue

local function bagCount(itemID)
  return (GetItemCount and GetItemCount(itemID, false)) or 0
end
ns.bagCount = bagCount

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
ns.forgetOpenRecipeIDs = forgetOpenRecipeIDs

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
  if entry.crafter and entry.crafter ~= charKey() then return false end -- another character crafts it
  if not openRecipeIDs()[entry.recipeID] then return false end
  if not entry.prof then entry.prof = professionForRecipe(entry.recipeID) end
  return true
end
ns.inOpenProfession = inOpenProfession

local function recipeDef(recipe)
  local reagents = {}
  for _, reagent in ipairs(recipe.reagents) do
    reagents[#reagents + 1] = { id = reagent.id, n = reagent.name, c = reagent.count }
  end
  return {
    recipeID = recipe.recipeID, name = recipe.name,
    prof = recipe.prof or professionForRecipe(recipe.recipeID) or professionInfo(true) or professionName(),
    crafter = recipe.crafter, productID = recipe.productID, made = recipe.made, reagents = reagents,
  }
end
ns.recipeDef = recipeDef

-- Add crafts of a recipe (merged into an existing entry for that recipe).
-- subs: recipes of craftable reagents to craft instead of buy. Their crafts
-- aren't stored - computeQueue() works them out from what's in your bags.
-- de: what it makes is to be disenchanted (the entry is priced by that).
-- vendor: what it makes is to be sold to a vendor (priced by that).
local function queueAdd(recipe, crafts, subs, de, vendor)
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
  if de then entry.de, entry.vendor = true, nil end
  if vendor and not entry.de then entry.vendor = true end
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
      recipeID = def.recipeID, name = def.name, prof = def.prof, crafter = def.crafter, productID = productID, made = def.made or 1,
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
ns.planDerived = planDerived

-- The queue as it should be crafted: reagent crafts first, deepest level
-- first (live: needed by the queue, minus what's in your bags), then the
-- queued items.
local function planEntries(mains)
  local plan, derived = planDerived(mains)
  local list = {}
  for _, d in ipairs(plan) do
    if d.count > 0 then list[#list + 1] = d end
  end
  for _, main in ipairs(mains) do list[#list + 1] = main end
  return list, derived
end

computeQueue = function()
  local queue = craftQueue()
  -- "Craft reagents" unticked in the queue window: buy every reagent.
  if db.skipReagentCrafts then
    local list = {}
    for _, main in ipairs(queue) do list[#list + 1] = main end
    return list, {}
  end
  return planEntries(queue)
end
ns.computeQueue = computeQueue

-- Stop crafting a reagent for every queued item (buy it instead).
local function dropSub(subID)
  for _, main in ipairs(craftQueue()) do
    if main.subs then main.subs[subID] = nil end
  end
end
ns.dropSub = dropSub

-- Craftable reagents of a recipe (made by another learned recipe of this
-- profession), with a first per-unit guess at craft-or-buy: craft when its
-- reagent cost per unit is below what it costs to buy (vendor or AH - no AH
-- cut, nothing is sold), or when it can't be bought at all (not on the AH).
-- recommend() then decides by the whole shopping list.
-- How many to craft is worked out later from your bags (computeQueue).
local function subReagents(recipe, crafts, byProduct)
  local list = {}
  byProduct = byProduct or (ns.panel and ns.panel.byProduct) or {}
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
ns.subTree = subTree

-- Ticked, and everything above it is ticked too.
local function effectivelyIncluded(flat, index)
  local entry = flat[index]
  while entry do
    if not entry.include then return false end
    entry = entry.parent and flat[entry.parent]
  end
  return true
end
ns.effectivelyIncluded = effectivelyIncluded

-- Recipes chosen for crafting in a subTree.
local function chosenSubs(flat)
  local list = {}
  for i, entry in ipairs(flat) do
    if effectivelyIncluded(flat, i) then list[#list + 1] = entry.sub end
  end
  return list
end
ns.chosenSubs = chosenSubs

-- Queue a list of {recipe, crafts, subs, de}.
local function queueOrdered(steps)
  local done, failed = {}, {}
  for _, step in ipairs(steps) do
    local ok, reason = queueAdd(step.recipe, step.crafts, step.subs, step.de, step.vendor)
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
  if #done > 0 and ns.showQueueWindow then ns.showQueueWindow() end
  if ns.updateQueueWindow then ns.updateQueueWindow() end
  return done, failed
end
ns.queueOrdered = queueOrdered

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
ns.craftableNow = craftableNow

-- Reagents still missing for a crafting plan (computeQueue's shape): needs
-- minus bags/bank minus what earlier entries will craft. Returns list,
-- estimated cost, unpriced items, items the AH doesn't list enough of.
-- opts: pricing (default: Buy items from vendors as set). all: price
-- everything the plan uses, as if your bags and bank were empty.
local function shoppingFor(entries, opts, all)
  local need, produced, names = {}, {}, {}
  for _, entry in ipairs(entries) do
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
    local bags = all and 0 or bagCount(id)
    local short = n - bags - (produced[id] or 0)
    if short > 0 then
      local bank = all and 0 or math.max(0, ((GetItemCount and GetItemCount(id, true)) or bags) - bags)
      local buy = math.max(0, short - bank)
      -- What buying that many costs.
      local total = nil
      if buy > 0 then total = API.BuyCost(id, buy, opts or priceOpts()) end
      if buy > 0 then
        if total then cost = cost + total else unpriced = unpriced + 1 end
      end
      list[#list + 1] = { id = id, name = names[id] or itemName(id) or ("item " .. id), count = short,
        bank = math.min(bank, short), buy = buy, total = total }
    end
  end
  table.sort(list, function(a, b) return a.name < b.name end)
  return list, cost, unpriced
end

-- The whole queue's shopping list: list, cost, unpriced.
local function queueShopping()
  return shoppingFor((computeQueue()))
end
ns.queueShopping = queueShopping

------------------------------------------------------------------------------
-- Craft or buy, by the shopping list. Crafting a reagent is only worth it
-- when the queue's shopping list gets cheaper overall.
------------------------------------------------------------------------------

-- Copies of queue entries (mains) keeping only the reagent recipes on(id)
-- says to craft.
local function withSubs(mains, on)
  local copy = {}
  for i, main in ipairs(mains) do
    local subs = {}
    for id, def in pairs(main.subs or {}) do
      if on(id) then subs[id] = def end
    end
    copy[i] = setmetatable({ subs = subs }, { __index = main })
  end
  return copy
end
ns.withSubs = withSubs

-- Shopping list for mains crafting the reagents on(id) allows (the rest are
-- bought): cost, unpriced. opts, all: as for shoppingFor.
local function shoppingCost(mains, on, opts, all)
  local _, cost, unpriced = shoppingFor((planEntries(withSubs(mains, on))), opts, all)
  return cost, unpriced
end
ns.shoppingCost = shoppingCost

-- What crafting reagent recipe `id` (and the ticked ones below it) does to
-- the shopping list, the others as on(id) says: craft / buy = list cost
-- each way, saving = buy - craft; needed: it can't be bought; unknown: its
-- craft leaves something unpriced.
local function craftEffect(mains, on, id, opts)
  local craft, craftUnpriced = shoppingCost(mains, function(x) return x == id or on(x) end, opts)
  local buy, buyUnpriced = shoppingCost(mains, function(x) return x ~= id and on(x) end, opts)
  return {
    craft = craft, buy = buy, saving = buy - craft,
    needed = craftUnpriced < buyUnpriced, unknown = craftUnpriced > buyUnpriced,
  }
end
ns.craftEffect = craftEffect

-- What crafting `units` of a reagent gains over buying them: the cost of
-- buying that many, minus the cost of buying its reagents for the crafts
-- that make them. Everything at AH value, whatever you already own.
-- Returns { units, buy, craft, gain } - buy / craft / gain nil when unpriced.
local function craftGain(recipe, units, opts)
  opts = opts or priceOpts()
  local result = { units = units }
  if units <= 0 then return result end
  local crafts = math.ceil(units / (recipe.made or 1))
  result.buy = API.BuyCost(recipe.productID, units, opts)
  local craft = 0
  for _, reagent in ipairs(recipe.reagents) do
    local total = reagent.id and API.BuyCost(reagent.id, reagent.count * crafts, opts)
    if not total then craft = nil break end
    craft = craft + total
  end
  result.craft = craft
  if result.buy and craft then result.gain = result.buy - craft end
  return result
end
ns.craftGain = craftGain

-- The queue's profit, priced like its shopping list (Buy items from
-- vendors, the reagents it crafts): the
-- queued items' AH value after the cut (for items queued to disenchant,
-- what disenchanting them gives; for items queued to sell to a vendor, what
-- the vendor pays, no cut), minus every reagent the queue uses
-- (what's already in your bags and bank too, at what it would cost to buy).
-- Returns profit, saving (what the reagent crafts save over buying those
-- reagents; 0 with Craft reagents off), unsold (queued items with no
-- price), incomplete (a reagent unpriced).
local function queueProfit()
  local queue = craftQueue()
  local _, cost, unpriced = shoppingFor((computeQueue()), nil, true)
  local sales, unsold, deMissing = 0, 0, false
  for _, main in ipairs(queue) do
    -- Queued to disenchant: what disenchanting it gives instead.
    local sell, cut = nil, API.AH_CUT
    if main.de then
      local missing
      if main.productID then sell, missing = API.DisenchantValue(main.productID) end
      if sell and missing > 0 then deMissing = true end
    elseif main.vendor then
      sell, cut = main.productID and API.VendorSellPrice(main.productID), 0
    else
      sell = main.productID and API.SellPrice(main.productID)
    end
    if sell then
      sales = sales + sell * (main.made or 1) * main.count * (1 - cut)
    else
      unsold = unsold + 1
    end
  end
  local saving = 0
  if not db.skipReagentCrafts then saving = shoppingCost(queue, function() return false end, nil, true) - cost end
  return math.floor(sales - cost), saving, unsold, unpriced > 0 or deMissing
end
ns.queueProfit = queueProfit

-- Vendor shuffle: the queued items marked to sell to a vendor, start to
-- finish. Everything they use is priced at what it costs to buy (what you
-- own too, like the Profit line); `have` and outOfPocket show what you
-- already own. Returns {
--   mains        the vendor-marked queue entries
--   buys         { id, name, count, have, src = "AH" | "vendor", unit, total } (total nil: no price)
--   ahCost, vendorCost, unpriced
--   reagentCrafts  reagent crafts, deepest first (computeQueue's derived entries)
--   sales        { entry, units, unit, total } (unit nil: no vendor price)
--   salesTotal, unsold, net, outOfPocket (buying what you don't own)
--   saving       what crafting the reagents saves over buying them
--   ahNet        the same crafts sold on the AH after the cut (nil: an item has no AH price)
--   incomplete   a reagent or sale unpriced
-- }
local function vendorShufflePlan()
  local mains = {}
  for _, main in ipairs(craftQueue()) do
    if main.vendor and main.count > 0 then mains[#mains + 1] = main end
  end
  local plan = { mains = mains, buys = {}, reagentCrafts = {}, sales = {}, ahCost = 0, vendorCost = 0,
    unpriced = 0, salesTotal = 0, unsold = 0, saving = 0 }
  if #mains == 0 then
    plan.net, plan.outOfPocket = 0, 0
    return plan
  end

  local entries
  if db.skipReagentCrafts then
    entries = {}
    for _, main in ipairs(mains) do entries[#entries + 1] = main end
  else
    entries = planEntries(mains)
  end
  for _, entry in ipairs(entries) do
    if entry.auto then plan.reagentCrafts[#plan.reagentCrafts + 1] = entry end
  end

  local opts = priceOpts()
  local list, cost, unpriced = shoppingFor(entries, opts, true)
  for _, item in ipairs(list) do
    local _, src = API.BuyPrice(item.id, opts)
    local buy = {
      id = item.id, name = item.name, count = item.count, total = item.total, src = src or "AH",
      unit = item.total and item.buy > 0 and item.total / item.buy or nil,
      have = (GetItemCount and GetItemCount(item.id, true)) or bagCount(item.id),
    }
    if buy.total then
      if buy.src == "vendor" then plan.vendorCost = plan.vendorCost + buy.total
      else plan.ahCost = plan.ahCost + buy.total end
    end
    plan.buys[#plan.buys + 1] = buy
  end
  plan.unpriced = unpriced
  local _, ownedCost = shoppingFor(entries, opts)
  plan.outOfPocket = ownedCost

  local ahSales = 0
  for _, main in ipairs(mains) do
    local units = (main.made or 1) * main.count
    local unit = main.productID and API.VendorSellPrice(main.productID)
    local sale = { entry = main, units = units, unit = unit, total = unit and unit * units }
    if sale.total then plan.salesTotal = plan.salesTotal + sale.total else plan.unsold = plan.unsold + 1 end
    plan.sales[#plan.sales + 1] = sale
    local ah = ahSales and main.productID and API.SellPrice(main.productID)
    ahSales = ah and (ahSales + ah * units * (1 - API.AH_CUT)) or nil
  end

  plan.net = plan.salesTotal - cost
  plan.ahNet = ahSales and math.floor(ahSales - cost) or nil
  if not db.skipReagentCrafts then
    plan.saving = shoppingCost(mains, function() return false end, opts, true) - cost
  end
  plan.incomplete = unpriced > 0 or plan.unsold > 0
  return plan
end
ns.vendorShufflePlan = vendorShufflePlan

-- Fill bags: as many crafts of the vendor-marked items as fit in your free
-- bag slots (general bags only) and your gold. Space counts the reagents you
-- still need (bought, or taken from the bank) plus the items made, so
-- nothing overflows mid-craft. Crafts are added one at a time to each item
-- in turn, so several marked items share the space.
local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
local GetFreeSlots = (C_Container and C_Container.GetContainerNumFreeSlots) or GetContainerNumFreeSlots

local function freeBagSlots()
  local free = 0
  for bag = 0, NUM_BAG_SLOTS or 4 do
    local n, bagType = GetFreeSlots(bag)
    if n and (bagType == 0 or bagType == nil) then free = free + n end
  end
  return free
end

-- nil until the game has loaded the item's info.
local function stackSize(itemID)
  local size = select(8, GetItemInfo(itemID))
  if size and size > 0 then return size end
  if C_Item and C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(itemID) end
end

-- Bag slots (beyond what's used now) and gold that crafting `mains` needs.
-- Simulates your bags through the crafts: after shopping (bought and bank
-- reagents added), after each level of reagent crafts, after the queued
-- crafts. Reagents used up free their slots as the crafted items fill new
-- ones. Within a step, bag use moves in a straight line between its ends,
-- except for partly filled stacks: one extra slot per item the step touches
-- (minus one) covers those.
local function fillNeeds(mains)
  local entries = mains
  if not db.skipReagentCrafts then entries = planEntries(mains) end
  local list, cost = shoppingFor(entries, priceOpts())
  local inv, ids, unknown = {}, {}, false
  local function touch(id)
    if inv[id] == nil then
      inv[id] = bagCount(id)
      ids[#ids + 1] = id
    end
  end
  for _, e in ipairs(entries) do
    if e.productID then touch(e.productID) end
    for _, r in ipairs(e.reagents) do if r.id then touch(r.id) end end
  end
  local function used()
    local n = 0
    for _, id in ipairs(ids) do
      local size = stackSize(id)
      if not size then unknown = true size = 1 end
      n = n + math.ceil(math.max(inv[id], 0) / size)
    end
    return n
  end
  local baseline = used()
  for _, item in ipairs(list) do
    touch(item.id)
    inv[item.id] = inv[item.id] + item.count
  end
  local peak = used() - baseline
  -- Steps in craft order: each depth of reagent crafts, then the queued
  -- crafts (planEntries lists them that way).
  local i = 1
  while i <= #entries do
    local depth = entries[i].auto and entries[i].depth or 0
    local before, touched, k = used(), {}, 0
    local j = i
    while j <= #entries and (entries[j].auto and entries[j].depth or 0) == depth do
      local e = entries[j]
      for _, r in ipairs(e.reagents) do
        if r.id then
          inv[r.id] = inv[r.id] - r.c * e.count
          touched[r.id] = true
        end
      end
      if e.productID then
        inv[e.productID] = inv[e.productID] + (e.made or 1) * e.count
        touched[e.productID] = true
      end
      j = j + 1
    end
    for _ in pairs(touched) do k = k + 1 end
    peak = math.max(peak, math.max(before, used()) - baseline + math.max(k - 1, 0))
    i = j
  end
  return peak, cost, unknown
end

local MAX_FILL_STEPS = 400
local MAX_STRIDE = 256

local function fillBagsForVendor()
  local marked, trial = {}, {}
  for _, main in ipairs(craftQueue()) do
    if main.vendor then
      marked[#marked + 1] = main
      trial[#trial + 1] = setmetatable({ count = 0 }, { __index = main })
    end
  end
  if #marked == 0 then return nil, "Mark a queued item with V first." end
  if not GetFreeSlots then return nil, "This client doesn't report free bag slots." end
  local free, gold = freeBagSlots(), GetMoney()
  -- Stack sizes decide the space; don't guess them.
  if select(3, fillNeeds(marked)) then return nil, "Item info is still loading - try Fill bags again in a moment." end
  -- Each item in turn takes a stride of crafts: doubling while they fit,
  -- halving when they don't, done when even one doesn't fit.
  local stride, full, open, steps, limit = {}, {}, #trial, 0, nil
  for i in ipairs(trial) do stride[i] = 1 end
  while open > 0 and steps < MAX_FILL_STEPS do
    for i, t in ipairs(trial) do
      if not full[i] then
        t.count = t.count + stride[i]
        steps = steps + 1
        local slots, cost = fillNeeds(trial)
        if slots > free or cost > gold then
          t.count = t.count - stride[i]
          if stride[i] > 1 then
            stride[i] = math.floor(stride[i] / 2)
          else
            full[i], open = true, open - 1
            limit = limit or (slots > free and "bag space" or "gold")
          end
        else
          stride[i] = math.min(stride[i] * 2, MAX_STRIDE)
        end
      end
    end
  end
  local slots, cost = fillNeeds(trial)
  local result = { free = free, slots = slots, cost = cost, limit = limit, items = {} }
  for i, main in ipairs(marked) do
    result.items[i] = { name = main.name, count = trial[i].count }
    if trial[i].count > 0 then main.count = trial[i].count end
  end
  log("fill bags", free, "free slots, uses", slots, "cost", cost, "limit", limit or "steps")
  return result
end
ns.fillBagsForVendor = fillBagsForVendor

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
ns.applyChoices = applyChoices

-- The craftable reagents of several recipes (steps: { recipe, crafts }),
-- each listed once (parent = index in the merged list), and the steps as
-- queue entries offering every one of them (for shoppingCost). Each step
-- gets tree = { [recipeID] = true } of its own reagent recipes.
local function mergeTrees(steps, byProduct)
  local merged, indexOf, mains, defs = {}, {}, {}, {}
  for _, step in ipairs(steps) do
    local main = recipeDef(step.recipe)
    main.count, main.subs = step.crafts, {}
    step.tree = {}
    local map = {}
    for i, entry in ipairs(subTree(step.recipe, step.crafts, byProduct)) do
      local id = entry.sub.recipeID
      step.tree[id] = true
      defs[id] = defs[id] or recipeDef(entry.sub)
      main.subs[id] = defs[id]
      if not indexOf[id] then
        entry.parent = entry.parent and map[entry.parent]
        merged[#merged + 1] = entry
        indexOf[id] = #merged
      end
      map[i] = indexOf[id]
    end
    mains[#mains + 1] = main
  end
  return merged, mains
end
ns.mergeTrees = mergeTrees

local function effectWhy(effect)
  if effect.needed then return "no current AH price" end
  if effect.unknown then return "craft cost unknown" end
  if effect.saving > 0 then return "saves " .. API.Money(effect.saving) end
  return "cheaper to buy"
end
ns.effectWhy = effectWhy

-- The craft-or-buy rule, for a merged reagent list and its mains: craft a
-- reagent when that makes the shopping list cheaper or it can't be bought,
-- never when that leaves something unpriced.
-- Starts from the per-unit comparison and decides top-down, twice
-- (a reagent's answer can change once the ones below it are decided).
-- Mains' reagent recipes not in the list stay crafted. opts: pricing.
local function recommend(flat, mains, opts)
  local state = {}
  for _, entry in ipairs(flat) do state[entry.sub.recipeID] = entry.include and true or false end
  local function on(id) return state[id] ~= false end
  for _ = 1, 2 do
    for _, entry in ipairs(flat) do
      local id = entry.sub.recipeID
      local effect = craftEffect(mains, on, id, opts)
      state[id] = effect.needed or (not effect.unknown and effect.saving > 0)
      entry.why = effectWhy(effect)
    end
  end
  for _, entry in ipairs(flat) do entry.include = state[entry.sub.recipeID] end
  return flat
end
ns.recommend = recommend

------------------------------------------------------------------------------
-- Buying the queue's vendor-sold reagents when you open a merchant (Buy
-- items from vendors ticked), after you confirm the total: what the
-- Missing list still needs, skipping
-- items that cost tokens or honor, capped by limited stock and your gold.
------------------------------------------------------------------------------

local function merchantItem(i)
  local info = C_MerchantFrame and C_MerchantFrame.GetItemInfo and C_MerchantFrame.GetItemInfo(i)
  if info then return info.price, info.stackCount, info.numAvailable, info.isPurchasable, info.hasExtendedCost end
  if GetMerchantItemInfo then
    local _, _, price, stack, available, purchasable, _, extended = GetMerchantItemInfo(i)
    return price, stack, available, purchasable, extended
  end
end

local merchantBuying = false
local function buyFromMerchant()
  if db.noVendor or merchantBuying or not (GetMerchantNumItems and GetMerchantItemID and BuyMerchantItem) then return end
  local want = {}
  for _, item in ipairs((queueShopping())) do
    if item.buy > 0 then want[item.id] = item end
  end
  if not next(want) then return end
  local calls, bought, poor, money = {}, {}, {}, GetMoney()
  for i = 1, GetMerchantNumItems() do
    local item = want[GetMerchantItemID(i)]
    local price, stack, available, purchasable, extended = merchantItem(i)
    if item and price and price > 0 and purchasable ~= false and not extended then
      stack = math.max(stack or 1, 1)
      -- Items sold in bundles are bought a bundle per call; others in as
      -- many per call as the merchant allows.
      local purchases = math.ceil(item.buy / stack)
      if available and available >= 0 then purchases = math.min(purchases, available) end
      local affordable = math.floor(money / price)
      if affordable < purchases then poor[#poor + 1] = item.name end
      purchases = math.min(purchases, affordable)
      if purchases > 0 then
        money = money - purchases * price
        bought[#bought + 1] = ("%dx %s"):format(purchases * stack, item.name)
        if stack > 1 then
          for _ = 1, purchases do calls[#calls + 1] = { i } end
        else
          local per = math.max((GetMerchantItemMaxStack and GetMerchantItemMaxStack(i)) or 1, 1)
          local left = purchases
          while left > 0 do
            calls[#calls + 1] = { i, math.min(left, per) }
            left = left - per
          end
        end
      end
    end
  end
  if #calls == 0 then
    if #poor > 0 then ns.msg("Not enough gold to buy any of: " .. table.concat(poor, ", ")) end
    return
  end
  local spend = GetMoney() - money
  -- Nothing is bought until you confirm.
  StaticPopupDialogs.PROFESSIONPROFIT_VENDOR_BUY = StaticPopupDialogs.PROFESSIONPROFIT_VENDOR_BUY or {
    text = "%s", button1 = PURCHASE or "Buy", button2 = CANCEL or "Cancel",
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
  }
  local dialog = StaticPopupDialogs.PROFESSIONPROFIT_VENDOR_BUY
  dialog.OnAccept = function()
    ns.msg(("Buying for the queue: %s (%s)."):format(table.concat(bought, ", "), API.Money(spend)))
    log("vendor buy", #calls, "purchases", table.concat(bought, ", "))
    -- One purchase at a time, a moment apart, while the merchant stays open.
    merchantBuying = true
    for n, call in ipairs(calls) do
      C_Timer.After((n - 1) * 0.2, function()
        if MerchantFrame and MerchantFrame:IsShown() then BuyMerchantItem(call[1], call[2]) end
        if n == #calls then merchantBuying = false end
      end)
    end
  end
  local text = ("ProfessionProfit: buy reagents for the craft queue?\n\n%s\n\nTotal: %s"):format(
    table.concat(bought, "\n"), API.Money(spend))
  if #poor > 0 then text = text .. "\n|cffff6666Not enough gold for all of: " .. table.concat(poor, ", ") .. "|r" end
  StaticPopup_Show("PROFESSIONPROFIT_VENDOR_BUY", text)
end
local function cancelMerchantBuy()
  if StaticPopup_Hide then StaticPopup_Hide("PROFESSIONPROFIT_VENDOR_BUY") end
end
ns.cancelMerchantBuy = cancelMerchantBuy
ns.buyFromMerchant = buyFromMerchant

local function firstCraftable()
  for index, entry in ipairs(computeQueue()) do
    local n = craftableNow(entry)
    if n > 0 then return entry, index, math.min(n, entry.count) end
  end
end
ns.firstCraftable = firstCraftable
