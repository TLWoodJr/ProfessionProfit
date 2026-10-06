-- ProfessionProfit: Reading the open profession's learned recipes, and opening a recipe in the window.

local ADDON, ns = ...
local msg, log, idFromLink, nameFromLink, isModern, skilletShown = ns.msg, ns.log, ns.idFromLink, ns.nameFromLink, ns.isModern, ns.skilletShown
local hostFrame, professionInfo, itemName = ns.hostFrame, ns.professionInfo, ns.itemName

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

-- Switch the Professions window to its recipe list (Forever can be showing
-- the profession overview page instead).
local function showModernRecipesPage()
  local frame = ProfessionsFrame
  if frame.SetTab and frame.recipesTabID then
    local current = frame.GetTab and frame:GetTab()
    if current ~= frame.recipesTabID then
      local ok, err = pcall(frame.SetTab, frame, frame.recipesTabID)
      log("SetTab(recipes)", ok and "ok" or err)
    end
  end
end

local function selectInRecipeList(recipeID)
  local list = ProfessionsFrame.CraftingPage and ProfessionsFrame.CraftingPage.RecipeList
  local info = C_TradeSkillUI.GetRecipeInfo(recipeID)
  if list and list.SelectRecipe and info then
    local ok, err = pcall(list.SelectRecipe, list, info, true)
    return ok, ok and "RecipeList:SelectRecipe" or tostring(err)
  end
  return false, "no RecipeList:SelectRecipe"
end

-- The recipe search box and "have materials"-style filters can hide the
-- recipe from the list, which makes selecting it silently fail.
local function clearRecipeFilters()
  local list = ProfessionsFrame.CraftingPage and ProfessionsFrame.CraftingPage.RecipeList
  local box = list and list.SearchBox
  if box and box.GetText and box:GetText() ~= "" then
    box:SetText("")
    log("cleared recipe search box")
  end
  if C_TradeSkillUI.SetRecipeItemNameFilter then pcall(C_TradeSkillUI.SetRecipeItemNameFilter, "") end
  if Professions and Professions.SetDefaultFilters then
    local ok, err = pcall(Professions.SetDefaultFilters)
    log("Professions.SetDefaultFilters", ok and "ok" or err)
  end
end

-- Try progressively stronger ways to open the recipe, checking each one.
local OPEN_STEPS = {
  function(id) return selectInRecipeList(id) end,
  function(id)
    clearRecipeFilters()
    return true, "cleared filters (retry next step)"
  end,
  function(id) return selectInRecipeList(id) end,
  function(id)
    local ok, err = pcall(C_TradeSkillUI.OpenRecipe, id)
    return ok, ok and "C_TradeSkillUI.OpenRecipe" or tostring(err)
  end,
}

local function openModernRecipe(recipe, step)
  step = step or 1
  local id = recipe.recipeID
  if step == 1 then
    log("open recipe", recipe.name, id, "currently selected:", selectedModernRecipeID() or "none")
    showModernRecipesPage()
  end
  local ok, how = OPEN_STEPS[step](id)
  log("  step", step, how, ok and "" or "(failed)")
  -- Without a way to read the selection, never escalate to clearing filters.
  local page = ProfessionsFrame.CraftingPage
  if not (page and page.SchematicForm and page.SchematicForm.GetRecipeInfo) then
    if not ok then pcall(C_TradeSkillUI.OpenRecipe, id) end
    log("  can't verify selection; stopping after step", step)
    return
  end
  -- The list rebuilds asynchronously, so check a moment later.
  C_Timer.After(step == 2 and 0.3 or 0.15, function()
    if selectedModernRecipeID() == id then
      log("  opened", recipe.name, "via step", step)
    elseif step < #OPEN_STEPS then
      openModernRecipe(recipe, step + 1)
    else
      log("  could not open", recipe.name, "- selected is", selectedModernRecipeID() or "none")
      msg(("Couldn't select %s in the recipe list."):format(recipe.name))
    end
  end)
end

local function openRecipeInUI(recipe)
  if skilletShown() and Skillet and Skillet.SetSelectedSkill and recipe.recipeID then
    local index = Skillet.data and Skillet.data.skillIndexLookup and Skillet.data.skillIndexLookup[recipe.recipeID]
    log("open recipe in Skillet", recipe.name, recipe.recipeID, "index", index or "none")
    if index then
      pcall(Skillet.SetSelectedSkill, Skillet, index)
      pcall(Skillet.UpdateTradeSkillWindow, Skillet)
    else
      msg(("%s isn't in Skillet's recipe list (check Skillet's filters)."):format(recipe.name))
    end
    return
  end
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
  if skilletShown() then
    pcall(HideUIPanel, SkilletFrame)
    if SkilletFrame:IsShown() then SkilletFrame:Hide() end
  end
  if isModern() and C_TradeSkillUI.CloseTradeSkill then
    pcall(C_TradeSkillUI.CloseTradeSkill)
  end
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
