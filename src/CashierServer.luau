local DataStoreService = game:GetService("DataStoreService")
local MarketplaceService = game:GetService("MarketplaceService")
local MessagingService = game:GetService("MessagingService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

if RunService:IsClient() then
	return {} :: CashierServer
end

--[=[
    @type ItemType "DevProduct" | "Gamepass" | "Semipass"
    @within CashierServer

    Determines the type of an item.
]=]
type ItemType = "DevProduct" | "Gamepass" | "Semipass"

--[=[
	@interface ItemData
	@within CashierServer
	.name string -- The name of the item
	.type ItemType -- The type of the item
	.id number -- The id of the gamepass or developer product linked with the item
	.giftId number? -- The id of the developer product for gifting this item
	.callback ((Player, ...any?) -> boolean)? -- A callback to be called when delivering the item to a player
	.predicate ((player: Player, ...any) -> boolean)? -- A function to check if the user can purchase the item with the given params

	Configuration data for an item registered with Cashier.

	```lua
	local items = {
		{
			name = "VIP",
			type = "Gamepass",
			id = 1234,
			giftId = 4321,
			callback = function(player: Player)
				DataService:arrayInsert(player, "titles", "VIP")

				-- grants any extra benefits here

				return true
			end
		},
		{
			name = "Starter Pack",
			type = "Semipass",
			id = 7890,
			giftId = 987,
			callback = function(player: Player)
				DataService:update(player, "cash", function(value)
					return value + 5000
				end)

				return true
			end
		},
		{
			name = "Upgrade Unit",
			type "DevProduct",
			id = 6969,
			predicate = function(player: Player, unitId: string)
				-- make any validation here, for example
				-- if unitId is not nill
				-- if it is a valid unitId
				-- if it's not at max level, etc.

				return true
			end,
			callback = function(player: Player, unitId: string)
				-- the unitId will be the same one given to the predicate

				return true
			end
		},
	}
	```

	:::warning
	If the `type` of the item is set to `"Gamepass"`, the `id` should also be a id of a gamepass.
	:::
]=]
type ItemData = {
	name: string,
	type: ItemType,
	id: number,
	giftId: number?,
	callback: ((player: Player, ...any?) -> boolean)?,
	predicate: ((player: Player, ...any) -> boolean)?,
}

--[=[
    @interface Item
    @within CashierServer
    .name string
    .type ItemType
    .id number -- The id of the gamepass of developer product linked with the item
    .giftId number? -- The id of the developer product for gifting this item

    Useful information of an item.
]=]
type Item = {
	name: string,
	type: ItemType,
	id: number,
	giftId: number?,
}

--[=[
    @interface GiftData
    @within CashierServer
    .item string -- The name of the item
    .from number -- The id of the user that has gifted the item

    Data from a gift.
]=]
type GiftData = {
	item: string,
	from: number,
}

--[=[
	@interface PurchaseData
	@within CashierServer
	.player Player -- The player who bought the item
	.item string -- The name of the item
	.robuxSpent number -- The amout of robux spent on the purchase
	.recipientId number? -- The id of the recipient if the purchase was an gift

	Data from a purchase.
]=]
type PurchaseData = {
	player: Player,
	item: string,
	robuxSpent: number,
	recipientId: number?,
}

local DataService = require(script.Parent.Parent.DataService).server
local Networker = require(script.Parent.Parent.Networker)
local ServicePlayerData = require(script.Parent.Parent.ServicePlayerData)
local Sift = require(script.Parent.Parent.Sift)
local Signal = require(script.Parent.Parent.Signal)

local PLAYER_DATA_TEMPLATE = {
	gifting = nil,
}

local purchaseHistoryStore = DataStoreService:GetDataStore("PurchaseHistory")

--[=[
    @class CashierServer

    The server-side of Cashier. Handles item registration, purchase processing, gamepass tracking,
    gifting and inventory management.
]=]
local CashierServer = {}

--[=[
	@method init
	@within CashierServer
	@param options InitOptions

	Initializes the server-side of Cashier.

	```lua
	local DataService = require(path.to.DataService).server
	local Cashier = require(path.to.Cashier).server

	local items = require(path.to.items)

	Cashier:init(items)
	```

	:::warning
	`:init(...)` should be called before using any other method.
	:::
]=]
function CashierServer.init(self: CashierServer, itemsData: { ItemData }): ()
	self._items = Sift.Array.map(itemsData, function(itemData)
		return Sift.Dictionary.removeKeys(itemData, "callback", "predicate")
	end)

	self._itemsCallback = {}
	self._itemsPredicate = {}
	for _, itemData in itemsData do
		self._itemsCallback[itemData.name] = itemData.callback
		self._itemsPredicate[itemData.name] = itemData.predicate
	end

	self._networker = Networker.server.new("Cashier", self, {
		self.getAllItems,
		self.purchaseItem,
		self.gift,
	})
	self._playerData = ServicePlayerData.new(PLAYER_DATA_TEMPLATE)
	self._pendingParams = {}

	--[=[
		@external Signal<T...> https://sleitnick.github.io/RbxUtil/api/Signal/
		@prop purchaseCompleted Signal<PurchaseData>
		@within CashierServer

		A signal that fires when a player buys an item, providing the `PurchaseData`.
	]=]
	self.purchaseCompleted = Signal.new()

	local function onPlayerAdded(player: Player): ()
		DataService:waitForData(player)
		local gifts = DataService:get(player, "_gifts") :: { GiftData }?
		if gifts and #gifts > 0 then
			for _, giftData in gifts do
				self:giveItem(player, giftData.item)
				self._networker:fire(player, "onGiftReceived", giftData)
			end

			DataService:set(player, "_gifts", nil)
		end

		for _, item in self._items do
			if item.type ~= "Gamepass" then
				continue
			end

			local success, ownsGamepass = pcall(function()
				return MarketplaceService:UserOwnsGamePassAsync(player.UserId, item.id)
			end)

			if success and ownsGamepass and not self:hasItem(player, item.name) then
				self:giveItem(player, item.name)
			end
		end
	end

	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end

	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(function(player)
		self._pendingParams[player] = nil
	end)

	MessagingService:SubscribeAsync("_gift", function(message)
		local player = Players:GetPlayerByUserId(message.Data.userId)
		if not player then
			return
		end

		local giftData = message.Data.giftData

		self:giveItem(player, giftData.item)
		self._networker:fire(player, "onGiftReceived", giftData)

		DataService:update(player, "_gifts", function(gifts)
			if not gifts then
				return nil
			end

			local index = Sift.Array.findWhere(gifts, function(data)
				return Sift.Dictionary.equals(giftData, data)
			end)

			if not index then
				return gifts
			end

			local newGifts = Sift.Array.removeIndex(gifts, index)
			return if #newGifts == 0 then nil else newGifts
		end)
	end)

	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player, gamepassId, wasPurchased)
		if not wasPurchased or not MarketplaceService:UserOwnsGamePassAsync(player.UserId, gamepassId) then
			return
		end

		local item = self:getItemById(gamepassId)
		if not item then
			return
		end

		self:giveItem(player, item.name)
		self._networker:fire(player, "_purchaseCompleted", item.name, false)
		self.purchaseCompleted:Fire({
			player = player,
			item = item.name,
			robuxSpent = self:getItemPrice(item.name),
		})
	end)

	MarketplaceService.ProcessReceipt = function(receiptInfo)
		local success, result = pcall(
			purchaseHistoryStore.UpdateAsync,
			purchaseHistoryStore,
			receiptInfo.PurchaseId,
			function(isPurchased: boolean)
				if isPurchased then
					return true
				end

				local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
				if not player then
					return nil
				end

				local item = self:getItemById(receiptInfo.ProductId)
				if not item then
					warn(`No item found with id {receiptInfo.ProductId}`)
					return nil
				end

				if self:isGiftId(receiptInfo.ProductId) then
					task.spawn(self._processGift, self, player, receiptInfo)

					return true
				else
					local didHandlerGrantPurchase = self:giveItem(player, item.name)
					if not didHandlerGrantPurchase then
						return nil
					end

					self._networker:fire(player, "_purchaseCompleted", item.name, false)
					self.purchaseCompleted:Fire({
						player = player,
						item = item.name,
						robuxSpent = receiptInfo.CurrencySpent,
					})

					return true
				end
			end
		)

		if not success then
			warn(`Failed to process receipt due to data store error: {result}`)
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end

		return if result == true
			then Enum.ProductPurchaseDecision.PurchaseGranted
			else Enum.ProductPurchaseDecision.NotProcessedYet
	end
