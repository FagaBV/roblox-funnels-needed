--------------------------------------------------
-- LaunchTubeServer (Script, ServerScriptService)
-- Detects LaunchZone touches, sucks the player into the tube,
-- SLOWLY charges them up to the top of the tube (with continuous
-- VFX), then blasts them out into the flight arc. Landing drifts
-- them forward so they don't come down back inside LaunchZone,
-- and re-entering LaunchZone after landing does nothing until
-- they've actually left it once.
--------------------------------------------------

local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local modules = ReplicatedStorage:WaitForChild("Modules")
local LaunchConfig = require(modules:WaitForChild("LaunchConfig"))
local TrailConfig = require(modules:WaitForChild("TrailConfig"))
local OverchargeConfig = require(modules:WaitForChild("OverchargeConfig"))
local PetConfig = require(modules:WaitForChild("PetConfig"))

local PlayerDataService = require(ServerScriptService.Modules:WaitForChild("PlayerDataService"))

local remotes = ReplicatedStorage:WaitForChild("Remotes")
local launchEffect = remotes:FindFirstChild("LaunchEffect")
if not launchEffect then
	launchEffect = Instance.new("RemoteEvent")
	launchEffect.Name = "LaunchEffect"
	launchEffect.Parent = remotes
end

local tube = Workspace:WaitForChild("GlassTube")
local launchZone = tube:WaitForChild("LaunchZone")
local launchCenter = tube:WaitForChild("LaunchCenter")
local basePad = tube:WaitForChild("BasePad")
local blastSound = basePad:WaitForChild("BlastSound")

-- TODO: add a Part or Attachment named "TubeTop" inside GlassTube,
-- positioned at the mouth of the tube -- that's where the charge-
-- rise ends and the real launch happens. Falls back to a flat
-- offset above LaunchCenter until you add it, so nothing errors,
-- but it won't line up with your actual tube model until you do.
local tubeTop = tube:FindFirstChild("TubeTop")
local FALLBACK_TUBE_HEIGHT = 20

local function getTubeTopPosition()
	if tubeTop then
		return tubeTop.Position
	end
	return launchCenter.Position + Vector3.new(0, FALLBACK_TUBE_HEIGHT, 0)
end

-- Finds the actual ground Y below a given X/Z by raycasting straight
-- down from high above it. getTubeTopPosition() is elevated (top of
-- the tube) -- landingPosition below is only ever meant to use its
-- X/Z, never its Y, or the character/landing effects end up floating
-- at tube height instead of on the ground.
local RAYCAST_START_HEIGHT = 500
local LANDING_Y_PADDING = 3 -- HumanoidRootPart sits ~3 studs above the feet -- keeps them from clipping into the ground

