local DataStoreService = game:GetService("DataStoreService")
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

if not RunService:IsServer() then
	return {} :: CashierServer
end

local ProfileStore = require(ServerScriptService.ServerPackages.ProfileStore)
local Networker = require(ReplicatedStorage.Packages.Networker)
local Sift = require(ReplicatedStorage.Packages.Sift)
local Signal = require(ReplicatedStorage.Packages.Signal)

local PROFILE_STORE_INDEX = "Cashier"
local TEMPLATE = {
	items = {} :: { [string]: true },
	unsent = {} :: { [string]: number },
}

local purchaseHistoryStore = DataStoreService:GetDataStore("PurchaseHistory")

--[=[
	@type ItemType "DevProduct" | "Gamepass" | "Semipass"
	@within CashierServer

	Determines the type of an item.
]=]
type ItemType = "DevProduct" | "Gamepass" | "Semipass"

--[=[
	@interface Item
	@within CashierServer
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
	@interface ItemData
	@within CashierServer
	.name string -- The unique name of the item
	.type ItemType -- The type of the item ("DevProduct", "Gamepass", or "Semipass")
	.id number -- The Roblox GamePass ID or Developer Product ID
	.giftId number? -- The Developer Product ID used for gifting this item
	.callback (Player, ...any?) -> boolean -- Callback executed on the server when granting the item to a player
	.predicate ((Player, ...any?) -> boolean)? -- Optional validator function to check if a player is eligible to purchase the item

	Configuration data for an item registered with Cashier.

	```lua
	local items = {
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
			name = "Starter Pack",
			type = "Semipass",
			id = 789012,
			giftId = 210987,
			callback = function(player: Player)
				DataService:update(player, "cash", function(value)
					return value + 5000
				end)
				return true
			end,
		},
		{
			name = "Upgrade Unit",
			type = "DevProduct",
			id = 345678,
			predicate = function(player: Player, unitId: string)
				-- Validate that the unit exists and can be upgraded
				return unitId ~= nil and UnitService:canUpgrade(player, unitId)
			end,
			callback = function(player: Player, unitId: string)
				UnitService:upgrade(player, unitId)
				return true
			end,
		},
	}
	```
	
	:::warning
	If `type` is `"Gamepass"`, `id` must be a valid Roblox GamePass ID. If `type` is `"DevProduct"` or `"Semipass"`, `id` must be a Developer Product ID.
	:::
]=]
type ItemData = Item & {
	callback: (Player, ...any?) -> boolean,
	predicate: ((Player, ...any?) -> boolean)?,
}

--[=[
	@interface GiftData
	@within CashierServer
	.item string -- The name of the gifted item
	.from number -- The UserId of the player who sent the gift
]=]
type GiftData = {
	item: string,
	from: number,
}

--[=[
	@interface PurchaseData
	@within CashierServer
	.player Player -- The player who made the purchase
	.item string -- The name of the purchased item
	.robuxSpent number -- The amount of Robux spent on the purchase
	.recipientId number? -- The recipient UserId if the purchase was a gift
]=]
type PurchaseData = {
	player: Player,
	item: string,
	robuxSpent: number,
	recipientId: number?,
}

--[=[
	@interface InitOptions
	@within CashierServer
	.itemsData { ItemData } -- An array of all item configurations to register

	Options for initializing the server-side of Cashier.
]=]
type InitOptions = {
	itemsData: { ItemData },
}

--[=[
	@class CashierServer
	@server
	
	The server-side singleton for Cashier. Handles item registration, purchase validation, receipt processing, and cross-server gifting.
]=]
local CashierServer = {
	_giftingCache = {} :: { [Player]: number },
	_items = {} :: { Item },
	_itemsCallback = {} :: { [string]: (Player, ...any?) -> boolean },
	_itemsPredicate = {} :: { [string]: (Player, ...any?) -> boolean },
	_pendingParams = {} :: { [Player]: { [string]: { any } } },
	_profiles = {} :: { [Player]: ProfileStore.Profile<typeof(TEMPLATE)> },
	--[=[
		@prop purchaseCompleted Signal<PurchaseData>
		@within CashierServer

		A signal that fires when a player completes a purchase, providing the `PurchaseData`.
	]=]
	purchaseCompleted = Signal.new() :: Signal.Signal<PurchaseData>,
}

