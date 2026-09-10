--------------------------------------------------
-- PlayerDataService  (ModuleScript)
-- Location: ServerScriptService.Modules.PlayerDataService
--
-- Single source of truth for a player's Cash, Energy, owned
-- cores/trails/launch controls and their equipped item in each
-- category. Creates the leaderstats (this is what makes the
-- default Roblox leaderboard show Cash/Energy for every player)
-- and persists everything through DataStoreService.
--
-- Other server scripts (ChargeServer, CoreServer, TrailServer,
-- LaunchServer) require this module instead of keeping their
-- own tables, so there is only ever one copy of a player's state.
--------------------------------------------------

local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CoreConfig = require(ReplicatedStorage.Modules.CoreConfig)
local TrailConfig = require(ReplicatedStorage.Modules.TrailConfig)
local LaunchConfig = require(ReplicatedStorage.Modules.LaunchConfig)
local PetConfig = require(ReplicatedStorage.Modules.PetConfig)

local dataStore = DataStoreService:GetDataStore("CoreGame_ReleaseMode_2")
-- Same datastore key as before -- no version bump needed.
-- loadData() below backfills OwnedTrails/EquippedTrail,
-- OwnedLaunchControls/EquippedLaunchControl, and now
-- OwnedPets/EquippedPet with defaults for any existing save
-- that predates them, so nobody's Cash/Energy/cores/trails get
-- wiped by this update.

--------------------------------------------------
-- SORTED CORE / TRAIL / LAUNCH LISTS (by Order) -- used to
-- find the "first" item and to check unlock order.
--------------------------------------------------

local function buildSortedIds(config)
	local ids = {}
	for id, item in pairs(config) do
		-- Exclusive (playtime-reward-only) items never enter the
		-- normal buy-in-order chain -- they're granted directly,
		-- so including them here would either block the real
		-- catalog behind a Price=0 reward item, or (with their
		-- Order=-1) just be dead weight. Filtering them out here
		-- means GetPrerequisite/GetTrailPrerequisite/
		-- GetLaunchPrerequisite never see them at all.
		if not item.Exclusive then
			table.insert(ids, id)
		end
	end
	table.sort(ids, function(a, b)
		return config[a].Order < config[b].Order
	end)
	return ids
end

local sortedCoreIds = buildSortedIds(CoreConfig)
local sortedTrailIds = buildSortedIds(TrailConfig)
local sortedLaunchIds = buildSortedIds(LaunchConfig)

local FIRST_CORE_ID = sortedCoreIds[1]
-- Trails have no free starter item (Blue Spark costs 500, per
-- design) -- a new player simply owns none and has none equipped.
local FIRST_LAUNCH_ID = sortedLaunchIds[1]
-- Launch Controls DO have a free starter (Basuj  ic Launch costs 0,
-- like SparkCore) -- same auto-owned/auto-equipped pattern as cores.

local MAX_EQUIPPED_PETS = 3

-- New-player Energy boost -- session-only, 10 minutes from joining.
local STARTER_ENERGY_BOOST_DURATION = 10 * 60
local STARTER_ENERGY_BOOST_MULTIPLIER = 2

--------------------------------------------------
-- STATE
--------------------------------------------------

local PlayerDataService = {}
PlayerDataService.MAX_EQUIPPED_PETS = MAX_EQUIPPED_PETS

-- Fired (player) whenever that player's equipped-pets LIST changes
-- (order matters -- it maps to follow slots). PetFollowServer listens
-- to this to know when to rebuild someone's following pets.
PlayerDataService.PetsChanged = Instance.new("BindableEvent")

local profiles = {}
-- [player] = {
--   OwnedCores = {}, EquippedCore = "",
--   OwnedTrails = {}, EquippedTrail = "",
--   OwnedLaunchControls = {}, EquippedLaunchControl = "",
--   OwnedPets = {}, EquippedPets = { petId, petId, ... }, -- up to MAX_EQUIPPED_PETS, ordered
--   OverchargeLevel = 0,
--   leaderstats = Instance,
-- }

