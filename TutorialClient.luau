--------------------------------------------------
-- TutorialClient (LocalScript, StarterPlayerScripts)
-- Drives the TutorialCard carousel.
--------------------------------------------------

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Lighting = game:GetService("Lighting")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local mainUI = playerGui:WaitForChild("MainUI")

local startChargeButton = mainUI:WaitForChild("StartCharge")

local card = mainUI:WaitForChild("TutorialCard")
local iconLabel = card:WaitForChild("IconLabel")
local titleLabel = card:WaitForChild("TitleLabel")
local messageLabel = card:WaitForChild("MessageLabel")
local nextButton = card:WaitForChild("NextButton")
local skipButton = card:WaitForChild("SkipButton")
local dotsRow = card:WaitForChild("DotsRow")

-- Optional -- FindFirstChild (not WaitForChild) on purpose, so this
-- script still works fine even before StepImage has been added in
-- Studio. Every place that touches it below checks for nil first.
local stepImage = card:FindFirstChild("StepImage")

--------------------------------------------------
-- ANIMATION HELPERS
--
-- UIScale (not Size directly) for the pop-in punch -- scaling Size
-- itself would fight with whatever layout/anchoring is already set
-- up on these objects, where a UIScale scales the whole element
-- visually around its AnchorPoint without touching the real Size at
-- all, so it can't conflict with anything else.
--------------------------------------------------

local function getOrCreateScale(instance)
	local scale = instance:FindFirstChildOfClass("UIScale")
	if not scale then
		scale = Instance.new("UIScale")
		scale.Parent = instance
	end
	return scale
end

local iconScale = getOrCreateScale(iconLabel)
local imageScale = stepImage and getOrCreateScale(stepImage)

-- Punchy scale-in, used any time a step's icon/image should feel
-- like it's "arriving" -- 0.5 -> 1 with Back easing overshoots
-- slightly past 1 before settling, which reads as a little bounce.
local function popIn(scale)
	if not scale then return end
	scale.Scale = 0.5
	TweenService:Create(scale, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		Scale = 1,
	}):Play()
end

-- Slide-up + fade-in, used for the text so each step's words feel
-- like they're settling into place rather than just instantly
-- appearing. originalPosition captured once below (before any
-- animation ever runs) so repeated calls always slide up from the
-- same starting offset instead of drifting.
local titleOriginalPosition = titleLabel.Position
local messageOriginalPosition = messageLabel.Position

local function slideFadeIn(label, originalPosition)
	label.Position = originalPosition + UDim2.fromOffset(0, 10)
	label.TextTransparency = 1
	TweenService:Create(label, TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Position = originalPosition,
		TextTransparency = 0,
	}):Play()
end

