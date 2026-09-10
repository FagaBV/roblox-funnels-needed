--------------------------------------------------
-- TrailServer  (Script)
-- Location: ServerScriptService.TrailServer
--
-- Mirrors CoreServer exactly, but for trails. Trails must
-- also be unlocked IN ORDER -- Blue Spark first, then Comet
-- Tail, and so on. No skipping ahead by saving cash.
--------------------------------------------------

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local modules = ReplicatedStorage:WaitForChild("Modules")
local TrailConfig = require(modules:WaitForChild("TrailConfig"))

local PlayerDataService = require(
	ServerScriptService.Modules:WaitForChild("PlayerDataService")
)

local remotes = ReplicatedStorage:WaitForChild("Remotes")
local buyTrail = remotes:WaitForChild("BuyTrail")
local equipTrail = remotes:WaitForChild("EquipTrail")

-- Lets a client ask for a fresh OwnedTrails/EquippedTrail sync on
-- demand, instead of relying solely on the one-shot PlayerAdded
-- push below. That push can race a LocalScript's own startup --
-- if the client's buyTrail.OnClientEvent listener isn't connected
-- yet the instant this fires, it's gone for good, leaving the
-- client thinking almost nothing is owned even though the real
-- profile is fine. Created here defensively so it works even if
-- you haven't added it in Studio yet.
local requestTrailSync = remotes:FindFirstChild("RequestTrailSync")
if not requestTrailSync then
	requestTrailSync = Instance.new("RemoteEvent")
	requestTrailSync.Name = "RequestTrailSync"
	requestTrailSync.Parent = remotes
end

--------------------------------------------------
-- SYNC PAYLOAD TO CLIENT
--------------------------------------------------

local function syncPlayer(player, extra)

	local payload = {
		OwnedTrails = PlayerDataService.GetOwnedTrails(player),
		EquippedTrail = PlayerDataService.GetEquippedTrail(player),
	}

	if extra then
		for key, value in pairs(extra) do
			payload[key] = value
		end
	end

	buyTrail:FireClient(player, payload)
end

--------------------------------------------------
-- INITIAL SYNC
--------------------------------------------------
-- PlayerDataService.Setup(player) is called by CoreServer.lua's
-- PlayerAdded handler -- this script only needs to push the
-- trail-specific state to the client once that's ready.
--------------------------------------------------

Players.PlayerAdded:Connect(function(player)

	-- Wait a moment for CoreServer's PlayerAdded (which calls
	-- PlayerDataService.Setup) to run first. Order between two
	-- PlayerAdded handlers in different scripts isn't guaranteed,
	-- so poll briefly instead of assuming.
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
-- BUY TRAIL
--------------------------------------------------

buyTrail.OnServerEvent:Connect(function(player, trailId)

	local trail = TrailConfig[trailId]

	if not trail then
		return
	end

	if trail.Exclusive then
		-- Bundle-only trail -- never buyable through this remote.
		-- ShopServer grants it directly via PlayerDataService.GrantTrail
		-- after a real Robux purchase, bypassing this path entirely.
		return
	end

	if PlayerDataService.IsTrailOwned(player, trailId) then
		return
	end

	local prerequisite = PlayerDataService.GetTrailPrerequisite(trailId)

	if prerequisite and not PlayerDataService.IsTrailOwned(player, prerequisite) then

		syncPlayer(player, {
			Error = "locked",
			TrailId = trailId,
		})

		return
	end

	local price = tonumber(trail.Price) or 0

	if price > 0 then

		local success = PlayerDataService.TrySpendCash(player, price)

		if not success then

			syncPlayer(player, {
				Error = "cash",
				TrailId = trailId,
			})

			return
		end
	end

	PlayerDataService.GrantTrail(player, trailId)
	PlayerDataService.SetEquippedTrail(player, trailId)

	syncPlayer(player, {
		Purchased = trailId,
	})
end)

--------------------------------------------------
-- EQUIP TRAIL
--------------------------------------------------

equipTrail.OnServerEvent:Connect(function(player, trailId)

	if not TrailConfig[trailId] then
		return
	end

	if not PlayerDataService.IsTrailOwned(player, trailId) then
		return
	end

	PlayerDataService.SetEquippedTrail(player, trailId)

	syncPlayer(player)
end)

--------------------------------------------------
-- ON-DEMAND RESYNC
-- A client fires this once it's actually ready to receive the
-- data, instead of the server having to guess when that is.
--------------------------------------------------

requestTrailSync.OnServerEvent:Connect(function(player)
	syncPlayer(player)
end)