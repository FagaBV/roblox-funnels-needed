--------------------------------------------------
-- TrailShopClient
--------------------------------------------------
-- Mirrors CoreShopClient exactly (grid tiles, lock overlay,
-- detail panel, rarity styling, purchase popup) but for
-- trails, and with TWO stats in the detail panel instead of
-- one -- Flight Mult and Cash Mult.
--
-- REQUIRED GUI STRUCTURE -- built by BuildTrailShop_CommandBar.
-- Same WaitForChild-errors-loudly approach as CoreShopClient:
-- if the tree doesn't match, you find out immediately.
--------------------------------------------------

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local player = Players.LocalPlayer

local modules = ReplicatedStorage:WaitForChild("Modules")
local TrailConfig = require(modules:WaitForChild("TrailConfig"))
local NumberFormatter = require(modules:WaitForChild("NumberFormatter"))
local ResponsiveGrid = require(modules:WaitForChild("ResponsiveGrid"))
local ShopPopAnimator = require(modules:WaitForChild("ShopPopAnimator"))

local remotes = ReplicatedStorage:WaitForChild("Remotes")
local buyTrail = remotes:WaitForChild("BuyTrail")
local equipTrail = remotes:WaitForChild("EquipTrail")
local requestTrailSync = remotes:WaitForChild("RequestTrailSync")

local playerGui = player:WaitForChild("PlayerGui")
local mainUI = playerGui:WaitForChild("MainUI")

local trailShop = mainUI:WaitForChild("TrailShop")
local itemList = trailShop:WaitForChild("ItemList")
local template = itemList:WaitForChild("Template")
local closeButton = trailShop:WaitForChild("CloseButton")
local detailPanel = trailShop:WaitForChild("DetailPanel")

local sideButtons = mainUI:WaitForChild("SideButtons")
local openTrailShopButton = sideButtons:WaitForChild("OpenTrailShopButton")

template.Visible = false
trailShop.Visible = false

ResponsiveGrid.Apply(itemList:WaitForChild("UIGridLayout"), 3, 4, 500)

--------------------------------------------------
-- RARITY STYLING -- identical palette to CoreShopClient, so
-- the two shops feel like the same system.
--------------------------------------------------

local RARITY_STYLE = {
	Common    = { Background = Color3.fromRGB(90, 90, 100),   Stroke = Color3.fromRGB(190, 190, 190), Intensity = 0 },
	Uncommon  = { Background = Color3.fromRGB(35, 110, 60),   Stroke = Color3.fromRGB(100, 255, 130), Intensity = 1 },
	Rare      = { Background = Color3.fromRGB(30, 80, 150),   Stroke = Color3.fromRGB(90, 170, 255),  Intensity = 2 },
	Epic      = { Background = Color3.fromRGB(95, 35, 150),   Stroke = Color3.fromRGB(200, 100, 255), Intensity = 3 },
	Legendary = { Background = Color3.fromRGB(150, 100, 20),  Stroke = Color3.fromRGB(255, 210, 80),  Intensity = 4 },
}

--------------------------------------------------
-- STATE
--------------------------------------------------

local ownedTrails = {}
local equippedTrail = nil
local rows = {}
local selectedTrailId = nil

--------------------------------------------------
-- SORTED TRAIL LIST (by Order field)
--------------------------------------------------

local sortedTrailIds = {}

for trailId, trail in pairs(TrailConfig) do
	if not trail.Exclusive then
		table.insert(sortedTrailIds, trailId)
	end
end

table.sort(sortedTrailIds, function(a, b)
	return TrailConfig[a].Order < TrailConfig[b].Order
end)

local trailIndexById = {}
for index, trailId in ipairs(sortedTrailIds) do
	trailIndexById[trailId] = index
end

--------------------------------------------------
-- LOCK STATE
--------------------------------------------------
-- Same rule as cores: a trail is locked if the PREVIOUS
-- trail (by Order) isn't owned yet. No buying ahead.
--------------------------------------------------

local function isLocked(trailId)

	local index = trailIndexById[trailId]

	if index == 1 then
		return false
	end

	local previousId = sortedTrailIds[index - 1]

	return ownedTrails[previousId] ~= true
end

--------------------------------------------------
-- STYLE A ROW BY RARITY (background/stroke/animation)
--------------------------------------------------

local activeAnimations = {}

