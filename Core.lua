-- ProfessionProfit: a "Profit" tab under the profession window listing every
-- learned recipe with reagent cost, sale price and profit. While the auction
-- house is open it searches the AH for all reagents and crafted items.
--
-- Prices come from Auctionator through LibCraftProfit-1.0 (shared with
-- RecipeProfit), and Scan AH searches through Auctionator too, so the
-- numbers always match Auctionator's.
--
-- Two profession UIs are supported:
--   modern:  ProfessionsFrame + C_TradeSkillUI (WoW Forever: one window, K)
--   classic: TradeSkillFrame + GetTradeSkillInfo() etc.
-- Diagnostics go to DevLog when it's installed (/devlog to view).
--
-- The addon is split into files (see the TOC) sharing the namespace table
-- `ns`. Core.lua: shared helpers - profession window detection, item info,
-- stock counts and pricing.

local ADDON, ns = ...

-- Saved variables (ProfessionProfitDB) reach every file through onInit:
-- each file keeps its own `local db`, set when the addon loads.
local inits = {}
function ns.onInit(fn) inits[#inits + 1] = fn end
function ns.runInit(saved) for _, fn in ipairs(inits) do fn(saved) end end

local ROW_HEIGHT = 18
ns.ROW_HEIGHT = ROW_HEIGHT

local API = LibStub("LibCraftProfit-1.0")
ns.API = API
local db
ns.onInit(function(saved) db = saved end)

local RED, GREY, GREEN = "|cffff6666", "|cffa0a0a0", "|cff33ff33"
ns.RED = RED; ns.GREY = GREY; ns.GREEN = GREEN

local DIFFICULTY_COLORS = {
  optimal = { 1, 0.5, 0.25 }, medium = { 1, 1, 0 }, easy = { 0.25, 0.75, 0.25 }, trivial = { 0.55, 0.55, 0.55 },
}
ns.DIFFICULTY_COLORS = DIFFICULTY_COLORS

local function msg(text)
  DEFAULT_CHAT_FRAME:AddMessage("|cffffd100ProfessionProfit:|r " .. text)
end
ns.msg = msg

local function log(...)
  if DevLog then DevLog.Log(ADDON, ...) end
end
ns.log = log

local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
local RequestLoadItemDataByID = (C_Item and C_Item.RequestLoadItemDataByID) or function() end

local function idFromLink(link)
  return link and tonumber(link:match("item:(%d+)"))
end
ns.idFromLink = idFromLink

local function nameFromLink(link)
  return link and link:match("%[(.-)%]")
end
ns.nameFromLink = nameFromLink

local function ahOpen()
  return (AuctionHouseFrame and AuctionHouseFrame:IsShown()) or (AuctionFrame and AuctionFrame:IsShown())
end
ns.ahOpen = ahOpen

------------------------------------------------------------------------------
-- Reading learned recipes
------------------------------------------------------------------------------

-- Modern when the client ships the retail Professions UI (loaded on demand
-- the first time you press K), even before that window exists.
local modernCached
local function isModern()
  if modernCached ~= nil then return modernCached end
  if not (C_TradeSkillUI and C_TradeSkillUI.GetAllRecipeIDs) then
    modernCached = false
    return false
  end
  if ProfessionsFrame then
    modernCached = true
    return true
  end
  local getInfo = (C_AddOns and C_AddOns.GetAddOnInfo) or GetAddOnInfo
  local ok, name, _, _, loadable, reason = pcall(getInfo, "Blizzard_Professions")
  modernCached = ok and name ~= nil and reason ~= "MISSING"
  return modernCached
end
ns.isModern = isModern

-- Blizzard's profession window (nil until it exists).
local function baseHost()
  if isModern() then return ProfessionsFrame end
  return TradeSkillFrame
end
ns.baseHost = baseHost

-- Skillet replaces Blizzard's window with its own SkilletFrame.
local function skilletShown()
  return SkilletFrame ~= nil and SkilletFrame:IsShown()
end
ns.skilletShown = skilletShown

-- The window our tab and panel attach to right now.
local function hostFrame()
  if skilletShown() then return SkilletFrame end
  return baseHost()
end
ns.hostFrame = hostFrame

local function hostShown()
  if skilletShown() then return true end
  local host = baseHost()
  return host and host:IsShown()
end
ns.hostShown = hostShown

-- name, rank, maxRank of the open profession
local lastProfession -- { name, rank, max }: the overview page reports no profession

local function professionInfo(strict)
  if isModern() then
    for _, getter in ipairs({ "GetChildProfessionInfo", "GetBaseProfessionInfo" }) do
      local fn = C_TradeSkillUI[getter]
      local ok, info = pcall(fn or error)
      if ok and type(info) == "table" and info.professionName and info.professionName ~= "" then
        lastProfession = { info.professionName, info.skillLevel, info.maxSkillLevel }
        return info.professionName, info.skillLevel, info.maxSkillLevel
      end
    end
    if lastProfession and not strict then return unpack(lastProfession) end
    return nil
  end
  local name, rank, maxRank = GetTradeSkillLine and GetTradeSkillLine()
  if name and name ~= "" and name ~= "UNKNOWN" then return name, rank, maxRank end
end
ns.professionInfo = professionInfo

local function professionName()
  return (professionInfo())
end
ns.professionName = professionName

-- Classic only: expand collapsed categories so every learned recipe is listed.
local function expandAll()
  if not isModern() and ExpandTradeSkillSubClass then pcall(ExpandTradeSkillSubClass, 0) end
end
ns.expandAll = expandAll

ns.itemNamePending = false
local function itemName(itemID)
  local name = itemID and GetItemInfo(itemID)
  if not name and itemID then
    RequestLoadItemDataByID(itemID)
    ns.itemNamePending = true
  end
  return name
end
ns.itemName = itemName

-- Bind on pickup: can't be sold on the AH. Unknown until the item's data
-- has loaded (the table refreshes when it arrives).
local BIND_ON_PICKUP = (Enum and Enum.ItemBind and Enum.ItemBind.OnAcquire) or 1
local function isBoP(itemID)
  if not itemID then return false end
  local name, _, _, _, _, _, _, _, _, _, _, _, _, bindType = GetItemInfo(itemID)
  if not name then
    RequestLoadItemDataByID(itemID)
    ns.itemNamePending = true
    return false
  end
  return bindType == BIND_ON_PICKUP
end
ns.isBoP = isBoP

------------------------------------------------------------------------------
-- Stock: crafted items you own (bags + bank + your active auctions)
------------------------------------------------------------------------------

local GetItemCount = (C_Item and C_Item.GetItemCount) or GetItemCount
ns.GetItemCount = GetItemCount

local function charKey()
  return (UnitName("player") or "?") .. "-" .. (GetRealmName and GetRealmName() or "?")
end
ns.charKey = charKey

-- Active auctions are only visible while the AH is open, so keep the last
-- known counts per character.
local function ownedAuctions()
  db.ownedAuctions = db.ownedAuctions or {}
  return db.ownedAuctions[charKey()]
end
ns.ownedAuctions = ownedAuctions

local function recordOwnedAuctions()
  if not (C_AuctionHouse and C_AuctionHouse.GetNumOwnedAuctions) then return end
  local counts = {}
  local soldStatus = Enum and Enum.AuctionStatus and Enum.AuctionStatus.Sold or 1
  for i = 1, C_AuctionHouse.GetNumOwnedAuctions() do
    local info = C_AuctionHouse.GetOwnedAuctionInfo(i)
    if info and info.itemKey and info.status ~= soldStatus then
      local id = info.itemKey.itemID
      counts[id] = (counts[id] or 0) + (info.quantity or 1)
    end
  end
  db.ownedAuctions = db.ownedAuctions or {}
  db.ownedAuctions[charKey()] = { counts = counts, time = time() }
  log("owned auctions recorded:", C_AuctionHouse.GetNumOwnedAuctions(), "auctions")
end
ns.recordOwnedAuctions = recordOwnedAuctions

-- total, bags, bank, onAH
local function stockOf(itemID)
  if not itemID or not GetItemCount then return 0, 0, 0, 0 end
  local bags = GetItemCount(itemID, false) or 0
  local all = GetItemCount(itemID, true) or bags
  local owned = ownedAuctions()
  local onAH = owned and owned.counts[itemID] or 0
  return all + onAH, bags, all - bags, onAH
end
ns.stockOf = stockOf

------------------------------------------------------------------------------
-- Pricing (LibCraftProfit: Auctionator's prices, same rules as its "To Craft")
------------------------------------------------------------------------------

local function evaluate(recipe)
  API.Evaluate(recipe)
  if recipe.productID then
    recipe.stock, recipe.stockBags, recipe.stockBank, recipe.stockAH = stockOf(recipe.productID)
  else
    recipe.stock = nil
  end
end
ns.evaluate = evaluate
local tabs = {}
ns.tabs = tabs