-- Idle bob for the step image -- small continuous up/down float so
-- the card feels alive even while the player's just reading, not
-- just on step-change. Infinite + Reverses gives a smooth back-and-
-- forth for free, no manual loop needed. Only created if StepImage
-- exists; Play()'d in openTutorial, Cancel()'d in closeTutorial so it
-- isn't silently running (and retweening a hidden object) forever.
local imageIdleTween = nil
if stepImage then
	imageIdleTween = TweenService:Create(
		stepImage,
		TweenInfo.new(1.3, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
		{ Position = stepImage.Position + UDim2.fromOffset(0, 8) }
	)
end

local remotes = ReplicatedStorage:WaitForChild("Remotes")
local showTutorial = remotes:WaitForChild("ShowTutorial")

--------------------------------------------------
-- CONTENT (kept in sync with the installer's TUTORIAL_STEPS)
--------------------------------------------------

-- Image: paste your own rbxassetid:// here once you've uploaded a
-- screenshot/illustration for that step (Studio > Asset Manager >
-- Images, or the Toolbox). Left as "" (blank) for now -- StepImage
-- just stays hidden for any step that doesn't have one yet, so this
-- won't break before you've added art for every step.
local TUTORIAL_STEPS = {
	{ Icon = "?", Title = "Charge Up", Image = "rbxassetid://123339983459026",
		Message = "Tap the button to start charging! Keep a steady rhythm for more Energy." },
	{ Icon = "??", Title = "Equip a Launch Cannon", Image = "rbxassetid://75603162505084",
		Message = "Equip one in the shop -- it decides how far your blast sends you." },
	{ Icon = "??", Title = "Reach the Moon", Image = "rbxassetid://103725497535891",
		Message = "Keep pushing and reach the karman line to earn Travels." },
	{ Icon = "??", Title = "Talk to NPCs", Image = "rbxassetid://105101157419059",
		Message = "Press E near an NPC to talk." },
	{ Icon = "??", Title = "Launch & Upgrade", Image = "rbxassetid://134232481948573",
		Message = "Step into the tube to launch! Fly higher for more Cash." },
}

local COLOR_DOT_ON = Color3.fromRGB(255, 210, 90)
local COLOR_DOT_OFF = Color3.fromRGB(70, 60, 95)
local BLUR_SIZE = 14

--------------------------------------------------
-- BLUR
--------------------------------------------------

local blur = Lighting:FindFirstChild("TutorialBlur")
if not blur then
	blur = Instance.new("BlurEffect")
	blur.Name = "TutorialBlur"
	blur.Size = 0
	blur.Parent = Lighting
end

--------------------------------------------------
-- STEP DISPLAY
--------------------------------------------------

local currentStep = 1

local function refreshDots()
	for i = 1, #TUTORIAL_STEPS do
		local dot = dotsRow:FindFirstChild("Dot" .. i)
		if dot then
			local wasOn = dot.BackgroundColor3 == COLOR_DOT_ON
			local isOn = (i == currentStep)
			dot.BackgroundColor3 = isOn and COLOR_DOT_ON or COLOR_DOT_OFF

			if isOn and not wasOn then
				popIn(getOrCreateScale(dot))
			end
		end
	end
end

local function showStep(index)

	currentStep = index
	local step = TUTORIAL_STEPS[index]

	iconLabel.Text = step.Icon
	titleLabel.Text = step.Title
	messageLabel.Text = step.Message

	popIn(iconScale)
	slideFadeIn(titleLabel, titleOriginalPosition)
	slideFadeIn(messageLabel, messageOriginalPosition)

	-- StepImage: only show/animate it for steps that actually have
	-- one set (Image ~= "") -- keeps older/unfinished steps from
	-- showing a broken/blank image box.
	if stepImage then
		if step.Image ~= "" then
			stepImage.Image = step.Image
			stepImage.Visible = true
			popIn(imageScale)
		else
			stepImage.Visible = false
		end
	end

	nextButton.Text = (index == #TUTORIAL_STEPS) and "Let's Go!" or "Next"

	refreshDots()
end

--------------------------------------------------
-- OPEN / CLOSE
--------------------------------------------------

local originalSize = card.Size
local isOpen = false

local function closeTutorial()

	if not isOpen then
		return
	end
	isOpen = false

	TweenService:Create(card, TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
		Size = UDim2.new(originalSize.X.Scale, 0, 0, 0),
		BackgroundTransparency = 1,
	}):Play()

	TweenService:Create(blur, TweenInfo.new(0.25), { Size = 0 }):Play()

	if imageIdleTween then
		imageIdleTween:Cancel()
	end

	task.delay(0.18, function()
		if not isOpen then
			card.Visible = false
		end
	end)
end

local function openTutorial()

	isOpen = true
	card.Visible = true
	card.BackgroundTransparency = 0
	card.Size = UDim2.new(originalSize.X.Scale, 0, 0, 0)

	showStep(1)

	TweenService:Create(card, TweenInfo.new(0.4, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		Size = originalSize,
	}):Play()

	TweenService:Create(blur, TweenInfo.new(0.3), { Size = BLUR_SIZE }):Play()

	if imageIdleTween then
		imageIdleTween:Play()
	end
end

--------------------------------------------------
-- GUIDED WALKTHROUGH -- runs once, right after the player finishes
-- (not skips) the slide tutorial. Step 1 points at StartCharge
-- until they tap it (doesn't care what that button's own click
-- handler does -- just listens alongside it). Step 2 then points a
-- Beam from the player to the LaunchZone part inside whichever
-- LocalTubeSkin currently exists, auto-following the player for
-- free since Beams track their Attachments live with no per-frame
-- code needed -- until they actually touch it, or 60s pass.
--------------------------------------------------

local GUIDE_COLOR = Color3.fromRGB(255, 210, 90)
local GUIDE_DARK = Color3.fromRGB(20, 15, 30)

-- Own ScreenGui with a very high DisplayOrder so the pointer always
-- renders above every other bit of UI, no matter what -- this is
-- what actually fixes it showing up behind things like the
-- OVERCHARGE bar. A ZIndex bump alone can't fix that since ZIndex
-- only resolves ordering WITHIN one ScreenGui -- across different
-- ScreenGuis, DisplayOrder is what decides which one draws on top.
local guideGui = playerGui:FindFirstChild("TutorialGuideGui")
if not guideGui then
	guideGui = Instance.new("ScreenGui")
	guideGui.Name = "TutorialGuideGui"
	guideGui.DisplayOrder = 1000
	guideGui.IgnoreGuiInset = false
	guideGui.ResetOnSpawn = false
	guideGui.Parent = playerGui
end

local function createPointerArrow(targetButton, caption)

	local absPos = targetButton.AbsolutePosition
	local absSize = targetButton.AbsoluteSize

	local pointer = Instance.new("Frame")
	pointer.Name = "TutorialGuidePointer"
	pointer.AnchorPoint = Vector2.new(0.5, 1)
	pointer.Position = UDim2.fromOffset(absPos.X + absSize.X / 2, absPos.Y - 8)
	pointer.Size = UDim2.fromOffset(0, 0)
	pointer.BackgroundTransparency = 1
	pointer.ZIndex = 50
	pointer.Parent = guideGui

	local arrowLabel = Instance.new("TextLabel")
	arrowLabel.Name = "Arrow"
	arrowLabel.AnchorPoint = Vector2.new(0.5, 1)
	arrowLabel.Position = UDim2.new(0.5, 0, 0, 0)
	arrowLabel.Size = UDim2.fromOffset(40, 40)
	arrowLabel.BackgroundTransparency = 1
	arrowLabel.Font = Enum.Font.GothamBlack
	arrowLabel.TextScaled = true
	arrowLabel.TextColor3 = GUIDE_COLOR
	arrowLabel.TextStrokeTransparency = 0.3
	arrowLabel.Text = "\xE2\x96\xBC" -- ¡
	arrowLabel.ZIndex = 51
	arrowLabel.Parent = pointer

	local captionLabel = Instance.new("TextLabel")
	captionLabel.Name = "Caption"
	captionLabel.AnchorPoint = Vector2.new(0.5, 1)
	captionLabel.Position = UDim2.new(0.5, 0, 0, -40)
	captionLabel.Size = UDim2.fromOffset(220, 30)
	captionLabel.BackgroundColor3 = GUIDE_DARK
	captionLabel.BackgroundTransparency = 0.15
	captionLabel.Font = Enum.Font.GothamBold
	captionLabel.TextScaled = true
	captionLabel.TextColor3 = Color3.new(1, 1, 1)
	captionLabel.Text = caption
	captionLabel.ZIndex = 51
	captionLabel.Parent = pointer

	local captionCorner = Instance.new("UICorner")
	captionCorner.CornerRadius = UDim.new(1, 0)
	captionCorner.Parent = captionLabel

	-- bounce loop, stops itself once the pointer gets destroyed
	task.spawn(function()
		while pointer.Parent do

			local down = TweenService:Create(arrowLabel, TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut), { Position = UDim2.new(0.5, 0, 0, 10) })
			local up = TweenService:Create(arrowLabel, TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut), { Position = UDim2.new(0.5, 0, 0, 0) })

			down:Play()
			down.Completed:Wait()
			if not pointer.Parent then break end
			up:Play()
			up.Completed:Wait()
		end
	end)

	return pointer