-- Active timed potion buffs -- session-only, NOT saved/persisted
-- (if the server restarts mid-buff, it's gone, same as any other
-- session state). [player] = { [buffType] = { Multiplier=..,
-- ExpiresAt=os.clock()+.. } }. Declared here (not down by the
-- other POTION functions) so Teardown below can clear it too --
-- Lua closures can only capture a local that's already in scope at
-- the point they're defined.
local activeBuffs = {}

--------------------------------------------------
-- INTERNAL: build default profile for a new player
--------------------------------------------------

local function newProfile()
	return {
		Cash = 0,
		Energy = 0,
		OwnedCores = { [FIRST_CORE_ID] = true },
		EquippedCore = FIRST_CORE_ID,
		OwnedTrails = {},
		EquippedTrail = "",
		OwnedLaunchControls = { [FIRST_LAUNCH_ID] = true },
		EquippedLaunchControl = FIRST_LAUNCH_ID,
		OwnedPets = {},
		EquippedPets = {},
		OwnedMaps = {}, -- unlocked with Travels, not Cash -- see TravelsServer/MapServer
		OverchargeLevel = 0,
		LastSpinTime = 0,
		Potions = {}, -- [potionId] = count
		PurchasedOfferIds = {}, -- [offerId] = true, across BOTH bundle and pet pools
		RedeemedCodes = {}, -- [code] = true, code is always the UPPERCASE trimmed form
	}
end

--------------------------------------------------
-- INTERNAL: leaderstats
--------------------------------------------------

local function buildLeaderstats(player, saved)

	local leaderstats = Instance.new("Folder")
	leaderstats.Name = "leaderstats"

	local cash = Instance.new("IntValue")
	cash.Name = "Cash"
	cash.Value = saved.Cash
	cash.Parent = leaderstats

	local energy = Instance.new("IntValue")
	energy.Name = "Energy"
	energy.Value = saved.Energy
	energy.Parent = leaderstats

	leaderstats.Parent = player

	return leaderstats
end

--------------------------------------------------
-- LOAD / SAVE
--------------------------------------------------

local function loadData(player)

	local saved

	local ok, result = pcall(function()
		return dataStore:GetAsync("Player_" .. player.UserId)
	end)

	if ok and result then
		saved = result
	else
		saved = newProfile()
	end

	-- Backfill in case new fields were added since this player
	-- last saved (e.g. new cores/trails/launch controls, or
	-- trails/launch controls not existing yet in their save at
	-- all -- this is what lets existing players keep their
	-- Cash/Energy/cores/trails after this update).
	saved.Cash = saved.Cash or 0
	saved.Energy = saved.Energy or 0
	saved.OwnedCores = saved.OwnedCores or { [FIRST_CORE_ID] = true }
	saved.OwnedCores[FIRST_CORE_ID] = true -- always unlocked
	saved.EquippedCore = saved.EquippedCore or FIRST_CORE_ID
	saved.OwnedTrails = saved.OwnedTrails or {}
	saved.EquippedTrail = saved.EquippedTrail or ""
	saved.OwnedLaunchControls = saved.OwnedLaunchControls or { [FIRST_LAUNCH_ID] = true }
	saved.OwnedLaunchControls[FIRST_LAUNCH_ID] = true -- always unlocked
	saved.EquippedLaunchControl = saved.EquippedLaunchControl or FIRST_LAUNCH_ID
	saved.OverchargeLevel = saved.OverchargeLevel or 0
	saved.OwnedPets = saved.OwnedPets or {}

	-- Migrate pre-stacking saves (OwnedPets[petId] = true) into
	-- counts (OwnedPets[petId] = 1) so nobody's existing pets vanish
	-- or get miscounted when this update lands.
	for petId, owned in pairs(saved.OwnedPets) do
		if owned == true then
			saved.OwnedPets[petId] = 1
		end
	end

	saved.EquippedPets = saved.EquippedPets or {}
	saved.LastSpinTime = saved.LastSpinTime or 0

	-- Migrate old single-EquippedPet saves (pre-multi-equip) into
	-- the new array so nobody's equipped pet silently vanishes.
	if saved.EquippedPet and saved.EquippedPet ~= "" and #saved.EquippedPets == 0 then
		table.insert(saved.EquippedPets, saved.EquippedPet)
	end
	saved.EquippedPet = nil

	saved.Potions = saved.Potions or {}
	saved.PurchasedOfferIds = saved.PurchasedOfferIds or {}
	saved.OwnedMaps = saved.OwnedMaps or {}
	saved.RedeemedCodes = saved.RedeemedCodes or {}

	return saved
