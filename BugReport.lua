-- ProfessionProfit: bug reports. Records when the game blocks this addon
-- ("only available to the Blizzard UI") and Lua errors coming from it, keeps
-- them in ProfessionProfitDB.bugs across reloads, and /pp bug shows a report
-- (versions, settings, what went wrong, recent diagnostics) ready to copy.

local ADDON, ns = ...
local API, msg, log, isModern, professionInfo = ns.API, ns.msg, ns.log, ns.isModern, ns.professionInfo
local db
local MAX_BUGS = 20
local LOG_LINES_PER_BUG = 25
local ISSUES_URL = "https://github.com/TLWoodJr/ProfessionProfit/issues"

local GetAddOnMetadata = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
local IsAddOnLoaded = (C_AddOns and C_AddOns.IsAddOnLoaded) or IsAddOnLoaded

local function addonVersion(name)
  if not (IsAddOnLoaded and IsAddOnLoaded(name)) then return nil end
  local ok, version = pcall(GetAddOnMetadata, name, "Version")
  return ok and version or "?"
end

-- An error is ours when this addon's (or its library's) files are on the stack.
local function isOurs(text)
  return type(text) == "string" and (text:find(ADDON, 1, true) or text:find("LibCraftProfit", 1, true)) ~= nil
end

local warnedThisSession = false

-- kind: "blocked" or "error". The same problem again only bumps its count.
local function record(kind, title, details)
  if not db then return end
  db.bugs = db.bugs or {}
  for _, bug in ipairs(db.bugs) do
    if bug.kind == kind and bug.title == title then
      bug.count = (bug.count or 1) + 1
      bug.last = date("%Y-%m-%d %H:%M:%S")
      return
    end
  end
  table.insert(db.bugs, {
    kind = kind, title = title, details = details, count = 1,
    first = date("%Y-%m-%d %H:%M:%S"), last = date("%Y-%m-%d %H:%M:%S"),
    version = addonVersion(ADDON), log = ns.recentLog(LOG_LINES_PER_BUG),
  })
  while #db.bugs > MAX_BUGS do table.remove(db.bugs, 1) end
  if not warnedThisSession then
    warnedThisSession = true
    if kind == "blocked" then
      msg("|cffff6666the game blocked an action (" .. title .. ").|r If a pop-up asks, choose Ignore rather than Disable. "
        .. "Type |cffffffff/pp bug|r and send the report so it can be fixed.")
    else
      msg("|cffff6666hit an error.|r Type |cffffffff/pp bug|r and send the report so it can be fixed.")
    end
  end
end

------------------------------------------------------------------------------
-- Capturing
------------------------------------------------------------------------------

-- ADDON_ACTION_FORBIDDEN / BLOCKED name the addon the game blames and the
-- protected function it refused.
local watcher = CreateFrame("Frame")
watcher:RegisterEvent("ADDON_ACTION_FORBIDDEN")
watcher:RegisterEvent("ADDON_ACTION_BLOCKED")
watcher:SetScript("OnEvent", function(_, event, addon, func)
  if addon ~= ADDON then return end
  log("blocked:", event, func)
  record("blocked", tostring(func or "?"), event .. ": the game refused " .. tostring(func or "?")
    .. ". Usually Blizzard's own code ran with data this addon touched (taint).")
end)

-- Lua errors: through BugGrabber when it's installed (it doesn't let others
-- replace the error handler), else by chaining the current handler.
local function onError(message, stack)
  if not (isOurs(message) or isOurs(stack)) then return end
  record("error", tostring(message):sub(1, 200), stack)
end

local function hookErrors()
  if BugGrabber and BugGrabber.RegisterCallback then
    BugGrabber.RegisterCallback(ns, "BugGrabber_BugGrabbed", function(_, err)
      if type(err) == "table" then onError(err.message, err.stack) end
    end)
    return
  end
  local previous = geterrorhandler()
  seterrorhandler(function(message, ...)
    pcall(onError, message, debugstack and debugstack(3) or nil)
    if previous then return previous(message, ...) end
  end)
end

ns.onInit(function(saved)
  db = saved
  hookErrors()
end)

------------------------------------------------------------------------------
-- The report
------------------------------------------------------------------------------

