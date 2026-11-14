-- ProfessionProfit: the price source menu (the cog at the Profit tab's
-- bottom left): choose Auctionator or one of TSM's prices. Saved in
-- db.priceSource and handed to LibCraftProfit, which reads every price from it.

local ADDON, ns = ...
local API, msg = ns.API, ns.msg
local db
ns.onInit(function(saved)
  db = saved
  if db.priceSource then API.SetPriceSource(db.priceSource) end
end)

local ROW = 20
local menu

local function choose(key)
  db.priceSource = key
  API.SetPriceSource(key) -- fires PricesUpdated: the table refreshes
  menu:Hide()
  local source = API.ActiveSource()
  msg("prices now come from " .. (source and source.name or "nothing (no price source loaded)") .. ".")
end

local function createRow(i)
  local row = CreateFrame("Button", nil, menu)
  row:SetHeight(ROW)
  row:SetPoint("TOPLEFT", 10, -30 - (i - 1) * ROW)
  row:SetPoint("RIGHT", -10, 0)
  row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
  row.check = row:CreateTexture(nil, "OVERLAY")
  row.check:SetSize(16, 16)
  row.check:SetPoint("LEFT", 2, 0)
  row.check:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
  row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  row.text:SetPoint("LEFT", row.check, "RIGHT", 4, 0)
  row.text:SetPoint("RIGHT")
  row.text:SetJustifyH("LEFT")
  row:SetScript("OnClick", function(self) if self.source.available then choose(self.source.key) end end)
  row:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine(self.source.name)
    GameTooltip:AddLine(self.source.description, 1, 1, 1, true)
    if not self.source.available then GameTooltip:AddLine("Not loaded.", 1, 0.4, 0.4) end
    GameTooltip:Show()
  end)
  row:SetScript("OnLeave", GameTooltip_Hide)
  return row
end

local function createMenu(parent)
  menu = CreateFrame("Frame", "ProfessionProfitPriceSourceMenu", parent, BackdropTemplateMixin and "BackdropTemplate" or nil)
  menu:Hide()
  menu:SetFrameStrata("DIALOG")
  menu:SetClampedToScreen(true)
  menu:EnableMouse(true)
  if menu.SetBackdrop then
    menu:SetBackdrop({
      bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
      edgeSize = 16, insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    menu:SetBackdropColor(0.07, 0.06, 0.05, 0.97)
    menu:SetBackdropBorderColor(0.6, 0.5, 0.3, 1)
  end
  local title = menu:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  title:SetPoint("TOPLEFT", 14, -10)
  title:SetText("Price source")
  local close = CreateFrame("Button", nil, menu, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", 0, 0)
  menu.note = menu:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  menu.note:SetPoint("BOTTOMLEFT", 14, 10)
  menu.note:SetPoint("RIGHT", -14, 0)
  menu.note:SetJustifyH("LEFT")
  menu.rows = {}
  tinsert(UISpecialFrames, menu:GetName()) -- Escape closes it
end

local function update()
  local sources = API.PriceSources()
  local chosen, active = API.GetPriceSource(), API.ActiveSource()
  for i, source in ipairs(sources) do
    local row = menu.rows[i] or createRow(i)
    menu.rows[i] = row
    row.source = source
    row.check:SetShown(active ~= nil and source.key == active.key)
    row.text:SetText(source.available and source.name or ("|cff808080" .. source.name .. " (not loaded)|r"))
    row:Show()
  end
  local note
  if not active then
    note = "No price source loaded: install Auctionator or TSM."
  elseif active.key ~= chosen then
    note = "Your choice isn't loaded, so " .. active.name .. " is used."
  elseif active.key ~= "auctionator" then
    note = "Scan AH searches through Auctionator, which doesn't update TSM's prices."
  end
  menu.note:SetText(note or "")
  menu:SetSize(230, 30 + #sources * ROW + (note and 40 or 14))
end

function ns.togglePriceSourceMenu(anchor)
  if not menu then createMenu(anchor:GetParent()) end
  if menu:IsShown() then menu:Hide() return end
  update()
  menu:ClearAllPoints()
  menu:SetPoint("BOTTOMLEFT", anchor, "TOPLEFT", 0, 4)
  menu:Show()
end
