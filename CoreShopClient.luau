--------------------------------------------------
-- CoreShopClient
--------------------------------------------------
-- Builds a GRID core shop (like the reference Food shop
-- screenshot): big icon tiles on the left, a detail panel
-- on the right that shows whatever tile was last clicked.
-- Locked cores (anything past the next core you can afford
-- to unlock) are dimmed with a lock icon over them.
--
-- REQUIRED GUI STRUCTURE -- see SETUP_INSTRUCTIONS.md.
-- This script will error on missing WaitForChild calls if
-- the tree doesn't match, on purpose, so you find out
-- immediately what's missing instead of it failing silently.
--------------------------------------------------

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local player = Players.LocalPlayer

local modules = ReplicatedStorage:WaitForChild("Modules")
local CoreConfig = require(modules:WaitForChild("CoreConfig"))
local NumberFormatter = require(modules:WaitForChild("NumberFormatter"))
local ResponsiveGrid = require(modules:WaitForChild("ResponsiveGrid"))
local ShopPopAnimator = require(modules:WaitForChild("ShopPopAnimator"))

local remotes = ReplicatedStorage:WaitForChild("Remotes")
local buyCore = remotes:WaitForChild("BuyCore")
local equipCore = remotes:WaitForChild("EquipCore")

local playerGui = player:WaitForChild("PlayerGui")
local mainUI = playerGui:WaitForChild("MainUI")

local coreShop = mainUI:WaitForChild("CoreShop")
local itemList = coreShop:WaitForChild("ItemList")
local template = itemList:WaitForChild("Template")
local closeButton = coreShop:WaitForChild("CloseButton")
local detailPanel = coreShop:WaitForChild("DetailPanel")

local sideButtons = mainUI:WaitForChild("SideButtons")
local openShopButton = sideButtons:WaitForChild("OpenShopButton")

template.Visible = false
coreShop.Visible = false

ResponsiveGrid.Apply(itemList:WaitForChild("UIGridLayout"), 3, 4, 500)

--------------------------------------------------
-- RARITY STYLING
--------------------------------------------------
-- Card BACKGROUND colors (soft, like the food shop tiles)
-- and a separate brighter STROKE/glow color per rarity.
-- "Intensity" drives how much extra animation a rarity gets:
-- Common/Uncommon = flat color, Rare = slow pulse border,
-- Epic = pulse + scale breathing, Legendary = full rainbow
-- gradient + pulse + breathing.
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

local ownedCores = {}
local equippedCore = nil
local rows = {}
local selectedCoreId = nil

--------------------------------------------------
-- SORTED CORE LIST (by Order field)
--------------------------------------------------

local sortedCoreIds = {}

for coreId in pairs(CoreConfig) do
	table.insert(sortedCoreIds, coreId)
end

table.sort(sortedCoreIds, function(a, b)
	return CoreConfig[a].Order < CoreConfig[b].Order
end)

local coreIndexById = {}
for index, coreId in ipairs(sortedCoreIds) do
	coreIndexById[coreId] = index
end

--------------------------------------------------
-- LOCK STATE
--------------------------------------------------
-- A core is locked if the PREVIOUS core (by Order) isn't
-- owned yet. There's no way to buy ahead just by having
-- enough cash -- unlock is strictly sequential.
--------------------------------------------------

local function isLocked(coreId)

	local index = coreIndexById[coreId]

	if index == 1 then
		return false
	end

	local previousId = sortedCoreIds[index - 1]

	return ownedCores[previousId] ~= true
end

--------------------------------------------------
-- STYLE A ROW BY RARITY (background/stroke/animation)
--------------------------------------------------

local activeAnimations = {} -- [row] = true, used to avoid stacking loops

local function applyRarity(row, core)

	local style = RARITY_STYLE[core.Rarity] or RARITY_STYLE.Common

	row.BackgroundColor3 = style.Background

	local stroke = row:FindFirstChild("RarityStroke")
	if stroke then
		stroke.Color = style.Stroke
	end

	local nameLabel = row.NameLabel
	local gradient = nameLabel:FindFirstChild("RarityGradient")

	if activeAnimations[row] then
		return -- animation loop already running for this row
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

	-- Border pulse + (for Epic/Legendary) a slight breathing
	-- scale, speed scaling with rarity intensity.
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

local function applyIcon(row, core)

	local icon = row:FindFirstChild("Icon")

	if not icon then
		return
	end

	if core.IconId and core.IconId ~= 0 then
		icon.Image = "rbxassetid://" .. tostring(core.IconId)
	else
		icon.Image = ""
	end
end

--------------------------------------------------
-- LOCK OVERLAY (dim + lock icon over unowned-ahead cores)
--------------------------------------------------

local function applyLockState(row, coreId)

	local overlay = row:FindFirstChild("LockOverlay")

	if not overlay then
		return
	end

	local locked = isLocked(coreId)

	overlay.Visible = locked
	row.Icon.ImageTransparency = locked and 0.55 or 0
end

local function applyEquippedBadge(row, coreId)
	local badge = row:FindFirstChild("EquippedBadge")
	if not badge then
		return
	end
	badge.Visible = equippedCore == coreId
end

--------------------------------------------------
-- REFRESH A SINGLE ROW
--------------------------------------------------

local function refreshRow(coreId)

	local row = rows[coreId]

	if not row then
		return
	end

	local core = CoreConfig[coreId]

	row.NameLabel.Text = core.DisplayName

	applyLockState(row, coreId)
	applyEquippedBadge(row, coreId)

	if coreId == selectedCoreId then
		row.SelectedStroke.Enabled = true
	elseif row:FindFirstChild("SelectedStroke") then
		row.SelectedStroke.Enabled = false
	end