end

local function saveData(player)

	local profile = profiles[player]

	if not profile then
		return
	end

	local payload = {
		Cash = profile.leaderstats.Cash.Value,
		Energy = profile.leaderstats.Energy.Value,
		OwnedCores = profile.OwnedCores,
		EquippedCore = profile.EquippedCore,
		OwnedTrails = profile.OwnedTrails,
		EquippedTrail = profile.EquippedTrail,
		OwnedLaunchControls = profile.OwnedLaunchControls,
		EquippedLaunchControl = profile.EquippedLaunchControl,
		OverchargeLevel = profile.OverchargeLevel,
		OwnedPets = profile.OwnedPets,
		EquippedPets = profile.EquippedPets,
		Potions = profile.Potions,
		PurchasedOfferIds = profile.PurchasedOfferIds,
		LastSpinTime = profile.LastSpinTime,
		OwnedMaps = profile.OwnedMaps,
		RedeemedCodes = profile.RedeemedCodes,
	}

	local ok, err = pcall(function()
		dataStore:SetAsync("Player_" .. player.UserId, payload)
	end)

	if not ok then
		warn("[PlayerDataService] Save failed for", player.Name, err)
	end
end

--------------------------------------------------
-- PUBLIC: called from PlayerAdded / PlayerRemoving
--------------------------------------------------

function PlayerDataService.Setup(player)

	local saved = loadData(player)
	local leaderstats = buildLeaderstats(player, saved)

	profiles[player] = {
		OwnedCores = saved.OwnedCores,
		EquippedCore = saved.EquippedCore,
		OwnedTrails = saved.OwnedTrails,
		EquippedTrail = saved.EquippedTrail,
		OwnedLaunchControls = saved.OwnedLaunchControls,
		EquippedLaunchControl = saved.EquippedLaunchControl,
		OverchargeLevel = saved.OverchargeLevel,
		OwnedPets = saved.OwnedPets,
		EquippedPets = saved.EquippedPets,
		Potions = saved.Potions,
		PurchasedOfferIds = saved.PurchasedOfferIds,
		LastSpinTime = saved.LastSpinTime,
		OwnedMaps = saved.OwnedMaps,
		RedeemedCodes = saved.RedeemedCodes,
		leaderstats = leaderstats,
	}

	player:SetAttribute("EquippedCore", saved.EquippedCore)
	player:SetAttribute("EquippedTrail", saved.EquippedTrail)
	player:SetAttribute("EquippedLaunchControl", saved.EquippedLaunchControl)
	player:SetAttribute("OverchargeLevel", saved.OverchargeLevel)
	-- Attributes can't hold arrays -- this is a comma-joined debug/
	-- leaderboard-friendly view only. petSync (real payload) is the
	-- actual source of truth the client UI uses.
	player:SetAttribute("EquippedPetsList", table.concat(saved.EquippedPets, ","))

	-- Start the session-only new-player 2x Energy boost.
	-- workspace:GetServerTimeNow() is replicated/synchronized with clients,
	-- so the HUD countdown uses the same clock as the server.
	player:SetAttribute(
		"EnergyBoostEndTime",
		workspace:GetServerTimeNow() + STARTER_ENERGY_BOOST_DURATION
	)
	player:SetAttribute("EnergyBoostMultiplier", STARTER_ENERGY_BOOST_MULTIPLIER)

	return profiles[player]
end

function PlayerDataService.Teardown(player)
	saveData(player)
	profiles[player] = nil
	activeBuffs[player] = nil
end

--------------------------------------------------
-- PUBLIC: accessors used by CoreServer / ChargeServer / TrailServer / LaunchServer
--------------------------------------------------

function PlayerDataService.GetProfile(player)
	return profiles[player]
end

function PlayerDataService.GetCash(player)
	local profile = profiles[player]
	return profile and profile.leaderstats.Cash.Value or 0
end

function PlayerDataService.AddCash(player, amount)
	local profile = profiles[player]
	if profile then
		profile.leaderstats.Cash.Value += amount
	end
