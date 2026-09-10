--------------------------------------------------
-- CoreServer  (Script)
-- Location: ServerScriptService.CoreServer
--
-- This is the piece that was missing -- CoreShopClient
-- fires BuyCore / EquipCore, but nothing was listening on
-- the server, so purchases never actually happened.
--
-- Cores must be unlocked IN ORDER: a core can only be
-- bought if the previous core (by CoreConfig.Order) is
-- already owned. There is no way to skip ahead by saving
-- cash for a later core.
--------------------------------------------------

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local modules = ReplicatedStorage:WaitForChild("Modules")
local CoreConfig = require(modules:WaitForChild("CoreConfig"))

local PlayerDataService = require(ServerScriptService.Modules:WaitForChild("PlayerDataService"))

local remotes = ReplicatedStorage:WaitForChild("Remotes")
local buyCore = remotes:WaitForChild("BuyCore")
local equipCore = remotes:WaitForChild("EquipCore")

--------------------------------------------------
-- SYNC PAYLOAD TO CLIENT
--------------------------------------------------

local function syncPlayer(player, extra)

	local payload = {
		OwnedCores = PlayerDataService.GetOwnedCores(player),
		EquippedCore = PlayerDataService.GetEquippedCore(player),
	}

	if extra then
		for key, value in pairs(extra) do
			payload[key] = value
		end
	end

	buyCore:FireClient(player, payload)
end

--------------------------------------------------
-- PLAYER JOIN / LEAVE
--------------------------------------------------

Players.PlayerAdded:Connect(function(player)

	PlayerDataService.Setup(player)

	syncPlayer(player)
end)

Players.PlayerRemoving:Connect(function(player)
	PlayerDataService.Teardown(player)
end)

--------------------------------------------------
-- BUY CORE
--------------------------------------------------

buyCore.OnServerEvent:Connect(function(player, coreId)

	local core = CoreConfig[coreId]

	if not core then
		return
	end

	--------------------------------------------------
	-- ALREADY OWNED -- ignore
	--------------------------------------------------

	if PlayerDataService.IsOwned(player, coreId) then
		return
	end

	--------------------------------------------------
	-- ORDER LOCK -- must own the previous core first
	--------------------------------------------------

	local prerequisite = PlayerDataService.GetPrerequisite(coreId)

	if prerequisite and not PlayerDataService.IsOwned(player, prerequisite) then

		syncPlayer(player, {
			Error = "locked",
			CoreId = coreId,
		})

		return
	end

	--------------------------------------------------
	-- CAN THEY AFFORD IT?
	--------------------------------------------------

	local price = tonumber(core.Price) or 0

	if price > 0 then

		local success = PlayerDataService.TrySpendCash(player, price)

		if not success then

			syncPlayer(player, {
				Error = "cash",
				CoreId = coreId,
			})

			return
		end
	end

	--------------------------------------------------
	-- GRANT + AUTO-EQUIP THE NEW CORE
	--------------------------------------------------

	PlayerDataService.GrantCore(player, coreId)
	PlayerDataService.SetEquipped(player, coreId)

	syncPlayer(player, {
		Purchased = coreId,
	})
end)

--------------------------------------------------
-- EQUIP CORE
--------------------------------------------------

equipCore.OnServerEvent:Connect(function(player, coreId)

	if not CoreConfig[coreId] then
		return
	end

	if not PlayerDataService.IsOwned(player, coreId) then
		return
	end

	PlayerDataService.SetEquipped(player, coreId)

	syncPlayer(player)
end)