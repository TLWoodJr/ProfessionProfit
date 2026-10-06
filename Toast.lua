-- ProfessionProfit: Pop-ups for the profit of a craft and for gold taken from the mailbox.

local ADDON, ns = ...
local API, RED, isModern, hostShown, evaluate, readRecipes = ns.API, ns.RED, ns.isModern, ns.hostShown, ns.evaluate, ns.readRecipes
local earned = ns.earned
local db
ns.onInit(function(saved) db = saved end)

------------------------------------------------------------------------------
-- Toasts: an achievement-style pop-up with the profit of what you just
-- crafted, or the gold you just took from the mailbox. Repeats of the same
-- thing (casts of one recipe, letters in one mail run) add up in one toast.
------------------------------------------------------------------------------

local TOAST_HOLD = 4 -- seconds shown after the last cast
local toast

-- Learned recipes of the open profession by recipe ID (modern) or name
-- (classic, matched against the cast's spell name). Rebuilt when the list changes.
local function recipeForSpell(spellID)
  if not hostShown() then return nil end
  if not ns.craftLookup then
    ns.craftLookup = {}
    for _, recipe in ipairs(readRecipes()) do
      ns.craftLookup[recipe.recipeID or recipe.name] = recipe
    end
  end
  if isModern() then return ns.craftLookup[spellID] end
  local name = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(spellID)
  if not name and GetSpellInfo then name = GetSpellInfo(spellID) end
  return name and ns.craftLookup[name]
end

local function createToast()
  toast = CreateFrame("Frame", "ProfessionProfitCraftToast", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
  toast:SetSize(300, 64)
  toast:SetPoint("BOTTOM", UIParent, "BOTTOM", 0, 200)
  toast:SetFrameStrata("HIGH")
  toast:Hide()
  if toast.SetBackdrop then
    toast:SetBackdrop({
      bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
      edgeSize = 16, insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    toast:SetBackdropColor(0.07, 0.06, 0.05, 0.92)
    toast:SetBackdropBorderColor(1, 0.82, 0, 1)
  end

  toast.icon = toast:CreateTexture(nil, "ARTWORK")
  toast.icon:SetSize(42, 42)
  toast.icon:SetPoint("LEFT", 11, 0)

  toast.title = toast:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  toast.title:SetPoint("TOPLEFT", toast.icon, "TOPRIGHT", 10, -1)
  toast.title:SetPoint("RIGHT", -10, 0)
  toast.title:SetJustifyH("LEFT")

  toast.amount = toast:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
  toast.amount:SetPoint("TOPLEFT", toast.title, "BOTTOMLEFT", 0, -3)
  toast.amount:SetPoint("RIGHT", -10, 0)
  toast.amount:SetJustifyH("LEFT")

  toast.detail = toast:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  toast.detail:SetPoint("TOPLEFT", toast.amount, "BOTTOMLEFT", 0, -2)
  toast.detail:SetPoint("RIGHT", -10, 0)
  toast.detail:SetJustifyH("LEFT")

  -- Fade in, hold, fade out. Restarted (from fully shown) by each cast.
  toast.anim = toast:CreateAnimationGroup()
  local fadeIn = toast.anim:CreateAnimation("Alpha")
  fadeIn:SetFromAlpha(0)
  fadeIn:SetToAlpha(1)
  fadeIn:SetDuration(0.25)
  fadeIn:SetOrder(1)
  local fadeOut = toast.anim:CreateAnimation("Alpha")
  fadeOut:SetFromAlpha(1)
  fadeOut:SetToAlpha(0)
  fadeOut:SetStartDelay(TOAST_HOLD)
  fadeOut:SetDuration(1)
  fadeOut:SetOrder(2)
  toast.fadeIn = fadeIn
  toast.anim:SetScript("OnFinished", function() toast:Hide(); toast.key = nil end)
end

-- opts: incomplete (price has gaps), detail (small line; default: the amount
-- per repeat, or profit/loss).
local function showToast(key, title, icon, amount, opts)
  opts = opts or {}
  if not toast then createToast() end
  local again = toast:IsShown() and toast.key == key
  toast.casts = again and toast.casts + 1 or 1
  toast.total = (again and toast.total or 0) + amount
  toast.key = key

  local good = toast.total >= 0
  toast.icon:SetTexture(icon or 134400) -- question mark
  toast.title:SetText(toast.casts > 1 and ("%s x%d"):format(title, toast.casts) or title)
  toast.amount:SetText((good and "+" or "") .. API.Money(toast.total) .. (opts.incomplete and (RED .. " *|r") or ""))
  toast.amount:SetTextColor(good and 0.2 or 1, good and 1 or 0.3, 0.2)
  toast.detail:SetText(opts.detail or (toast.casts > 1 and (API.Money(amount) .. (opts.each or " per craft"))
    or opts.label or (good and "profit" or "loss")))
  toast:SetBackdropBorderColor(good and 1 or 0.8, good and 0.82 or 0.2, good and 0 or 0.2, 1)

  toast.anim:Stop()
  toast.fadeIn:SetDuration(again and 0 or 0.25)
  toast:SetAlpha(1)
  toast:Show()
  toast.anim:Play()
  if not again and good and SOUNDKIT and SOUNDKIT.LOOT_WINDOW_COIN_SOUND then
    PlaySound(SOUNDKIT.LOOT_WINDOW_COIN_SOUND)
  end
end
ns.showToast = showToast

-- kind: "queued" (profit goes to the queue's total), "reagent" (a reagent for
-- the queue: counts what it saved over buying it - no AH cut, it isn't sold).
local function craftToast(spellID, kind)
  local recipe = recipeForSpell(spellID)
  if recipe and recipe.productID then evaluate(recipe) end
  local amount, opts = recipe and recipe.profit, { incomplete = recipe and recipe.incomplete }
  if kind == "reagent" then
    local buy = recipe and recipe.productID and API.BuyPrice(recipe.productID)
    amount = (buy and recipe.missing == 0) and (buy * recipe.made - recipe.cost) or nil
    opts = { label = amount and (amount >= 0 and "saved vs buying" or "more than buying"), each = " saved per craft" }
    if amount then earned.saved, earned.reagents = earned.saved + amount, earned.reagents + 1 end
  elseif kind == "queued" then
    if amount then
      earned.total, earned.crafts = earned.total + amount, earned.crafts + 1
    else
      earned.unpriced = earned.unpriced + 1
    end
  end
  if db.craftToastOff or not amount then return end -- no price for the product
  local icon = C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(recipe.productID)
  if not icon and GetItemIcon then icon = GetItemIcon(recipe.productID) end
  showToast(recipe.recipeID or recipe.name, "Crafted " .. (recipe.productName or recipe.name), icon, amount, opts)
end
ns.craftToast = craftToast

-- Mail: gold gained just after a letter's money was taken (by hand, Open
-- All or a mail addon - they all go through these two functions). Anything
-- else, like looting coins, doesn't show a toast.
local MAIL_TAKE_WINDOW = 5 -- seconds for the gold to arrive after taking it


local function noteMailSubject(index)
  if not GetInboxHeaderInfo or type(index) ~= "number" then return end
  local _, _, _, subject, money = GetInboxHeaderInfo(index)
  if money and money > 0 then ns.mailSubject, ns.mailTakeTime = subject, GetTime() end
end
if TakeInboxMoney then hooksecurefunc("TakeInboxMoney", noteMailSubject) end
if AutoLootMailItem then hooksecurefunc("AutoLootMailItem", noteMailSubject) end

local function mailMoneyChanged()
  local money = GetMoney()
  local gained = ns.lastMoney and money - ns.lastMoney
  ns.lastMoney = money
  if not ns.mailOpen or not gained or gained <= 0 or db.mailToastOff then return end
  if not ns.mailTakeTime or GetTime() - ns.mailTakeTime > MAIL_TAKE_WINDOW then return end
  showToast("mail", "Collected mail", 133784, gained, -- coin icon
    { detail = ns.mailSubject or "gold from the mailbox" })
  ns.mailSubject = nil
end
ns.mailMoneyChanged = mailMoneyChanged
