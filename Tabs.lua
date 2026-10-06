-- ProfessionProfit: Recipes / Profit / Queue tabs on the profession window, and attaching to it.

local ADDON, ns = ...
local RED, msg, log, isModern, baseHost, skilletShown = ns.RED, ns.msg, ns.log, ns.isModern, ns.baseHost, ns.skilletShown
local hostFrame, hostShown, professionInfo, tabs, logEnvironment, refreshSoon = ns.hostFrame, ns.hostShown, ns.professionInfo, ns.tabs, ns.logEnvironment, ns.refreshSoon
local raiseAbove, createPanel, toggleQueueWindow, syncQueueWindow = ns.raiseAbove, ns.createPanel, ns.toggleQueueWindow, ns.syncQueueWindow

------------------------------------------------------------------------------
-- Tabs under the profession window
------------------------------------------------------------------------------

local built = false
ns.built = built
local lastError

-- Plain buttons styled like the rest of this UI. Blizzard's tab templates
-- differ between clients and can fail silently, so don't depend on them.
local function createTab(host, text)
  local tab = CreateFrame("Button", nil, host, "UIPanelButtonTemplate")
  tab:SetSize(100, 24)
  tab:SetText(text)
  tab:SetFrameLevel(host:GetFrameLevel() + 45)
  return tab
end

local function selectTab(id)
  for i = 1, 2 do
    -- Highlight the active tab by locking it pushed/disabled-looking.
    if tabs[i] then tabs[i]:SetEnabled(i ~= id) end
  end
  ns.panel:SetShown(id == 2)
end
ns.selectTab = selectTab

-- Used by the Profit table: clicking a row opens that recipe on the Recipes tab.
function ns.showRecipesTab() selectTab(1) end

-- Move the panel and tabs onto a profession window (Blizzard's or Skillet's).
local function attachTo(host)
  if not ns.panel or not host or ns.panel.host == host then return end
  log("attaching to", host)
  ns.panel.host = host
  ns.panel:SetParent(host)
  ns.panel:ClearAllPoints()
  ns.panel:SetAllPoints(host)
  for i, tab in ipairs(tabs) do
    tab:SetParent(host)
    tab:SetFrameLevel(host:GetFrameLevel() + 45)
    tab:ClearAllPoints()
    if i == 1 then
      tab:SetPoint("TOPLEFT", host, "BOTTOMLEFT", 16, -2)
    else
      tab:SetPoint("LEFT", tabs[i - 1], "RIGHT", 4, 0)
    end
  end
  if ns.panel:IsShown() then raiseAbove(host) end
end

local skilletHooked = false
local function hookSkillet()
  if skilletHooked or not SkilletFrame then return end
  skilletHooked = true
  SkilletFrame:HookScript("OnShow", function()
    log("SkilletFrame OnShow")
    attachTo(SkilletFrame)
    C_Timer.After(0.3, syncQueueWindow)
    refreshSoon()
  end)
  SkilletFrame:HookScript("OnHide", function()
    local base = baseHost()
    if base and base:IsShown() then attachTo(base) end
  end)
  if SkilletFrame:IsShown() then attachTo(SkilletFrame) end
end

-- The overview page (no profession picked) has no recipes to price: hide
-- Recipes / Profit there, closing Profit if it's open. The recipe list lives
-- on ProfessionsFrame.CraftingPage, which the overview hides; switching back
-- to the overview may not change what the game reports as the profession.
-- Checked a moment after the window changes (the game updates a bit late).
local function updateTabsForOverview()
  C_Timer.After(0.2, function()
    if not (tabs[1] and isModern() and hostShown()) then return end
    local page = ProfessionsFrame and ProfessionsFrame.CraftingPage
    local overview = (page and not page:IsShown()) or not professionInfo(true)
    if overview == tabs.overview then return end
    tabs.overview = overview
    local shown = {}
    for _, child in ipairs({ ProfessionsFrame:GetChildren() }) do
      if child:IsShown() and child ~= ns.panel then shown[#shown + 1] = child:GetDebugName() end
    end
    log("overview:", overview, "craftingPage shown:", page and page:IsShown(), "profession:",
      professionInfo(true) or "none", "| shown:", table.concat(shown, ", "))
    tabs[1]:SetShown(not overview)
    tabs[2]:SetShown(not overview)
    if overview and ns.panel and ns.panel:IsShown() then selectTab(1) end
  end)
end
ns.updateTabsForOverview = updateTabsForOverview

local baseHooked = false
local function hookBase()
  local base = baseHost()
  if baseHooked or not base then return end
  baseHooked = true
  base:HookScript("OnShow", function()
    log("host OnShow")
    -- Skillet hides Blizzard's window as soon as it opens; stay on Skillet.
    if not skilletShown() then attachTo(base) end
    refreshSoon()
    updateTabsForOverview()
    C_Timer.After(0.3, syncQueueWindow)
  end)
  base:HookScript("OnHide", function()
    tabs.overview = nil
    C_Timer.After(0, syncQueueWindow)
  end)
  -- Switching between a profession and the overview swaps this page.
  local page = base.CraftingPage
  if page then
    page:HookScript("OnShow", updateTabsForOverview)
    page:HookScript("OnHide", updateTabsForOverview)
  end
end

local function buildUI()
  local host = baseHost() or (SkilletFrame ~= nil and SkilletFrame) or nil
  if built or not host then return end
  built = true
  ns.built = built
  log("building UI on", host)
  createPanel(host)
  tabs[1] = createTab(host, "Recipes")
  tabs[2] = createTab(host, "Profit")
  tabs[1]:SetPoint("TOPLEFT", host, "BOTTOMLEFT", 16, -2)
  tabs[2]:SetPoint("LEFT", tabs[1], "RIGHT", 4, 0)
  tabs[3] = createTab(host, "Queue")
  tabs[3]:SetPoint("TOPRIGHT", host, "BOTTOMRIGHT", -16, -2)
  tabs[1]:SetScript("OnClick", function() selectTab(1) end)
  tabs[2]:SetScript("OnClick", function() selectTab(2) end)
  tabs[3]:SetScript("OnClick", toggleQueueWindow)
  ns.updateQueueWindow()
  if not isModern() and TradeSkillFrame_Update then hooksecurefunc("TradeSkillFrame_Update", refreshSoon) end
  hookBase()
  hookSkillet()
  selectTab(1)
  log("UI built; tab1:", tabs[1], "tab2:", tabs[2])
end

local function createTabs(reason)
  if built then hookBase() hookSkillet() return end
  if not hostFrame() then return end
  local ok, err = xpcall(buildUI, function(e) return tostring(e) .. "\n" .. (debugstack and debugstack(2) or "") end)
  if ok then
    logEnvironment("UI built after " .. tostring(reason))
  else
    lastError = err
    ns.lastError = lastError
    log("buildUI error:", err)
    msg(RED .. "failed to add the Profit tab:|r " .. tostring(err):match("^[^\n]*"))
  end
end
ns.createTabs = createTabs
