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
	@interface Limited
	@within CashierClient
	.name string -- The name of the limited
	.id number -- The developer product id linked to the limited
	.initialStock number -- The initial stock when the limited was created
	.stockLeft number -- The remaining stock available for purchase
	.onePerPlayer boolean -- Determines if a player can only purchase this limited once
	.expiration number? -- The Unix timestamp at which the limited expires

	Configuration and state data for a stock-limited item.
]=]
type Limited = {
	name: string,
	id: number,
	initialStock: number,
	stockLeft: number,
	onePerPlayer: boolean,
	expiration: number?,
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

    The client-side of Cashier. Handles purchase prompts, item queries, gift sending,
    and limited items for the local player.
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

	--[=[
		@prop limitedChanged Signal<Limited>
		@within CashierClient

		A signal that fires whenever a limited's data changes, providing the updated limited info.
	]=]
	self.limitedChanged = Signal.new()

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

function CashierClient._onLimitedChanged(self: CashierClient, limited: Limited): ()
	local limiteds = self:getAllLimiteds()
	local index = Sift.Array.findWhere(limiteds, function(l: Limited)
		return l.name == limited.name
	end)

	if index then
		self._limiteds[index] = limited
	else
		table.insert(self._limiteds, limited)
	end

	self.limitedChanged:Fire(limited)
end

function CashierClient._onLimitedRemoved(self: CashierClient, limitedName: string): ()
	local limiteds = self:getAllLimiteds()
	local index = Sift.Array.findWhere(limiteds, function(l: Limited)
		return l.name == limitedName
	end)

	if index then
		table.remove(self._limiteds, index)
	end
end

--[=[
	@method getAllLimiteds
	@within CashierClient
	@return { Limited }

	Returns an array with all currently available limited items.

	```lua
	local Cashier = require(path.to.Cashier).client

	for _, limited in Cashier:getAllLimiteds() do
		print(limited.name, limited.stockLeft)
	end
	```
]=]
function CashierClient.getAllLimiteds(self: CashierClient): { Limited }
	if not self._limiteds then
		self._limiteds = self._networker:fetch("getAllLimiteds")
	end

	return self._limiteds
end

--[=[
	@method getLimitedByName
	@within CashierClient
	@param name string
	@return Limited?

	Retrieves a limited item by its name. Returns `nil` if no limited with the given name exists.

	```lua
	local Cashier = require(path.to.Cashier).client

	local limited = Cashier:getLimitedByName("Exclusive Sword")
	if limited then
		print(limited.stockLeft)
	end
	```
]=]
function CashierClient.getLimitedByName(self: CashierClient, name: string): Limited?
	local limiteds = self:getAllLimiteds()
	local index = Sift.Array.findWhere(limiteds, function(limited: Limited)
		return limited.name == name
	end)

	return limiteds[index]
end

--[=[
	@method getLimitedFromId
	@within CashierClient
	@param id number
	@return Limited?

	Retrieves a limited item by its developer product id. Returns `nil` if no limited with the given id exists.

	```lua
	local Cashier = require(path.to.Cashier).client

	local limited = Cashier:getLimitedFromId(123456)
	if limited then
		print(limited.name, limited.stockLeft)
	end
	```
]=]
function CashierClient.getLimitedFromId(self: CashierClient, id: number): Limited?
	local limiteds = self:getAllLimiteds()
	local index = Sift.Array.findWhere(limiteds, function(limited: Limited)
		return limited.id == id
	end)

	return limiteds[index]
end

--[=[
	@method purchaseLimited
	@within CashierClient
	@param limitedName string

	Prompts the local player to purchase a limited item. Performs client-side validation
	(stock, expiration, one-per-player) before requesting the server.

	```lua
	local Cashier = require(path.to.Cashier).client

	local button = script.Parent
	button.Activated:Connect(function()
		Cashier:purchaseLimited("Exclusive Sword")
	end)
	```
]=]
function CashierClient.purchaseLimited(self: CashierClient, limitedName: string): ()
	local limited = self:getLimitedByName(limitedName)
	if not limited then
		return
	end

	if limited.stockLeft <= 0 then
		return
	end

	if limited.expiration and limited.expiration <= os.time() then
		return
	end

	if limited.onePerPlayer and self:hasLimited(limitedName) then
		return
	end

	self._networker:fetch("purchaseLimited", limitedName)
end

--[=[
	@method hasLimited
	@within CashierClient
	@param limitedName string
	@return boolean

	Checks if the local player owns the given limited item.

	```lua
	local Cashier = require(path.to.Cashier).client

	if Cashier:hasLimited("Exclusive Sword") then
		print("Player owns the Exclusive Sword!")
	end
	```
]=]
function CashierClient.hasLimited(self: CashierClient, limitedName: string): boolean
	if not self:getLimitedByName(limitedName) then
		warn(`No limited with name "{limitedName}"`)
		return
	end

	local limiteds = DataService:get("_limiteds")
	if not limiteds then
		return false
	end

	return Sift.Set.has(limiteds, limitedName)
end

type CashierClient = typeof(CashierClient) & {
	_items: { Item },
	_limiteds: { Limited },
	_purchasing: boolean,
	_networker: Networker.Client,
	purchaseStarted: Signal.Signal<>,
	purchaseFinished: Signal.Signal<string, boolean, boolean>,
	limitedChanged: Signal.Signal<Limited>,
}

return CashierClient :: CashierClient
