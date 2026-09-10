--------------------------------------------------
-- LaunchShopClient
--------------------------------------------------
-- Mirrors CoreShopClient/TrailShopClient (grid tiles, lock
-- overlay, detail panel, rarity styling, purchase popup) but
-- for launch controls, with THREE stats in the detail panel --
-- Energy Mult, Flight Mult, and Cash Mult -- and two extra
-- rarity tiers (Mythic, Secret) beyond Core/TrailConfig's five.
--
-- REQUIRED GUI STRUCTURE -- built by BuildLaunchShop_CommandBar.
-- Same WaitForChild-errors-loudly approach as CoreShopClient:
-- if the tree doesn't match, you find out immediately.
--------------------------------------------------

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local player = Players.LocalPlayer

local modules = ReplicatedStorage:WaitForChild("Modules")
local LaunchConfig = require(modules:WaitForChild("LaunchConfig"))
local NumberFormatter = require(modules:WaitForChild("NumberFormatter"))
local ResponsiveGrid = require(modules:WaitForChild("ResponsiveGrid"))
local ShopPopAnimator = require(modules:WaitForChild("ShopPopAnimator"))

local remotes = ReplicatedStorage:WaitForChild("Remotes")
local buyLaunchControl = remotes:WaitForChild("BuyLaunchControl")
local equipLaunchControl = remotes:WaitForChild("EquipLaunchControl")

local playerGui = player:WaitForChild("PlayerGui")
local mainUI = playerGui:WaitForChild("MainUI")

local launchShop = mainUI:WaitForChild("LaunchShop")
local itemList = launchShop:WaitForChild("ItemList")
local template = itemList:WaitForChild("Template")
local closeButton = launchShop:WaitForChild("CloseButton")
local detailPanel = launchShop:WaitForChild("DetailPanel")

local sideButtons = mainUI:WaitForChild("SideButtons")
local openLaunchShopButton = sideButtons:WaitForChild("OpenLaunchShopButton")

template.Visible = false
launchShop.Visible = false

ResponsiveGrid.Apply(itemList:WaitForChild("UIGridLayout"), 3, 4, 500)

--------------------------------------------------
-- RARITY STYLING -- same palette as CoreShopClient/TrailShopClient
-- for the first five tiers, plus two new ones (Mythic, Secret)
-- that only LaunchConfig uses. Intensity keeps climbing, so
-- Mythic/Secret get the rainbow gradient + breathing scale too,
-- just faster.
--------------------------------------------------

local RARITY_STYLE = {
	Common    = { Background = Color3.fromRGB(90, 90, 100),   Stroke = Color3.fromRGB(190, 190, 190), Intensity = 0 },
	Uncommon  = { Background = Color3.fromRGB(35, 110, 60),   Stroke = Color3.fromRGB(100, 255, 130), Intensity = 1 },
	Rare      = { Background = Color3.fromRGB(30, 80, 150),   Stroke = Color3.fromRGB(90, 170, 255),  Intensity = 2 },
	Epic      = { Background = Color3.fromRGB(95, 35, 150),   Stroke = Color3.fromRGB(200, 100, 255), Intensity = 3 },
	Legendary = { Background = Color3.fromRGB(150, 100, 20),  Stroke = Color3.fromRGB(255, 210, 80),  Intensity = 4 },
	Mythic    = { Background = Color3.fromRGB(180, 20, 90),   Stroke = Color3.fromRGB(255, 60, 180),  Intensity = 5 },
	Secret    = { Background = Color3.fromRGB(20, 20, 25),    Stroke = Color3.fromRGB(0, 255, 255),   Intensity = 6 },
}

--------------------------------------------------
-- STATE
--------------------------------------------------

local ownedLaunchControls = {}
local equippedLaunchControl = nil
local rows = {}
local selectedLaunchId = nil

--------------------------------------------------
-- SORTED LAUNCH CONTROL LIST (by Order field)
--------------------------------------------------

local sortedLaunchIds = {}