end

function CashierServer._processGift(self: CashierServer, player: Player, receiptInfo): ()
	local item = self:getItemById(receiptInfo.ProductId)
	if not item then
		return
	end

	local playerData = self._playerData:get(player)
	local recipientId = playerData.gifting
	playerData.gifting = nil

	local success = false
	if recipientId then
		local recipientProfile = DataService:asyncGetProfile(recipientId)
		if recipientProfile then
			local recipientItems = recipientProfile.Data["_items"]
			local hasItem = recipientItems and Sift.Set.has(recipientItems, item.name)
			if not hasItem then
				local recipient = Players:GetPlayerByUserId(recipientId)
				if recipient then
					local didGrantRecipient = self:giveItem(recipient, item.name)
					if not didGrantRecipient then
						self:addItemToInventory(player, item.name)
						return
					end

					self._networker:fire(recipient, "onGiftReceived", {
						item = item.name,
						from = player.UserId,
					})
				else
					local didAdded = self:addGift(recipientId, {
						item = item.name,
						from = player.UserId,
					})

					if not didAdded then
						self:addItemToInventory(player, item.name)
					end
				end
				success = true
			end
		end
	end

	if not success then
		self:addItemToInventory(player, item.name)
		self._networker:fire(player, "_purchaseCompleted", item.name, false)
		self.purchaseCompleted:Fire({
			player = player,
			item = item.name,
			robuxSpent = receiptInfo.CurrencySpent,
		})
	else
		self._networker:fire(player, "_purchaseCompleted", item.name, true)
		self.purchaseCompleted:Fire({
			player = player,
			item = item.name,
			robuxSpent = receiptInfo.CurrencySpent,
			recipientId = recipientId,
		})
	end
