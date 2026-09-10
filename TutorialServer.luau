--------------------------------------------------
-- TutorialServer (Script, ServerScriptService)
-- Fires ShowTutorial exactly once per player, ever, tracked via
-- its own small DataStore (kept separate from PlayerDataService on
-- purpose -- this is a self-contained, low-stakes feature).
--------------------------------------------------

local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local remotes = ReplicatedStorage:WaitForChild("Remotes")
local showTutorial = remotes:WaitForChild("ShowTutorial")

local tutorialStore = DataStoreService:GetDataStore("Tutorial_Release_15")

local SETTLE_DELAY = 2.5 -- let the world/HUD visually settle before popping the tutorial up

local function hasSeenTutorial(player)
	local ok, result = pcall(function()
		return tutorialStore:GetAsync(tostring(player.UserId))
	end)
	if not ok then
		warn("[TutorialServer] GetAsync failed for " .. player.Name .. ": " .. tostring(result))
		return true -- fail safe: don't spam a returning player if DataStore hiccups
	end
	return result == true
end

local function markTutorialSeen(player)
	task.spawn(function()
		local ok, err = pcall(function()
			tutorialStore:SetAsync(tostring(player.UserId), true)
		end)
		if not ok then
			warn("[TutorialServer] SetAsync failed for " .. player.Name .. ": " .. tostring(err))
		end
	end)
end

local function handlePlayer(player)

	if hasSeenTutorial(player) then
		return
	end

	if not player.Character then
		player.CharacterAdded:Wait()
	end

	task.wait(SETTLE_DELAY)

	if not player.Parent then
		return -- left before we got to show it
	end

	showTutorial:FireClient(player)
	markTutorialSeen(player)
end

Players.PlayerAdded:Connect(function(player)
	task.spawn(handlePlayer, player)
end)

for _, player in ipairs(Players:GetPlayers()) do
	task.spawn(handlePlayer, player)
end