--[=[
	@method init
	@within CashierServer
	@param options InitOptions -- Options containing item configurations
	
	Initializes CashierServer, sets up ProfileStore session handling, registers network endpoints, and connects MarketplaceService purchase events.

	```lua
	local Cashier = require(path.to.Cashier).server
	local items = require(path.to.items)

	Cashier:init({
		itemsData = items,
	})
	```
]=]
function CashierServer.init(self: CashierServer, options: InitOptions): ()
	assert(RunService:IsServer(), "Cashier's server-side can only be used by the server.")
	assert(self._networker == nil, "Cashier's server-side has already been initialized.")

	self._items = Sift.Array.map(options.itemsData, function(itemData)
		return Sift.Dictionary.removeKeys(itemData, "callback", "predicate")
	end)

	for _, itemData in options.itemsData do
		self._itemsCallback[itemData.name] = itemData.callback
		self._itemsPredicate[itemData.name] = itemData.predicate
	end

	self._networker = Networker.server.new("Cashier", self, {
		self._purchase,
		self._gift,
		self.getUnsentItems,
	})
	self._playerStore = ProfileStore.New(PROFILE_STORE_INDEX, TEMPLATE)

	for _, player in Players:GetPlayers() do
		task.spawn(self._playerAdded, self, player)
	end

	Players.PlayerAdded:Connect(function(player)
		self:_playerAdded(player)
	end)

	Players.PlayerRemoving:Connect(function(player)
		self:_playerRemoving(player)
	end)

	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player, gamepassId, wasPurchased)
		if not wasPurchased then
			return
		end

		local success, ownsGamepass =
			pcall(MarketplaceService.UserOwnsGamePassAsync, MarketplaceService, player.UserId, gamepassId)
		if not success or not ownsGamepass then
			return
		end

		local item = self:getItemById(gamepassId)
		if not item then
			return
		end

		local didGranted = self:give(player, item.name)
		if not didGranted then
			return
		end

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
					local didHandlerGrantPurchase = self:give(player, item.name)
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

function CashierServer._playerAdded(self: CashierServer, player: Player): ()
	local profile = self._playerStore:StartSessionAsync(tostring(player.UserId))

	if not profile then
		player:Kick("Profile load fail - Please rejoin")
		return
	end

	profile:AddUserId(player.UserId)
	profile:Reconcile()
	profile.OnSessionEnd:Connect(function()
		self._profiles[player] = nil
		player:Kick("Profile session end - Please rejoin")
	end)

	if not player:IsDescendantOf(Players) then
		profile:EndSession()
		return
	end

	self._profiles[player] = profile

	for _, item in self._items do
		if item.type ~= "Gamepass" then
			continue
		end

		local success, ownsGamepass = pcall(function()
			return MarketplaceService:UserOwnsGamePassAsync(player.UserId, item.id)
		end)

		if success and ownsGamepass and not self:has(player, item.name) then
			self:give(player, item.name)
		end
	end

	self._networker:set(player, "_items", self._items)
	self._networker:set(player, "_owned", profile.Data.items)

	profile:MessageHandler(function(giftData, processed: () -> ())
		self:give(player, giftData.item)
		self._networker:fire(player, "onGiftReceived", giftData)

		processed()
	end)
end

function CashierServer._playerRemoving(self: CashierServer, player: Player): ()
	local profile = self._profiles[player]
	if not profile then
		return
	end

	profile:EndSession()
	self._profiles[player] = nil
	self._pendingParams[player] = nil
	self._giftingCache[player] = nil
end

function CashierServer._processGift(self: CashierServer, player: Player, receiptInfo): ()
	local item = self:getItemById(receiptInfo.ProductId)
	if not item then
		return
	end

	local recipientId = self._giftingCache[player]
	self._giftingCache[player] = nil

	local success = false
	local recipient = Players:GetPlayerByUserId(recipientId)
	if recipient then
		local didGrantRecipient = self:give(recipient, item.name)
		if not didGrantRecipient then
			self._networker:fire(player, "_giftingFailed", item.name, recipientId)
		else
			self._networker:fire(recipient, "onGiftReceived", {
				item = item.name,
				from = player.UserId,
			})

			success = true
		end
	else
		success = self._playerStore:MessageAsync(
			tostring(recipientId),
			{
				item = item.name,
				from = player.UserId,
			} :: GiftData
		)
	end

	if not success then
		self:_addItemToUnsent(player, item.name)
		self._networker:fire(player, "_giftingFailed", item.name, recipientId)
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

