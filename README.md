# Cashier

A clean, robust Roblox library to streamline Gamepass, Developer Product, and Gifting management.

---

## Installation

Add Cashier to your `wally.toml`:

```toml
[dependencies]
Cashier = "yuzkkj/cashier@1.0.0"
```

Then install with Wally:

```bash
wally install
```

---

## Simple Usage

### 1. Server Setup

Initialize `Cashier.server` with your registered items:

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
                print(player.Name, "unlocked VIP!")
                -- Grant titles, permissions, or perks here
                return true
            end,
        },
        {
            name = "500 Coins",
            type = "DevProduct",
            id = 23456789,
            callback = function(player: Player)
                print(player.Name, "bought 500 Coins!")
                -- Add currency to player data
                return true
            end,
        },
    },
})
```

### 2. Client Setup & Purchasing

Initialize `Cashier.client` and prompt purchases:

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Cashier = require(ReplicatedStorage.Packages.Cashier).client

-- Initialize the client
Cashier:init()

-- Prompt a purchase on button click
local buyButton = script.Parent
buyButton.Activated:Connect(function()
    Cashier:purchase("VIP")
end)

-- Listen for when the player acquires the item
Cashier.itemAcquired:Connect(function(itemName: string)
    print(`Unlocked {itemName}!`)
end)
```

### 3. Gifting an Item

Send a gift to any player (even if they are offline or in another server):

```lua
local success, err = Cashier:gift(targetUserId, "VIP")
if not success then
    warn("Gifting failed:", err)
end
```

---

## Documentation

- **Getting Started Guide**: https://yuzkkj.github.io/cashier/docs/intro
- **Complete API Reference**: https://yuzkkj.github.io/cashier/api

If you're new to the package, start with the Getting Started guide and use the API reference for full method and type details.