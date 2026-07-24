local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

if RunService:IsServer() then
	return {} :: CashierClient
end

--[=[
    @type ItemType "DevProduct" | "Gamepass" | "Semipass"
    @within CashierClient

    Determines the type of an item.
]=]
type ItemType = "DevProduct" | "Gamepass" | "Semipass"

--[=[
    @interface Item
    @within CashierClient
    .name string -- The name of the item
    .description string -- The description of the item
    .iconId string -- The icon of the item. This is a full "rbxassetid://..." string
    .type ItemType -- The type of the item
    .id number -- The id of the gamepass of developer product linked with the item
    .giftId number? -- The id of the developer product for gifting this item

    Useful information of an item.
]=]
type Item = {
	name: string,
	description: string?,
	iconId: string?,
	type: ItemType,
	id: number,
	giftId: number?,
}

--[=[
    @interface GiftData
    @within CashierClient
    .item string -- The name of the item
    .from number -- The id of the user that has gifted the item

    Data from a gift.
]=]
type GiftData = {
	item: string,
	from: number,
}

local DataService = require(script.Parent.Parent.DataService).client
local Networker = require(script.Parent.Parent.Networker)
local Sift = require(script.Parent.Parent.Sift)
local Signal = require(script.Parent.Parent.Signal)

local localPlayer = Players.LocalPlayer

--[=[
    @class CashierClient

    The client-side of Cashier. Handles purchase prompts, item queries and gift sending.
]=]
local CashierClient = {}

--[=[
    @method init
    @within CashierClient

    Initializes the client-side of Cashier.

    ```lua
    local Cashier = require(path.to.Cashier).client

    Cashier:init()
    ```

    :::warning
    `:init(...)` should be called before using any other method.
    :::
]=]
function CashierClient.init(self: CashierClient): ()
	self._purchasing = false
	self._networker = Networker.client.new("Cashier", self)

	--[=[
        @prop purchaseStarted Signal<>
        @within CashierClient

        A signal that fires when a purchase prompt is shown to the player.
    ]=]
	self.purchaseStarted = Signal.new()

	--[=[
        @prop purchaseFinished Signal<string, boolean, boolean>
        @within CashierClient

        A signal that fires when a purchase prompt is closed, providing the name of the item, a boolean indicating whether the purchase was completed successfully, and a boolean indicating if the purchase was a gift.
    ]=]
	self.purchaseFinished = Signal.new()

	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player, gamepassId, wasPurchased)
		if player ~= localPlayer then
			return
		end

		local item = self:getItemById(gamepassId)
		if not item then
			return
		end

		if wasPurchased then
			return
		end

		self._purchasing = false
		self.purchaseFinished:Fire(item.name, wasPurchased, false)
	end)

	MarketplaceService.PromptProductPurchaseFinished:Connect(function(userId, productId, wasPurchased)
		if userId ~= localPlayer.UserId then
			return
		end

		local item = self:getItemById(productId)
		if not item then
			return
		end

		if wasPurchased then
			return
		end

		self._purchasing = false
		self.purchaseFinished:Fire(item.name, wasPurchased, self:isGiftId(productId))
	end)
end

function CashierClient._purchaseStarted(self: CashierClient): ()
	if self._purchasing then
		return
	end

	self._purchasing = true
	self.purchaseStarted:Fire()
end

function CashierClient._purchaseCompleted(self: CashierClient, itemName: string, wasGift: boolean): ()
	if not self._purchasing then
		return
	end

	self._purchasing = false
	self.purchaseFinished:Fire(itemName, true, wasGift)
end

--[=[
    @method getAllItems
    @within CashierClient
    @return { Item }

    Returns an array with all registered items.

    ```lua
    local Cashier = require(path.to.Cashier).client

    for _, item in Cashier:getAllItems() do
        print(item.name, item.type)
    end
    ```
]=]
function CashierClient.getAllItems(self: CashierClient): { Item }
	if not self._items then
		self._items = self._networker:fetch("getAllItems")
	end

	return self._items
end

--[=[
    @method getItemById
    @within CashierClient
    @param itemId number
    @return Item?

    Retrieves the info of an item with the given id.
    `itemId` can be either a normal id or a giftId.

    ```lua
    local Cashier = require(path.to.Cashier).client

    local item = Cashier:getItemById(1234)
    for k, v in item do
        print(k, v)
    end
    ```
]=]
function CashierClient.getItemById(self: CashierClient, itemId: number): Item?
	local items = self:getAllItems()
	local index = Sift.Array.findWhere(items, function(item: Item)
		return item.id == itemId or item.giftId == itemId
	end)

	return items[index]
end