local function applyRarity(row, trail)

	local style = RARITY_STYLE[trail.Rarity] or RARITY_STYLE.Common

	row.BackgroundColor3 = style.Background

	local stroke = row:FindFirstChild("RarityStroke")
	if stroke then
		stroke.Color = style.Stroke
	end

	local nameLabel = row.NameLabel
	local gradient = nameLabel:FindFirstChild("RarityGradient")

	if activeAnimations[row] then
		return
	end

	activeAnimations[row] = true

	if style.Intensity <= 0 then
		nameLabel.TextColor3 = style.Stroke
		if gradient then
			gradient.Enabled = false
		end
		return
	end

	if style.Intensity >= 4 and gradient then
		gradient.Enabled = true
	else
		nameLabel.TextColor3 = style.Stroke
	end

	task.spawn(function()

		local t = 0

		while row.Parent do

			t += RunService.Heartbeat:Wait() * (0.6 + style.Intensity * 0.4)

			if stroke then
				stroke.Transparency = 0.35 + math.sin(t * 3) * 0.25
			end

			if style.Intensity >= 3 then
				local scale = 1 + math.sin(t * 2.4) * 0.02 * style.Intensity
				row.Size = UDim2.new(
					template.Size.X.Scale * scale, template.Size.X.Offset,
					template.Size.Y.Scale * scale, template.Size.Y.Offset
				)
			end

			if gradient and gradient.Enabled then
				gradient.Rotation = (gradient.Rotation + style.Intensity * 1.5) % 360
			end
		end
	end)
end

--------------------------------------------------
-- APPLY ICON
--------------------------------------------------

local function applyIcon(row, trail)

	local icon = row:FindFirstChild("Icon")

	if not icon then
		return
	end

	if trail.IconId and trail.IconId ~= 0 then
		icon.Image = "rbxassetid://" .. tostring(trail.IconId)
	else
		icon.Image = ""
	end
end

--------------------------------------------------
-- LOCK OVERLAY
--------------------------------------------------

local function applyLockState(row, trailId)

	local overlay = row:FindFirstChild("LockOverlay")

	if not overlay then
		return
	end

	local locked = isLocked(trailId)

	overlay.Visible = locked
	row.Icon.ImageTransparency = locked and 0.55 or 0
end

local function applyEquippedBadge(row, trailId)
	local badge = row:FindFirstChild("EquippedBadge")
	if not badge then
		return
	end
	badge.Visible = equippedTrail == trailId
end

--------------------------------------------------
-- REFRESH A SINGLE ROW
--------------------------------------------------

local function refreshRow(trailId)

	local row = rows[trailId]

	if not row then
		return
	end

	local trail = TrailConfig[trailId]

	row.NameLabel.Text = trail.DisplayName

	applyLockState(row, trailId)
	applyEquippedBadge(row, trailId)

	if trailId == selectedTrailId then
		row.SelectedStroke.Enabled = true
	elseif row:FindFirstChild("SelectedStroke") then
		row.SelectedStroke.Enabled = false
	end
end

local function refreshAll()
	for _, trailId in ipairs(sortedTrailIds) do
		refreshRow(trailId)
	end
end

--------------------------------------------------
-- DETAIL PANEL (right side -- shows selected trail)
--------------------------------------------------

local function showDetail(trailId)

	selectedTrailId = trailId
	local trail = TrailConfig[trailId]
	local locked = isLocked(trailId)
	local owned = ownedTrails[trailId] == true
	local equipped = equippedTrail == trailId

	detailPanel.Visible = true
	detailPanel.DetailName.Text = trail.DisplayName

	if trail.IconId and trail.IconId ~= 0 then
		detailPanel.DetailIcon.Image = "rbxassetid://" .. tostring(trail.IconId)
	else
		detailPanel.DetailIcon.Image = ""
	end

	detailPanel.DetailIcon.ImageTransparency = locked and 0.55 or 0

	detailPanel.DetailFlightStat.Text = "??x" .. string.format("%.2f", trail.FlightMult)
	detailPanel.DetailCashStat.Text = "??x" .. string.format("%.2f", trail.CashMult)

	if trail.Price <= 0 then
		detailPanel.DetailPrice.Text = "FREE"
	else
		detailPanel.DetailPrice.Text = "$ " .. NumberFormatter.Format(trail.Price)
	end

	local lockedLabel = detailPanel:FindFirstChild("LockedRequirementLabel")

	if locked then

		local previousId = sortedTrailIds[trailIndexById[trailId] - 1]
		local previousName = TrailConfig[previousId].DisplayName

		if lockedLabel then
			lockedLabel.Visible = true
			lockedLabel.Text = "Buy " .. previousName .. " first"
		end

		detailPanel.DetailActionButton.Text = "LOCKED"
		detailPanel.DetailActionButton.AutoButtonColor = false

	else

		if lockedLabel then
			lockedLabel.Visible = false
		end

		detailPanel.DetailActionButton.AutoButtonColor = true

		if equipped then
			detailPanel.DetailActionButton.Text = "EQUIPPED"
		elseif owned then
			detailPanel.DetailActionButton.Text = "EQUIP"
		else
			detailPanel.DetailActionButton.Text = "BUY"
		end
	end

	refreshAll()
end

detailPanel.DetailActionButton.Activated:Connect(function()

	if not selectedTrailId or isLocked(selectedTrailId) then
		return
	end

	local owned = ownedTrails[selectedTrailId] == true
	local equipped = equippedTrail == selectedTrailId

	if equipped then
		return
	elseif owned then
		equipTrail:FireServer(selectedTrailId)
	else
		buyTrail:FireServer(selectedTrailId)
	end
end)

