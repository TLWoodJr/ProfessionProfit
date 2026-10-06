-- ProfessionProfit: Saved variables, events and slash commands.

local ADDON, ns = ...
local API, msg, log, isModern, recordOwnedAuctions, logEnvironment = ns.API, ns.msg, ns.log, ns.isModern, ns.recordOwnedAuctions, ns.logEnvironment
local forgetOpenRecipeIDs, updateScanButton, startScan, refreshSoon, stopProcessing, onCraftStarted = ns.forgetOpenRecipeIDs, ns.updateScanButton, ns.startScan, ns.refreshSoon, ns.stopProcessing, ns.onCraftStarted
local onCraftStopped, onCraftSucceeded, showReagentWindow, toggleQueueWindow, syncQueueWindow, selectTab = ns.onCraftStopped, ns.onCraftSucceeded, ns.showReagentWindow, ns.toggleQueueWindow, ns.syncQueueWindow, ns.selectTab
local updateTabsForOverview, createTabs, showToast, craftToast, mailMoneyChanged = ns.updateTabsForOverview, ns.createTabs, ns.showToast, ns.craftToast, ns.mailMoneyChanged
local db
ns.onInit(function(saved) db = saved end)

------------------------------------------------------------------------------
-- Events
------------------------------------------------------------------------------

local frame = CreateFrame("Frame")
-- Event names differ between client versions (WoW Forever has no
-- TRADE_SKILL_UPDATE), so register each one only if this client knows it.
for _, event in ipairs({ "ADDON_LOADED", "PLAYER_LOGIN", "TRADE_SKILL_SHOW", "TRADE_SKILL_UPDATE", "TRADE_SKILL_LIST_UPDATE",
  "TRADE_SKILL_DATA_SOURCE_CHANGED", "TRADE_SKILL_CLOSE", "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED",
  "BAG_UPDATE_DELAYED", "GET_ITEM_INFO_RECEIVED", "OWNED_AUCTIONS_UPDATED",
  "PLAYERBANKSLOTS_CHANGED", "BANKFRAME_OPENED", "UNIT_SPELLCAST_SUCCEEDED",
  "UNIT_SPELLCAST_START", "UNIT_SPELLCAST_INTERRUPTED", "UNIT_SPELLCAST_FAILED",
  "MAIL_SHOW", "MAIL_CLOSED", "PLAYER_MONEY", "TRAINER_SHOW", "TRAINER_CLOSED" }) do
  pcall(frame.RegisterEvent, frame, event)
end

