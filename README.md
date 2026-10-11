# Greedy Goblin

[![WoW WotLK 3.3.5](https://img.shields.io/badge/WoW%20WotLK-3.3.5-9370DB?style=flat-square)](./GreedyGoblin.toc)
[![Lua](https://img.shields.io/badge/made%20with-Lua-2C2D72?style=flat-square&logo=lua)](./GreedyGoblin.lua)
[![Dependencies](https://img.shields.io/badge/dependencies-none-3c873a?style=flat-square)](./GreedyGoblin.toc)

⭐ If you find this addon handy, star the repository — it helps others discover it!

[Features](#features) • [Installation](#installation) • [Getting started](#getting-started) • [Usage](#usage) • [How costing works](#how-costing-works) • [Data storage](#data-storage)

---

A standalone crafting profit list for **World of Warcraft: Wrath of the Lich King (3.3.5)**. It learns every recipe you know, scans the whole auction house itself, and shows materials cost, sell price and profit for each recipe in a single window — one window, one tooltip, no library dependencies and no other hooks.

## Features

- 🏭 **Automatic recipe learning** — open each of your profession windows once and every recipe is remembered, including reagents and average craft yield
- 🔍 **Self-contained AH scanner** — performs its own get-all scan of the auction house and stores the lowest buyout for every item seen, per realm
- 🔌 **Auctionator mode** — when Auctionator is present at first install, its price database becomes the sole source of market prices: no own scanning, no AH data kept, scan buttons hidden. A chat message tells you which source is active, and the choice can be toggled anytime with `/gg auctionator on|off`
- 🏷️ **Smart material costing** — every material is priced at the cheapest of vendor, auction house, or crafting it yourself (resolved recursively up to 4 levels deep)
- 🧙 **Alt crafting** — recipes learned on your other characters of the realm also count as ways to craft a material yourself (`/gg alts on|off`, on by default)
- 💰 **Profit at a glance** — sortable list with materials cost, sell price after the AH cut, profit and margin; hover a row for the full cost breakdown
- 🔎 **Search bar** — a filter at the top of the window matches recipe names, or the name of any material the recipe uses (including crafting chains and the enchanting vellum)
- 📜 **Enchanting support** — scrolls and vellums are detected on the AH, so enchanting recipes are costed and valued correctly; each vellum is priced at the cheaper of buying or crafting it (e.g. on an Inscription alt)
- 🎯 **Missing price lookups** — a *Find Unknown Prices* action performs targeted AH searches for anything you haven't priced yet
- 🔄 **Refresh button** — re-pull every price straight from the active source (Auctionator's database or the own scan data) and rebuild the list instantly, no rescan needed
- 🎨 **ElvUI skin** — the window is automatically skinned when [ElvUI](https://github.com/tukui-org/ElvUI) is enabled, plain Blizzard UI otherwise
- 📦 **Standalone** — a single `.lua` file, works with both faction and neutral auction houses

## Requirements

- World of Warcraft: Wrath of the Lich King, client **3.3.5**
- No libraries or other addons required. When [Auctionator](https://github.com/TheMouseNest/Auctionator) is loaded it drives all market prices (see [Auctionator mode](#auctionator-mode)), [ElvUI](https://github.com/tukui-org/ElvUI) only reskins the window.

## Installation

1. Copy the addon into your game folder so that the following files exist:
   `Interface/AddOns/GreedyGoblin/GreedyGoblin.toc`
   `Interface/AddOns/GreedyGoblin/GreedyGoblin.lua`
2. Restart the game client (or `/reload`).
3. Type `/gg` to open the profit list.

## Getting started

1. **Learn your recipes** — open each of your profession windows once; recipes are learned automatically and stored per character.
2. **Teach it vendor prices** — visit material vendors (thread, flux, …); browsing a merchant records its prices.
3. **Scan the auction house** — open the AH and click **Scan AH** (or run `/gg scan`) to gather prices for everything on sale.
4. **Fill in the gaps** — click **Find Unknown Prices** (or `/gg unknown`) to look up items that had no price yet.
5. Repeat step 3–4 occasionally to keep prices fresh, especially after patch days.

> [!NOTE]
> In [Auctionator mode](#auctionator-mode), steps 3–4 are replaced by the **Refresh Prices** button (or `/gg refresh`): it re-pulls the latest prices straight from Auctionator's database without touching the auction house (see [Refresh prices](#refresh-prices)).

> [!NOTE]
> With Auctionator already installed when you first set the addon up, steps 3–4 are not needed: GreedyGoblin enables **Auctionator mode** on first install (it says so in the chat window) and takes every market price from Auctionator instead (see [Auctionator mode](#auctionator-mode)).

> [!TIP]
> The addon assumes the faction AH cut of 5%. If you post on a neutral auction house, set the cut first with `/gg cut 15`.

> [!TIP]
> Your other characters can craft, too: with [alt crafting](#alt-crafting) on, recipes learned on any character of the current realm count as ways to craft a material. Open each profession window on an alt once to make its recipes available to the others.

## Usage

Type `/gg` to open the window. The list shows one row per known recipe:

| Column | Meaning |
| --- | --- |
| Recipe | Recipe name, with the average yield shown for multi-craft recipes (`x3`) |
| Profession | The profession the recipe belongs to |
| Materials | Cheapest possible cost of the reagents |
| Sells for | Price after the AH cut (`v` marks a vendor fallback price) |
| Profit | Sell price minus material cost |
| Margin | Profit as a percentage of the sell price |

Click any column header to sort by it (click again to reverse). Rows with unknown prices always sort last. The status bar at the bottom shows how many items were scanned, how old the scan is, the AH cut, and the number of recipes.

### Search bar

A filter box at the top of the window matches recipes against the **recipe name** and the names of **every material shown in the row tooltip** — including the cheaper crafting sources of those materials, and the enchanting vellum (searching `vellum` lists all enchanting recipes). Matching is case-insensitive; while a filter is active, the status bar shows *N of M recipes shown*. Escape clears the text (a second press releases focus), and column sorting applies to the filtered list.

### Refresh prices

The **Refresh Prices** button in the bottom-right corner of the window (or `/gg refresh`) drops every cached cost and re-reads every market price from the active source — Auctionator's live database in [Auctionator mode](#auctionator-mode), otherwise the addon's own stored AH scan — then rebuilds the whole list from the top, keeping the current sort order and search filter. It is available in both modes, never contacts the auction house, and can be used anytime: the quickest way to pick up fresh prices after browsing or searching the AH with Auctionator while the window is open. It is safe to use while a scan or lookup is running.

### Scanning the auction house

The **Scan AH** and **Find Unknown Prices** buttons are hidden while [Auctionator mode](#auctionator-mode) is active.

**Scan AH** queries the entire auction house at once and stores the lowest buyout per unit for every item found. The result replaces the previous scan data for that realm. Scanning is chunked in the background to keep the game responsive, and it respects Blizzard's full-scan cooldown — the button stays disabled until the AH allows a new scan.

### Find Unknown Prices

**Find Unknown Prices** collects everything without a usable price — materials at any crafting depth, crafted products, enchant scrolls and vellums — then performs a targeted AH search for each of them (up to 3 pages per search). Items checked in the last 10 minutes are skipped within the same session to avoid spamming queries, and items already priced by Auctionator count as known.

### Auctionator mode

On first install, GreedyGoblin checks whether Auctionator is loaded, stores the decision, and informs you in the chat window which price source is active. From then on the stored choice is used (toggle it anytime with `/gg auctionator on|off`). While the mode is on:

- every market price — materials, crafted products, enchant scrolls and the enchanting vellum — comes from Auctionator's database
- no **Scan AH**, **Find Unknown Prices** or **Clear Database** buttons — the whole own-scan machinery is off (**Refresh Prices** stays, since it only reads Auctionator's database)
- all previously scanned AH data (prices, scroll and vellum registries) is cleared automatically

> [!NOTE]
> Vendor and crafting costs still apply: Auctionator replaces only the addon's own auction house scanning.

Opt out to keep doing your own scans with `/gg auctionator off`, and turn it back on with `/gg auctionator on`. Auctionator prices are read live from Auctionator's own database and are not stored in `GreedyGoblinDB`.

> [!NOTE]
> If the auction house is closed or doesn't answer, scans abort gracefully and tell you what happened.

### Alt crafting

With **alt crafting** on (the default), recipes learned on any other character of the current realm count as ways to craft a material yourself. A material is then costed at the cheapest of vendor, market price, crafting it with a recipe of the current character, or crafting it on one of your alts — the row tooltip appends the owning alt's name to a crafting source, e.g. `craft: Inscription, Gnomie` instead of plain `craft: Inscription`.

Toggle with `/gg alts off` (only the recipes of the current character are used) and back with `/gg alts on`. `/gg alts` without an argument lists every character of the current realm together with the recipes it has learned. Recipes are stored per character (see [Data storage](#data-storage)): open each profession window on an alt once to make its recipes available to the rest.

The same applies to the enchanting vellum: when an alt — e.g. an Inscriber — has learned to craft one, every vellum is priced at the cheaper of buying it on the AH or crafting it, and the tooltip shows the chosen vellum with its source and, when crafted, its materials.

### Row tooltip

Hovering a recipe row opens a tooltip with the complete breakdown: every material with its quantity, its cheapest source (vendor & NPC name, AH, auctionator, or `craft: Profession` — with the alt's name appended when the recipe belongs to another character — for materials you or your alts can make), the vellum cost for enchants (see [Alt crafting](#alt-crafting)), the AH cut and the final profit.

> [!IMPORTANT]
> Enchanting recipes have no crafted product: the addon prices scrolls of the enchant found on the AH and includes the priciest vellum in the material cost — every vellum is priced at the cheaper of buying it on the AH or crafting it (see [Alt crafting](#alt-crafting)).

## Slash commands

| Command | Description |
| --- | --- |
| `/gg` or `/greedygoblin` | Open or close the profit list window |
| `/gg scan` | Start a full auction house scan |
| `/gg unknown` | Look up prices for unknown items |
| `/gg refresh` | Re-read all prices from the active source (Auctionator or the own AH scan) and rebuild the list |
| `/gg auctionator on\|off` | Toggle Auctionator mode (decided automatically at first install) |
| `/gg alts on\|off` | Toggle [alt crafting](#alt-crafting) (on by default); without an argument, list the recipes every character of the current realm has learned |
| `/gg cut <percent>` | Set the AH cut (5 for faction AH, 15 for neutral AH) |
| `/gg reset` | Forget the recipes learned for the current character |
| `/gg clear` | Wipe the entire database (asks for confirmation) |

## How costing works

For each recipe the addon computes the cheapest realistic way to obtain every reagent:

1. Each material is priced at the **cheapest** of these sources: a vendor you've met, your own AH scan, [Auctionator](https://github.com/TheMouseNest/Auctionator)'s database (the sole market source in [Auctionator mode](#auctionator-mode)), or crafting it with a recipe known on this or any other character of the realm (see [Alt crafting](#alt-crafting)).
2. Crafted material costs are resolved **recursively**, up to 4 levels deep, with cycle protection — so e.g. *Saronite Ore → Smelted Bar → Crafted Item* chains are all explored and the best option wins.
3. The material cost is the sum of the reagent costs. The sell price is the lowest AH buyout of the product (times the average craft yield), minus the AH cut — falling back to Auctionator, then the vendor sell price, when the AH price is unknown.
4. **Profit = sell price − material cost**, and the margin is the profit relative to the sell price.

Vendor prices are picked up automatically whenever you browse a merchant that sells materials you use.

## Data storage

Everything is kept in the `GreedyGoblinDB` saved variable:

- **AH prices** — per realm: lowest unit buyout per item, plus scan timestamp and item count (always empty in Auctionator mode)
- **Recipes** — per character: every recipe learned from your profession windows; with [alt crafting](#alt-crafting) on, they also serve as craft sources for the other characters of the same realm
- **Vendor prices** — per item, along with the name of the vendor it was seen at
- **Scrolls & vellums** — item IDs catalogued from AH scans, used for enchanting
- **AH cut** — your configured auction house cut (default 5%)
- **Alt crafting** — on or off (on by default), a single toggle shared by all of your characters
- **Auctionator mode** — on or off, decided automatically at first install based on whether Auctionator is detected

> [!NOTE]
> Auctionator prices are read live from Auctionator's own database and are never stored in `GreedyGoblinDB`.

Use the **Clear Database** button or `/gg clear` to delete everything, then open your profession windows again to re-learn recipes.