end

--[=[
	@method getAllItems
	@within CashierServer
	@return { Item }

	Returns the `Item` of all items.

	```lua
	local Cashier = require(path.to.Cashier).server

	for _, item in Cashier:getAllItems() do
		print(item)
	end
	```
]=]
function CashierServer.getAllItems(self: CashierServer): { Item }
	return self._items
end

--[=[
    @method getItemById
    @within CashierServer
    @param itemId number
    @return Item?

    Retrieves the info of an item with the given id.
    `itemId` can be either a normal id or a giftId.

    ```lua
    local Cashier = require(path.to.Cashier).server

    local item = Cashier:getItemById(1234)
    for k, v in item do
        print(k, v)
    end
    ```
]=]
function CashierServer.getItemById(self: CashierServer, itemId: number): Item?
	local index = Sift.Array.findWhere(self._items, function(item: Item)
		return item.id == itemId or item.giftId == itemId
	end)

	return self._items[index]
end

--[=[
    @method getItemByName
    @within CashierServer
    @param itemName string
    @return Item?

    Retrieves the info of an item with the given name.

    ```lua
    local Cashier = require(path.to.Cashier).server

    local item = Cashier:getItemByName("VIP")
    for k, v in item do
        print(k, v)
    end
    ```
]=]
function CashierServer.getItemByName(self: CashierServer, itemName: string): Item?
	local index = Sift.Array.findWhere(self._items, function(item: Item)
		return item.name == itemName
	end)

	return self._items[index]
end

--[=[
	@method getItemsOfType
	@within CashierServer
	@param itemType ItemType

	Returns an array with all items of the given type.

	```lua
	local Cashier = require(path.to.Cashier).server
	
	for _, item in Cashier:getItemsOfType("Gamepass") do
		print(item)
	end
	```
]=]
function CashierServer.getItemsOfType(self: CashierServer, itemType: ItemType): { Item }
	return Sift.Array.filter(self._items, function(itemData: ItemData)
		return itemData.type == itemType
	end)
end