end

function PlayerDataService.TrySpendCash(player, amount)
	local profile = profiles[player]
	if not profile then
		return false
	end
	if profile.leaderstats.Cash.Value < amount then
		return false
	end
	profile.leaderstats.Cash.Value -= amount
	return true
end

function PlayerDataService.AddEnergy(player, amount)
	local profile = profiles[player]
	if not profile then
		return
	end

	local finalAmount = amount

	-- Only Energy earned is doubled. Negative Energy changes are left alone.
	if amount > 0 then
		local boostEndTime = player:GetAttribute("EnergyBoostEndTime")
		if boostEndTime and workspace:GetServerTimeNow() < boostEndTime then
			finalAmount = amount * STARTER_ENERGY_BOOST_MULTIPLIER
		end
	end

	profile.leaderstats.Energy.Value += finalAmount
end

--------------------------------------------------
-- STARTER ENERGY BOOST
--------------------------------------------------

function PlayerDataService.GetStarterEnergyBoostRemaining(player)
	local endTime = player:GetAttribute("EnergyBoostEndTime")
	if not endTime then
		return 0
	end

	return math.max(0, endTime - workspace:GetServerTimeNow())
end

function PlayerDataService.GetStarterEnergyMultiplier(player)
	if PlayerDataService.GetStarterEnergyBoostRemaining(player) > 0 then
		return STARTER_ENERGY_BOOST_MULTIPLIER
	end

	return 1
end

--------------------------------------------------
-- CORES
--------------------------------------------------

function PlayerDataService.IsOwned(player, coreId)
	local profile = profiles[player]
	return profile ~= nil and profile.OwnedCores[coreId] == true
end

function PlayerDataService.GetOwnedCores(player)
	local profile = profiles[player]
	return profile and profile.OwnedCores or {}
end

function PlayerDataService.GetEquippedCore(player)
	local profile = profiles[player]
	return profile and profile.EquippedCore or FIRST_CORE_ID
end

-- Returns the core id that must already be owned before
-- `coreId` can be bought, or nil if `coreId` is the first core.
function PlayerDataService.GetPrerequisite(coreId)

	for index, id in ipairs(sortedCoreIds) do
		if id == coreId then
			if index == 1 then
				return nil
			end
			return sortedCoreIds[index - 1]
		end
	end

	return nil
end

function PlayerDataService.GrantCore(player, coreId)
	local profile = profiles[player]
	if profile then
		profile.OwnedCores[coreId] = true
	end
end

function PlayerDataService.SetEquipped(player, coreId)
	local profile = profiles[player]
	if profile then
		profile.EquippedCore = coreId
		player:SetAttribute("EquippedCore", coreId)
	end
end

function PlayerDataService.SortedCoreIds()
	return sortedCoreIds
end

--------------------------------------------------
-- TRAILS (same pattern as cores, separate ownership/equip state)
--------------------------------------------------

function PlayerDataService.IsTrailOwned(player, trailId)
	local profile = profiles[player]
	return profile ~= nil and profile.OwnedTrails[trailId] == true
end

function PlayerDataService.GetOwnedTrails(player)
	local profile = profiles[player]
	return profile and profile.OwnedTrails or {}
end

function PlayerDataService.GetEquippedTrail(player)
	local profile = profiles[player]
	return profile and profile.EquippedTrail or ""
end

-- Returns the trail id that must already be owned before
-- `trailId` can be bought, or nil if `trailId` is the first trail.
function PlayerDataService.GetTrailPrerequisite(trailId)

	for index, id in ipairs(sortedTrailIds) do
		if id == trailId then
			if index == 1 then
				return nil
			end
			return sortedTrailIds[index - 1]
		end
	end

	return nil
end

function PlayerDataService.GrantTrail(player, trailId)
	local profile = profiles[player]
	if profile then
		profile.OwnedTrails[trailId] = true
	end
end

function PlayerDataService.SetEquippedTrail(player, trailId)
	local profile = profiles[player]
	if profile then
		profile.EquippedTrail = trailId
		player:SetAttribute("EquippedTrail", trailId)
	end
end

function PlayerDataService.SortedTrailIds()
	return sortedTrailIds
