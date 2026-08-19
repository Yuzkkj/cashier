---
sidebar_position: 3
---

# Purchasing & Queries

Cashier provides a rich set of querying, purchasing, and event-driven APIs for both client and server.

---

## Client Purchases

To initiate a purchase on the client, call `Cashier:purchase(itemName, ...)`:

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Cashier = require(ReplicatedStorage.Packages.Cashier).client

local buyButton = script.Parent
buyButton.Activated:Connect(function()
    Cashier:purchase("VIP")
end)
```

Cashier handles:
1. Sending the purchase request to the server.
2. Running any server-side `predicate` checks.
3. Displaying the native Roblox purchase prompt to the player.
4. Catching receipt completions and triggering callbacks.
5. Firing client signals when the transaction concludes.

---

## Checking Item Ownership

You can check whether a player owns a specific `"Gamepass"` or `"Semipass"` on both the client and server.

### Client-Side
```lua
-- Client
if Cashier:has("VIP") then
    print("Player owns VIP!")
end
```

### Server-Side
```lua
-- Server
if Cashier:has(player, "VIP") then
    print(`{player.Name} has VIP access!`)
end
```

:::note Developer Products
`Cashier:has()` will always return `false` for `"DevProduct"` items, as developer products are consumable and can be purchased multiple times.
:::

---

## Item Catalog Queries

Cashier automatically replicates all registered item definitions from the server to the client, allowing you to dynamically populate custom in-game shop UIs.

### Get All Items
```lua
local allItems = Cashier:getAllItems()

for _, item in allItems do
    print(item.name, item.type, item.id)
end
```

### Filter Items by Type
```lua
local gamepasses = Cashier:getItemsOfType("Gamepass")
local consumables = Cashier:getItemsOfType("DevProduct")
```

### Find an Item by Name or ID
```lua
-- Find by name
local vipItem = Cashier:getItemByName("VIP")

-- Find by ID (supports standard ID or giftId)
local item = Cashier:getItemById(12345678)
```

### Fetch Item Robux Price

You can asynchronously fetch the current live Robux price of any registered item using `getItemPrice`:

```lua
local price = Cashier:getItemPrice("VIP")
print(`VIP costs {price} Robux`)
```

:::info Client vs. Server Price Discrepancies
When querying item prices, keep in mind that the returned price can differ between the client and the server:
- **On the Client**: `MarketplaceService:GetProductInfoAsync` can take into account personalized discounts (for instance, if the player has Roblox Premium benefits or regional pricing).
- **On the Server**: `MarketplaceService:GetProductInfoAsync` returns the standard baseline price without user-specific discounts.

For custom shop UIs, it is recommended to call `Cashier:getItemPrice()` on the **client** so players see their exact personalized price. When a purchase completes, the server receives the true amount paid directly from `receiptInfo.CurrencySpent`.
:::

---

## Signals & Events

Cashier provides signals on both client and server to keep your UI and game state in sync.

### Client Signals

```lua
local Cashier = require(ReplicatedStorage.Packages.Cashier).client

-- 1. Fires when a purchase prompt opens
Cashier.purchaseStarted:Connect(function()
    print("Purchase prompt opened!")
end)

-- 2. Fires when a purchase prompt closes (completed or cancelled)
Cashier.purchaseFinished:Connect(function(itemName: string, wasPurchased: boolean, wasGift: boolean)
    if wasPurchased then
        print(`Successfully purchased {itemName}!`)
    else
        print(`Purchase for {itemName} was cancelled.`)
    end
end)

-- 3. Fires whenever the player acquires a new item (pass or semipass)
Cashier.itemAcquired:Connect(function(itemName: string)
    print(`Unlocked {itemName}! Refreshing player perks...`)
end)

-- 4. Fires if a gift delivery fails
Cashier.giftingFailed:Connect(function(itemName: string, recipientId: number)
    warn(`Failed to deliver {itemName} to UserId {recipientId}. It was saved to your unsent vault.`)
end)
```

---

### Server Signals

On the server, you can listen for `purchaseCompleted` to track analytics, send webhook logs, or broadcast global chat announcements:

```lua
local Cashier = require(ReplicatedStorage.Packages.Cashier).server

Cashier.purchaseCompleted:Connect(function(purchaseData)
    print(`{purchaseData.player.Name} spent {purchaseData.robuxSpent} Robux on {purchaseData.item}!`)
    
    if purchaseData.recipientId then
        print(`This purchase was a gift for UserId {purchaseData.recipientId}!`)
    end
end)
```
