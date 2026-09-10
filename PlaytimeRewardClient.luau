--------------------------------------------------
-- PlaytimeRewardClient  (LocalScript, StarterPlayerScripts)
--
-- Drives MainUI.PlaytimeRewards (built by
-- BuildPlaytimeRewards_CommandBar.lua): one tile per milestone in
-- PlaytimeRewardConfig, showing a live countdown until it unlocks,
-- a CLAIM button once unlocked (and not yet claimed this session),
-- or a "Claimed" state after. SESSION-based -- see
-- PlaytimeRewardServer's header comment ("Leaving Resets Gifts!"),
-- this resets to locked/unclaimed on rejoin, matching the reference
-- design.
--
-- REQUIRED GUI STRUCTURE -- built by
-- BuildPlaytimeRewards_CommandBar.lua. This script errors on
-- missing WaitForChild calls on purpose, so you find out
-- immediately what's missing instead of it failing silently.
--------------------------------------------------

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local player = Players.LocalPlayer

local modules = ReplicatedStorage:WaitForChild("Modules")
local PlaytimeRewardConfig = require(modules:WaitForChild("PlaytimeRewardConfig"))

local remotes = ReplicatedStorage:WaitForChild("Remotes")
local claimPlaytimeReward = remotes:WaitForChild("ClaimPlaytimeReward")
local playtimeRewardSync = remotes:WaitForChild("PlaytimeRewardSync")

local playerGui = player:WaitForChild("PlayerGui")
local mainUI = playerGui:WaitForChild("MainUI")

local panel = mainUI:WaitForChild("PlaytimeRewards")
local closeButton = panel.Header:WaitForChild("CloseButton")
local itemList = panel:WaitForChild("ItemList")
local container = itemList:WaitForChild("Container")
local template = container:WaitForChild("Template")

-- Moved off SideButtons -- now MainUI.PlaytimeOpen directly.
local openButton = mainUI:WaitForChild("PlaytimeOpen")

-- Create this yourself in Studio: a TextLabel named "AvailableLabel"
-- as a child of PlaytimeOpen, Visible = false. Toggled on whenever
-- at least one milestone is unlocked and not yet claimed, even
-- while the panel itself is closed -- a "there's a free gift"
-- notification badge.
local availableLabel = openButton:WaitForChild("AvailableLabel")
availableLabel.Visible = false

-- Create this one too: a TextLabel named "CountdownLabel", also a
-- child of PlaytimeOpen, Visible = false. Shows time remaining
-- until the NEXT (soonest) not-yet-unlocked milestone -- the two
-- badges are mutually exclusive: AvailableLabel takes over the
-- instant something's actually claimable, CountdownLabel only shows
-- while nothing is.
local countdownLabel = openButton:WaitForChild("CountdownLabel")
countdownLabel.Visible = false

-- NOTE: for the pop to scale from the button's own center rather
-- than a corner, PlaytimeOpen's AnchorPoint should be (0.5, 0.5).
local originalSize = openButton.Size

--------------------------------------------------
-- BOUNCE LOOP -- pops the button up/down while a gift is available,
-- to draw the eye. Guarded by isBouncing so repeated refresh()
-- calls (every second) can't stack multiple loops on top of each
-- other.
--------------------------------------------------

local isBouncing = false

local function startBounce()

	if isBouncing then
		return
	end
	isBouncing = true

	task.spawn(function()
		while availableLabel.Visible and openButton.Parent do

			local grow = TweenService:Create(
				openButton,
				TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{ Size = originalSize + UDim2.fromOffset(14, 14) }
			)
			local shrink = TweenService:Create(
				openButton,
				TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
				{ Size = originalSize }
			)

			grow:Play()
			grow.Completed:Wait()
			shrink:Play()
			shrink.Completed:Wait()

			task.wait(1) -- pause between pops
		end

		openButton.Size = originalSize
		isBouncing = false
	end)
end

template.Visible = false
panel.Visible = false

--------------------------------------------------
-- SORTED MILESTONES
--------------------------------------------------

local sortedMilestones = {}
for _, milestone in ipairs(PlaytimeRewardConfig.Milestones) do
	table.insert(sortedMilestones, milestone)
end
table.sort(sortedMilestones, function(a, b)
	return a.Time < b.Time
end)

--------------------------------------------------
-- STATE
--------------------------------------------------

