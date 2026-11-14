# ProfessionProfit

Adds a **Profit** tab to the profession window for WoW Forever. It shows what every recipe you know makes at today's
auction house prices. It also queues the crafts, builds the shopping list and buys the vendor reagents.

**Requires a price source: [Auctionator](https://www.curseforge.com/wow/addons/auctionator) or
[TradeSkillMaster](https://www.curseforge.com/wow/addons/tradeskill-master)** (either one, or both). With Auctionator
the numbers match its "To Craft" column. Scan AH and the shopping list need Auctionator; with TSM only, update prices
with TSM itself.

## Features

- **Profit table**: every learned recipe with reagent cost, AH sale price, profit (after the 5% AH cut) and margin. Sort by
  any column and hover a row for the full breakdown.
- **Price source**: the cog at the Profit tab's bottom left picks where prices come from: Auctionator, or TSM's Min
  Buyout, Market Value, Recent Value or Region Market Avg. ProfessionProfit stores no prices of its own.
- **Scan AH**: with the auction house open, searches every reagent and crafted item in Auctionator (it updates
  Auctionator's prices, not TSM's).
- **Filters**: Profitable only, a minimum profit (g/s/c) and margin (%), Missing prices, Not listed. Bind-on-pickup
  items are hidden.
- **Not listed**: items with none on the AH show their last known price in blue, plus break-even and suggested
  listing prices.
- **Craft queue**: add recipes with a quantity or top up to a restock target. The reagent window shows whether
  crafting a reagent saves or loses money compared to buying it. Reagents made by your other professions or other
  characters count too, once you've opened that profession on that character. Crafts for another character are
  greyed out in the queue: craft them there and mail them over.
- **Shopping list**: one click makes an Auctionator shopping list of what you're missing and searches it.
- **Vendor auto-buy**: at a vendor, a confirmation lists the queue's vendor reagents and their total. Turn it off
  with "Buy items from vendors" or `/pp vendor`.
- **Craft all**: crafts the queue one press at a time with a key binding (Key Bindings > AddOns > ProfessionProfit).
  A pop-up shows each craft's profit.
- **Shuffle**: a Shuffle column shows what each recipe makes if you craft it and disenchant the result: the
  expected enchanting materials at AH prices after the cut, minus the craft cost. Hover a row for the materials
  and their chances. Scan AH searches the materials too.
- **Vendor**: a Vendor column shows what each recipe makes if you sell what it crafts to a vendor: the vendor's
  price (no AH cut) minus the craft cost. "Profitable only" counts whichever of AH, shuffle and vendor pays most.
- **Disenchant queue** (enchanters): tick Disenchant when you queue a recipe with +, and what it makes is queued
  for disenchanting with its projected profit. The Disenchant button on the Profit tab (or its key binding)
  disenchants the next one in your bags. A pop-up shows each disenchant's realized profit next to the projection,
  and the queue window adds them up.
- **Disenchant Scan** (enchanters): with Enchanting open and the auction house open, a button on the Profit tab
  searches the enchanting materials for current prices, then every uncommon or better weapon and armor listed,
  and shows the ones worth more disenchanted (materials at AH prices after the cut) than their cheapest buyout.
  Click one to buy it: it goes to the top of the buy list and the planner shows its listings.
- **Disenchant planner**: To buy lists what you picked from the scan. Each press of Buy buys the first item's
  cheapest listing outright (no AH confirm) while it still makes a profit, and plans it for disenchanting at the
  price paid. The planner shows its listings by price (how many at each, green while profitable), updated with every
  purchase without searching again, and the scan row follows the new cheapest price. To disenchant lists what's planned, how many are in your bags and the projected profit, with a
  Disenchant button. The planner opens by itself when a planned item arrives in an enchanter's bags (from the mail, say).
- **Across characters**: the disenchant plan is shared by all your characters. Queue and craft on an alt, mail the
  items to your enchanter and disenchant them there. Each row shows how many are in your bags, how many each other
  character had when you last logged it in, and (on hover) how many are still to craft or in the mail.

## Commands

| Command | What it does |
| --- | --- |
| `/pp scan` | Scan AH prices for the open profession |
| `/pp queue` | Show or hide the craft queue |
| `/pp reagents` | Show the queue's reagent window again after closing it |
| `/pp vendor` | Turn Buy items from vendors on or off |
| `/pp toast` | Turn the craft profit pop-up on or off (`/pp toast test` previews it) |
| `/pp toast mail` | Turn the mail gold pop-up on or off |
| `/pp toast de` | Turn the disenchant profit pop-up on or off |
| `/pp descan` | Scan the AH for gear worth more disenchanted than its buyout |
| `/pp planner` | Show or hide the Disenchant planner |
| `/pp debug` | Diagnostics if the Profit tab is missing (include this in bug reports) |

## Bugs and requests

Open an issue at <https://github.com/TLWoodJr/ProfessionProfit/issues> with your `/pp debug` output and your
Auctionator version.

## Licence

GPL-3.0. See [LICENSE](LICENSE). Uses [LibCraftProfit-1.0](https://github.com/TLWoodJr/LibCraftProfit-1.0),
LibStub and CallbackHandler-1.0.