function CashierServer._addItemToUnsent(self: CashierServer, player: Player, itemName: string): ()
	local profile = self._profiles[player]
	if not profile then
		return
	end

	profile.Data.unsent = Sift.Dictionary.update(profile.Data.unsent, itemName, function(amount)
		return amount + 1
	end, function()
		return 1
	end)
end

function CashierServer._purchase(self: CashierServer, player: Player, itemName: string, ...: any?): ()
	local item = self:getItemByName(itemName)
	if not item then
		return
	end

	if self:has(player, itemName) then
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

	self._networker:set(player, "_purchasing", true)
end

function CashierServer._gift(
	self: CashierServer,
	player: Player,
	recipientId: number,
	itemName: string
): (boolean, string?)
	if recipientId == player.UserId then
		return false, "You cannot gift yourself"
	end

	local item = self:getItemByName(itemName)
	if not item then
		return false, `No item found with name "{itemName}"`
	end

	if not item.giftId then
		return false, `You cannot gift this item`
	end

	local recipientProfile = self._playerStore:GetAsync(tostring(recipientId))
	if recipientProfile then
		local isOwned = Sift.Set.has(recipientProfile.Data.items, itemName)
		local hasPendingGift = recipientProfile.global_updates ~= nil
			and Sift.Array.findWhere(recipientProfile.global_updates, function(update)
					local giftData = update[2] :: GiftData?
					return giftData ~= nil and giftData.item == itemName
				end)
				~= nil

		if item.type ~= "DevProduct" and (isOwned or hasPendingGift) then
			return false, "User already owns this item"
		end
	end

	local profile = self._profiles[player]
	if not profile then
		player:Kick("Something went wrong - Please rejoin")
		return
	end

	self._giftingCache[player] = recipientId

	if profile.Data.unsent[itemName] then
		profile.Data.unsent = Sift.Dictionary.update(profile.Data.unsent, itemName, function(amount)
			return if amount - 1 > 0 then amount - 1 else nil
		end)

		task.spawn(self._processGift, self, player, {
			ProductId = item.id,
			CurrencySpent = self:getItemPrice(itemName),
		})

		return true
	end

	MarketplaceService:PromptProductPurchase(player, item.giftId)
	self._networker:set(player, "_purchasing", true)

	return true
end

--[=[
	@method getUnsentItems
	@within CashierServer
	@param player Player -- The player to get the unsent items of
	@return { [string]: number } -- A dictionary mapping item names to unsent gift counts
	
	Returns all unsent gifts stored in the player's profile that failed to deliver.

	```lua
	local Cashier = require(path.to.Cashier).server

	local unsentItems = Cashier:getUnsentItems(player)

	for itemName, amount in unsentItems do
		print(`{player.Name} has {amount} unsent {itemName}(s).`)
	end
	```
]=]
function CashierServer.getUnsentItems(self: CashierServer, player: Player): { [string]: number }
	local profile = self._profiles[player]
	if not profile then
		return {}
	end

	return profile.Data.unsent
end

--[=[
	@method getAllItems
	@within CashierServer
	@return { Item } -- An array containing all registered items

	Returns an array of all registered items.

	```lua
	local Cashier = require(path.to.Cashier).server

	local items = Cashier:getAllItems()

	for _, item in items do
		print(item.name, item.type)
	end
	```
]=]
function CashierServer.getAllItems(self: CashierServer): { Item }
	return self._items
end

--[=[
	@method getItemsOfType
	@within CashierServer
	@param itemType ItemType -- The type of items to retrieve ("DevProduct" | "Gamepass" | "Semipass")
	@return { Item } -- An array containing items of the specified type

	Retrieves all registered items of a specific type.

	```lua
	local Cashier = require(path.to.Cashier).server

	local gamepasses = Cashier:getItemsOfType("Gamepass")

	for _, item in gamepasses do
		print(item.name)
	end
	```
]=]
function CashierServer.getItemsOfType(self: CashierServer, itemType: ItemType): { Item }
	return Sift.Array.filter(self._items, function(item: Item)
		return item.type == itemType
	end)
end

