-- ProfessionProfit: Recipes your characters know in every profession, saved
-- whenever a profession window is read, so a reagent that another of your
-- professions (or another character) makes can be crafted instead of bought.

local ADDON, ns = ...
local charKey, evaluate, itemName, log = ns.charKey, ns.evaluate, ns.itemName, ns.log
local db
ns.onInit(function(saved) db = saved end)

-- db.knownRecipes[charKey][profession] = { t = time(),
--   recipes = { [recipeID] = { name, productID, made, { { reagentID, count }, ... } } } }
local function recordKnown(recipes, prof)
  if not prof or #recipes == 0 then return end
  -- Someone else's profession (a linked or guild recipe list) isn't yours.
  for _, check in ipairs({ "IsTradeSkillLinked", "IsTradeSkillGuild", "IsNPCCrafting" }) do
    local fn = C_TradeSkillUI and C_TradeSkillUI[check]
    if fn then
      local ok, yes = pcall(fn)
      if ok and yes then return end
    end
  end
  local saved = {}
  for _, recipe in ipairs(recipes) do
    if recipe.recipeID and recipe.productID then
      local reagents, complete = {}, true
      for _, reagent in ipairs(recipe.reagents) do
        if reagent.id then reagents[#reagents + 1] = { reagent.id, reagent.count } else complete = false end
      end
      if complete then saved[recipe.recipeID] = { recipe.name, recipe.productID, recipe.made, reagents } end
    end
  end
  db.knownRecipes = db.knownRecipes or {}
  local mine = db.knownRecipes[charKey()] or {}
  db.knownRecipes[charKey()] = mine
  mine[prof] = { t = time(), recipes = saved }
end
ns.recordKnown = recordKnown

-- "Name" for a character on this realm, else "Name-Realm".
local function crafterName(key)
  local name, realm = key:match("^(.-)%-(.*)$")
  if not name then return key end
  if realm == (GetRealmName and GetRealmName()) then return name end
  return key
end
ns.crafterName = crafterName

-- Where a recipe is crafted, for labels: "Blacksmithing", or "Alt, Blacksmithing".
local function crafterLabel(recipe)
  if recipe.crafter then return crafterName(recipe.crafter) .. (recipe.prof and (", " .. recipe.prof) or "") end
  return recipe.prof
end
ns.crafterLabel = crafterLabel

-- A saved recipe as a priced recipe table.
local function build(key, prof, recipeID, s)
  local reagents = {}
  for _, r in ipairs(s[4]) do reagents[#reagents + 1] = { id = r[1], name = itemName(r[1]), count = r[2] } end
  local recipe = {
    key = recipeID, recipeID = recipeID, name = s[1], productID = s[2],
    productName = itemName(s[2]) or s[1], made = s[3] or 1, reagents = reagents,
    prof = prof, crafter = key ~= charKey() and key or nil,
  }
  evaluate(recipe)
  return recipe
end

-- Every saved recipe that makes a reagent of some saved recipe, priced, by
-- product: { [productID] = recipe } with recipe.prof, and recipe.crafter
-- (charKey) when only another character knows it. This character's recipes
-- win, then other characters in name order. Cached for a second.
local cache
local function knownByProduct()
  if cache and GetTime() - cache.t < 1 then return cache.map end
  local me, keys, used = charKey(), {}, {}
  for key, profs in pairs(db.knownRecipes or {}) do
    keys[#keys + 1] = key
    for _, rec in pairs(profs) do
      for _, s in pairs(rec.recipes or {}) do
        for _, r in ipairs(s[4]) do used[r[1]] = true end
      end
    end
  end
  table.sort(keys, function(a, b)
    if (a == me) ~= (b == me) then return a == me end
    return a < b
  end)
  local map = {}
  for _, key in ipairs(keys) do
    for prof, rec in pairs(db.knownRecipes[key]) do
      for recipeID, s in pairs(rec.recipes or {}) do
        local productID = s[2]
        if used[productID] and not map[productID] then map[productID] = build(key, prof, recipeID, s) end
      end
    end
  end
  cache = { t = GetTime(), map = map }
  return map
end

-- The open profession's priced recipes by product (live), plus whatever
-- your other professions and characters make that live doesn't.
local function withKnown(live)
  local map = {}
  for productID, recipe in pairs(live or {}) do map[productID] = recipe end
  for productID, recipe in pairs(knownByProduct()) do
    if not map[productID] then map[productID] = recipe end
  end
  return map
end
ns.withKnown = withKnown

-- A saved recipe (any of your characters) that makes itemID, priced, or nil.
local function knownRecipeFor(itemID)
  for key, profs in pairs(db.knownRecipes or {}) do
    for prof, rec in pairs(profs) do
      for recipeID, s in pairs(rec.recipes or {}) do
        if s[2] == itemID then return build(key, prof, recipeID, s) end
      end
    end
  end
end
ns.knownRecipeFor = knownRecipeFor

local function forgetKnownCache() cache = nil end
ns.forgetKnownCache = forgetKnownCache