--[=[
    @method getItemByName
    @within CashierClient
    @param itemName string
    @return Item?

    Retrieves the info of an item with the given name.

    ```lua
    local Cashier = require(path.to.Cashier).client

    local item = Cashier:getItemByName("VIP")
    for k, v in item do
        print(k, v)
    end
    ```
]=]
function CashierClient.getItemByName(self: CashierClient, itemName: string): Item?
	local items = self:getAllItems()
	local index = Sift.Array.findWhere(items, function(item: Item)
		return item.name == itemName
	end)

	return items[index]
end

--[=[
	@method getItemsOfType
	@within CashierClient
	@param itemType ItemType
	@return { Item }

	Returns an array with all items of the given type.

	```lua
	local Cashier = require(path.to.Cashier).client

	for _, item in Cashier:getItemsOfType("Gamepass") do
		print(item.name, item.id)
	end
	```
]=]
function CashierClient.getItemsOfType(self: CashierClient, itemType: ItemType): { Item }
	local items = self:getAllItems()
	return Sift.Array.filter(items, function(item: Item)
		return item.type == itemType
	end)
end

--[=[
	@method isGiftId
	@within CashierClient
	@param id number
	@return boolean

	Checks if an id is the `giftId` of an item.

	```lua
	local Cashier = require(path.to.Cashier).client

	local isGiftId = Cashier:isGiftId(4321)
	print(isGiftId)
	```
]=]
function CashierClient.isGiftId(self: CashierClient, id): boolean
	local item = self:getItemById(id)
	if not item then
		return false
	end

	return item.giftId == id
end

--[=[
    @method getItemPrice
    @within CashierClient
    @yields
    @param itemName string
    @return number

    Returns the price in robux of an item.

    ```lua
    local Cashier = require(path.to.Cashier).client

    local priceLabel = script.Parent

    local price = Cashier:getItemPrice("VIP")
    priceLabel.Text = `${price}`
    ```
]=]
function CashierClient.getItemPrice(self: CashierClient, itemName: string): number
	local item = self:getItemByName(itemName)
	if not item then
		return
	end

	local success, productInfo = pcall(function()
		return MarketplaceService:GetProductInfoAsync(
			item.id,
			if item.type == "Gamepass" then Enum.InfoType.GamePass else Enum.InfoType.Product
		)
	end)

	return if success and productInfo then productInfo.PriceInRobux else 0
end

--[=[
    @method hasItem
    @within CashierClient
    @param itemName string
    @return boolean

    Checks if the user has the item with the given name.

    ```lua
    local Cashier = require(path.to.Cashier).client

    local textLabel = script.Parent

    local hasItem = Cashier:hasItem("VIP")
    if hasItem then
        textLabel.Text = "Owned"
    end
    ```
]=]
function CashierClient.hasItem(self: CashierClient, itemName: string): boolean
	if not self:getItemByName(itemName) then
		warn(`No item with name "{itemName}"`)
		return false
	end

	local items = DataService:get("_items")
	if not items then
		return false
	end

	return Sift.Set.has(items, itemName)
end

--[=[
    @method purchaseItem
    @within CashierClient
    @param itemName string
    @param ... any? -- Extra params passed to the item's predicate

    Prompts the local player to purchase the item with the given name.

    ```lua
    local Cashier = require(path.to.Cashier).client

    local button = script.Parent
    button.Activated:Connect(function()
        Cashier:purchaseItem("VIP")
    end)
    ```
]=]
function CashierClient.purchaseItem(self: CashierClient, itemName: string, ...: any?): ()
	if self._purchasing then
		return
	end

	self._networker:fetch("purchaseItem", itemName, ...)
end

--[=[
    @method gift
    @within CashierClient
    @param userId number
    @param itemName string
    @return boolean -- Whether the gift was successfully initiated
    @return string? -- An error message in case the user could not gift the other one

    Prompts the user to purchase the item for the other player.

    ```lua
    local Cashier = require(path.to.Cashier).client

    local giftButton = script.Parent
    giftButton.Activated:Connect(function()
        Cashier:gift(6969, "VIP")
    end)
    ```
]=]
function CashierClient.gift(self: CashierClient, userId: number, itemName: string): (boolean, string?)
	if self._purchasing then
		return false
	end

	return self._networker:fetch("gift", userId, itemName)
end

--[=[
    @method onGiftReceived
    @within CashierClient
    @tag Override
    @param giftData GiftData

    Overridable method called when the user receives a gift.

    ```lua
    local Cashier = require(path.to.Cashier).client

    function Cashier:onGiftReceived(giftData: GiftData)
        print(`{giftData.from} gifted you {giftData.item}!`)
    end
    ```
]=]
function CashierClient.onGiftReceived(self: CashierClient, giftData: GiftData) end

type CashierClient = typeof(CashierClient) & {
	_items: { Item },
	_purchasing: boolean,
	_networker: Networker.Client,
	purchaseStarted: Signal.Signal<>,
	purchaseFinished: Signal.Signal<string, boolean, boolean>,
}

return CashierClient :: CashierClient