local function findGroundPosition(horizontalPosition, ignoreInstances)

	local origin = Vector3.new(
		horizontalPosition.X,
		horizontalPosition.Y + RAYCAST_START_HEIGHT,
		horizontalPosition.Z
	)

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = ignoreInstances or {}

	local result = Workspace:Raycast(origin, Vector3.new(0, -RAYCAST_START_HEIGHT * 2, 0), params)

	if result then
		return Vector3.new(horizontalPosition.X, result.Position.Y + LANDING_Y_PADDING, horizontalPosition.Z)
	end

	-- Nothing hit (shouldn't normally happen) -- fall back to the
	-- original guess rather than erroring.
	return horizontalPosition
end

--------------------------------------------------
-- CONFIG
--------------------------------------------------

local SUCK_IN_TIME = 0.6
local CHARGE_RISE_TIME = 1 -- slow climb up the tube before the actual launch
local BLAST_DELAY = 0.15

-- Flight height/duration scale with the equipped Launch Control's
-- FlightMult (x1 - x500). NOTE: this is a scripted arc, not physics --
-- real gravity can't produce 35-45s cinematic flights without absurd
-- velocities, so height is just directly animated over time.
local BASE_MAX_HEIGHT = 500   -- displayed height units at FlightMult = 1

-- IMPORTANT:
-- The player does NOT need to physically travel 100,000 Roblox studs.
-- That enormous physical distance is what can trigger StreamingEnabled
-- content-loading pauses on the client.
--
-- Keep the gameplay/UI height in the original units, but compress the
-- physical character movement into a compressed vertical corridor:
--   100,000 displayed height -> 20,000 Roblox studs
--   (WORLD_HEIGHT_SCALE = 0.2)
--
-- Rewards and the Height attribute still use the displayed height.
local WORLD_HEIGHT_SCALE = 0.2
local BASE_DURATION = 6       -- seconds up+down, at FlightMult = 1
local MAX_DURATION = 40       -- cap so top-tier launches don't run forever

-- HEIGHT SAFETY / ENDGAME CAP
-- The flight is a scripted arc, so maxHeight is the actual peak.
-- Keep the normal gameplay target at 100,000 and NEVER allow the
-- scripted arc to request more than 105,000.
local TARGET_MAX_HEIGHT = 100000
-- HARD LIMIT: 100,000 displayed height units is the absolute ceiling.
-- With WORLD_HEIGHT_SCALE = 0.2 this equals exactly 20,000 Roblox studs
-- above TubeTop. No energy, trail, pet, or FlightMult can exceed it.
local ABSOLUTE_MAX_HEIGHT = TARGET_MAX_HEIGHT

-- Energy is allowed to make launches stronger, but it must not be
-- able to turn an otherwise reasonable Launch Control into a
-- hundreds-of-thousands-height launch.
local ENERGY_FOR_DOUBLE_HEIGHT = 5000
local MAX_ENERGY_HEIGHT_MULT = 10

-- How far forward (studs, along LaunchCenter's LookVector) the
-- player drifts over the course of the flight, so they land clear
-- of the tube/LaunchZone instead of dropping straight back into it.
-- Increase this if your LaunchZone footprint is bigger than ~15 studs.
local LANDING_FORWARD_OFFSET = 20

-- Energy boosts flight height, but the multiplier is capped above.
-- true: launching also resets your Energy to 0 (spends it, like a
-- fuel cost -- but this also resets your progress toward the next
-- Overcharge level, since that threshold is checked against the
-- same Energy value). false: Energy just boosts height and is
-- left alone, so it keeps building toward Overcharge too.
local CONSUME_ENERGY_ON_LAUNCH = false

local DEFAULT_LAUNCH_CONTROL_FLIGHT_MULT = 1
local DEFAULT_VFX_COLOR = Color3.fromRGB(205, 144, 2)
-- Built-in Roblox particle texture (rbxasset://, ships with every
-- place -- no upload needed) so the boom is ALWAYS visible even if
-- LaunchConfig's VFX fields aren't resolving. If you see this
-- generic sparkle instead of your own VFX, that confirms the
-- fallback is being used -- see the DEBUG_VFX warnings below.
local DEFAULT_VFX_TEXTURE = "rbxasset://textures/particles/sparkles_main.dds"

-- Prints exactly what color/texture/config each launch resolved to
-- Output, so you can tell at a glance whether your LaunchConfig
-- fields are actually being found. Set to false once it's working.
local DEBUG_VFX = false

-- Time-based safety net in case TouchEnded doesn't fire (e.g. the
-- character got destroyed instead of walking out normally). The
-- REAL gate is "must leave LaunchZone, then re-enter it" -- see
-- awaitingExit below.
local RELAUNCH_COOLDOWN = 2

local BASE_CASH_PER_HEIGHT = 0.25
local REWARD_UPDATE_INTERVAL = 0.1

-- The boom burst's look (particle count/speed/lifetime) now lives
-- in LaunchBoomClient.lua since that's where it actually renders --
-- nothing left to configure here.

--------------------------------------------------
-- FLIP ANIMATIONS
-- TODO: replace with your published animation IDs (Studio >
-- Animation Editor > Publish gives you the rbxassetid://).
-- LaunchFlip plays the instant they blast off and freezes at
-- LAUNCH_FLIP_HOLD_TIME, holding that exact pose. FallFlip plays
-- from the apex (see runFlight below) and freezes at
-- FALL_FLIP_HOLD_TIME, holding ITS pose for the rest of the descent.
-- Both are built once here and reused for every launch.
--------------------------------------------------

local LAUNCH_FLIP_ANIMATION_ID = "rbxassetid://90114874875076"
local FALL_FLIP_ANIMATION_ID = "rbxassetid://81984168473095"

-- Playback speed multiplier -- 1 = exactly the timing you keyframed,
-- lower = plays slower/longer without touching the animation itself
-- (e.g. 0.5 takes twice as long, same motion start to finish).
local LAUNCH_FLIP_SPEED = 1.5
local FALL_FLIP_SPEED = 0.3

-- Time (in SECONDS, on the animation's own timeline -- same units
-- shown on the Animation Editor's scrubber, unaffected by the speed
-- multipliers above) where each animation should freeze and hold
-- that exact pose, instead of looping or playing to its natural end.
-- Scrub each animation in the Animation Editor to find these:
--   LAUNCH_FLIP_HOLD_TIME -- the frame in LaunchFlip whose pose
--     already matches FallFlip's very first frame, so switching
--     tracks reads as one continuous motion instead of a visible snap.
--   FALL_FLIP_HOLD_TIME -- the frame in FallFlip where it should
--     stop rotating and just hold for the rest of the descent.
local LAUNCH_FLIP_HOLD_TIME = 4.16 -- TODO: tune to your animation
local FALL_FLIP_HOLD_TIME = 6.29 -- TODO: tune to your animation

local launchFlipAnimation = Instance.new("Animation")
launchFlipAnimation.Name = "LaunchFlip"
launchFlipAnimation.AnimationId = LAUNCH_FLIP_ANIMATION_ID

local fallFlipAnimation = Instance.new("Animation")
fallFlipAnimation.Name = "FallFlip"
fallFlipAnimation.AnimationId = FALL_FLIP_ANIMATION_ID

-- Loads and plays one of the two animations above on a character.
-- Priority = Action so it properly overrides the default idle/walk
-- animation while held -- IMPORTANT: because of that, whatever
-- calls this is responsible for :Stop()-ing the returned track once
-- the player lands, or they'll keep holding their frozen pose forever.
-- See the RESTORE CONTROL section in launchPlayer.
local function playFlipAnimation(humanoid, animation, speed, holdTime)

	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = humanoid
	end

	local ok, track = pcall(function()
		return animator:LoadAnimation(animation)
	end)

	if not ok or not track then
		if DEBUG_VFX then
			warn("[LaunchTubeServer] Failed to load " .. animation.Name .. " animation: " .. tostring(track))
		end
		return nil
	end

	track.Priority = Enum.AnimationPriority.Action
	track.Looped = false
	track:Play(0.1, 1, speed or 1)

	-- Freeze exactly at holdTime (in the animation's own timeline,
	-- not real elapsed seconds -- unaffected by the speed multiplier)
	-- instead of looping or letting it play to its natural end.
	-- AdjustSpeed(0) stops it from advancing any further while
	-- leaving it visually holding whatever pose it's at right then.
	if holdTime then
		task.spawn(function()
			while track.IsPlaying and track.TimePosition < holdTime do
				task.wait()
			end
			if track.IsPlaying then
				track:AdjustSpeed(0)
			end
		end)
	end

	return track
end

--------------------------------------------------
-- STATE
--------------------------------------------------

local launching = {} -- [player] = true while mid-sequence
local lastLanded = {} -- [player] = os.clock() timestamp of their last landing
local awaitingExit = {} -- [player] = true until they've left LaunchZone since their last landing

local function getEquippedLaunchConfig(player)
	local ok, equippedId = pcall(function()
		return PlayerDataService.GetEquippedLaunchControl(player)
	end)

	if not ok and DEBUG_VFX then
		warn("[LaunchTubeServer] PlayerDataService.GetEquippedLaunchControl errored: " .. tostring(equippedId))
	end

	if ok and equippedId and LaunchConfig[equippedId] then
		return LaunchConfig[equippedId]
	end

	if DEBUG_VFX and ok then
		warn("[LaunchTubeServer] Equipped Launch Control id '" .. tostring(equippedId)
			.. "' has no matching entry in LaunchConfig -- using all defaults (gray, no flight/cash bonus).")
	end

	return nil
end

local function getFlightMult(player)
	local launch = getEquippedLaunchConfig(player)
	local baseMult = (launch and launch.FlightMult) or DEFAULT_LAUNCH_CONTROL_FLIGHT_MULT
	local potionMult = PlayerDataService.GetBuffMultiplier(player, "FlightMult")
	return baseMult * potionMult
end

local function getVFXColor(player)
	local launch = getEquippedLaunchConfig(player)

	if DEBUG_VFX and launch and not launch.VFXColor then
		warn("[LaunchTubeServer] Equipped Launch Control has no .VFXColor field -- using default gray. "
			.. "Check the field name in LaunchConfig matches 'VFXColor' exactly.")
	end

	return (launch and launch.VFXColor) or DEFAULT_VFX_COLOR
end

local function getVFXTexture(player)
	local launch = getEquippedLaunchConfig(player)
	local assetId = launch and launch.VFXAssetId

	if DEBUG_VFX and launch and (not assetId or assetId == 0) then
		warn("[LaunchTubeServer] Equipped Launch Control has no usable .VFXAssetId (got "
			.. tostring(assetId) .. ") -- using the built-in fallback sparkle texture. "
			.. "Check the field name/value in LaunchConfig matches 'VFXAssetId' exactly.")
	end

	if assetId and assetId ~= 0 then
		return "rbxassetid://" .. tostring(assetId)
	end

	return DEFAULT_VFX_TEXTURE
end

--------------------------------------------------
-- HEIGHT CASH MULTIPLIER STACK (unchanged)
--------------------------------------------------

local function getOverchargeCashMult(player)
	local ok, level = pcall(function()
		return PlayerDataService.GetOverchargeLevel(player)
	end)
	if not ok or not level then
		return 1
	end
	local oc = OverchargeConfig[level] or OverchargeConfig[1]
	return (oc and oc.CashMult) or 1
end

local function getTrailCashMult(player)
	local ok, equippedId = pcall(function()
		return PlayerDataService.GetEquippedTrail(player)
	end)
	if ok and equippedId and TrailConfig[equippedId] then
		return TrailConfig[equippedId].CashMult or 1
	end
	return 1
end

local function getLaunchCashMult(player)
	local launch = getEquippedLaunchConfig(player)
	return (launch and launch.CashMult) or 1
end

-- Now wired up to the real Pet system (EggServer/PlayerDataService).
local function getPetCashMult(player)

	local ok, equippedId = pcall(function()
		return PlayerDataService.GetEquippedPet(player)
	end)

	if ok and equippedId and PetConfig[equippedId] then
		return PetConfig[equippedId].CashMult or 1
	end

	return 1
end

local function getHeightCashMultiplier(player)
	return getOverchargeCashMult(player)
		* getTrailCashMult(player)
		* getLaunchCashMult(player)
		* getPetCashMult(player)
		* PlayerDataService.GetBuffMultiplier(player, "CashMult")
end

--------------------------------------------------
-- BOOM AT TUBETOP
-- IMPORTANT: ParticleEmitter:Emit() does NOT replicate server ->
-- client. Calling it here (in a server Script) only "emits" inside
-- the server's own headless simulation, which never renders
-- anything to anyone -- that's why the old version logged every
-- step perfectly and still showed nothing. This function no longer
-- builds any Part/Attachment/ParticleEmitter at all -- it just
-- resolves what the burst SHOULD look like (server-authoritative,
-- since it depends on the equipped Launch Control) and sends that
-- to every client. The actual Part+Attachment+ParticleEmitter+Emit
-- now lives in LaunchBoomClient.lua, which is where it can
-- actually be seen.
--------------------------------------------------

local function fireBoomAtTubeTop(player)

	local color = getVFXColor(player)
	local texture = getVFXTexture(player)
	local position = getTubeTopPosition()

	if DEBUG_VFX then
		print(string.format(
			"[LaunchTubeServer] Boom firing for %s -- color=(%d,%d,%d) texture=%s pos=%s",
			player.Name, color.R * 255, color.G * 255, color.B * 255, texture, tostring(position)
			))
	end

	blastSound:Play() -- Sound.Play() DOES replicate from the server, unlike ParticleEmitter:Emit()

	-- Broadcast to everyone, not just the launching player, so people
	-- standing near the tube see each other launch too. The Player
	-- field lets each client tell whether THIS is their own launch --
	-- used client-side to keep the wind sound local-only while the
	-- boom visuals still show for everyone. If you'd rather only the
	-- launching player sees the boom too, swap this loop for a
	-- single `launchEffect:FireClient(player, payload)`.
	local payload = {
		Type = "Blast",
		Player = player.UserId,
		Color = { color.R, color.G, color.B },
		Texture = texture,
		Position = { position.X, position.Y, position.Z },
	}

	for _, otherPlayer in ipairs(Players:GetPlayers()) do
		launchEffect:FireClient(otherPlayer, payload)
	end

	if DEBUG_VFX then
		print("[LaunchTubeServer] LaunchEffect broadcast to all clients for " .. player.Name)
	end
end

--------------------------------------------------
-- CHARGE-RISE
-- Slow climb from LaunchCenter up to TubeTop. Tube glow is
-- already running by the time this is called (started right when
-- the player entered, see launchPlayer below) and keeps running
-- through this -- this function just does the movement.
--------------------------------------------------

local function runChargeRise(hrp)

	local endPosition = getTubeTopPosition()

	local riseTween = TweenService:Create(
		hrp,
		TweenInfo.new(CHARGE_RISE_TIME, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
		{ CFrame = CFrame.new(endPosition) }
	)

	riseTween:Play()
	riseTween.Completed:Wait()
end

--------------------------------------------------
-- FLIGHT ARC
-- height(t) = maxHeight * sin(pi * t / duration) -- smooth up, smooth down.
-- Horizontal position drifts forward along LaunchCenter's
-- LookVector over the course of the flight, so landing happens
-- clear of the tube instead of straight back down into it.
--------------------------------------------------

local function runFlight(player, character, hrp, humanoid, maxHeight, duration, cashMultiplier, launchFlipTrack)

	local basePosition = getTubeTopPosition()
	local forwardDirection = launchCenter.CFrame.LookVector

	--------------------------------------------------
	-- PHYSICS PARAMETERS
	-- Real unanchored physics instead of a scripted CFrame-per-frame
	-- loop -- Roblox's own replication engine smoothly interpolates/
	-- extrapolates velocity-based motion for every observer
	-- automatically, which is what a hand-rolled broadcast+Lerp
	-- system was fighting to reproduce (and losing to, since it was
	-- racing against the raw property replication of the old
	-- Anchored CFrame writes).
	--
	-- Ascent gravity is derived so the character still reaches the
	-- exact same worldApexHeight at the exact same t = duration/2
	-- the old scripted arc used, keeping existing height/duration
	-- game balance intact. Descent deliberately uses a LOWER gravity
	-- than the ascent (FALL_GRAVITY_MULTIPLIER) for the explicitly
	-- requested "falls slower" floaty feel -- this does mean total
	-- airtime can run a bit longer than `duration`, which is fine:
	-- reward is based purely on peak height reached, never on total
	-- flight time.
	--------------------------------------------------

	local worldApexHeight = maxHeight * WORLD_HEIGHT_SCALE
	local tApex = duration / 2

	local riseGravity = 8 * worldApexHeight / (duration * duration)
	local v0y = 4 * worldApexHeight / duration

	local FALL_GRAVITY_MULTIPLIER = 0.4
	local fallGravity = riseGravity * FALL_GRAVITY_MULTIPLIER

	local v0Horizontal = forwardDirection * (LANDING_FORWARD_OFFSET / duration)

	--------------------------------------------------
	-- DISABLE COLLISION FOR THE WHOLE FLIGHT -- real unanchored
	-- physics could otherwise clip/bounce off trees, rocks, other
	-- players, terrain, etc. mid-air, which is exactly the "thrown
	-- around the map" risk. Restored right before this function
	-- returns, whether it lands normally or breaks out early.
	--------------------------------------------------

	local originalCanCollide = {}
	for _, part in ipairs(character:GetDescendants()) do
		if part:IsA("BasePart") then
			originalCanCollide[part] = part.CanCollide
			part.CanCollide = false
		end
	end

	local function restoreCollision()
		for part, wasCollidable in pairs(originalCanCollide) do
			if part.Parent then
				part.CanCollide = wasCollidable
			end
		end
	end

	--------------------------------------------------
	-- LAUNCH IMPULSE + LIFT FORCE
	--------------------------------------------------

	hrp.Anchored = false
	hrp.AssemblyLinearVelocity = v0Horizontal + Vector3.new(0, v0y, 0)

	local liftAttachment = Instance.new("Attachment")
	liftAttachment.Name = "FlightLiftAttachment"
	liftAttachment.Parent = hrp

	local lift = Instance.new("VectorForce")
	lift.Name = "FlightLift"
	lift.Attachment0 = liftAttachment
	lift.RelativeTo = Enum.ActuatorRelativeTo.World
	lift.ApplyAtCenterOfMass = true -- straight lift, no unwanted spin/torque from an off-center attachment
	lift.Parent = hrp

	-- Counteracts however much of Workspace.Gravity is needed to make
	-- the character's ACTUAL net downward acceleration equal `g`.
	local function setEffectiveGravity(g)
		local counterAccel = Workspace.Gravity - g
		lift.Force = Vector3.new(0, hrp.AssemblyMass * counterAccel, 0)
	end

	setEffectiveGravity(riseGravity)

	--------------------------------------------------
	-- FLIGHT LOOP
	--------------------------------------------------

	local peakHeight = 0
	local lastRewardUpdate = 0
	local finishedNormally = true

	local fallFlipTrack = nil
	local hasPlayedFallAnimation = false
	local pastApex = false

	-- Generous safety cap in case ground proximity is somehow never
	-- detected (stuck on geometry, etc.) -- forces a landing attempt
	-- regardless rather than looping forever.
	local SAFETY_TIMEOUT = duration * 3
	local startTime = os.clock()

	-- How close (studs) to the ground before handing off to the
	-- existing scripted landing in launchPlayer's RESTORE CONTROL,
	-- instead of letting real physics actually make contact. With
	-- collision already disabled above, this is mainly about a clean
	-- VISUAL handoff (no brief clip into terrain before the snap)
	-- rather than safety -- safety is already guaranteed by
	-- CanCollide = false, so there's no bounce/fling risk either way.
	local GROUND_HANDOFF_DISTANCE = 30

	-- A single distance threshold checked once per Heartbeat can't
	-- reliably catch an unbounded fall speed -- a tall enough flight
	-- (or any server lag stretching the frame interval) can cover
	-- more than GROUND_HANDOFF_DISTANCE in a single tick, so the
	-- character visually sinks into the terrain for a frame before
	-- the raycast below ever notices, and RESTORE CONTROL's landing
	-- snap then visibly pops them back up. MAX_FALL_SPEED caps
	-- descent speed outright; SOFT_LANDING_START_DISTANCE then tapers
	-- it down further on final approach, so GROUND_HANDOFF_DISTANCE
	-- always has enough margin to catch it within one frame
	-- regardless of how tall the flight was.
	local MAX_FALL_SPEED = 350 -- studs/sec, applied for the whole descent
	local SOFT_LANDING_START_DISTANCE = 140 -- studs from ground where the extra taper kicks in
	local SOFT_LANDING_MIN_SPEED = 40 -- studs/sec, the cap right at GROUND_HANDOFF_DISTANCE

	local groundRayParams = RaycastParams.new()
	groundRayParams.FilterType = Enum.RaycastFilterType.Exclude
	groundRayParams.FilterDescendantsInstances = { tube, character }

	while os.clock() - startTime < SAFETY_TIMEOUT do

		if not character.Parent or not hrp.Parent then
			finishedNormally = false
			break
		end

		local velocity = hrp.AssemblyLinearVelocity

		-- PlatformStand disables Roblox's built-in upright-stabilization
		-- for the whole flight -- with nothing else holding rotation
		-- steady, any tiny bit of incidental torque (solver jitter, the
		-- apex gravity swap, etc.) can start a slow uncontrolled tumble.
		-- Zeroing angular velocity every frame prevents it from ever
		-- accumulating, without touching the flip animations at all --
		-- those animate joints via the Animator/Motor6D system,
		-- completely separate from the root part's own raw physics
		-- angular velocity.
		hrp.AssemblyAngularVelocity = Vector3.zero

		if not pastApex and velocity.Y <= 0 then
			pastApex = true
			setEffectiveGravity(fallGravity)
		end

		-- Terminal velocity cap for the whole descent -- see the
		-- MAX_FALL_SPEED comment above for why a distance threshold
		-- alone can't safely catch an unbounded fall speed.
		if pastApex and velocity.Y < -MAX_FALL_SPEED then
			hrp.AssemblyLinearVelocity = Vector3.new(velocity.X, -MAX_FALL_SPEED, velocity.Z)
		end

		-- Play the falling flip right as they start to come back
		-- down -- velocity crossing zero is the real-physics
		-- equivalent of the old "progress >= 0.5" apex check.
		if not hasPlayedFallAnimation and pastApex then
			hasPlayedFallAnimation = true

			-- LaunchFlip is only for the ascent. Stop it before
			-- switching to the looping descent animation so the two
			-- Action tracks cannot fight over the same joints.
			if launchFlipTrack then
				launchFlipTrack:Stop(0.2)
			end

			fallFlipTrack = playFlipAnimation(humanoid, fallFlipAnimation, FALL_FLIP_SPEED, FALL_FLIP_HOLD_TIME)
		end

		local heightMeters = math.max(0, (hrp.Position.Y - basePosition.Y) / WORLD_HEIGHT_SCALE)

		-- ABSOLUTE PHYSICAL CEILING.
		-- maxHeight is already clamped, but physics can move the character
		-- several studs in one frame. Clamp the actual HRP position as a
		-- second line of defense so the player can never physically cross
		-- the 100,000-height boundary.
		if heightMeters >= ABSOLUTE_MAX_HEIGHT then
			local ceilingY = basePosition.Y + ABSOLUTE_MAX_HEIGHT * WORLD_HEIGHT_SCALE
			local position = hrp.Position

			if position.Y > ceilingY then
				hrp.CFrame =
					CFrame.new(position.X, ceilingY, position.Z)
					* hrp.CFrame.Rotation
			end

			local currentVelocity = hrp.AssemblyLinearVelocity
			if currentVelocity.Y > 0 then
				hrp.AssemblyLinearVelocity = Vector3.new(
					currentVelocity.X,
					0,
					currentVelocity.Z
				)
			end

			heightMeters = ABSOLUTE_MAX_HEIGHT
		end

		player:SetAttribute("Height", math.min(heightMeters, ABSOLUTE_MAX_HEIGHT))

		if heightMeters > peakHeight then
			peakHeight = heightMeters

			local now = os.clock()
			if now - lastRewardUpdate >= REWARD_UPDATE_INTERVAL then
				lastRewardUpdate = now
				if player.Parent then
					launchEffect:FireClient(player, {
						Type = "HeightCash",
						Amount = peakHeight * BASE_CASH_PER_HEIGHT * cashMultiplier,
						Final = false,
					})
				end
			end
		end

		-- Only worth raycasting for ground once actually descending --
		-- avoids wasted raycasts during the rise.
		if pastApex then
			local rayResult = Workspace:Raycast(hrp.Position, Vector3.new(0, -500, 0), groundRayParams)
			if rayResult then

				local distanceToGround = hrp.Position.Y - rayResult.Position.Y

				-- Soft-landing taper: the closer to the ground, the
				-- lower the fall-speed cap gets, down to
				-- SOFT_LANDING_MIN_SPEED right at the handoff point --
				-- a controlled final approach instead of relying on a
				-- single instant-handoff distance to catch whatever
				-- speed the character happened to still have.
				if distanceToGround <= SOFT_LANDING_START_DISTANCE then

					local t = math.clamp(distanceToGround / SOFT_LANDING_START_DISTANCE, 0, 1)
					local speedCap = SOFT_LANDING_MIN_SPEED + (MAX_FALL_SPEED - SOFT_LANDING_MIN_SPEED) * t

					local currentVelocity = hrp.AssemblyLinearVelocity
					if currentVelocity.Y < -speedCap then
						hrp.AssemblyLinearVelocity = Vector3.new(currentVelocity.X, -speedCap, currentVelocity.Z)
					end
				end

				if distanceToGround <= GROUND_HANDOFF_DISTANCE then
					break
				end
			end
		end

		RunService.Heartbeat:Wait()
	end

	--------------------------------------------------
	-- STOP PUSHING/LIFTING, RESTORE NORMAL COLLISION -- before
	-- handing back to RESTORE CONTROL in launchPlayer, which does the
	-- actual final anchor + precise ground snap.
	--------------------------------------------------

	lift:Destroy()
	liftAttachment:Destroy()
	restoreCollision()

	-- Without this, whatever residual fall speed the character still
	-- had at handoff would still be sitting on the part the instant
	-- RESTORE CONTROL snaps its CFrame to the ground and collision
	-- comes back -- a direct CFrame set doesn't clear velocity, so
	-- that leftover momentum would immediately jolt/bounce them right
	-- at the moment they're supposed to land cleanly.
	if hrp.Parent then
		hrp.AssemblyLinearVelocity = Vector3.zero
		hrp.AssemblyAngularVelocity = Vector3.zero
	end

	--------------------------------------------------
	-- GRANT THE REWARD
	--------------------------------------------------

	local finalCash = peakHeight * BASE_CASH_PER_HEIGHT * cashMultiplier

	-- Reset Height FIRST, before attempting to grant the reward below.
	-- AddCash was previously called before this reset with no pcall --
	-- if it ever threw (bad profile state, DataStore hiccup, etc.) the
	-- whole function halted right there, leaving Height (and this
	-- player's Launching/Flying state back in launchPlayer) stuck at
	-- whatever it was mid-flight, forever -- exactly the height meter
	-- bug this is fixing.
	if player.Parent then
		player:SetAttribute("Height", 0)
	end

	if finalCash > 0 then

		local addOk, addErr = pcall(function()
			PlayerDataService.AddCash(player, finalCash)
		end)

		if not addOk then
			warn("[LaunchTubeServer] AddCash failed (Height/state already reset, so this is safely contained): " .. tostring(addErr))
		elseif player.Parent then
			player:SetAttribute("Cash", PlayerDataService.GetCash(player))
		end

	end

	if player.Parent then

		launchEffect:FireClient(player, {
			Type = "HeightCash",
			Amount = finalCash,
			Final = true,
		})

	end

	return finishedNormally, fallFlipTrack
end

--------------------------------------------------
-- FULL SEQUENCE
--------------------------------------------------

local function launchPlayer(player)

	if DEBUG_VFX then
		print("[LaunchTubeServer] launchPlayer called for " .. player.Name)
	end

	if launching[player] then
		if DEBUG_VFX then print("[LaunchTubeServer] -> bailed: already launching") end
		return
	end

	local landedAt = lastLanded[player]
	if landedAt and os.clock() - landedAt < RELAUNCH_COOLDOWN then
		if DEBUG_VFX then print("[LaunchTubeServer] -> bailed: relaunch cooldown") end
		return
	end

	local character = player.Character
	if not character then return end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local hrp = character:FindFirstChild("HumanoidRootPart")
	if not humanoid or not hrp then return end

	launching[player] = true
	player:SetAttribute("Launching", true)

	--------------------------------------------------
	-- FREEZE CONTROL + SUCK IN
	--------------------------------------------------

	humanoid.PlatformStand = true
	hrp.Anchored = true

	local suckTween = TweenService:Create(
		hrp,
		TweenInfo.new(SUCK_IN_TIME, Enum.EasingStyle.Sine, Enum.EasingDirection.In),
		{ CFrame = CFrame.new(launchCenter.Position) }
	)
	suckTween:Play()
	suckTween.Completed:Wait()

	--------------------------------------------------
	-- CHARGE-RISE (slow climb up the tube, VFX running)
	--------------------------------------------------

	if hrp.Parent then
		runChargeRise(hrp)
	end

	--------------------------------------------------
	-- BOOM + LAUNCH (the actual "push as hard as possible", right at TubeTop)
	--------------------------------------------------

	-- "Flying" is narrower than "Launching" -- true only from this
	-- exact moment (reaching TubeTop) through landing, NOT during
	-- the suck-in/charge-rise. Anything that should only show once
	-- the player is actually airborne (e.g. TrailVFXClient's flight
	-- trail) watches this instead of Launching, so it doesn't
	-- attach early and end up visually "catching up" once the
	-- actual fast motion starts.
	player:SetAttribute("Flying", true)

	local boomOk, boomErr = pcall(fireBoomAtTubeTop, player)
	if not boomOk then
		warn("[LaunchTubeServer] fireBoomAtTubeTop errored (continuing the launch anyway): " .. tostring(boomErr))
	end

	task.wait(BLAST_DELAY)

	local flightMult = getFlightMult(player)

	local energy = math.max(0, player:GetAttribute("Energy") or 0)
	local energyHeightMult = math.min(
		1 + energy / ENERGY_FOR_DOUBLE_HEIGHT,
		MAX_ENERGY_HEIGHT_MULT
	)

	local rawMaxHeight = BASE_MAX_HEIGHT * flightMult * energyHeightMult

	-- HARD CLAMP.
	-- The displayed height can NEVER exceed 100,000.
	-- WORLD_HEIGHT_SCALE = 0.2 means the physical apex is:
	--     100,000 * 0.2 = 20,000 studs above TubeTop.
	-- Do not compress/soft-cap here: anything above the limit is simply
	-- discarded so every launch has the exact same absolute ceiling.
	local maxHeight = math.clamp(
		rawMaxHeight,
		0,
		ABSOLUTE_MAX_HEIGHT
	)

	-- Keep top-end flights from becoming an instant vertical teleport.
	-- The arc remains smooth; only the requested peak is capped.
	local duration = math.min(MAX_DURATION, BASE_DURATION * math.sqrt(math.max(1, flightMult)))
	local cashMultiplier = getHeightCashMultiplier(player)

	-- Preload the highest physical point of this flight.
	-- At the absolute cap this is exactly 20,000 studs above TubeTop.
	if Workspace.StreamingEnabled then
		task.spawn(function()
			pcall(function()
				local apexPosition = getTubeTopPosition()
					+ Vector3.new(0, maxHeight * WORLD_HEIGHT_SCALE, 0)
				player:RequestStreamAroundAsync(apexPosition, 8)
			end)
		end)
	end

	if DEBUG_VFX then
		print(string.format(
			"[LaunchTubeServer] Energy=%.0f -> energyHeightMult=%.3fx (flightMult=%.3fx) -> raw=%.1f -> peak=%.1f",
			energy, energyHeightMult, flightMult, rawMaxHeight, maxHeight
			))
	end

	if CONSUME_ENERGY_ON_LAUNCH then
		PlayerDataService.ResetEnergy(player)
		player:SetAttribute("Energy", 0)
	end

	local launchFlipTrack = playFlipAnimation(humanoid, launchFlipAnimation, LAUNCH_FLIP_SPEED, LAUNCH_FLIP_HOLD_TIME)

	local finished, fallFlipTrack = runFlight(player, character, hrp, humanoid, maxHeight, duration, cashMultiplier, launchFlipTrack)

	--------------------------------------------------
	-- RESTORE CONTROL
	--------------------------------------------------

	if finished and hrp.Parent then

		local landingXZ = getTubeTopPosition() + launchCenter.CFrame.LookVector * LANDING_FORWARD_OFFSET
		local landingPosition = findGroundPosition(landingXZ, { tube, character })

		hrp.CFrame = CFrame.new(landingPosition)
		hrp.Anchored = false
		humanoid.PlatformStand = false

		-- No FlightPositionUpdate broadcast needed anymore -- now
		-- that the flight itself is real unanchored physics, Roblox
		-- replicates hrp.Anchored/CFrame changes normally on its own,
		-- same as any other part.

		-- Stop whichever flip animation is still holding its pose --
		-- FallFlip if they made it to the apex, otherwise LaunchFlip
		-- (e.g. a very short flight). A short fade instead of an
		-- instant cut so it blends into the normal idle/walk animation.
		if fallFlipTrack then
			fallFlipTrack:Stop(0.3)
		elseif launchFlipTrack then
			launchFlipTrack:Stop(0.3)
		end

		-- Landing smoke -- actual particle burst happens client-side
		-- in LaunchBoomClient.lua (ParticleEmitter:Emit() has to run
		-- there, same reason the boom itself does). Broadcasting to
		-- everyone, matching how the boom itself broadcasts. Player
		-- field again lets the client keep the wind stop local-only.
		local landingPayload = {
			Type = "Landing",
			Player = player.UserId,
			Position = { landingPosition.X, landingPosition.Y, landingPosition.Z },
		}

		for _, otherPlayer in ipairs(Players:GetPlayers()) do
			launchEffect:FireClient(otherPlayer, landingPayload)
		end
	end

	launching[player] = nil
	player:SetAttribute("Launching", false)
	player:SetAttribute("Flying", false)
	lastLanded[player] = os.clock()
	awaitingExit[player] = true -- must leave LaunchZone before they can trigger it again
end

--------------------------------------------------
-- TOUCH DETECTION
--------------------------------------------------

launchZone.Touched:Connect(function(hit)

	local character = hit:FindFirstAncestorOfClass("Model")
	if not character then return end

	local player = Players:GetPlayerFromCharacter(character)
	if not player then return end

	if awaitingExit[player] then
		if DEBUG_VFX then print("[LaunchTubeServer] Touched ignored for " .. player.Name .. " -- awaitingExit is true") end
		return -- landed here before, hasn't actually left the zone yet
	end

	launchPlayer(player)
end)

launchZone.TouchEnded:Connect(function(hit)

	local character = hit:FindFirstAncestorOfClass("Model")
	if not character then return end

	local player = Players:GetPlayerFromCharacter(character)
	if not player then return end

	awaitingExit[player] = false
end)

Players.PlayerRemoving:Connect(function(player)
	launching[player] = nil
	lastLanded[player] = nil
	awaitingExit[player] = nil
end)

--------------------------------------------------
-- PRELOAD THE LAUNCH ZONE
-- The flight itself is physically compressed to <= 1,050 studs.
-- We also request the apex region before the launch begins, so the
-- client is much less likely to hit a StreamingEnabled content-load
-- pause while the character is moving.
--------------------------------------------------

local PRELOAD_TIMEOUT = 10 -- seconds to wait for streaming before giving up

local function preloadLaunchZone(player)

	if not Workspace.StreamingEnabled then
		return -- nothing to preload -- everything's already loaded for everyone
	end

	task.spawn(function()
		local ok, err = pcall(function()
			player:RequestStreamAroundAsync(launchCenter.Position, PRELOAD_TIMEOUT)
		end)
		if not ok and DEBUG_VFX then
			warn("[LaunchTubeServer] RequestStreamAroundAsync failed for " .. player.Name .. ": " .. tostring(err))
		end
	end)
end

Players.PlayerAdded:Connect(function(player)

	preloadLaunchZone(player) -- as soon as they join, doesn't need a character

	player.CharacterAdded:Connect(function()
		preloadLaunchZone(player) -- cheap insurance on every (re)spawn too

		-- Safety net: a fresh spawn should never inherit a stuck
		-- Height/Launching/Flying value from a prior interrupted
		-- flight (e.g. the AddCash failure case fixed above, or a
		-- leftover DEMO_MODE test value). Skipped while an actual
		-- launch is mid-flight for this player so it can't stomp on
		-- a real in-progress sequence.
		if not launching[player] then
			player:SetAttribute("Height", 0)
			player:SetAttribute("Launching", false)
			player:SetAttribute("Flying", false)
		end
	end)
end)

for _, player in ipairs(Players:GetPlayers()) do
	preloadLaunchZone(player)
end