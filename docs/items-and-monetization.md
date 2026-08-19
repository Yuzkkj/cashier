---
sidebar_position: 2
---

# Items & Monetization

In traditional Roblox development, Gamepasses and Developer Products are handled in completely separate codebases with different APIs, receipt handlers, and prompt listeners.

**Cashier solves this by treating every purchasable product as a unified "Item".**

Whether a player is purchasing a permanent pass, consumable coins, a stock-limited weapon, or a custom game perk, you interact with the same clean interface.

---

## Item Types

Cashier supports three distinct item types:

```lua
type ItemType = "DevProduct" | "Gamepass" | "Semipass"
```

| Type | Description | Persistence | Repeatable |
| :--- | :--- | :--- | :--- |
| **`"Gamepass"`** | Standard Roblox GamePass linked to a Roblox GamePass ID. | Saved in Roblox's GamePass system + synced to Cashier | No (One-time) |
| **`"DevProduct"`** | Repeatable Developer Product linked to a Roblox Product ID. Used for coins, gems, consumables, or temporary boosts. | Handled via receipts; not tracked as permanently "owned" | Yes (Repeatable) |
| **`"Semipass"`** | Custom one-time purchase backed by a Developer Product ID. Ownership is tracked directly in Cashier's database. | Saved in Cashier's ProfileStore database | No (One-time) |

### Why use `"Semipass"`?

A **Semipass** uses a Developer Product ID under the hood, but behaves like a Gamepass in your game:
- Players can only buy it once (unless reset or gifted).
- It does not rely on Roblox's Gamepass inventory, making it ideal if you want perks that can be reset upon game prestige, transferred, or managed entirely within your game's data.

---

## Item Configuration

Every item registered in `Cashier:init()` is defined using the `ItemData` interface:

```lua
type ItemData = {
    name: string,
    type: "DevProduct" | "Gamepass" | "Semipass",
    id: number,
    giftId: number?,
    callback: (player: Player, ...any?) -> boolean,
    predicate: ((player: Player, ...any?) -> boolean)?,
}
```

### Properties Breakdown

- **`name`** (`string`): The unique identifier for this item across Cashier.
- **`type`** (`ItemType`): `"Gamepass"`, `"DevProduct"`, or `"Semipass"`.
- **`id`** (`number`): The Roblox GamePass ID (for `"Gamepass"`) or Developer Product ID (for `"DevProduct"` / `"Semipass"`).
- **`giftId`** (`number?`, optional): A Developer Product ID used specifically when players gift this item to others.
- **`callback`** (`function`): Executed on the server when the purchase or gift is granted. Must return `true` on success.
- **`predicate`** (`function?`, optional): An optional validator function called on the server *before* the purchase prompt is shown to the player.

---

## Using Predicates for Purchase Validation

Some purchases require validation before opening a prompt (such as checking if the player has reached a certain level, has enough backpack space, or if an item has remaining stock).

When a client calls `Cashier:purchase(itemName, ...)`, any extra arguments are passed directly to the server `predicate`:

```lua
-- Server configuration
{
    name = "Upgrade Unit",
    type = "DevProduct",
    id = 55566677,
    
    -- Gating logic: runs BEFORE prompting the purchase
    predicate = function(player: Player, unitId: string)
        local unit = UnitService:getUnit(player, unitId)
        if not unit then
            return false -- Unit does not exist
        end
        if unit.level >= unit.maxLevel then
            return false -- Already at max level, prevent purchase
        end
        return true -- Validation passed, prompt the purchase
    end,

    -- Reward logic: runs when the receipt is successfully processed
    callback = function(player: Player, unitId: string)
        UnitService:levelUpUnit(player, unitId)
        return true
    end,
}
```

On the client, pass the target `unitId`:

```lua
-- Client
Cashier:purchase("Upgrade Unit", selectedUnitId)
```

:::info How Predicates Work
If the `predicate` returns `false` (or `nil`), Cashier will immediately abort and will not display the purchase prompt to the player, preventing accidental purchases that cannot be fulfilled.
:::

---

## Best Practices for Callbacks

1. **Always return a boolean**:
   - Return `true` if the item/perks were successfully delivered.
   - Return `false` if an error occurred during granting. Returning `false` leaves the receipt ungranted so Roblox can safely retry the transaction later.

2. **Keep callbacks non-blocking**:
   - If you need to perform heavy calculations or asynchronous saves, perform them within your game's data services and return `true` once the grant is recorded.