end

-- Shared beam-pointer: Attachment on the player + Attachment on
-- targetPart + a Beam between them (auto-follows the player live,
-- no per-frame code needed). Cleans up on arrival (or a 60s safety
-- timeout if they wander off) and calls onArrived -- but only on
-- actual arrival, never on timeout, so a distracted player doesn't
-- get force-marched into the next step.
--
-- wireCompletion (optional): a function(onComplete) that wires up
-- its OWN way of detecting "arrived" instead of targetPart.Touched,
-- and returns the Connection it made (so this function can still
-- disconnect it on cleanup/timeout). Needed for any targetPart that
-- can't reliably fire .Touched itself -- e.g. a cosmetic tube skin
-- clone, which has CanTouch = false on every part on purpose (see
-- TubeSkinClient.lua) so it can never interfere with the REAL
-- launch tube's collision. Default (no wireCompletion) still just
-- uses targetPart.Touched, which is fine for a normal real part.
local function pointBeamAt(targetPart, labelText, onArrived, wireCompletion)

	local character = player.Character or player.CharacterAdded:Wait()
	local hrp = character:WaitForChild("HumanoidRootPart")

	local originAttachment = Instance.new("Attachment")
	originAttachment.Name = "TutorialGuideOrigin"
	originAttachment.Parent = hrp

	local targetAttachment = Instance.new("Attachment")
	targetAttachment.Name = "TutorialGuideTarget"
	targetAttachment.Parent = targetPart

	local beam = Instance.new("Beam")
	beam.Name = "TutorialGuideBeam"
	beam.Attachment0 = originAttachment
	beam.Attachment1 = targetAttachment
	beam.Width0 = 1.2
	beam.Width1 = 0.4
	beam.Color = ColorSequence.new(GUIDE_COLOR)
	beam.Transparency = NumberSequence.new(0.2)
	beam.FaceCamera = true
	-- TODO: paste a real arrow-chevron texture id here (plus
	-- TextureMode = Enum.TextureMode.Wrap and a nonzero TextureSpeed)
	-- for actual flowing arrows along the beam -- left as a plain
	-- glowing beam for now since no arrow asset exists yet.
	beam.Parent = originAttachment

	local billboard = Instance.new("BillboardGui")
	billboard.Name = "TutorialGuideLabel"
	billboard.Adornee = targetAttachment
	billboard.Size = UDim2.fromOffset(200, 40)
	billboard.StudsOffset = Vector3.new(0, 3, 0)
	billboard.AlwaysOnTop = true
	billboard.Parent = targetAttachment

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundColor3 = GUIDE_DARK
	label.BackgroundTransparency = 0.15
	label.Font = Enum.Font.GothamBlack
	label.TextScaled = true
	label.TextColor3 = GUIDE_COLOR
	label.Text = labelText
	label.Parent = billboard

	local labelCorner = Instance.new("UICorner")
	labelCorner.CornerRadius = UDim.new(0, 8)
	labelCorner.Parent = label

	local touchConn
	local altConn
	local done = false

	local function cleanup()
		if done then return end
		done = true
		if touchConn then
			touchConn:Disconnect()
		end
		if altConn then
			altConn:Disconnect()
		end
		originAttachment:Destroy() -- also destroys the Beam (parented to it)
		targetAttachment:Destroy() -- also destroys the BillboardGui (adorned to it)
	end

	if wireCompletion then

		altConn = wireCompletion(function()
			cleanup()
			if onArrived then
				onArrived()
			end
		end)

	else

		touchConn = targetPart.Touched:Connect(function(hit)
			local touchedCharacter = hit:FindFirstAncestorOfClass("Model")
			if touchedCharacter == player.Character then
				cleanup()
				if onArrived then
					onArrived()
				end
			end
		end)
	end

	task.delay(60, cleanup)
