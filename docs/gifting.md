---
sidebar_position: 4
---

# Gifting System

Gifting is one of Cashier's most powerful features. Cashier provides built-in player-to-player gifting that works across all servers and delivers gifts even to players who are offline.

---

## How Gifting Works

When an item is registered with a `giftId` (a Developer Product ID representing the gift):

1. **Prompt**: The sender initiates a gift and specifies the recipient's `UserId`. Cashier prompts the sender to purchase the Developer Product defined by `giftId`.
2. **Instant Local Delivery**: If the recipient is in the same Roblox server, Cashier grants the item immediately and fires `onGiftReceived` on the recipient's client.
3. **Cross-Server Delivery**: If the recipient is playing in another server of your game, ProfileStore routes the message across servers via MessagingService.
4. **Offline Delivery**: If the recipient is offline, ProfileStore saves the gift in the recipient's message queue in DataStore. As soon as the recipient joins any server in the future, the item is delivered automatically on join.
5. **Fail-Safe Unsent Vault**: If delivery cannot take place for any reason, Cashier automatically credits the item to the sender's `unsent` vault so they never lose Robux.

---

## Configuring a Giftable Item

To make any item giftable, supply a `giftId` in its item configuration:

```lua
-- Server item registration
{
    name = "VIP",
    type = "Gamepass",
    id = 12345678,     -- Gamepass ID for self-purchases
    giftId = 87654321, -- Developer Product ID for gifting
    callback = function(player: Player)
        print(`Granted VIP to {player.Name}`)
        return true
    end,
}
```

:::warning Why giftId must be a Developer Product ID
Gamepasses can only be bought once per Roblox account. Because players may want to gift the same item to multiple friends, `giftId` must always be a **Developer Product ID**.
:::

---

## Sending a Gift

On the client, call `Cashier:gift(recipientUserId, itemName)`:

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Cashier = require(ReplicatedStorage.Packages.Cashier).client

local targetUserId = 12345678 -- UserId of the recipient

local success, errorMessage = Cashier:gift(targetUserId, "VIP")
if not success then
    warn("Unable to initiate gift:", errorMessage)
end
```

### Pre-Purchase Protections

Cashier automatically verifies the following before prompting the purchase:
- Prevents self-gifting (`recipientId == player.UserId`).
- Prevents gifting an item if the recipient already owns it (or already has a pending gift for it).
- Prevents gifting items that do not have a `giftId` configured.

---

## Handling Rare Delivery Failures & Unsent Items

On rare occasions, when attempting to gift an item, the delivery to the recipient might fail due to unforeseen issues (such as DataStore network outages or temporary recipient state errors).

When this occurs:
1. Cashier catches the failure and safely deposits the purchased item into the sender's **Unsent Items** vault.
2. Cashier fires the `giftingFailed` signal on the sender's client.

### Alerting the Player with `giftingFailed`

You should connect to `giftingFailed` to display a user-friendly notification to the player reassuring them that their Robux was not lost:

```lua
local Cashier = require(ReplicatedStorage.Packages.Cashier).client

Cashier.giftingFailed:Connect(function(itemName: string, recipientId: number)
    -- Display a notification UI to the sender
    print(`We couldn't deliver {itemName} to UserId {recipientId} right now.`)
    print("Don't worry! The item was saved to your Unsent Gifts vault and you can re-send it at any time.")
end)
```

---

## Unsent Gift Vault

When a player has items in their unsent vault, they can re-gift the item to the same friend or a different friend at any time. When gifting an item that exists in the unsent vault, Cashier **will not prompt a Robux purchase** and will deliver the stored copy directly!

### Querying Unsent Items

#### Client
```lua
local unsent = Cashier:getUnsentItems()

for itemName, count in unsent do
    print(`You have {count} unsent {itemName}(s) in your vault.`)
end
```

#### Server
```lua
local unsent = Cashier:getUnsentItems(player)
```

---

## Receiving Gifts

When a player receives a gift, you can show a notification or UI by overriding `Cashier:onGiftReceived()` on the client:

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Cashier = require(ReplicatedStorage.Packages.Cashier).client

function Cashier:onGiftReceived(giftData)
    print(`You received a gift! {giftData.item} was sent by UserId: {giftData.from}`)
    -- Show your custom Gift Received notification UI here
end
```

`giftData` contains:
- **`item`** (`string`): The name of the gifted item.
- **`from`** (`number`): The `UserId` of the player who sent the gift.
