--------------------------------------------------
-- LaunchServer  (Script)
-- Location: ServerScriptService.LaunchServer
--
-- Mirrors CoreServer/TrailServer exactly, but for launch
-- controls. Must also be unlocked IN ORDER -- Basic Launch
-- first, then Hop Launch, and so on. No skipping ahead by
-- saving cash.
--------------------------------------------------

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local modules = ReplicatedStorage:WaitForChild("Modules")
local LaunchConfig = require(modules:WaitForChild("LaunchConfig"))

local PlayerDataService = require(
	ServerScriptService.Modules:WaitForChild("PlayerDataService")
)

local remotes = ReplicatedStorage:WaitForChild("Remotes")
local buyLaunchControl = remotes:WaitForChild("BuyLaunchControl")
local equipLaunchControl = remotes:WaitForChild("EquipLaunchControl")

--------------------------------------------------
-- SYNC PAYLOAD TO CLIENT
--------------------------------------------------

local function syncPlayer(player, extra)

	local payload = {
		OwnedLaunchControls = PlayerDataService.GetOwnedLaunchControls(player),
		EquippedLaunchControl = PlayerDataService.GetEquippedLaunchControl(player),
	}

	if extra then
		for key, value in pairs(extra) do
			payload[key] = value
		end
	end

	buyLaunchControl:FireClient(player, payload)
end

--------------------------------------------------
-- INITIAL SYNC
--------------------------------------------------
-- PlayerDataService.Setup(player) is called by CoreServer.lua's
-- PlayerAdded handler -- this script only needs to push the
-- launch-control-specific state once that's ready.
--------------------------------------------------

Players.PlayerAdded:Connect(function(player)

	local profile = PlayerDataService.GetProfile(player)
	local attempts = 0

	while not profile and attempts < 50 do
		task.wait(0.1)
		profile = PlayerDataService.GetProfile(player)
		attempts += 1
	end

	syncPlayer(player)
end)

--------------------------------------------------
-- BUY LAUNCH CONTROL
--------------------------------------------------

buyLaunchControl.OnServerEvent:Connect(function(player, launchId)

	local launch = LaunchConfig[launchId]

	if not launch then
		return
	end

	if launch.Exclusive then
		-- Bundle-only launch control -- never buyable through this
		-- remote. ShopServer grants it directly via
		-- PlayerDataService.GrantLaunchControl after a real Robux
		-- purchase, bypassing this path entirely.
		return
	end

	if PlayerDataService.IsLaunchControlOwned(player, launchId) then
		return
	end

	local prerequisite = PlayerDataService.GetLaunchPrerequisite(launchId)

	if prerequisite and not PlayerDataService.IsLaunchControlOwned(player, prerequisite) then

		syncPlayer(player, {
			Error = "locked",
			LaunchId = launchId,
		})

		return
	end

	local price = tonumber(launch.Price) or 0

	if price > 0 then

		local success = PlayerDataService.TrySpendCash(player, price)

		if not success then

			syncPlayer(player, {
				Error = "cash",
				LaunchId = launchId,
			})

			return
		end
	end

	PlayerDataService.GrantLaunchControl(player, launchId)
	PlayerDataService.SetEquippedLaunchControl(player, launchId)

	syncPlayer(player, {
		Purchased = launchId,
	})
end)

--------------------------------------------------
-- EQUIP LAUNCH CONTROL
--------------------------------------------------

equipLaunchControl.OnServerEvent:Connect(function(player, launchId)

	if not LaunchConfig[launchId] then
		return
	end

	if not PlayerDataService.IsLaunchControlOwned(player, launchId) then
		return
	end

	PlayerDataService.SetEquippedLaunchControl(player, launchId)

	syncPlayer(player)
end)