local claimedIds = {}
local tiles = {}

local function formatTime(seconds)
	seconds = math.max(0, math.ceil(seconds))
	local m = math.floor(seconds / 60)
	local s = seconds % 60
	return string.format("%d:%02d", m, s)
end

--------------------------------------------------
-- BUILD TILES (once)
--------------------------------------------------

local function buildTiles()

	for _, milestone in ipairs(sortedMilestones) do

		local tile = template:Clone()
		tile.Name = milestone.Id
		tile.LayoutOrder = milestone.Time
		tile.Visible = true
		tile.Parent = container

		local icon = tile:FindFirstChild("Icon")
		if icon then
			icon.Image = (milestone.IconId and milestone.IconId ~= 0) and ("rbxassetid://" .. tostring(milestone.IconId)) or ""
		end

		tile.NameLabel.Text = milestone.DisplayName

		tiles[milestone.Id] = tile

		tile.ClaimButton.Activated:Connect(function()
			print("[PlaytimeRewardClient] CLAIM clicked for Id =", milestone.Id)
			local ok, err = pcall(function()
				claimPlaytimeReward:FireServer(milestone.Id)
			end)
			if not ok then
				warn("[PlaytimeRewardClient] FireServer failed:", err)
			end
		end)
	end
end

--------------------------------------------------
-- REFRESH ALL TILES -- called every second while open, plus
-- whenever a server sync comes in
--------------------------------------------------

local function refresh()

	local sessionPlaytime = player:GetAttribute("SessionPlaytime") or 0
	local hasAvailable = false
	local nextCountdownTime = nil -- soonest not-yet-unlocked milestone, if any

	for _, milestone in ipairs(sortedMilestones) do

		local claimed = claimedIds[milestone.Id] == true
		local unlocked = sessionPlaytime >= milestone.Time

		if unlocked and not claimed then
			hasAvailable = true
		elseif not claimed and not unlocked and not nextCountdownTime then
			-- sortedMilestones is ascending by Time, so the first one
			-- that's still locked is necessarily the soonest.
			nextCountdownTime = milestone.Time - sessionPlaytime
		end

		local tile = tiles[milestone.Id]
		if tile then

			if claimed then
				tile.StateLabel.Visible = false
				tile.ClaimButton.Visible = true
				tile.ClaimButton.Active = false
				tile.ClaimButton.AutoButtonColor = false
				tile.ClaimButton.Text = "Rewarded"
				tile.ClaimButton.BackgroundColor3 = Color3.fromRGB(200, 60, 60)
			elseif unlocked then
				tile.StateLabel.Visible = false
				tile.ClaimButton.Visible = true
				tile.ClaimButton.Active = true
				tile.ClaimButton.AutoButtonColor = true
				tile.ClaimButton.Text = "CLAIM"
				tile.ClaimButton.BackgroundColor3 = Color3.fromRGB(90, 210, 60)
			else
				tile.ClaimButton.Visible = false
				tile.StateLabel.Visible = true
				tile.StateLabel.Text = formatTime(milestone.Time - sessionPlaytime)
			end
		end
	end

	availableLabel.Visible = hasAvailable

	if hasAvailable then
		startBounce()
		countdownLabel.Visible = false
	elseif nextCountdownTime then
		countdownLabel.Visible = true
		countdownLabel.Text = formatTime(nextCountdownTime)
	else
		-- Nothing left to claim OR unlock this session (everything claimed).
		countdownLabel.Visible = false
	end
end

--------------------------------------------------
-- SYNC FROM SERVER
--------------------------------------------------

playtimeRewardSync.OnClientEvent:Connect(function(payload)

	if not payload then
		return
	end

	claimedIds = payload.ClaimedIds or {}
	refresh()
end)

--------------------------------------------------
-- LOCAL TICK -- runs regardless of whether the panel is open, since
-- the AvailableLabel badge needs to turn on even while it's closed
--------------------------------------------------

task.spawn(function()
	while true do
		task.wait(1)
		refresh()
	end
end)

--------------------------------------------------
-- OPEN / CLOSE
--------------------------------------------------

openButton.Activated:Connect(function()
	panel.Visible = true
	refresh()
end)

closeButton.Activated:Connect(function()
	panel.Visible = false
end)

--------------------------------------------------
-- INIT
--------------------------------------------------

buildTiles()
refresh()