--------------------------------------------------
-- PURCHASE POPUP
--------------------------------------------------

local function showPurchasePopup(trailId)

	local trail = TrailConfig[trailId]
	local style = RARITY_STYLE[trail.Rarity] or RARITY_STYLE.Common

	local popup = Instance.new("Frame")
	popup.Name = "PurchasePopup"
	popup.AnchorPoint = Vector2.new(0.5, 0.5)
	popup.Position = UDim2.fromScale(0.5, 0.4)
	popup.Size = UDim2.fromOffset(0, 0)
	popup.BackgroundColor3 = style.Background
	popup.BorderSizePixel = 0
	popup.ZIndex = 50
	popup.Parent = trailShop

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 16)
	corner.Parent = popup

	local stroke = Instance.new("UIStroke")
	stroke.Color = style.Stroke
	stroke.Thickness = 3
	stroke.Parent = popup

	local icon = Instance.new("ImageLabel")
	icon.Size = UDim2.new(0.5, 0, 0.5, 0)
	icon.Position = UDim2.new(0.25, 0, 0.08, 0)
	icon.BackgroundTransparency = 1
	icon.ZIndex = 51
	icon.Image = (trail.IconId and trail.IconId ~= 0) and ("rbxassetid://" .. tostring(trail.IconId)) or ""
	icon.Parent = popup

	local title = Instance.new("TextLabel")
	title.Size = UDim2.new(1, -20, 0.15, 0)
	title.Position = UDim2.new(0, 10, 0.62, 0)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamBlack
	title.TextScaled = true
	title.TextColor3 = Color3.new(1, 1, 1)
	title.Text = trail.Rarity:upper() .. " TRAIL UNLOCKED!"
	title.ZIndex = 51
	title.Parent = popup

	local name = Instance.new("TextLabel")
	name.Size = UDim2.new(1, -20, 0.15, 0)
	name.Position = UDim2.new(0, 10, 0.78, 0)
	name.BackgroundTransparency = 1
	name.Font = Enum.Font.GothamBold
	name.TextScaled = true
	name.TextColor3 = style.Stroke
	name.Text = trail.DisplayName
	name.ZIndex = 51
	name.Parent = popup

	local openTween = TweenService:Create(
		popup,
		TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Size = UDim2.fromScale(0.32, 0.42) }
	)

	openTween:Play()

	task.delay(1.6, function()

		local closeTween = TweenService:Create(
			popup,
			TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
			{ Size = UDim2.fromOffset(0, 0), BackgroundTransparency = 1 }
		)

		closeTween:Play()
		closeTween.Completed:Wait()
		popup:Destroy()
	end)
end

--------------------------------------------------
-- BUILD LIST (runs once)
--------------------------------------------------

local function buildList()

	for _, trailId in ipairs(sortedTrailIds) do

		local trail = TrailConfig[trailId]

		local row = template:Clone()

		row.Name = trailId
		row.LayoutOrder = trail.Order
		row.Visible = true
		row.Parent = itemList

		rows[trailId] = row

		applyRarity(row, trail)
		applyIcon(row, trail)

		row.SelectButton.Activated:Connect(function()
			showDetail(trailId)
		end)

		refreshRow(trailId)
	end
end

--------------------------------------------------
-- OPEN / CLOSE
--------------------------------------------------
-- No restyling needed here -- OpenTrailShopButton is a clone
-- of your already-styled OpenShopButton (see the command bar
-- script), so it matches automatically.
--------------------------------------------------

openTrailShopButton.Activated:Connect(function()
	ShopPopAnimator.Open(trailShop)
end)

closeButton.Activated:Connect(function()
	ShopPopAnimator.Close(trailShop)
end)

--------------------------------------------------
-- RECEIVE OWNED / EQUIPPED SYNC FROM SERVER
--------------------------------------------------

local receivedFirstSync = false

buyTrail.OnClientEvent:Connect(function(payload)

	if not payload then
		return
	end

	receivedFirstSync = true

	if payload.OwnedTrails then
		ownedTrails = payload.OwnedTrails
	end

	if payload.EquippedTrail then
		equippedTrail = payload.EquippedTrail
	end

	if payload.Purchased then
		showPurchasePopup(payload.Purchased)
	end

	refreshAll()

	if selectedTrailId then
		showDetail(selectedTrailId)
	end
end)

--------------------------------------------------
-- INIT
--------------------------------------------------

buildList()

-- Ask the server for a fresh sync instead of hoping we connected
-- OnClientEvent above in time to catch TrailServer's one-shot push
-- on join -- that race is exactly what left everything looking
-- locked/unowned before. Retries a couple times in case the very
-- first request goes out before the server's even finished loading
-- this player's profile.
task.spawn(function()
	for _ = 1, 5 do
		if receivedFirstSync then
			return
		end
		requestTrailSync:FireServer()
		task.wait(1)
	end
end)