end

--------------------------------------------------
-- LAUNCH CONTROLS (same pattern as cores/trails, separate ownership/equip state)
--------------------------------------------------

function PlayerDataService.IsLaunchControlOwned(player, launchId)
	local profile = profiles[player]
	return profile ~= nil and profile.OwnedLaunchControls[launchId] == true
end

function PlayerDataService.GetOwnedLaunchControls(player)
	local profile = profiles[player]
	return profile and profile.OwnedLaunchControls or {}
end

function PlayerDataService.GetEquippedLaunchControl(player)
	local profile = profiles[player]
	return profile and profile.EquippedLaunchControl or FIRST_LAUNCH_ID
end

-- Returns the launch control id that must already be owned
-- before `launchId` can be bought, or nil if `launchId` is the
-- first one.
function PlayerDataService.GetLaunchPrerequisite(launchId)

	for index, id in ipairs(sortedLaunchIds) do
		if id == launchId then
			if index == 1 then
				return nil
			end
			return sortedLaunchIds[index - 1]
		end
	end

	return nil
end

function PlayerDataService.GrantLaunchControl(player, launchId)
	local profile = profiles[player]
	if profile then
		profile.OwnedLaunchControls[launchId] = true
	end
end

function PlayerDataService.SetEquippedLaunchControl(player, launchId)
	local profile = profiles[player]
	if profile then
		profile.EquippedLaunchControl = launchId
		player:SetAttribute("EquippedLaunchControl", launchId)
	end
end

function PlayerDataService.SortedLaunchControlIds()
	return sortedLaunchIds
end

--------------------------------------------------
-- OVERCHARGE
--------------------------------------------------

function PlayerDataService.GetOverchargeLevel(player)
	local profile = profiles[player]
	return profile and profile.OverchargeLevel or 0
end

function PlayerDataService.AddOverchargeLevel(player)
	local profile = profiles[player]
	if profile then
		profile.OverchargeLevel += 1
	end
end

function PlayerDataService.ResetEnergy(player)
	local profile = profiles[player]
	if profile then
		profile.leaderstats.Energy.Value = 0
	end
end

--------------------------------------------------
-- DAILY WHEEL
--------------------------------------------------

function PlayerDataService.GetLastSpinTime(player)
	local profile = profiles[player]
	return profile and profile.LastSpinTime or 0
end

function PlayerDataService.SetLastSpinTime(player, unixTime)
	local profile = profiles[player]
	if profile then
		profile.LastSpinTime = unixTime
	end
end

--------------------------------------------------