for launchId, launch in pairs(LaunchConfig) do
	if not launch.Exclusive then
		table.insert(sortedLaunchIds, launchId)
	end
end

table.sort(sortedLaunchIds, function(a, b)
	return LaunchConfig[a].Order < LaunchConfig[b].Order
end)

local launchIndexById = {}
for index, launchId in ipairs(sortedLaunchIds) do
	launchIndexById[launchId] = index
end

--------------------------------------------------
-- LOCK STATE
--------------------------------------------------
-- Same rule as cores: a launch is locked if the PREVIOUS
-- launch (by Order) isn't owned yet. No buying ahead.
--------------------------------------------------

local function isLocked(launchId)

	local index = launchIndexById[launchId]

	if index == 1 then
		return false
	end

	local previousId = sortedLaunchIds[index - 1]

	return ownedLaunchControls[previousId] ~= true
end

--------------------------------------------------
-- STYLE A ROW BY RARITY (background/stroke/animation)
--------------------------------------------------

local activeAnimations = {}

local function applyRarity(row, launch)

	local style = RARITY_STYLE[launch.Rarity] or RARITY_STYLE.Common

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

local function applyIcon(row, launch)

	local icon = row:FindFirstChild("Icon")

	if not icon then
		return
	end

	if launch.IconId and launch.IconId ~= 0 then
		icon.Image = "rbxassetid://" .. tostring(launch.IconId)
	else
		icon.Image = ""
	end
end

--------------------------------------------------
-- LOCK OVERLAY
--------------------------------------------------

local function applyLockState(row, launchId)

	local overlay = row:FindFirstChild("LockOverlay")

	if not overlay then
		return
	end

	local locked = isLocked(launchId)

	overlay.Visible = locked
	row.Icon.ImageTransparency = locked and 0.55 or 0
end

local function applyEquippedBadge(row, launchId)
	local badge = row:FindFirstChild("EquippedBadge")
	if not badge then
		return
	end
	badge.Visible = equippedLaunchControl == launchId
end

--------------------------------------------------
-- REFRESH A SINGLE ROW
--------------------------------------------------

local function refreshRow(launchId)

	local row = rows[launchId]

	if not row then
		return
	end

	local launch = LaunchConfig[launchId]

	row.NameLabel.Text = launch.DisplayName

	applyLockState(row, launchId)
	applyEquippedBadge(row, launchId)

	if launchId == selectedLaunchId then
		row.SelectedStroke.Enabled = true
	elseif row:FindFirstChild("SelectedStroke") then
		row.SelectedStroke.Enabled = false
	end
end

local function refreshAll()
	for _, launchId in ipairs(sortedLaunchIds) do
		refreshRow(launchId)
	end
end

--------------------------------------------------
-- DETAIL PANEL (right side -- shows selected launch)
--------------------------------------------------

local function showDetail(launchId)

	selectedLaunchId = launchId
	local launch = LaunchConfig[launchId]
	local locked = isLocked(launchId)
	local owned = ownedLaunchControls[launchId] == true
	local equipped = equippedLaunchControl == launchId

	detailPanel.Visible = true
	detailPanel.DetailName.Text = launch.DisplayName

	if launch.IconId and launch.IconId ~= 0 then
		detailPanel.DetailIcon.Image = "rbxassetid://" .. tostring(launch.IconId)
	else
		detailPanel.DetailIcon.Image = ""
	end

	detailPanel.DetailIcon.ImageTransparency = locked and 0.55 or 0

	detailPanel.DetailEnergyStat.Text = "?x" .. string.format("%.2f", launch.EnergyMult)
	detailPanel.DetailFlightStat.Text = "??x" .. string.format("%.2f", launch.FlightMult)
	detailPanel.DetailCashStat.Text = "??x" .. string.format("%.2f", launch.CashMult)

	if launch.Price <= 0 then
		detailPanel.DetailPrice.Text = "FREE"
	else
		detailPanel.DetailPrice.Text = "$ " .. NumberFormatter.Format(launch.Price)
	end

	local lockedLabel = detailPanel:FindFirstChild("LockedRequirementLabel")

	if locked then

		local previousId = sortedLaunchIds[launchIndexById[launchId] - 1]
		local previousName = LaunchConfig[previousId].DisplayName

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

	if not selectedLaunchId or isLocked(selectedLaunchId) then
		return
	end

	local owned = ownedLaunchControls[selectedLaunchId] == true
	local equipped = equippedLaunchControl == selectedLaunchId

	if equipped then
		return
	elseif owned then
		equipLaunchControl:FireServer(selectedLaunchId)
	else
		buyLaunchControl:FireServer(selectedLaunchId)
	end