--[=[
	@method isGiftId
	@within CashierServer
	@param id number
	@return boolean

	Checks if an id is the `giftId` of an item.

	```lua
	local Cashier = require(path.to.Cashier).server

	local isGiftId = Cashier:isGiftId(4321)
	print(isGiftId)
	```
]=]
function CashierServer.isGiftId(self: CashierServer, id: number): boolean
	local item = self:getItemById(id)
	if not item then
		return false
	end

	return item.giftId == id
end

--[=[
	@method getItemPrice
	@within CashierServer
	@param itemName string
	@return number

	Returns the price in robux of an item.
]=]
function CashierServer.getItemPrice(self: CashierServer, itemName: string): number
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
    @within CashierServer
    @param player Player
    @param itemName string
    @return boolean

    Checks if the user has the item with the given name.

    ```lua
    local Players = game:GetService("Players")
    local Cashier = require(path.to.Cashier).server

    local player = Players:GetPlayers()[1]
    if player then
        local hasItem = Cashier:hasItem(player, "VIP")
        print(hasItem)
    end
    ```
]=]
function CashierServer.hasItem(self: CashierServer, player: Player, itemName: string): boolean
	if not self:getItemByName(itemName) then
		warn(`No item with name "{itemName}"`)
		return false
	end

	local playerItems = DataService:get(player, "_items")
	if not playerItems then
		return false
	end

	return Sift.Set.has(playerItems, itemName)
end

--[=[
    @method giveItem
    @within CashierServer
    @param player Player
    @param itemName string
    @return boolean

    Gives the item to the player and calls the `callback` of the `ItemData`, if it exists.

    ```lua
    local Players = game:GetService("Players")

    local Cashier = require(path.to.Cashier).server

    Cashier:giveItem(Players.IYuzkkj, "VIP")
    ```
]=]
function CashierServer.giveItem(self: CashierServer, player: Player, itemName: string): boolean
	local item = self:getItemByName(itemName)
	if not item then
		return false
	end

	if self:hasItem(player, itemName) then
		return true
	end

	if item.type ~= "DevProduct" then
		DataService:update(player, "_items", function(playerItems)
			playerItems = playerItems or {}

			return Sift.Set.add(playerItems, itemName)
		end)
	end

	local callback = self._itemsCallback[itemName]
	if not callback then
		return true
	end

	local params = self._pendingParams[player] and self._pendingParams[player][itemName]
	if params then
		self._pendingParams[player][itemName] = nil

		return callback(player, table.unpack(params))
	else
		return callback(player)
	end
end

--[=[
    @method addItemToInventory
    @within CashierServer
    @param player Player
    @param itemName string
    @param amount number?

    Adds the item to the player inventory.

    ```lua
    local Players = game:GetService("Players")

    local Cashier = require(path.to.Cashier).server

    Cashier:addItemToInventory(Players.IYuzkkj, "VIP")
    ```

    :::note
    Further gift attempts of the same item will be sent without charging the user.
    :::
]=]
function CashierServer.addItemToInventory(self: CashierServer, player: Player, itemName: string, amount: number?): ()
	local item = self:getItemByName(itemName)
	if not item then
		return
	end

	DataService:update(player, "_inventory", function(inventory)
		inventory = inventory or {}

		return Sift.Dictionary.update(inventory, itemName, function(value)
			return if amount then value + amount else value + 1
		end, function()
			return 1
		end)
	end)
end

--[=[
	@method addGift
	@within CashierServer
	@param userId number
	@param giftData GiftData
	@return boolean -- Tells if the gift was successfully added

	Adds the item to the player's pending gifts.
	The player will receive the item if it is online in another server, or the next time they join the game.

	```lua
	local Cashier = require(path.to.Cashier).server

	Cashier:addGift(6969, {
		item = "VIP",
		from = 9696
	})
	```
]=]
function CashierServer.addGift(self: CashierServer, userId: number, giftData: GiftData): boolean
	local item = self:getItemByName(giftData.item)
	if not item then
		return false
	end

	local recipientProfile = DataService:asyncGetProfile(userId)
	if not recipientProfile then
		return false
	end

	local recipientItems = recipientProfile.Data["_items"]
	local hasItem = recipientItems and Sift.Set.has(recipientItems, item.name)
	if hasItem then
		return false
	end

	local recipientGifts = recipientProfile.Data["_gifts"] or {}
	table.insert(recipientGifts, giftData)
	recipientProfile.Data["_gifts"] = recipientGifts

	if recipientProfile:IsActive() then
		recipientProfile:Save()
	else
		recipientProfile:SetAsync()
	end

	local s, err = pcall(function()
		MessagingService:PublishAsync("_gift", {
			userId = userId,
			giftData = giftData,
		})
	end)

	if not s then
		warn(err)
	end

	return true