--------------------------------------------------
-- PETS
--------------------------------------------------
-- No prerequisite/order-lock here -- eggs are gacha-style, not
-- sequential unlocks like Cores/Trails/Launch Controls.
-- OwnedPets STACKS -- [petId] = count, same shape as Potions, not
-- a boolean set -- duplicates are real, separate copies (for
-- trading) rather than being silently dropped. A count that hits 0
-- deletes the key entirely rather than leaving a 0 sitting in the
-- table, so `OwnedPets[petId]` alone is a reliable truthy/falsy
-- "owned at all" check anywhere that just needs that.
-- Up to MAX_EQUIPPED_PETS can be equipped at once, as an ORDERED
-- array (order maps to PetFollowServer's follow-slot positions).
--------------------------------------------------

function PlayerDataService.IsPetOwned(player, petId)
	local profile = profiles[player]
	return profile ~= nil and (profile.OwnedPets[petId] or 0) > 0
end

function PlayerDataService.GetPetCount(player, petId)
	local profile = profiles[player]
	return profile and (profile.OwnedPets[petId] or 0) or 0
end

function PlayerDataService.GetOwnedPets(player)
	local profile = profiles[player]
	return profile and profile.OwnedPets or {}
end

function PlayerDataService.GetEquippedPets(player)
	local profile = profiles[player]
	return profile and profile.EquippedPets or {}
end

function PlayerDataService.IsPetEquipped(player, petId)
	local profile = profiles[player]
	if not profile then
		return false
	end
	for _, id in ipairs(profile.EquippedPets) do
		if id == petId then
			return true
		end
	end
	return false
end

function PlayerDataService.GrantPet(player, petId, count)
	local profile = profiles[player]
	if profile then
		profile.OwnedPets[petId] = (profile.OwnedPets[petId] or 0) + (count or 1)
	end
end

-- For trading (or any future "give this pet away" flow): removes
-- `count` (default 1) copies of petId from inventory. Returns true
-- if the player had enough and they were removed, false otherwise
-- (nothing changed). If this removes the LAST copy of a pet that's
-- currently equipped, it also gets unequipped automatically --
-- same SetAttribute/PetsChanged side effects as ToggleEquippedPet,
-- so PetFollowServer/PetInventoryClient both pick it up immediately
-- instead of showing a pet that no longer exists in inventory.
function PlayerDataService.RemovePet(player, petId, count)

	count = count or 1

	local profile = profiles[player]
	if not profile then
		return false
	end

	local current = profile.OwnedPets[petId] or 0
	if current < count then
		return false
	end

	local remaining = current - count

	if remaining <= 0 then

		profile.OwnedPets[petId] = nil

		for index, id in ipairs(profile.EquippedPets) do
			if id == petId then
				table.remove(profile.EquippedPets, index)
				player:SetAttribute("EquippedPetsList", table.concat(profile.EquippedPets, ","))
				PlayerDataService.PetsChanged:Fire(player)
				break
			end
		end
	else
		profile.OwnedPets[petId] = remaining
	end

	return true
end

-- Player-initiated equip/unequip through the EquipPet remote.
-- Firing on an equipped pet unequips it; firing on an unequipped
-- one equips it (unless all slots are full).
-- Returns true on success, or false + a reason string ("NotOwned"
-- / "MaxSlots") on failure so the caller can give UI feedback.
function PlayerDataService.ToggleEquippedPet(player, petId)

	local profile = profiles[player]
	if not profile then
		return false, "NoProfile"
	end

	if not profile.OwnedPets[petId] then
		return false, "NotOwned"
	end

	for index, id in ipairs(profile.EquippedPets) do
		if id == petId then
			table.remove(profile.EquippedPets, index)
			player:SetAttribute("EquippedPetsList", table.concat(profile.EquippedPets, ","))
			PlayerDataService.PetsChanged:Fire(player)
			return true
		end
	end

	if #profile.EquippedPets >= MAX_EQUIPPED_PETS then
		return false, "MaxSlots"
	end

	table.insert(profile.EquippedPets, petId)
	player:SetAttribute("EquippedPetsList", table.concat(profile.EquippedPets, ","))
	PlayerDataService.PetsChanged:Fire(player)
	return true
end

-- Used by EggServer right after a NEW pet is granted -- only fills
-- an empty slot, never forces a swap or bumps something the player
-- chose to equip.
function PlayerDataService.AutoEquipIfRoom(player, petId)

	local profile = profiles[player]
	if not profile then
		return
	end

	if #profile.EquippedPets >= MAX_EQUIPPED_PETS then
		return
	end

	for _, id in ipairs(profile.EquippedPets) do
		if id == petId then
			return
		end
	end

	table.insert(profile.EquippedPets, petId)
	player:SetAttribute("EquippedPetsList", table.concat(profile.EquippedPets, ","))
	PlayerDataService.PetsChanged:Fire(player)
end

--------------------------------------------------
-- POTIONS
--------------------------------------------------
-- Collected into a count-per-type inventory (playtime rewards),
-- consumed later via PotionServer's UsePotion remote for a timed
-- buff (PlayerBuffs). The count itself persists across sessions;
-- the buff timer it grants does not.
--------------------------------------------------

function PlayerDataService.GetPotions(player)
	local profile = profiles[player]
	return profile and profile.Potions or {}
end

function PlayerDataService.AddPotion(player, potionId, count)
	local profile = profiles[player]
	if not profile then return end
	profile.Potions[potionId] = (profile.Potions[potionId] or 0) + (count or 1)
end

-- Returns true and decrements by 1 if the player has at least one,
-- false if they don't (nothing decremented).
function PlayerDataService.ConsumePotion(player, potionId)
	local profile = profiles[player]
	if not profile then return false end

	local count = profile.Potions[potionId] or 0
	if count <= 0 then
		return false
	end

	profile.Potions[potionId] = count - 1
	return true
end

--------------------------------------------------
-- POTION BUFFS -- see `local activeBuffs` near the top of this
-- file for why it's declared up there instead of here.
--------------------------------------------------

function PlayerDataService.ActivatePotionBuff(player, buffType, multiplier, duration)
	local buffs = activeBuffs[player]
	if not buffs then
		buffs = {}
		activeBuffs[player] = buffs
	end
	buffs[buffType] = { Multiplier = multiplier, ExpiresAt = os.clock() + duration }
end

-- Returns the multiplier for buffType (e.g. "FlightMult") if an
-- unexpired buff is active, 1 otherwise -- safe to multiply
-- straight into any existing multiplier stack. Lazily clears the
-- buff out once it's found to be expired.
function PlayerDataService.GetBuffMultiplier(player, buffType)
	local buffs = activeBuffs[player]
	if not buffs then return 1 end
	local buff = buffs[buffType]
	if not buff then return 1 end
	if os.clock() >= buff.ExpiresAt then
		buffs[buffType] = nil
		return 1
	end
	return buff.Multiplier
end

-- Seconds remaining on buffType's active buff, 0 if none/expired --
-- for a potion HUD countdown later.
function PlayerDataService.GetBuffRemaining(player, buffType)
	local buffs = activeBuffs[player]
	if not buffs then return 0 end
	local buff = buffs[buffType]
	if not buff then return 0 end
	local remaining = buff.ExpiresAt - os.clock()
	if remaining <= 0 then
		buffs[buffType] = nil
		return 0
	end
	return remaining
end

--------------------------------------------------
-- ROBUX OFFERS (rotating bundle/pet purchases)
--------------------------------------------------
-- One shared "purchased" set covers BOTH pools (bundle offer ids
-- and pet offer ids never collide since they're separate config
-- tables with their own key namespaces) -- once bought, that
-- specific offer never rerolls back in for this player again.
--------------------------------------------------

function PlayerDataService.HasPurchasedOffer(player, offerId)
	local profile = profiles[player]
	return profile ~= nil and profile.PurchasedOfferIds[offerId] == true
end

function PlayerDataService.MarkOfferPurchased(player, offerId)
	local profile = profiles[player]
	if profile then
		profile.PurchasedOfferIds[offerId] = true
	end
end

function PlayerDataService.GetPurchasedOfferIds(player)
	local profile = profiles[player]
	return profile and profile.PurchasedOfferIds or {}
end

--------------------------------------------------
-- CODES
--------------------------------------------------
-- Same "redeemed once, tracked forever" shape as Robux Offers
-- above. `code` is always expected ALREADY NORMALIZED (uppercase,
-- trimmed) by the caller (CodeServer.lua) -- this module doesn't
-- normalize itself, so it stays a dumb, predictable set.
--------------------------------------------------

function PlayerDataService.HasRedeemedCode(player, code)
	local profile = profiles[player]
	return profile ~= nil and profile.RedeemedCodes[code] == true
end

function PlayerDataService.MarkCodeRedeemed(player, code)
	local profile = profiles[player]
	if profile then
		profile.RedeemedCodes[code] = true
	end
end

--------------------------------------------------
-- MAPS (unlocked with Travels, not Cash -- see TravelsServer/MapServer)
--------------------------------------------------

function PlayerDataService.IsMapOwned(player, mapId)
	local profile = profiles[player]
	return profile ~= nil and profile.OwnedMaps[mapId] == true
end

function PlayerDataService.GetOwnedMaps(player)
	local profile = profiles[player]
	return profile and profile.OwnedMaps or {}
end

function PlayerDataService.GrantMap(player, mapId)
	local profile = profiles[player]
	if profile then
		profile.OwnedMaps[mapId] = true
	end
end

--------------------------------------------------
-- AUTOSAVE every 2 minutes, plus save on leave / shutdown
--------------------------------------------------

task.spawn(function()
	while true do
		task.wait(120)
		for _, player in ipairs(Players:GetPlayers()) do
			saveData(player)
		end
	end
end)

game:BindToClose(function()
	for _, player in ipairs(Players:GetPlayers()) do
		saveData(player)
	end
end)

return PlayerDataService