end

--------------------------------------------------
-- STEP 3: shop area (Workspace.Earth.Part) -- final step, no
-- onArrived chain after this one.
--------------------------------------------------

local function pointToShop()

	local earthFolder = Workspace:FindFirstChild("Earth")
	local targetPart = earthFolder and earthFolder:FindFirstChild("Part")

	if not targetPart or not targetPart:IsA("BasePart") then
		return -- bail quietly rather than hard-error mid-tutorial
	end

	pointBeamAt(targetPart, "Buy upgrades here!")
end

--------------------------------------------------
-- STEP 2: launch tube -- chains into pointToShop once they actually
-- launch. Detected via the "Launching" attribute (set true by
-- LaunchTubeServer the instant a real launch starts) rather than
-- touching targetPart directly -- targetPart lives inside the
-- cosmetic LocalTubeSkin clone, which has CanTouch = false on every
-- part by design, so its own .Touched can never fire. This also
-- means the beam correctly detects a real launch no matter which
-- Launch Control skin is currently equipped/visible.
--------------------------------------------------

local function pointToLaunchTube()

	local tubeSkin = Workspace:FindFirstChild("LocalTubeSkin")
	if not tubeSkin then
		return -- not spawned in for some reason -- bail quietly rather than hard-error mid-tutorial
	end

	local targetPart = tubeSkin:FindFirstChild("BasePad") or tubeSkin:FindFirstChild("LaunchZone")
	if not targetPart or not targetPart:IsA("BasePart") then
		return
	end

	pointBeamAt(targetPart, "Launch here to earn Coins!", pointToShop, function(onComplete)
		return player:GetAttributeChangedSignal("Launching"):Connect(function()
			if player:GetAttribute("Launching") then
				onComplete()
			end
		end)
	end)
end

local guideStarted = false

local function startGuide()

	if guideStarted then
		return
	end
	guideStarted = true

	local pointer = createPointerArrow(startChargeButton, "Tap to start charging!")

	local connection
	connection = startChargeButton.Activated:Connect(function()
		connection:Disconnect()
		pointer:Destroy()
		pointToLaunchTube()
	end)
end

--------------------------------------------------
-- BUTTONS
--------------------------------------------------

nextButton.Activated:Connect(function()
	if currentStep < #TUTORIAL_STEPS then
		showStep(currentStep + 1)
	else
		closeTutorial()
		startGuide()
	end
end)

skipButton.Activated:Connect(function()
	closeTutorial()
	startGuide() -- skipping the slides shouldn't skip the actual in-world guidance too
end)

--------------------------------------------------
-- TRIGGER
--------------------------------------------------

showTutorial.OnClientEvent:Connect(function()
	openTutorial()
end)
