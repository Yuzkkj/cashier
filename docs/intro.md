---
sidebar_position: 1
---

# Getting Started

Cashier is a clean, robust, and modern Roblox monetization library designed to streamline Gamepasses, Developer Products, Semipasses, and Gifting into a single, unified workflow.

Instead of writing repetitive `MarketplaceService.ProcessReceipt` handlers, managing gamepass ownership checks on join, or wrestling with cross-server gifting logic, Cashier manages the entire lifecycle through a simple, centralized configuration.

---

## Key Features

- **Unified Item System**: Treat Gamepasses, Developer Products, and custom Semipasses uniformly with identical query and purchase APIs.
- **First-Class Player-to-Player Gifting**: Gift items to anyone—whether they are in the same server, playing on another server, or completely offline.
- **Unsent Gift Recovery**: If a gift fails to deliver, it is stored in the sender's unsent vault so they never lose Robux.
- **Safe Transactions**: Automated receipt processing with built-in purchase history logging to prevent double-granting exploits.
- **Gated Purchases & Predicates**: Verify custom conditions (player level, inventory space, remaining stock) on the server before displaying purchase prompts.
- **Limited Stock Items**: Easily build stock-limited items and seasonal drops using server-side predicates and callbacks.

---

## Installation

### Wally

Add Cashier to your `wally.toml` dependencies:

```toml
[dependencies]
Cashier = "yuzkkj/cashier@1.0.0"
```

Then install it using the Wally CLI:

```bash
wally install
```

### Manual Installation

You can also drop the Cashier package folder directly into `ReplicatedStorage.Packages` (or your preferred shared package location).

---

## Setting Up

Cashier is split into two modules: `server` and `client`. Both should be initialized once when your game starts.

### 1. Server Setup

On the server, require `Cashier.server` and call `Cashier:init()` with your item definitions:

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Cashier = require(ReplicatedStorage.Packages.Cashier).server

Cashier:init({
    itemsData = {
        {
            name = "VIP",
            type = "Gamepass",
            id = 12345678,
            giftId = 87654321,
            callback = function(player: Player)
                print(player.Name, "unlocked VIP perks!")
                -- Grant titles, permissions, or benefits here
                return true
            end,
        },
        {
            name = "1000 Coins",
            type = "DevProduct",
            id = 23456789,
            callback = function(player: Player)
                print(player.Name, "bought 1000 Coins!")
                -- Update player's currency in your data service
                return true
            end,
        },
    },
})
```

:::tip
Always return `true` from your `callback` when the reward is successfully applied. If a callback returns `false`, Cashier will keep the transaction pending so Roblox can retry it safely later.
:::

---

### 2. Client Setup

On the client, initialize `Cashier.client`. The client automatically synchronizes item definitions and owned items from the server.

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Cashier = require(ReplicatedStorage.Packages.Cashier).client

Cashier:init()
```

---

## Quick Example: Buying an Item

Once initialized, prompting a purchase and listening for rewards on the client is straightforward:

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Cashier = require(ReplicatedStorage.Packages.Cashier).client

-- Prompt the purchase when a button is clicked
local buyButton = script.Parent
buyButton.Activated:Connect(function()
    Cashier:purchase("VIP")
end)

-- Listen for when the player acquires the item
Cashier.itemAcquired:Connect(function(itemName: string)
    print(`Successfully acquired {itemName}!`)
end)
```

---

## Next Steps

- Explore [Items & Monetization](./items-and-monetization) to learn about Gamepasses, DevProducts, Semipasses, and Predicates.
- Learn about [Purchasing & Queries](./purchasing-and-inventory) to query item metadata, check ownership, and handle purchase signals.
- Check out the [Gifting Guide](./gifting) for full details on player-to-player and offline gifting.
- Read [Limited Stock Items](./limited-items) to learn how to create limited quantity items.
