local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

if not RunService:IsClient() then
	return {} :: CashierClient
end

local Packages = script.Parent.Parent
local Networker = require(Packages.Networker)
local Sift = require(Packages.Sift)
local Signal = require(Packages.Signal)

local localPlayer = Players.LocalPlayer

--[=[
	@type ItemType "DevProduct" | "Gamepass" | "Semipass"
	@within CashierClient

	Determines the type of an item.
]=]
type ItemType = "DevProduct" | "Gamepass" | "Semipass"

--[=[
	@interface Item
	@within CashierClient
	.name string -- The unique name of the item
	.type ItemType -- The type of the item ("DevProduct", "Gamepass", or "Semipass")
	.id number -- The Roblox GamePass ID or Developer Product ID
	.giftId number? -- The Developer Product ID used for gifting this item
]=]
type Item = {
	name: string,
	type: ItemType,
	id: number,
	giftId: number?,
}

--[=[
	@interface GiftData
	@within CashierClient
	.item string -- The name of the gifted item
	.from number -- The UserId of the player who sent the gift
]=]
type GiftData = {
	item: string,
	from: number,
}

--[=[
	@class CashierClient
	@client

	The client-side singleton for Cashier. Handles purchase prompts, gifting, item queries, and ownership state.
]=]
local CashierClient = {
	_items = {} :: { Item },
	_purchasing = false,
	--[=[
		@prop giftingFailed Signal<string, number>
		@within CashierClient

		Fires when a gift delivery fails, passing the item name and recipient UserId.
	]=]
	giftingFailed = Signal.new() :: Signal.Signal<string, number>,
	--[=[
		@prop itemAcquired Signal<string>
		@within CashierClient

		Fires when the local player acquires a new item (e.g. gamepass or semipass).
	]=]
	itemAcquired = Signal.new() :: Signal.Signal<string>,
	--[=[
		@prop purchaseStarted Signal<()>
		@within CashierClient

		Fires when a purchase prompt is opened.
	]=]
	purchaseStarted = Signal.new(),
	--[=[
		@prop purchaseFinished Signal<string, boolean, boolean>
		@within CashierClient

		Fires when a purchase prompt closes, passing the item name, whether the purchase succeeded, and whether it was a gift.
	]=]
	purchaseFinished = Signal.new() :: Signal.Signal<string, boolean, boolean>,
}

--[=[
	@method init
	@within CashierClient
	
	Initializes the client-side of Cashier and begins listening for network replication from the server.

	```lua
	local Cashier = require(path.to.Cashier).client

	Cashier:init()
	```
]=]
function CashierClient.init(self: CashierClient): ()
	assert(RunService:IsClient(), "Cashier client-side can only be used by the client.")
	assert(self._networker == nil, "Cashier client-side has already been initialized.")

	self._networker = Networker.client.new("Cashier", self)

	self._networker:getServerChangedSignal("_purchasing"):Connect(function(state)
		if not state then
			return
		end

		self.purchaseStarted:Fire()
	end)

	local previous = self._owned
	self._networker:getServerChangedSignal("_owned"):Connect(function(owned)
		if not previous then
			previous = owned
			return
		end

		local acquired = Sift.Set.difference(owned, previous)
		for itemName in acquired do
			self.itemAcquired:Fire(itemName)
		end

		previous = owned
	end)

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

function CashierClient._giftingFailed(self: CashierClient, itemName: string, recipientId: number): ()
	self._purchasing = false
	self.giftingFailed:Fire(itemName, recipientId)
end

function CashierClient._purchaseCompleted(self: CashierClient, itemName: string, wasGift: boolean): ()
	if not self._purchasing then
		return
	end

	self._purchasing = false
	self.purchaseFinished:Fire(itemName, true, wasGift)
end

--[=[
	@method getUnsentItems
	@within CashierClient
	@yields
	@return { [string]: number } -- A dictionary mapping item names to unsent gift counts
	
	Fetches the list of unsent gifts owned by the local player that were not delivered (e.g. due to delivery failure).

	```lua
	local Cashier = require(path.to.Cashier).client
	
	local unsentItems = Cashier:getUnsentItems()

	for itemName, amount in unsentItems do
		print(`You have {amount} unsent {itemName}(s).`)
	end
	```
]=]
function CashierClient.getUnsentItems(self: CashierClient): { [string]: number }
	return self._networker:fetch("getUnsentItems")
end

--[=[
	@method getAllItems
	@within CashierClient
	@return { Item } -- An array containing all registered items

	Returns an array of all registered items.

	```lua
	local Cashier = require(path.to.Cashier).client

	local items = Cashier:getAllItems()

	for _, item in items do
		print(item.name, item.type)
	end
	```
]=]
function CashierClient.getAllItems(self: CashierClient): { Item }
	return self._items
end

--[=[
	@method getItemsOfType
	@within CashierClient
	@param itemType ItemType -- The type of items to retrieve ("DevProduct" | "Gamepass" | "Semipass")
	@return { Item } -- An array containing items of the specified type

	Retrieves all registered items of a specific type.

	```lua
	local Cashier = require(path.to.Cashier).client

	local gamepasses = Cashier:getItemsOfType("Gamepass")

	for _, item in gamepasses do
		print(item.name)
	end
	```
]=]
function CashierClient.getItemsOfType(self: CashierClient, itemType: ItemType): { Item }
	return Sift.Array.filter(self._items, function(item: Item)
		return item.type == itemType
	end)
end

