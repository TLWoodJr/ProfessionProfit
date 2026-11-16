-- ProfessionProfit: Reading the open profession's learned recipes, and opening a recipe in the window.

local ADDON, ns = ...
local msg, log, idFromLink, nameFromLink, isModern = ns.msg, ns.log, ns.idFromLink, ns.nameFromLink, ns.isModern
local hostFrame, professionInfo, itemName = ns.hostFrame, ns.professionInfo, ns.itemName
local db
ns.onInit(function(saved) db = saved end)

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
  -- Saved for planning reagent crafts from other professions and characters.
  if ns.recordKnown then ns.recordKnown(list, professionInfo(true)) end
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
ns.readRecipes = readRecipes

-- Recipe currently shown in the Professions window's details pane.
local function selectedModernRecipeID()
  local page = ProfessionsFrame and ProfessionsFrame.CraftingPage
  local form = page and page.SchematicForm
  if form and form.GetRecipeInfo then
    local ok, info = pcall(form.GetRecipeInfo, form)
    if ok and type(info) == "table" then return info.recipeID end
  end
end

-- Opening a recipe must not run Blizzard's profession UI code from here
-- (RecipeList:SelectRecipe, SetTab, the search box, Professions filters):
-- Blizzard code called by an addon runs tainted, the selected recipe it
-- stores stays tainted, and the next press of Blizzard's Create button is
-- blocked ("only available to the Blizzard UI") and blamed on this addon.
-- C_TradeSkillUI.OpenRecipe is a game call: Blizzard's own event handler does
-- the selecting, so nothing it stores is tainted.
local function openModernRecipe(recipe)
  local id = recipe.recipeID
  log("open recipe", recipe.name, id, "currently selected:", selectedModernRecipeID() or "none")
  local ok, err = pcall(C_TradeSkillUI.OpenRecipe, id)
  if not ok then log("  OpenRecipe failed:", err) end
  -- The window updates a moment later; say so if the recipe didn't open
  -- (hidden by the search box or a filter, or the overview page is showing).
  C_Timer.After(0.3, function()
    local selected = selectedModernRecipeID()
    if selected == id then
      log("  opened", recipe.name)
    elseif selected ~= nil or not ok then
      log("  could not open", recipe.name, "- selected is", selected or "none")
      msg(("Couldn't open %s in the recipe list - clear the recipe search or filters if it's hidden."):format(recipe.name))
    end
  end)
end

local function openRecipeInUI(recipe)
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
ns.openRecipeInUI = openRecipeInUI

local function closeHost()
  -- A game call: Blizzard's own TRADE_SKILL_CLOSE handler hides the window.
  -- HideUIPanel from here would taint the UI panel layout.
  local close = (C_TradeSkillUI and C_TradeSkillUI.CloseTradeSkill) or CloseTradeSkill
  if close and pcall(close) then return end
  local host = hostFrame()
  if host and host:IsShown() then HideUIPanel(host) end
end
ns.closeHost = closeHost

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
ns.logEnvironment = logEnvironment

-- /pp dump: everything the game reports for every recipe ID of the open
-- profession, learned or not, saved to ProfessionProfitDB.recipeDump[profession]
-- (on disk after /reload) - to see what the client knows about unlearned
-- recipes before building on it. Counts go to chat.
local function dumpRecipes()
  if not isModern() then msg("/pp dump needs the Professions (K) window.") return end
  local ok, ids = pcall(C_TradeSkillUI.GetAllRecipeIDs)
  if not ok or type(ids) ~= "table" or #ids == 0 then
    msg("Open a profession first (no recipe IDs).")
    return
  end
  local prof = professionInfo(true) or "?"
  local dump = { time = time(), profession = prof, recipes = {} }
  local learned, unlearned, withSchematic, withOutput, lines = 0, 0, 0, 0, {}
  for _, id in ipairs(ids) do
    local info = C_TradeSkillUI.GetRecipeInfo(id)
    local okLine, lineID, lineName, parentID, parentName = pcall(C_TradeSkillUI.GetTradeSkillLineForRecipe or error, id)
    local okS, schematic = pcall(C_TradeSkillUI.GetRecipeSchematic, id, false)
    local row = {
      name = info and info.name, learned = info and info.learned, categoryID = info and info.categoryID,
      skillLine = okLine and lineName or nil, parentLine = okLine and parentName or nil,
      lineID = okLine and lineID or nil, parentLineID = okLine and parentID or nil,
      difficulty = info and info.relativeDifficulty, maxTrivial = info and info.maxTrivialLevel,
      enchant = info and info.isEnchantingRecipe or nil, gathering = info and info.isGatheringRecipe or nil,
      dummy = info and info.isDummyRecipe or nil,
    }
    if okS and type(schematic) == "table" then
      withSchematic = withSchematic + 1
      row.output, row.made, row.madeMax = schematic.outputItemID, schematic.quantityMin, schematic.quantityMax
      if row.output then withOutput = withOutput + 1 end
      row.reagents = {}
      for _, slot in ipairs(schematic.reagentSlotSchematics or {}) do
        local first = slot.reagents and slot.reagents[1]
        if first and first.itemID then row.reagents[#row.reagents + 1] = { first.itemID, slot.quantityRequired or 1, slot.reagentType } end
      end
    end
    if row.learned then learned = learned + 1 else unlearned = unlearned + 1 end
    local key = (row.parentLine or "?") .. " / " .. (row.skillLine or "?")
    lines[key] = (lines[key] or 0) + 1
    dump.recipes[id] = row
  end
  db.recipeDump = db.recipeDump or {}
  db.recipeDump[prof] = dump
  local parts = {}
  for key, n in pairs(lines) do parts[#parts + 1] = key .. ": " .. n end
  table.sort(parts)
  msg(("Dumped %d recipe IDs for %s: %d learned, %d unlearned, %d with reagents, %d with a crafted item.")
    :format(#ids, prof, learned, unlearned, withSchematic, withOutput))
  msg("By skill line: " .. table.concat(parts, ", "))
  msg("Saved to disk on /reload (ProfessionProfitDB.recipeDump). Open each profession and /pp dump again to add it.")
  log("recipe dump", prof, #ids, "ids", learned, "learned", unlearned, "unlearned", table.concat(parts, ", "))
end
ns.dumpRecipes = dumpRecipes
