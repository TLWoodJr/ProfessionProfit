-- ProfessionProfit: The craft queue: saved entries, restock targets and reagent-craft planning.

local ADDON, ns = ...
local API, log, isModern, hostShown, professionInfo, professionName = ns.API, ns.log, ns.isModern, ns.hostShown, ns.professionInfo, ns.professionName
local itemName, GetItemCount, charKey = ns.itemName, ns.GetItemCount, ns.charKey
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
-- of truth for Top up. Set in the + view's "Restock to" box, or remembered
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
    prof = professionForRecipe(recipe.recipeID) or professionInfo(true) or professionName(),
    productID = recipe.productID, made = recipe.made, reagents = reagents,
  }
end
ns.recipeDef = recipeDef

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
ns.planDerived = planDerived

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
ns.computeQueue = computeQueue

-- Stop crafting a reagent for every queued item (buy it instead).
local function dropSub(subID)
  for _, main in ipairs(craftQueue()) do
    if main.subs then main.subs[subID] = nil end
  end
end
ns.dropSub = dropSub

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
ns.queueShopping = queueShopping

local function firstCraftable()
  for index, entry in ipairs(computeQueue()) do
    local n = craftableNow(entry)
    if n > 0 then return entry, index, math.min(n, entry.count) end
  end
end
ns.firstCraftable = firstCraftable