local function buildReport()
  local lines = {}
  local function add(...) lines[#lines + 1] = table.concat({ ... }, "") end
  local version, build, _, toc = GetBuildInfo()
  local source = API.ActiveSource and API.ActiveSource()
  local _, lib = LibStub("LibCraftProfit-1.0")

  add("**ProfessionProfit bug report**")
  add("What were you doing when it happened? ")
  add("")
  add("ProfessionProfit ", addonVersion(ADDON) or "?", " | LibCraftProfit-1.0 r", tostring(lib))
  add("Game ", tostring(version), " (", tostring(build), ") interface ", tostring(toc), " | ", GetLocale(),
    " | ", isModern() and "Professions window" or "classic trade skill window")
  add("Auctionator ", addonVersion("Auctionator") or "not loaded", " | TSM ", addonVersion("TradeSkillMaster") or "not loaded",
    " | BugGrabber ", addonVersion("!BugGrabber") or "not loaded")
  add("Price source: ", source and source.name or "none", " | profession open: ", tostring(professionInfo(true) or "none"))
  add("")

  local bugs = db and db.bugs or {}
  if #bugs == 0 then
    add("No problems recorded. If something went wrong, describe it above.")
  end
  for i = #bugs, 1, -1 do
    local bug = bugs[i]
    add("--- ", bug.kind == "blocked" and "BLOCKED: " or "ERROR: ", bug.title)
    add(bug.first, (bug.count or 1) > 1 and (" (x" .. bug.count .. ", last " .. bug.last .. ")") or "",
      " on version ", tostring(bug.version))
    if bug.details then add(tostring(bug.details)) end
    if bug.log and #bug.log > 0 then
      add("Diagnostics just before:")
      for _, line in ipairs(bug.log) do add("  ", line) end
    end
    add("")
  end

  add("--- recent diagnostics")
  for _, line in ipairs(ns.recentLog(40)) do add("  ", line) end
  return table.concat(lines, "\n")
end
ns.buildBugReport = buildReport

local win

local function createWindow()
  win = CreateFrame("Frame", "ProfessionProfitBugReport", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
  win:SetSize(560, 420)
  win:SetPoint("CENTER")
  win:SetFrameStrata("DIALOG")
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
  tinsert(UISpecialFrames, "ProfessionProfitBugReport") -- Esc closes it
  local close = CreateFrame("Button", nil, win, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", -2, -2)

  local title = win:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  title:SetPoint("TOPLEFT", 14, -12)
  title:SetText("ProfessionProfit bug report")
  local hint = win:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  hint:SetPoint("TOPLEFT", 14, -30)
  hint:SetPoint("RIGHT", -14, 0)
  hint:SetJustifyH("LEFT")
  hint:SetText("Add what you were doing on the second line, then press Ctrl+A and Ctrl+C to copy it. Paste it to the author "
    .. "or into a GitHub issue: " .. ISSUES_URL)

  local scroll = CreateFrame("ScrollFrame", "ProfessionProfitBugReportScroll", win, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", 12, -62)
  scroll:SetPoint("BOTTOMRIGHT", -32, 44)
  local box = CreateFrame("EditBox", nil, scroll)
  box:SetMultiLine(true)
  box:SetAutoFocus(false)
  box:SetFontObject(ChatFontNormal)
  box:SetWidth(500)
  box:SetMaxLetters(0)
  box:SetScript("OnEscapePressed", function() win:Hide() end)
  scroll:SetScrollChild(box)
  scroll:SetScript("OnSizeChanged", function(_, width) box:SetWidth(width) end)
  -- Clicking anywhere in the text area focuses the box.
  scroll:EnableMouse(true)
  scroll:SetScript("OnMouseDown", function() box:SetFocus() end)
  win.box = box

  local selectAll = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
  selectAll:SetSize(100, 22)
  selectAll:SetPoint("BOTTOMLEFT", 12, 12)
  selectAll:SetText("Select all")
  selectAll:SetScript("OnClick", function() box:SetFocus() box:HighlightText() end)

  local clear = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
  clear:SetSize(110, 22)
  clear:SetPoint("BOTTOMRIGHT", -12, 12)
  clear:SetText("Clear recorded")
  clear:SetScript("OnClick", function()
    if not IsShiftKeyDown() then msg("Shift-click Clear recorded once you've sent the report.") return end
    if db then db.bugs = nil end
    box:SetText(buildReport())
    msg("recorded problems cleared.")
  end)
  win:Hide()
end

local function showBugReport()
  if not win then createWindow() end
  win.box:SetText(buildReport())
  win:Show()
  win.box:SetCursorPosition(0)
  win.box:SetFocus()
  win.box:HighlightText()
end
ns.showBugReport = showBugReport
