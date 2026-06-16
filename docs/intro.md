---
sidebar_position: 1
---

# Getting Started

:::info
Cashier is designed to work alongside [DataService](https://leifstout.github.io/dataService) by Leif Stout for persistent player data. Make sure DataService is set up in your project before using Cashier.
:::

Cashier handles all the boilerplate around in-game purchases so you can focus on what your items actually do. Gamepasses, developer products, gifting, and stock-limited items — all from a single config.

## Installation

Add Cashier to your `wally.toml`:

```toml
[dependencies]
Cashier = "yuzkkj/monetization-service@1.4.0"
```

Then run:

```bash
wally install
```

## Setting Up

Cashier has a server and a client module. Both need to be initialized before anything else.

### Server

```lua
local DataService = require(path.to.DataService).server
local Cashier = require(path.to.Cashier).server

DataService:init() -- DataService must be initialized first

Cashier:init({
    data = {
        {
            name = "VIP",
            type = "Gamepass",
            id = 123456,
            giftId = 654321,
            callback = function(player: Player)
                DataService:arrayInsert(player, "titles", "VIP")
                return true
            end,
        },
        {
            name = "500 Coins",
            type = "DevProduct",
            id = 789012,
            callback = function(player: Player)
                DataService:update(player, "coins", function(coins)
                    return coins + 500
                end)
                return true
            end,
        },
    },
    limitedsCallbacks = {
        ["Exclusive Sword"] = function(player: Player)
            DataService:arrayInsert(player, "weapons", "Exclusive Sword")
            return true
        end,
    },
})
```

### Client

```lua
local Cashier = require(path.to.Cashier).client

Cashier:init()
```

That's it. The client fetches item data from the server automatically.

## Purchasing Items

On the client, call `purchaseItem` with the item name. Cashier handles the prompt, receipt processing, and callback execution.

```lua
local Cashier = require(path.to.Cashier).client

local buyButton = script.Parent
buyButton.Activated:Connect(function()
    Cashier:purchaseItem("VIP")
end)
```

You can listen for when a purchase finishes:

```lua
Cashier.purchaseFinished:Connect(function(itemName, wasSuccessful, wasGift)
    if wasSuccessful then
        print("Bought", itemName)
    end
end)
```

## Predicates and Extra Params

Some purchases need validation or extra context. Use `predicate` to gate the purchase and pass extra arguments through:

```lua
-- Server config
{
    name = "Upgrade Unit",
    type = "DevProduct",
    id = 111222,
    predicate = function(player: Player, unitId: string)
        -- Validate that the unit exists and isn't maxed
        return UnitService:canUpgrade(player, unitId)
    end,
    callback = function(player: Player, unitId: string)
        UnitService:upgrade(player, unitId)
        return true
    end,
}
```

```lua
-- Client
Cashier:purchaseItem("Upgrade Unit", selectedUnit.id)
```

The extra params are passed to both the predicate and the callback.

## Gifting

Players can gift items to each other. The recipient gets the item even if they're offline — it'll be delivered next time they join.

```lua
-- Client
local success, errorMessage = Cashier:gift(recipientUserId, "VIP")
if not success then
    warn(errorMessage)
end
```

You can override `onGiftReceived` on the client to show a notification:

```lua
function Cashier:onGiftReceived(giftData)
    print(giftData.from, "gifted you", giftData.item)
end
```

## Checking Ownership

```lua
-- Client
if Cashier:hasItem("VIP") then
    -- Show VIP perks
end

-- Server
if Cashier:hasItem(player, "VIP") then
    -- Grant VIP perks
end
```

## Limited Items

Limiteds are stock-capped items that can expire. They're stored in a DataStore and synced to all clients in real time.

### Adding a Limited

```lua
-- Server
Cashier:addLimited({
    name = "Exclusive Sword",
    id = 333444, -- Developer product id
    initialStock = 100,
    stockLeft = 100,
    onePerPlayer = true,
    expiration = os.time() + 86400, -- Available for 24 hours
})
```

### Purchasing a Limited

```lua
-- Client
Cashier:purchaseLimited("Exclusive Sword")
```

The client checks stock and expiration locally before even asking the server. The server re-validates everything before prompting.

### Reacting to Changes

The `limitedChanged` signal fires whenever a limited's stock or expiration updates:

```lua
-- Client
Cashier.limitedChanged:Connect(function(limited)
    print(limited.name, "now has", limited.stockLeft, "left")
end)
```

### Managing Stock and Time

```lua
-- Server
Cashier:addStockToLimited("Exclusive Sword", 50)
Cashier:addTimeToLimited("Exclusive Sword", 3600) -- +1 hour
Cashier:removeLimited("Exclusive Sword")
```

## Item Types

| Type | Behavior |
|------|----------|
| `"Gamepass"` | Purchased once, ownership persists across sessions via Roblox's gamepass system |
| `"Semipass"` | Purchased once, ownership tracked in DataService (not a real gamepass) |
| `"DevProduct"` | Can be purchased multiple times, not tracked as "owned" |

## Notes

- Always initialize `DataService` before `Cashier` on the server.
- The `callback` should return `true` if the item was successfully granted. Returning `false` will cause the receipt to be retried later.
- Limiteds use an oversell strategy: once a player is in the purchase flow, the item is always delivered even if stock hits zero from another purchase. Stock acts as a soft cap for new prompts.

## Next Steps

Check the full API reference for every method, signal, and type available:

- [CashierServer](/api/CashierServer) — server-side item registration, purchase processing, gifting, and limiteds management.
- [CashierClient](/api/CashierClient) — client-side purchase prompts, item queries, and real-time limited updates.
