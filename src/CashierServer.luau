local DataStoreService = game:GetService("DataStoreService")
local MarketplaceService = game:GetService("MarketplaceService")
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

--[=[
	@interface Limited
	@within CashierServer
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
    @type InitOptions { ItemData }
    @within CashierServer

    Options for initializing the Cashier.
]=]
type InitOptions = {
	itemsData: { ItemData },
	limitedsCallbacks: { [string]: (player: Player) -> boolean },
}

local DataService = require(script.Parent.Parent.DataService).server
local Networker = require(script.Parent.Parent.Networker)
local ServicePlayerData = require(script.Parent.Parent.ServicePlayerData)
local Sift = require(script.Parent.Parent.Sift)
local Signal = require(script.Parent.Parent.Signal)

local DATA_STORE_KEY = "Limiteds"
local PLAYER_DATA_TEMPLATE = {
	gifting = nil,
}
local UPDATE_INTERVAL = 60

local purchaseHistoryStore = DataStoreService:GetDataStore("PurchaseHistory")

--[=[
    @class CashierServer

    The server-side of Cashier. Handles item registration, purchase processing, gamepass tracking,
    gifting, inventory management, and stock-limited items.
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
	local limitedsCallback = require(path.to.limitedsCallback)

	Cashier:init({
		itemsData = items,
		limitedsCallback = limitedsCallback
	})
	```

	:::warning
	`:init(...)` should be called before using any other method.
	:::
]=]
function CashierServer.init(self: CashierServer, options: InitOptions): ()
	self._items = Sift.Array.map(options.itemsData, function(itemData)
		return Sift.Dictionary.removeKeys(itemData, "callback", "predicate")
	end)

	self._itemsCallback = {}
	self._itemsPredicate = {}
	for _, itemData in options.itemsData do
		self._itemsCallback[itemData.name] = itemData.callback
		self._itemsPredicate[itemData.name] = itemData.predicate
	end

	self._limiteds = {}
	self._limitedsCallback = options.limitedsCallback or {}
	self._limitedsDataStore = DataStoreService:GetDataStore("Limiteds")

	self._networker = Networker.server.new("Cashier", self, {
		self.getAllItems,
		self.purchaseItem,
		self.gift,
		self.getAllLimiteds,
		self.purchaseLimited,
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

	self:_updateLimiteds()

	local function onPlayerAdded(player: Player): ()
		DataService:waitForData(player)
		local gifts = DataService:get(player, "_gifts") :: { GiftData }?
		if gifts and #gifts > 0 then
			for _, giftData in gifts do
				self:giveItem(player, giftData.item)

				self._networker:fire(player, "_onGiftReceived", giftData)
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

	DataService:addGlobalCallback("_gift", function(player, giftData: GiftData)
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

				local limited = self:getLimitedById(receiptInfo.ProductId)
				if limited then
					task.spawn(self._processLimitedPurchase, self, player, limited)

					self._networker:fire(player, "_purchaseCompleted", limited.name, false)
					self.purchaseCompleted:Fire({
						player = player,
						item = limited.name,
						robuxSpent = receiptInfo.CurrencySpent,
					})

					return true
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

	task.spawn(function()
		while true do
			self:_updateLimiteds()
			task.wait(UPDATE_INTERVAL)
		end
	end)
end

function CashierServer._updateLimiteds(self: CashierServer): ()
	local success, result = pcall(function()
		return self._limitedsDataStore:GetAsync(DATA_STORE_KEY)
	end)

	if not success then
		warn("Failed to get limiteds", result)
		return
	end

	local current: { Limited } = result or {}
	local previous = self._limiteds or {}

	-- Remove expired limiteds
	local now = os.time()
	current = Sift.Array.filter(current, function(limited: Limited)
		return not limited.expiration or limited.expiration > now
	end)

	self._limiteds = current

	-- Diff: find limiteds that changed or were added/removed
	for _, limited in current do
		local previousLimited = Sift.Array.findWhere(previous, function(prev: Limited)
			return prev.name == limited.name
		end)

		if not previousLimited then
			self._networker:fireAll("_onLimitedChanged", limited)
		else
			local prev = previous[previousLimited]
			if prev.stockLeft ~= limited.stockLeft or prev.expiration ~= limited.expiration then
				self._networker:fireAll("_onLimitedChanged", limited)
			end
		end
	end

	-- Notify removals (was in previous but not in current)
	for _, prev in previous do
		local stillExists = Sift.Array.findWhere(current, function(limited: Limited)
			return limited.name == prev.name
		end)

		if not stillExists then
			self._networker:fireAll("_onLimitedRemoved", prev.name)
		end
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
					end
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

	DataService:sendGlobalMessage("_gift", userId, giftData)

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
	local hasItem = recipientItems and Sift.Set.has(recipientItems, itemName)
		or recipientProfile
			and Sift.Array.findWhere(recipientProfile.Data["_gifts"], function(giftData)
				return giftData.item == itemName
			end) ~= nil
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

--[=[
	@method getAllLimiteds
	@within CashierServer
	@return { Limited }

	Returns an array with all currently available limited items.

	```lua
	local Cashier = require(path.to.Cashier).server

	for _, limited in Cashier:getAllLimiteds() do
		print(limited.name, limited.stockLeft)
	end
	```
]=]
function CashierServer.getAllLimiteds(self: CashierServer): { Limited }
	return self._limiteds
end

--[=[
	@method getLimitedByName
	@within CashierServer
	@param name string
	@return Limited?

	Retrieves a limited item by its name. Returns `nil` if no limited with the given name exists.

	```lua
	local Cashier = require(path.to.Cashier).server

	local limited = Cashier:getLimitedByName("Exclusive Sword")
	if limited then
		print(limited.stockLeft)
	end
	```
]=]
function CashierServer.getLimitedByName(self: CashierServer, name: string): Limited?
	local index = Sift.Array.findWhere(self._limiteds, function(limited: Limited)
		return limited.name == name
	end)

	return self._limiteds[index]
end

--[=[
	@method getLimitedById
	@within CashierServer
	@param id number
	@return Limited?

	Retrieves a limited item by its developer product id. Returns `nil` if no limited with the given id exists.

	```lua
	local Cashier = require(path.to.Cashier).server

	local limited = Cashier:getLimitedById(123456)
	if limited then
		print(limited.name, limited.stockLeft)
	end
	```
]=]
function CashierServer.getLimitedById(self: CashierServer, id: number): Limited?
	local index = Sift.Array.findWhere(self._limiteds, function(limited: Limited)
		return limited.id == id
	end)

	return self._limiteds[index]
end

--[=[
	@method addLimited
	@within CashierServer
	@param limited Limited

	Registers a new limited item. Writes it to the DataStore and notifies all connected clients.

	```lua
	local Cashier = require(path.to.Cashier).server

	Cashier:addLimited({
		name = "Exclusive Sword",
		id = 123456,
		initialStock = 100,
		stockLeft = 100,
		onePerPlayer = true,
		expiration = os.time() + 86400,
	})
	```
]=]
function CashierServer.addLimited(self: CashierServer, limited: Limited): ()
	if Sift.Array.findWhere(self._limiteds, function(info: Limited)
		return info.name == limited.name
	end) ~= nil then
		return
	end

	local success, err = pcall(function()
		self._limitedsDataStore:UpdateAsync(DATA_STORE_KEY, function(data)
			data = data or {}
			table.insert(data, limited)
			return data
		end)
	end)

	if not success then
		warn("Failed to add limited", err)
		return
	end

	self:_updateLimiteds()
end

--[=[
	@method addStockToLimited
	@within CashierServer
	@param limitedName string
	@param amount number

	Adds stock to an existing limited item. Increments both `stockLeft` and `initialStock`.

	```lua
	local Cashier = require(path.to.Cashier).server

	Cashier:addStockToLimited("Exclusive Sword", 50)
	```
]=]
function CashierServer.addStockToLimited(self: CashierServer, limitedName: string, amount: number): ()
	local success, err = pcall(function()
		self._limitedsDataStore:UpdateAsync(DATA_STORE_KEY, function(data)
			if not data then
				return nil
			end

			for _, limited in data do
				if limited.name == limitedName then
					limited.stockLeft += amount
					limited.initialStock += amount
					break
				end
			end

			return data
		end)
	end)

	if not success then
		warn("Failed to add stock to limited", err)
		return
	end

	self:_updateLimiteds()
end

--[=[
	@method addTimeToLimited
	@within CashierServer
	@param limitedName string
	@param amount number

	Extends the expiration of a limited item by `amount` seconds. If the limited has no expiration set, it starts from the current time.

	```lua
	local Cashier = require(path.to.Cashier).server

	-- Extend by 1 hour
	Cashier:addTimeToLimited("Exclusive Sword", 3600)
	```
]=]
function CashierServer.addTimeToLimited(self: CashierServer, limitedName: string, amount: number): ()
	local success, err = pcall(function()
		self._limitedsDataStore:UpdateAsync(DATA_STORE_KEY, function(data)
			if not data then
				return nil
			end

			for _, limited in data do
				if limited.name == limitedName then
					limited.expiration = (limited.expiration or os.time()) + amount
					break
				end
			end

			return data
		end)
	end)

	if not success then
		warn("Failed to add time to limited", err)
		return
	end

	self:_updateLimiteds()
end

--[=[
	@method removeLimited
	@within CashierServer
	@param limitedName string

	Removes a limited item from the DataStore and notifies all connected clients of the removal.

	```lua
	local Cashier = require(path.to.Cashier).server

	Cashier:removeLimited("Exclusive Sword")
	```
]=]
function CashierServer.removeLimited(self: CashierServer, limitedName: string): ()
	if Sift.Array.findWhere(self._limiteds, function(info: Limited)
		return info.name == limitedName
	end) == nil then
		return
	end

	local success, err = pcall(function()
		self._limitedsDataStore:UpdateAsync(DATA_STORE_KEY, function(data)
			if not data then
				return nil
			end

			local index = Sift.Array.findWhere(data, function(limited)
				return limited.name == limitedName
			end)

			if index then
				table.remove(data, index)
			end

			return data
		end)
	end)

	if not success then
		warn("Failed to remove limited", err)
		return
	end

	self:_updateLimiteds()
end

--[=[
	@method purchaseLimited
	@within CashierServer
	@param player Player
	@param limitedName string

	Validates and prompts the player to purchase a limited item. Checks that the limited exists,
	has stock remaining, is not expired, and respects the one-per-player constraint.

	```lua
	local Cashier = require(path.to.Cashier).server

	local success = Cashier:purchaseLimited(player, "Exclusive Sword")
	if not success then
		warn("Could not prompt limited purchase")
	end
	```
]=]
function CashierServer.purchaseLimited(self: CashierServer, player: Player, limitedName: string): ()
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

	if limited.onePerPlayer and self:hasLimited(player, limitedName) then
		return
	end

	MarketplaceService:PromptProductPurchase(player, limited.id)

	self._networker:fire(player, "_purchaseStarted")
end

--[=[
	@method hasLimited
	@within CashierServer
	@param player Player
	@param limitedName string
	@return boolean

	Checks if the player owns the given limited item.

	```lua
	local Cashier = require(path.to.Cashier).server

	if Cashier:hasLimited(player, "Exclusive Sword") then
		print("Player already owns this limited!")
	end
	```
]=]
function CashierServer.hasLimited(self: CashierServer, player: Player, limitedName: string): boolean
	if not self:getLimitedByName(limitedName) then
		warn(`No limited with name "{limitedName}"`)
		return false
	end

	local playerLimiteds = DataService:get(player, "_limiteds")
	if not playerLimiteds then
		return false
	end

	return Sift.Set.has(playerLimiteds, limitedName)
end

function CashierServer._processLimitedPurchase(self: CashierServer, player: Player, limited: Limited): ()
	-- Give the limited to the player's data
	DataService:update(player, "_limiteds", function(playerLimiteds)
		playerLimiteds = playerLimiteds or {}
		return Sift.Set.add(playerLimiteds, limited.name)
	end)

	-- Decrement stock (soft cap, can go below 0 in race conditions)
	pcall(function()
		self._limitedsDataStore:UpdateAsync(DATA_STORE_KEY, function(data)
			if not data then
				return nil
			end

			for _, entry in data do
				if entry.name == limited.name then
					entry.stockLeft -= 1
					break
				end
			end

			return data
		end)
	end)

	-- Call the limited's callback
	local callback = self._limitedsCallback[limited.name]
	if callback then
		callback(player)
	end

	self:_updateLimiteds()
end

type CashierServer = typeof(CashierServer) & {
	_items: { Item },
	_itemsCallback: { [string]: (player: Player, ...any?) -> boolean },
	_itemsPredicate: { [string]: (player: Player, ...any) -> boolean },
	_limiteds: { Limited },
	_limitedsCallback: { [string]: (player: Player) -> boolean },
	_limitedsDataStore: DataStore,
	_networker: Networker.Server,
	_pendingParams: { [Player]: { [string]: { any } } },
	_playerData: ServicePlayerData.ServicePlayerData<{
		gifting: number?,
	}>,
	purchaseCompleted: Signal.Signal<PurchaseData>,
}

return CashierServer :: CashierServer