frame:SetScript("OnEvent", function(_, event, arg, ...)
  if event == "UNIT_SPELLCAST_SUCCEEDED" or event == "UNIT_SPELLCAST_START"
      or event == "UNIT_SPELLCAST_INTERRUPTED" or event == "UNIT_SPELLCAST_FAILED" then
    if arg ~= "player" or not db then return end
    local spellID = select(2, ...)
    if event == "UNIT_SPELLCAST_SUCCEEDED" then
      craftToast(spellID, onCraftSucceeded(spellID))
    elseif event == "UNIT_SPELLCAST_START" then onCraftStarted(spellID)
    elseif event == "UNIT_SPELLCAST_INTERRUPTED" then onCraftStopped(spellID, "interrupted")
    else onCraftStopped(spellID, "not crafted (failed)") end
    return
  end
  if event ~= "BAG_UPDATE_DELAYED" and event ~= "GET_ITEM_INFO_RECEIVED" and event ~= "PLAYER_MONEY" then log("event", event, arg) end
  if event == "ADDON_LOADED" then
    if arg == ADDON then
      ProfessionProfitDB = ProfessionProfitDB or {}
      db = ProfessionProfitDB
      ns.runInit(db)
      db.sortKey = db.sortKey or "profit"
      if db.sortDesc == nil then db.sortDesc = true end
      API.RegisterCallback(ADDON, "PricesUpdated", function()
        refreshSoon()
        if ns.updateQueueWindow then ns.updateQueueWindow() end
      end)
      db.queueQty = db.queueQty or 1
      db.recipeCache = nil -- from an old auto-scan; nothing reads it
      -- Top up starts ticked every session; unticking it lasts until /reload.
      db.queueTopUp, db.topUpDefaulted = true, nil
    end
    -- The profession window may come from an addon with a different name on
    -- this client, so check after every addon load.
    if db then createTabs("ADDON_LOADED " .. tostring(arg)) end
    return
  end
  if not db then return end

  if event == "PLAYER_MONEY" then
    mailMoneyChanged()
    return
  elseif event == "MAIL_SHOW" then
    ns.mailOpen, ns.lastMoney, ns.mailSubject, ns.mailTakeTime = true, GetMoney(), nil, nil
    return
  elseif event == "MAIL_CLOSED" then
    ns.mailOpen = false
    return
  end

  -- The table sits a strata above the profession window, so it would cover a
  -- trainer opened next to it: show Recipes while training, then switch back.
  if event == "TRAINER_SHOW" then
    log("trainer opened; profit table visible:", ns.panel and ns.panel:IsVisible() or false)
    if ns.panel and ns.panel:IsShown() then
      ns.panel.trainerHid = true
      selectTab(1)
    end
    return
  elseif event == "TRAINER_CLOSED" then
    if ns.panel and ns.panel.trainerHid then
      ns.panel.trainerHid = nil
      selectTab(2)
    end
    return
  end

  if event == "PLAYER_LOGIN" then
    log("login: modern UI =", isModern(), "ProfessionsFrame =", ProfessionsFrame or "nil", "TradeSkillFrame =", TradeSkillFrame or "nil")
    createTabs("PLAYER_LOGIN")
  elseif event == "GET_ITEM_INFO_RECEIVED" then
    if ns.itemNamePending then
      ns.itemNamePending = false
      refreshSoon()
    end
  elseif event == "TRADE_SKILL_SHOW" then
    -- Blizzard may create the window after this event reaches us.
    createTabs("TRADE_SKILL_SHOW")
    C_Timer.After(0, function()
      createTabs("TRADE_SKILL_SHOW+0")
      if not ns.built then logEnvironment("profession opened but no host frame") end
      refreshSoon()
    end)
  elseif event == "TRADE_SKILL_UPDATE" or event == "TRADE_SKILL_LIST_UPDATE"
      or event == "TRADE_SKILL_DATA_SOURCE_CHANGED" or event == "BAG_UPDATE_DELAYED" then
    if event ~= "BAG_UPDATE_DELAYED" then
      forgetOpenRecipeIDs()
      ns.craftLookup = nil
      updateTabsForOverview()
    end
    refreshSoon()
    if ns.updateQueueWindow then ns.updateQueueWindow() end
  elseif event == "TRADE_SKILL_CLOSE" then
    ns.craftLookup = nil
    if ns.processing then stopProcessing("Stopped: the profession window was closed.") end
    C_Timer.After(0, syncQueueWindow)
  elseif event == "OWNED_AUCTIONS_UPDATED" then
    recordOwnedAuctions()
    refreshSoon()
  elseif event == "PLAYERBANKSLOTS_CHANGED" or event == "BANKFRAME_OPENED" then
    refreshSoon()
  elseif event == "AUCTION_HOUSE_SHOW" then
    -- Nothing is sent to the AH here: scans only run from the Profit tab, and
    -- your auctions are read when the AH's own Auctions tab loads them.
    if ns.panel then updateScanButton() end
  elseif event == "AUCTION_HOUSE_CLOSED" then
    if ns.panel then updateScanButton() end
  end
end)

SLASH_PROFESSIONPROFIT1 = "/pprofit"
SLASH_PROFESSIONPROFIT2 = "/pp"
SlashCmdList.PROFESSIONPROFIT = function(input)
  local cmd = (input or ""):match("^%s*(%S*)"):lower()
  if cmd == "scan" then
    startScan()
  elseif cmd == "queue" then
    toggleQueueWindow()
  elseif cmd == "reagents" then
    if ns.popup then ns.popup.closed = nil end
    if ns.queueWin and ns.queueWin:IsShown() then showReagentWindow() else msg("Open the craft queue to see its reagents.") end
  elseif cmd == "toast" then
    local arg = (input or ""):match("^%s*%S+%s+(%S+)")
    arg = arg and arg:lower()
    if arg == "test" then
      showToast("test", "Crafted Test Item", nil, 12345)
    elseif arg == "mail" then
      db.mailToastOff = not db.mailToastOff or nil
      msg("mail gold pop-up " .. (db.mailToastOff and "off." or "on."))
    else
      db.craftToastOff = not db.craftToastOff or nil
      msg("craft profit pop-up " .. (db.craftToastOff and "off." or "on."))
    end
  elseif cmd == "debug" then
    createTabs("/pp debug")
    logEnvironment("/pp debug")
    log("tabs built:", ns.built, "last error:", ns.lastError or "none")
    if DevLog then
      DevLog.Show()
      msg("diagnostics written to DevLog. /reload to save them to disk.")
    else
      msg("install/enable the DevLog addon to see diagnostics.")
    end
  else
    msg("commands:")
    print("  /pp scan - scan AH prices for the open profession")
    print("  /pp queue - show/hide the craft queue")
    print("  /pp reagents - show the queue's reagent window again after closing it")
    print("  /pp toast - turn the craft profit pop-up on/off (/pp toast test to preview)")
    print("  /pp toast mail - turn the mail gold pop-up on/off")
    print("  /pp debug - show diagnostics if the Profit tab is missing")
  end
end