end

--[=[
	@method purchaseItem
	@within CashierServer
	@param player Player
	@param itemName string
	@param ... any -- Extra params

	Prompts the user to purchase the item with the given name.

	```lua
	local Cashier = require(path.to.Cashier).client

	if not hasVIP then
		Cashier:purchaseItem(player, "VIP")
	end
	```
]=]
function CashierServer.purchaseItem(self: CashierServer, player: Player, itemName: string, ...: any): ()
	local item = self:getItemByName(itemName)
	if not item then
		return
	end

	if self:hasItem(player, itemName) then
		return
	end

	local predicate = self._itemsPredicate[itemName]
	if predicate then
		local result = predicate(player, ...)
		if not result then
			return
		end

		local params = { ... }
		if #params > 0 then
			if not self._pendingParams[player] then
				self._pendingParams[player] = {}
			end

			self._pendingParams[player][itemName] = params
		end
	end

	if item.type == "Gamepass" then
		MarketplaceService:PromptGamePassPurchase(player, item.id)
	else
		MarketplaceService:PromptProductPurchase(player, item.id)
	end

	self._networker:fire(player, "_purchaseStarted")
end

--[=[
    @method gift
    @within CashierServer
    @param player Player
    @param userId number
    @param itemName string
    @return boolean -- Tells if the gift was successfully initiated
    @return string? -- An error message in case the user could not gift the other one

    Prompts the user to purchase the item for the other player.
]=]
function CashierServer.gift(
	self: CashierServer,
	player: Player,
	userId: number,
	itemName: string
): (boolean, string?, boolean?)
	if userId == player.UserId then
		return false, "You cannot gift yourself", false
	end

	local item = self:getItemByName(itemName)
	if not item then
		return false, `No item found with name "{itemName}"`, false
	end

	if not item.giftId then
		return false, `You cannot gift this item`, false
	end

	local recipientProfile = DataService:asyncGetProfile(userId)
	if not recipientProfile then
		return false, `You can not gift someone who hasn't played the game before`, false
	end

	local recipientItems = recipientProfile.Data["_items"]
	local hasItem = item.type ~= "DevProduct"
		and (
			recipientItems and Sift.Set.has(recipientItems, itemName)
			or recipientProfile
				and recipientProfile.Data["_gifts"]
				and Sift.Array.findWhere(recipientProfile.Data["_gifts"], function(giftData)
					return giftData.item == itemName
				end) ~= nil
		)
	if hasItem then
		return false, `User already owns this item`, false
	end

	self._playerData:get(player).gifting = userId

	local playerInventory = DataService:get(player, "_inventory")
	if playerInventory and playerInventory[itemName] then
		DataService:update(player, "_inventory", function(inventory)
			inventory = Sift.Dictionary.update(inventory, itemName, function(value)
				return if value - 1 > 0 then value - 1 else nil
			end)

			if Sift.Dictionary.count(inventory) == 0 then
				return nil
			else
				return inventory
			end
		end)

		task.spawn(
			self._processGift,
			self,
			player,
			{ ProductId = item.id, CurrencySpent = self:getItemPrice(itemName) }
		)

		return true
	end

	MarketplaceService:PromptProductPurchase(player, item.giftId)
	self._networker:fire(player, "_purchaseStarted")

	return true
end

type CashierServer = typeof(CashierServer) & {
	_items: { Item },
	_itemsCallback: { [string]: (player: Player, ...any?) -> boolean },
	_itemsPredicate: { [string]: (player: Player, ...any) -> boolean },
	_networker: Networker.Server,
	_pendingParams: { [Player]: { [string]: { any } } },
	_playerData: ServicePlayerData.ServicePlayerData<{
		gifting: number?,
	}>,
	purchaseCompleted: Signal.Signal<PurchaseData>,
}

return CashierServer :: CashierServer