end

local function refreshAll()
	for _, coreId in ipairs(sortedCoreIds) do
		refreshRow(coreId)
	end
end

--------------------------------------------------
-- DETAIL PANEL (right side -- shows selected core)
--------------------------------------------------

local function showDetail(coreId)

	selectedCoreId = coreId
	local core = CoreConfig[coreId]
	local locked = isLocked(coreId)
	local owned = ownedCores[coreId] == true
	local equipped = equippedCore == coreId

	detailPanel.Visible = true
	detailPanel.DetailName.Text = core.DisplayName

	if core.IconId and core.IconId ~= 0 then
		detailPanel.DetailIcon.Image = "rbxassetid://" .. tostring(core.IconId)
	else
		detailPanel.DetailIcon.Image = ""
	end

	detailPanel.DetailIcon.ImageTransparency = locked and 0.55 or 0

	detailPanel.DetailStat.Text = "?" .. NumberFormatter.Format(core.Energy)

	if core.Price <= 0 then
		detailPanel.DetailPrice.Text = "FREE"
	else
		detailPanel.DetailPrice.Text = "$ " .. NumberFormatter.Format(core.Price)
	end

	local lockedLabel = detailPanel:FindFirstChild("LockedRequirementLabel")

	if locked then

		local previousId = sortedCoreIds[coreIndexById[coreId] - 1]
		local previousName = CoreConfig[previousId].DisplayName

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

	if not selectedCoreId or isLocked(selectedCoreId) then
		return
	end

	local owned = ownedCores[selectedCoreId] == true
	local equipped = equippedCore == selectedCoreId

	if equipped then
		return
	elseif owned then
		equipCore:FireServer(selectedCoreId)
	else
		buyCore:FireServer(selectedCoreId)
	end
end)

--------------------------------------------------
-- PURCHASE POPUP ("core acquired" reward feel)
--------------------------------------------------

local function showPurchasePopup(coreId)

	local core = CoreConfig[coreId]
	local style = RARITY_STYLE[core.Rarity] or RARITY_STYLE.Common

	local popup = Instance.new("Frame")
	popup.Name = "PurchasePopup"
	popup.AnchorPoint = Vector2.new(0.5, 0.5)
	popup.Position = UDim2.fromScale(0.5, 0.4)
	popup.Size = UDim2.fromOffset(0, 0)
	popup.BackgroundColor3 = style.Background
	popup.BorderSizePixel = 0
	popup.ZIndex = 50
	popup.Parent = coreShop

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
	icon.Image = (core.IconId and core.IconId ~= 0) and ("rbxassetid://" .. tostring(core.IconId)) or ""
	icon.Parent = popup

	local title = Instance.new("TextLabel")
	title.Size = UDim2.new(1, -20, 0.15, 0)
	title.Position = UDim2.new(0, 10, 0.62, 0)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamBlack
	title.TextScaled = true
	title.TextColor3 = Color3.new(1, 1, 1)
	title.Text = core.Rarity:upper() .. " CORE UNLOCKED!"
	title.ZIndex = 51
	title.Parent = popup

	local name = Instance.new("TextLabel")
	name.Size = UDim2.new(1, -20, 0.15, 0)
	name.Position = UDim2.new(0, 10, 0.78, 0)
	name.BackgroundTransparency = 1
	name.Font = Enum.Font.GothamBold
	name.TextScaled = true
	name.TextColor3 = style.Stroke
	name.Text = core.DisplayName
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

	for _, coreId in ipairs(sortedCoreIds) do

		local core = CoreConfig[coreId]

		local row = template:Clone()

		row.Name = coreId
		row.LayoutOrder = core.Order
		row.Visible = true
		row.Parent = itemList

		rows[coreId] = row

		applyRarity(row, core)
		applyIcon(row, core)

		row.SelectButton.Activated:Connect(function()
			showDetail(coreId)
		end)

		refreshRow(coreId)
	end
end

--------------------------------------------------
-- RESTYLE OPEN SHOP BUTTON
-- Light gray-ish transparent fill, thin white stroke.
--------------------------------------------------

local function restyleShopButton()

	openShopButton.BackgroundColor3 = Color3.fromRGB(200, 200, 210)
	openShopButton.BackgroundTransparency = 0.45
	openShopButton.BorderSizePixel = 0

	if not openShopButton:FindFirstChild("UICorner") then
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 12)
		corner.Parent = openShopButton
	end

	local stroke = openShopButton:FindFirstChild("UIStroke")
	if not stroke then
		stroke = Instance.new("UIStroke")
		stroke.Parent = openShopButton
	end
	stroke.Color = Color3.new(1, 1, 1)
	stroke.Thickness = 1.5
	stroke.Transparency = 0.1
end

--------------------------------------------------
-- OPEN / CLOSE
--------------------------------------------------

openShopButton.Activated:Connect(function()
	ShopPopAnimator.Open(coreShop)
end)

closeButton.Activated:Connect(function()
	ShopPopAnimator.Close(coreShop)
end)

--------------------------------------------------
-- RECEIVE OWNED / EQUIPPED SYNC FROM SERVER
--------------------------------------------------

buyCore.OnClientEvent:Connect(function(payload)

	if not payload then
		return
	end

	if payload.OwnedCores then
		ownedCores = payload.OwnedCores
	end

	if payload.EquippedCore then
		equippedCore = payload.EquippedCore
	end

	if payload.Purchased then
		showPurchasePopup(payload.Purchased)
	end

	refreshAll()

	if selectedCoreId then
		showDetail(selectedCoreId)
	end
end)

--------------------------------------------------
-- INIT
--------------------------------------------------

restyleShopButton()
buildList()