--[=[ 
	@method getItemByName
	@within CashierClient
	@param itemName string -- The name of the item to retrieve
	@return Item? -- The item with the specified name, or nil if not found

	Retrieves a registered item by its name.

	```lua
	local Cashier = require(path.to.Cashier).client

	local item = Cashier:getItemByName("VIP")

	if item then
		print("Found item with ID:", item.id)
	end
	```
]=]
function CashierClient.getItemByName(self: CashierClient, itemName: string): Item?
	local index = Sift.Array.findWhere(self._items, function(item: Item)
		return item.name == itemName
	end)

	return index and self._items[index]
end

--[=[ 
	@method getItemById
	@within CashierClient
	@param itemId number -- The ID of the item to retrieve
	@return Item? -- The item with the specified ID, or nil if not found

	Retrieves a registered item by its ID.

	```lua
	local Cashier = require(path.to.Cashier).client

	local item = Cashier:getItemById(123456)

	if item then
		print("Found item:", item.name)
	end
	```

	:::info
	`itemId` can be a standard product/gamepass ID or a gift Developer Product ID.
	:::
]=]
function CashierClient.getItemById(self: CashierClient, itemId: number): Item?
	local index = Sift.Array.findWhere(self._items, function(item: Item)
		return item.id == itemId or item.giftId == itemId
	end)

	return index and self._items[index]
end

--[=[ 
	@method getItemPrice
	@within CashierClient
	@yields
	@param itemName string -- The name of the item to get the price of
	@return number -- The price of the item in Robux, or 0 if unavailable

	Retrieves the price of an item in Robux from MarketplaceService.

	```lua
	local Cashier = require(path.to.Cashier).client

	local price = Cashier:getItemPrice("VIP")

	print(`VIP costs {price} Robux`)
	```
]=]
function CashierClient.getItemPrice(self: CashierClient, itemName: string): number
	local item = self:getItemByName(itemName)
	if not item then
		return 0
	end

	local success, productInfo = pcall(function()
		return MarketplaceService:GetProductInfoAsync(
			item.id,
			if item.type == "Gamepass" then Enum.InfoType.GamePass else Enum.InfoType.Product
		)
	end)

	return if success and productInfo and productInfo.PriceInRobux then productInfo.PriceInRobux else 0
end

--[=[ 
	@method isGiftId
	@within CashierClient
	@param itemId number -- The ID to check
	@return boolean -- True if the ID is a registered gift product ID, false otherwise

	Checks if an item ID is a registered gift Developer Product ID.

	```lua
	local Cashier = require(path.to.Cashier).client

	local id = 123456

	print(Cashier:isGiftId(id))
	```
]=]
function CashierClient.isGiftId(self: CashierClient, itemId: number): boolean
	return Sift.Array.findWhere(self._items, function(item: Item)
		return item.giftId == itemId
	end) ~= nil
end

--[=[ 
	@method has
	@within CashierClient
	@param itemName string -- The name of the item to check
	@return boolean -- True if the player owns the item, false otherwise

	Checks if the local player owns a specific item.

	```lua
	local Cashier = require(path.to.Cashier).client

	local hasItem = Cashier:has("VIP")

	if hasItem then
		print("You own the VIP gamepass.")
	end
	```
]=]
function CashierClient.has(self: CashierClient, itemName: string): boolean
	return if self._owned then Sift.Set.has(self._owned, itemName) else false
end

--[=[ 
	@method purchase
	@within CashierClient
	@param itemName string -- The name of the item to purchase
	@param ... any? -- Optional additional arguments passed to the server predicate and callback

	Initiates a purchase prompt for the specified item.

	```lua
	local Cashier = require(path.to.Cashier).client
	local button = script.Parent

	button.Activated:Connect(function()
		Cashier:purchase("VIP")
	end)
	```

	:::warning
	This method should only be called on the client.
	:::
]=]
function CashierClient.purchase(self: CashierClient, itemName: string, ...: any?): ()
	if self._purchasing then
		return
	end

	self._networker:fire("_purchase", itemName, ...)
end

--[=[ 
	@method gift
	@within CashierClient
	@yields
	@param recipientId number -- The UserId of the player to gift the item to
	@param itemName string -- The name of the item to gift
	@return boolean -- True if the gift was successfully initiated or delivered, false otherwise
	@return string? -- An error message if the gift request failed

	Sends a gift to another user by their UserId.

	```lua
	local Cashier = require(path.to.Cashier).client

	local success, errMsg = Cashier:gift(123456, "VIP")

	if not success then
		warn("Gifting failed:", errMsg)
	end
	```
]=]
function CashierClient.gift(self: CashierClient, recipientId: number, itemName: string): (boolean, string?)
	if self._purchasing then
		return false
	end

	return self._networker:fetch("_gift", recipientId, itemName)
end

--[=[
	@method onGiftReceived
	@within CashierClient
	@param giftData GiftData -- Information about the received gift

	An overridable callback invoked when the local player receives a gift. Can be overridden to display custom UI or notifications.

	```lua
	local Cashier = require(path.to.Cashier).client

	function Cashier:onGiftReceived(giftData)
		print(`You received {giftData.item} from UserId {giftData.from}.`)
	end
	```
]=]
function CashierClient.onGiftReceived(self: CashierClient, giftData: GiftData): () end

export type CashierClient = typeof(CashierClient) & {
	_owned: { [string]: true },
	_networker: Networker.Client,
}

return CashierClient :: CashierClient
