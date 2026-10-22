# ProfessionProfit

Adds a **Profit** tab to the profession window for WoW Forever. It shows what every recipe you know makes at today's
auction house prices. It also queues the crafts, builds the shopping list and buys the vendor reagents.

**Requires [Auctionator](https://www.curseforge.com/wow/addons/auctionator).** Prices come from Auctionator, so
the numbers match its "To Craft" column.

## Features

- **Profit table**: every learned recipe with reagent cost, sale price after the AH cut, profit and margin. Sort by
  any column and hover a row for the full breakdown.
- **Scan AH**: with the auction house open, reads the order books for the amount of each reagent you need, then
  searches the rest in Auctionator. A `!` marks a price that's been undercut.
- **Filters**: Profitable only, a minimum profit (g/s/c) and margin (%), Missing prices, Not listed. Bind-on-pickup
  items are hidden.
- **Not listed**: items with none on the AH show their last known price in blue, plus break-even and suggested
  listing prices.
- **Craft queue**: add recipes with a quantity or top up to a restock target. The reagent window shows whether
  crafting a reagent saves or loses money compared to buying it.
- **Shopping list**: one click makes an Auctionator shopping list of what you're missing and searches it.
- **Vendor auto-buy**: at a vendor, a confirmation lists the queue's vendor reagents and their total. Turn it off
  with "Buy items from vendors" or `/pp vendor`.
- **Craft all**: crafts the queue one press at a time with a key binding (Key Bindings > AddOns > ProfessionProfit).
  A pop-up shows each craft's profit.
- Works with Skillet's window if you use it.

## Commands

| Command | What it does |
| --- | --- |
| `/pp scan` | Scan AH prices for the open profession |
| `/pp queue` | Show or hide the craft queue |
| `/pp reagents` | Show the queue's reagent window again after closing it |
| `/pp vendor` | Turn Buy items from vendors on or off |
| `/pp toast` | Turn the craft profit pop-up on or off (`/pp toast test` previews it) |
| `/pp toast mail` | Turn the mail gold pop-up on or off |
| `/pp debug` | Diagnostics if the Profit tab is missing (include this in bug reports) |

## Bugs and requests

Open an issue at <https://github.com/TLWoodJr/ProfessionProfit/issues> with your `/pp debug` output and your
Auctionator version.

## Licence

GPL-3.0. See [LICENSE](LICENSE). Uses [LibCraftProfit-1.0](https://github.com/TLWoodJr/LibCraftProfit-1.0),
LibStub and CallbackHandler-1.0.