end)

--------------------------------------------------
-- PURCHASE POPUP
--------------------------------------------------

local function showPurchasePopup(launchId)

	local launch = LaunchConfig[launchId]
	local style = RARITY_STYLE[launch.Rarity] or RARITY_STYLE.Common

	local popup = Instance.new("Frame")
	popup.Name = "PurchasePopup"
	popup.AnchorPoint = Vector2.new(0.5, 0.5)
	popup.Position = UDim2.fromScale(0.5, 0.4)
	popup.Size = UDim2.fromOffset(0, 0)
	popup.BackgroundColor3 = style.Background
	popup.BorderSizePixel = 0
	popup.ZIndex = 50
	popup.Parent = launchShop

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
	icon.Image = (launch.IconId and launch.IconId ~= 0) and ("rbxassetid://" .. tostring(launch.IconId)) or ""
	icon.Parent = popup

	local title = Instance.new("TextLabel")
	title.Size = UDim2.new(1, -20, 0.15, 0)
	title.Position = UDim2.new(0, 10, 0.62, 0)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamBlack
	title.TextScaled = true
	title.TextColor3 = Color3.new(1, 1, 1)
	title.Text = launch.Rarity:upper() .. " LAUNCH CONTROL UNLOCKED!"
	title.ZIndex = 51
	title.Parent = popup

	local name = Instance.new("TextLabel")
	name.Size = UDim2.new(1, -20, 0.15, 0)
	name.Position = UDim2.new(0, 10, 0.78, 0)
	name.BackgroundTransparency = 1
	name.Font = Enum.Font.GothamBold
	name.TextScaled = true
	name.TextColor3 = style.Stroke
	name.Text = launch.DisplayName
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

	for _, launchId in ipairs(sortedLaunchIds) do

		local launch = LaunchConfig[launchId]

		local row = template:Clone()

		row.Name = launchId
		row.LayoutOrder = launch.Order
		row.Visible = true
		row.Parent = itemList

		rows[launchId] = row

		applyRarity(row, launch)
		applyIcon(row, launch)

		row.SelectButton.Activated:Connect(function()
			showDetail(launchId)
		end)

		refreshRow(launchId)
	end
end

--------------------------------------------------
-- OPEN / CLOSE
--------------------------------------------------
-- No restyling needed here -- OpenLaunchShopButton is a clone
-- of your already-styled OpenShopButton (see the command bar
-- script), so it matches automatically.
--------------------------------------------------

openLaunchShopButton.Activated:Connect(function()
	ShopPopAnimator.Open(launchShop)
end)

closeButton.Activated:Connect(function()
	ShopPopAnimator.Close(launchShop)
end)

--------------------------------------------------
-- RECEIVE OWNED / EQUIPPED SYNC FROM SERVER
--------------------------------------------------

buyLaunchControl.OnClientEvent:Connect(function(payload)

	if not payload then
		return
	end

	if payload.OwnedLaunchControls then
		ownedLaunchControls = payload.OwnedLaunchControls
	end

	if payload.EquippedLaunchControl then
		equippedLaunchControl = payload.EquippedLaunchControl
	end

	if payload.Purchased then
		showPurchasePopup(payload.Purchased)
	end

	refreshAll()

	if selectedLaunchId then
		showDetail(selectedLaunchId)
	end
end)

--------------------------------------------------
-- INIT
--------------------------------------------------

buildList()