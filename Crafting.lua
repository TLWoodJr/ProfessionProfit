-- ProfessionProfit: Crafting the queue step by step (Craft all / Continue / key binding).

local ADDON, ns = ...
local msg, log, hostShown, professionInfo, evaluate, readRecipes = ns.msg, ns.log, ns.hostShown, ns.professionInfo, ns.evaluate, ns.readRecipes
local craftQueue, computeQueue, inOpenProfession, recipeDef, subTree, effectivelyIncluded = ns.craftQueue, ns.computeQueue, ns.inOpenProfession, ns.recipeDef, ns.subTree, ns.effectivelyIncluded
local mergeTrees, recommend, applyChoices = ns.mergeTrees, ns.recommend, ns.applyChoices
local firstCraftable, refresh = ns.firstCraftable, ns.refresh
local db
ns.onInit(function(saved) db = saved end)

------------------------------------------------------------------------------
-- Processing the whole queue
------------------------------------------------------------------------------
-- One click crafts the whole list: each step crafts the full count of the
-- first craftable entry (reagent crafts come first). When a step finishes we
-- wait for the bags to update, recount the queue (so freshly crafted reagents
-- are used) and start the next step. If the game won't start a craft without
-- a click, the button turns into "Continue" and each click runs one step.

-- State on ns (the queue window shows it):
--   ns.crafting    current step: { recipeID, left, auto, name, started, lastProgress }
--   ns.processing  { steps, needClick } while "Craft all" is running
-- Since "Craft all" was last started: profit of the queued items crafted
-- (total), and what crafting reagents saved over buying them (saved).
local earned = { total = 0, crafts = 0, unpriced = 0, saved = 0, reagents = 0 }
ns.earned = earned

local STEP_START_TIMEOUT = 2.5  -- no cast start by then: the game wants a click
local STEP_IDLE_TIMEOUT = 5     -- no progress by then: the step ended early

local startStep

local function stopProcessing(reason)
  local wasRunning = ns.processing ~= nil
  ns.processing, ns.crafting = nil, nil
  if reason and wasRunning then msg(reason) end
  if ns.updateQueueWindow then ns.updateQueueWindow() end
end
ns.stopProcessing = stopProcessing

local function nothingCraftableReason(queue)
  if #queue == 0 then return "Craft queue finished." end
  local here = 0
  for _, e in ipairs(queue) do if inOpenProfession(e) then here = here + 1 end end
  if here == 0 then
    return ("Nothing left for this profession. Still queued: %s."):format(queue[1].prof or "another profession")
  end
  return "Done for now - what's left needs reagents (see Missing in the queue window)."
end

-- The game ignores crafts an addon starts without a click / key press.
-- Once we've seen that, stop trying and ask for the press straight away.
local function waitForPress()
  if not ns.processing then return end
  ns.processing.needClick = true
  if SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON then PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON) end
  if ns.updateQueueWindow then ns.updateQueueWindow() end
end

local function scheduleNextStep(delay)
  if not ns.processing then return end
  -- Bags update a moment after the last cast; recount after that.
  C_Timer.After(delay or 0.8, function()
    if not ns.processing or ns.crafting then return end
    if db.craftNeedsClick then
      if firstCraftable() then waitForPress() else startStep(false) end
    else
      startStep(false)
    end
  end)
end

-- Watch a running step: if crafting stops early (out of mats, moved...)
-- without a failure event, move on.
local function watchStep(step)
  C_Timer.After(1, function()
    if ns.crafting ~= step then return end
    if GetTime() - step.lastProgress > (step.started and STEP_IDLE_TIMEOUT or STEP_START_TIMEOUT) then
      if not step.started and ns.processing then
        -- The game ignored a craft we started without a click.
        log("step didn't start:", step.name, step.fromClick and "(from a click!)" or "(auto - needs a click)")
        ns.crafting = nil
        if not step.fromClick then
          if not db.craftNeedsClick then
            msg("The game needs a click or key press to start each step - press Continue, or bind a key: Key Bindings > AddOns > ProfessionProfit.")
          end
          db.craftNeedsClick = true
        end
        waitForPress()
      else
        log("step idle, moving on:", step.name, "left", step.left)
        ns.crafting = nil
        scheduleNextStep(0.2)
      end
      return
    end
    watchStep(step)
  end)
end

startStep = function(fromClick)
  if not ns.processing then return end
  ns.processing.needClick = false
  if not hostShown() then stopProcessing("Stopped: the profession window was closed.") return end
  local entry, _, n = firstCraftable()
  if not entry then
    stopProcessing(nothingCraftableReason(computeQueue()))
    return
  end
  local ok, err = pcall(C_TradeSkillUI.CraftRecipe, entry.recipeID, n)
  log("step", ns.processing.steps + 1, entry.name, entry.recipeID, "x" .. n, fromClick and "(click)" or "(auto)", ok and "ok" or err)
  if not ok then
    stopProcessing("Couldn't craft " .. entry.name .. ": " .. tostring(err))
    return
  end
  ns.processing.steps = ns.processing.steps + 1
  ns.crafting = { recipeID = entry.recipeID, left = n, auto = entry.auto, name = entry.name,
    started = false, lastProgress = GetTime(), fromClick = fromClick }
  watchStep(ns.crafting)
  if ns.updateQueueWindow then ns.updateQueueWindow() end
end

-- The queue window's main button.
local function craftButtonClicked()
  if ns.processing and not ns.processing.needClick then
    stopProcessing("Stopped.")
    return
  end
  if ns.processing and ns.processing.needClick then
    startStep(true)
    return
  end
  local queue = computeQueue()
  if #queue == 0 then msg("The craft queue is empty.") return end
  if not hostShown() then msg("Open the profession window (K) to craft.") return end
  if not firstCraftable() then
    msg(nothingCraftableReason(queue))
    return
  end
  ns.processing = { steps = 0 }
  earned.total, earned.crafts, earned.unpriced, earned.saved, earned.reagents = 0, 0, 0, 0, 0
  startStep(true)
