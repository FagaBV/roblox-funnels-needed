--------------------------------------------------
-- PlaytimeRewardServer  (Script)
-- Location: ServerScriptService.PlaytimeRewardServer
--
-- SESSION-based, not persisted -- both a player's elapsed
-- playtime and which milestones they've claimed reset to
-- 0/empty every time they join. Matches "Leaving Resets Gifts!"
-- from the reference design. If you'd rather this survive a
-- disconnect/rejoin instead, that needs DataStore-backed
-- tracking in PlayerDataService -- a different design, say so
-- and I'll redo it that way.
--------------------------------------------------

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local modules = ReplicatedStorage:WaitForChild("Modules")
local PlaytimeRewardConfig = require(modules:WaitForChild("PlaytimeRewardConfig"))
local PetConfig = require(modules:WaitForChild("PetConfig"))
local PotionConfig = require(modules:WaitForChild("PotionConfig"))

local PlayerDataService = require(
	ServerScriptService.Modules:WaitForChild("PlayerDataService")
)
local RateLimiter = require(
	ServerScriptService.Modules:WaitForChild("RateLimiter")
)

--------------------------------------------------
-- REMOTES -- self-creating, same pattern as TrailServer/ShopServer.
--------------------------------------------------

local remotes = ReplicatedStorage:WaitForChild("Remotes")

local function ensureRemote(name)
	local existing = remotes:FindFirstChild(name)
	if existing then
		return existing
	end
	local remote = Instance.new("RemoteEvent")
	remote.Name = name
	remote.Parent = remotes
	return remote
end

local claimPlaytimeReward = ensureRemote("ClaimPlaytimeReward")
local playtimeRewardSync = ensureRemote("PlaytimeRewardSync")
local potionSync = ensureRemote("PotionSync") -- owned by PotionServer.lua -- fired from here too on a Potion reward, so PotionHUDClient/ShopClient update immediately instead of waiting for PotionServer's next periodic tick

local CLAIM_MIN_INTERVAL = 0.3

local milestonesById = {}
for _, milestone in ipairs(PlaytimeRewardConfig.Milestones) do
	milestonesById[milestone.Id] = milestone
end

local POTION_BUFF_TYPES = { "FlightMult", "CashMult", "EnergyMult" }

local function syncPotionHUD(player)
	local activeBuffs = {}
	for _, buffType in ipairs(POTION_BUFF_TYPES) do
		local remaining = PlayerDataService.GetBuffRemaining(player, buffType)
		if remaining > 0 then
			activeBuffs[buffType] = remaining
		end
	end
	potionSync:FireClient(player, {
		Potions = PlayerDataService.GetPotions(player),
		ActiveBuffs = activeBuffs,
	})
end

--------------------------------------------------
-- SESSION STATE (in-memory only -- see header note)
--------------------------------------------------

local claimedByPlayer = {} -- [player] = { [milestoneId] = true }

local function syncPlayer(player)
	playtimeRewardSync:FireClient(player, {
		ClaimedIds = claimedByPlayer[player] or {},
	})
end

--------------------------------------------------
-- PLAYTIME TICKING
--------------------------------------------------

Players.PlayerAdded:Connect(function(player)
	claimedByPlayer[player] = {}
	player:SetAttribute("SessionPlaytime", 0)
	syncPlayer(player)
end)

Players.PlayerRemoving:Connect(function(player)
	claimedByPlayer[player] = nil
end)

task.spawn(function()
	while true do
		task.wait(1)
		for _, player in ipairs(Players:GetPlayers()) do
			player:SetAttribute("SessionPlaytime", (player:GetAttribute("SessionPlaytime") or 0) + 1)
		end
	end
end)

--------------------------------------------------
-- GRANT A MILESTONE'S REWARD
--------------------------------------------------

local function grantReward(player, milestone)

	if milestone.RewardType == "Cash" then

		local amount = tonumber(milestone.Amount) or 0
		if amount > 0 then
			PlayerDataService.AddCash(player, amount)
			local profile = PlayerDataService.GetProfile(player)
			local newTotal = profile and profile.leaderstats and profile.leaderstats.Cash and profile.leaderstats.Cash.Value
			print("[PlaytimeRewardServer] Granted", amount, "Cash to", player.Name, "-- new total:", newTotal)
		end

	elseif milestone.RewardType == "Energy" then

		local amount = tonumber(milestone.Amount) or 0
		if amount > 0 then
			PlayerDataService.AddEnergy(player, amount)
			print("[PlaytimeRewardServer] Granted", amount, "Energy to", player.Name)
		end

	elseif milestone.RewardType == "Pet" then

		if milestone.PetId and PetConfig[milestone.PetId] then
			PlayerDataService.GrantPet(player, milestone.PetId)
			-- Only fills an empty slot -- never bumps a pet the
			-- player already chose to equip, same rule EggServer
			-- follows on a fresh pull.
			PlayerDataService.AutoEquipIfRoom(player, milestone.PetId)
			print("[PlaytimeRewardServer] Granted Pet", milestone.PetId, "to", player.Name)
		else
			warn("[PlaytimeRewardServer] Milestone at", milestone.Time, "references an unknown PetId:", milestone.PetId)
		end

	elseif milestone.RewardType == "Potion" then

		if milestone.PotionId and PotionConfig[milestone.PotionId] then
			PlayerDataService.AddPotion(player, milestone.PotionId, milestone.Amount or 1)
			syncPotionHUD(player)
			print("[PlaytimeRewardServer] Granted Potion", milestone.PotionId, "to", player.Name)
		else
			warn("[PlaytimeRewardServer] Milestone at", milestone.Time, "references an unknown PotionId:", milestone.PotionId)
		end

	else
		warn("[PlaytimeRewardServer] Unknown RewardType:", tostring(milestone.RewardType))
	end
end

--------------------------------------------------
-- CLAIM
--------------------------------------------------

print("[PlaytimeRewardServer] Script loaded fully, connecting claim handler now.")

claimPlaytimeReward.OnServerEvent:Connect(function(player, milestoneId)

	print("[PlaytimeRewardServer] Received claim request from", player.Name, "for Id =", milestoneId)

	if not RateLimiter.Allow("ClaimPlaytimeReward", player, CLAIM_MIN_INTERVAL) then
		warn("[PlaytimeRewardServer] Rejected claim from", player.Name, "-- rate limited.")
		return
	end

	local claimed = claimedByPlayer[player]
	if not claimed then
		warn("[PlaytimeRewardServer] Rejected claim from", player.Name, "-- no session state (joined very recently?).")
		return
	end

	if claimed[milestoneId] then
		warn("[PlaytimeRewardServer] Rejected claim from", player.Name, "-- already claimed", milestoneId, "this session.")
		return
	end

	local milestone = milestonesById[milestoneId]
	if not milestone then
		warn("[PlaytimeRewardServer] Rejected claim from", player.Name, "-- no milestone with Id =", milestoneId, "in PlaytimeRewardConfig.")
		return
	end

	local sessionPlaytime = player:GetAttribute("SessionPlaytime") or 0
	if sessionPlaytime < milestone.Time then
		warn("[PlaytimeRewardServer] Rejected claim from", player.Name, "-- not unlocked yet (", sessionPlaytime, "/", milestone.Time, "s).")
		return -- not actually unlocked yet -- the client-side timer is informational only
	end

	if not PlayerDataService.GetProfile(player) then
		warn("[PlaytimeRewardServer] Rejected claim from", player.Name, "-- profile not loaded yet.")
		return
	end

	grantReward(player, milestone)

	claimed[milestoneId] = true
	syncPlayer(player)
end)