--[=[ 
	@method getItemByName
	@within CashierServer
	@param itemName string -- The name of the item to retrieve
	@return Item? -- The item with the specified name, or nil if not found

	Retrieves a registered item by its name.

	```lua
	local Cashier = require(path.to.Cashier).server

	local item = Cashier:getItemByName("VIP")

	if item then
		print("Found item with ID:", item.id)
	end
	```
]=]
function CashierServer.getItemByName(self: CashierServer, itemName: string): Item?
	local index = Sift.Array.findWhere(self._items, function(item: Item)
		return item.name == itemName
	end)

	return index and self._items[index]
end

--[=[ 
	@method getItemById
	@within CashierServer
	@param itemId number -- The ID of the item to retrieve
	@return Item? -- The item with the specified ID, or nil if not found

	Retrieves a registered item by its ID.

	```lua
	local Cashier = require(path.to.Cashier).server

	local item = Cashier:getItemById(123456)

	if item then
		print("Found item:", item.name)
	end
	```

	:::info
	`itemId` can be a standard product/gamepass ID or a gift Developer Product ID.
	:::
]=]
function CashierServer.getItemById(self: CashierServer, itemId: number): Item?
	local index = Sift.Array.findWhere(self._items, function(item: Item)
		return item.id == itemId or item.giftId == itemId
	end)

	return index and self._items[index]
end

--[=[ 
	@method getItemPrice
	@within CashierServer
	@yields
	@param itemName string -- The name of the item to get the price of
	@return number -- The price of the item in Robux, or 0 if unavailable

	Retrieves the price of an item in Robux from MarketplaceService.

	```lua
	local Cashier = require(path.to.Cashier).server

	local price = Cashier:getItemPrice("VIP")

	print(`VIP costs {price} Robux`)
	```
]=]
function CashierServer.getItemPrice(self: CashierServer, itemName: string): number
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
	@within CashierServer
	@param itemId number -- The ID of the item to check
	@return boolean -- True if the item is a gift ID, false otherwise

	Checks if an item ID is a registered gift Developer Product ID.

	```lua
	local Cashier = require(path.to.Cashier).server

	local id = 123456

	print(Cashier:isGiftId(id))
	```
]=]
function CashierServer.isGiftId(self: CashierServer, itemId: number): boolean
	return Sift.Array.findWhere(self._items, function(item: Item)
		return item.giftId == itemId
	end) ~= nil
end

--[=[
	@method has
	@within CashierServer
	@param player Player -- The player to check
	@param itemName string -- The name of the item
	@return boolean -- True if the player owns the item, false otherwise

	Checks if a player owns the specified item.
	
	```lua
	local Cashier = require(path.to.Cashier).server

	if not Cashier:has(player, "VIP") then
		print("You need VIP access to enter this zone")
	end
	```
]=]
function CashierServer.has(self: CashierServer, player: Player, itemName: string): boolean
	local profile = self._profiles[player]
	if not profile then
		return false
	end

	return Sift.Set.has(profile.Data.items, itemName)
end

--[=[
	@method give
	@within CashierServer
	@param player Player -- The player to grant the item to
	@param itemName string -- The name of the item
	@return boolean -- True if the item was successfully given, false otherwise

	Gives an item to a player, updates their profile data and client ownership state, and executes the item's registered callback.
	
	```lua
	local Cashier = require(path.to.Cashier).server

	Cashier:give(player, "VIP")
	```
]=]
function CashierServer.give(self: CashierServer, player: Player, itemName: string): boolean
	local item = self:getItemByName(itemName)
	if not item then
		return false
	end

	if self:has(player, itemName) then
		return false
	end

	local profile = self._profiles[player]
	if not profile then
		return false
	end

	if item.type ~= "DevProduct" then
		profile.Data.items = Sift.Set.add(profile.Data.items, itemName)
		self._networker:set(player, "_owned", profile.Data.items)
	end

	local callback = self._itemsCallback[itemName]
	local params = self._pendingParams[player] and self._pendingParams[player][itemName]
	if params then
		self._pendingParams[player][itemName] = nil

		return callback(player, table.unpack(params))
	else
		return callback(player)
	end
end

export type CashierServer = typeof(CashierServer) & {
	_networker: Networker.Server,
	_playerStore: ProfileStore.ProfileStore<typeof(TEMPLATE)>,
}

return CashierServer :: CashierServer