end
ns.craftButtonClicked = craftButtonClicked

-- Key binding "Craft next queue step": starts or continues, never stops.
function ProfessionProfit_CraftNext()
  if ns.processing and not ns.processing.needClick then return end -- a step is running
  craftButtonClicked()
end
BINDING_HEADER_PROFESSIONPROFIT = "ProfessionProfit"
BINDING_NAME_PROFESSIONPROFIT_CRAFTNEXT = "Craft next queue step"

local function onCraftStarted(spellID)
  if ns.crafting and ns.crafting.recipeID == spellID then
    if not ns.crafting.fromClick and db.craftNeedsClick then db.craftNeedsClick = false end
    ns.crafting.started = true
    ns.crafting.lastProgress = GetTime()
  end
end
ns.onCraftStarted = onCraftStarted

local function onCraftStopped(spellID, why)
  if ns.crafting and ns.crafting.recipeID == spellID and ns.processing then
    stopProcessing(("Stopped: %s was %s."):format(ns.crafting.name, why))
  end
end
ns.onCraftStopped = onCraftStopped

-- One cast finished: count it off the queue. Reagent crafts need no
-- bookkeeping - the new items in your bags lower their count by themselves.
-- Returns "queued" for a queued item, "reagent" for a reagent craft.
local function onCraftSucceeded(spellID)
  local isReagentCraft, stepDone, counted
  if ns.crafting and ns.crafting.recipeID == spellID then
    isReagentCraft = ns.crafting.auto
    ns.crafting.started = true
    ns.crafting.lastProgress = GetTime()
    ns.crafting.left = ns.crafting.left - 1
    if ns.crafting.left <= 0 then
      ns.crafting = nil
      stepDone = true
    end
  else
    local _, derived = computeQueue()
    isReagentCraft = derived[spellID] ~= nil and derived[spellID].count > 0
  end
  if not isReagentCraft then
    local queue = craftQueue()
    for index, entry in ipairs(queue) do
      if entry.recipeID == spellID then
        entry.count = entry.count - 1
        if entry.count <= 0 then table.remove(queue, index) end
        log("crafted", entry.name, "left", math.max(entry.count, 0))
        counted = "queued"
        break
      end
    end
  end
  -- Bags update a moment after the cast; recount then.
  C_Timer.After(0.3, function()
    if ns.updateQueueWindow then ns.updateQueueWindow() end
    if refresh then refresh() end
  end)
  if stepDone then scheduleNextStep() end
  return counted or (isReagentCraft and "reagent") or nil
end
ns.onCraftSucceeded = onCraftSucceeded

-- Re-decide which reagents to craft for everything queued in the open
-- profession, from current bags and prices (the queue's Refresh button).
local function recompileQueue()
  local prof = professionInfo(true)
  if not prof or not hostShown() then
    msg("Open a profession (K) to refresh its crafted reagents.")
    return
  end
  local byProduct, byID = {}, {}
  for _, recipe in ipairs(readRecipes()) do
    evaluate(recipe)
    if recipe.productID then byProduct[recipe.productID] = recipe end
    if recipe.recipeID then byID[recipe.recipeID] = recipe end
  end
  local crafting, buying, done, other = {}, {}, 0, {}
  local steps, others = {}, {}
  for _, main in ipairs(craftQueue()) do
    local recipe = inOpenProfession(main) and byID[main.recipeID]
    if recipe then
      done = done + 1
      local fresh = recipeDef(recipe)
      main.reagents, main.made, main.productID = fresh.reagents, fresh.made, fresh.productID
      steps[#steps + 1] = { main = main, recipe = recipe, crafts = main.count }
    else
      others[#others + 1] = main
      if not inOpenProfession(main) then other[main.prof or "another profession"] = true end
    end
  end
  -- Craft or buy by what it does to the whole queue's shopping list (and
  -- your remembered ticks).
  local merged, mains = mergeTrees(steps, byProduct)
  for _, main in ipairs(others) do mains[#mains + 1] = main end
  applyChoices(recommend(merged, mains))
  local chosen = {}
  for i, entry in ipairs(merged) do
    if effectivelyIncluded(merged, i) then
      chosen[entry.sub.recipeID] = recipeDef(entry.sub)
      crafting[entry.sub.name] = entry.include ~= entry.ruleInclude and "your choice" or entry.why
    else
      buying[entry.sub.name] = not entry.include and (entry.include ~= entry.ruleInclude and "your choice" or entry.why)
        or "level above is bought"
    end
  end
  for _, step in ipairs(steps) do
    step.main.subs = {}
    for id in pairs(step.tree) do step.main.subs[id] = chosen[id] end
  end
  local function describe(t)
    local parts = {}
    for name, why in pairs(t) do parts[#parts + 1] = name .. " (" .. why .. ")" end
    table.sort(parts)
    return #parts > 0 and table.concat(parts, ", ") or "none"
  end
  msg(("Refreshed %d queued %s item(s). Crafting: %s. Not crafting: %s."):format(done, prof, describe(crafting), describe(buying)))
  local others = {}
  for name in pairs(other) do others[#others + 1] = name end
  if #others > 0 then msg("Open " .. table.concat(others, ", ") .. " to refresh those entries too.") end
  log("recompile", prof, done, describe(crafting), "| buy:", describe(buying))
  ns.updateQueueWindow()
end
ns.recompileQueue = recompileQueue
