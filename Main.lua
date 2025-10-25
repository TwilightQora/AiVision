-- services (yeah, the usual)
local Players            = game:GetService("Players")          -- player list
local RunService         = game:GetService("RunService")       -- heartbeat/render
local Workspace          = game:GetService("Workspace")        -- world root
local CollectionService  = game:GetService("CollectionService")-- tags
local TweenService       = game:GetService("TweenService")     -- tweening overlays

-- ---------- defaults ----------
-- baseline config;
local DEFAULTS = {
	aiName = "AI",                     -- try to bind by this name if no instance passed
	detectionRange = 120,              -- how far we care
	detectionShape = "cube",           -- "cube" or "sphere"
	useFov = true,                     -- respect FOV or not
	fovDegrees = 120,                  -- meh, wide

	includeNPCs = true,                -- scan loose Humanoid models too
	rescanHz = 5,                      -- how often to rebuild target set
	updateHz = 60,                     -- render update throttle
	smoothRate = 18,                   -- positional smoothing
	losDebounce = 0.08,                -- seen/lost hysteresis

	beamWidth = 0.09,                  -- cosmetic
	fanSpacing = 0.20,                 -- cosmetic fan offset
	beamColor = Color3.new(1,1,1),     -- white beams

	showRangeCube = true,              -- debug volume
	rangeColor = Color3.fromRGB(255,90,140), -- bubblegum box
	rangeTransparency = 0.88,          -- ghosty

	seeThrough = {                     -- raycast passthrough rules
		enabled = true,                -- allow x-ray-ish behavior
		maxPenetrations = 12,          -- how many thin bits we can poke through
		passAlphaThreshold = 0.5,      -- parts this transparent get ignored
		passMaterials = {              -- glass & forcefields don't block
			[Enum.Material.Glass] = true,
			[Enum.Material.ForceField] = true
		},
		passAttribute = "SeeThroughVision", -- opt-in via attribute
	},

	overlay = {                        -- Highlight frosting on targets
		enabled = true,
		color = Color3.fromRGB(0,255,0),    -- neon slime green
		fillSeen = 0.75,                    -- lower = more filled
		outlineSeen = 0.0,                  -- 0 = full outline
		fadeTime = 0.25,                    -- quick fade
		easing = Enum.EasingStyle.Sine,     -- smooth
	},

	hotkeys = { enabled = false },     -- dev toggles (M/B/P)
	maxTargets = 8,                    -- cap per scan

	onSeen = nil,                      -- hook: function(model) end
	onLost = nil,                      -- hook: function(model) end
}

-- humanoid part name lists (R6 vs R15 — yes they’re different)
local R6_PARTS  = {"Head","Torso","Left Arm","Right Arm","Left Leg","Right Leg","HumanoidRootPart"}
local R15_PARTS = {
	"Head","UpperTorso","LowerTorso",
	"LeftUpperArm","LeftLowerArm","LeftHand",
	"RightUpperArm","RightLowerArm","RightHand",
	"LeftUpperLeg","LeftLowerLeg","LeftFoot",
	"RightUpperLeg","RightLowerLeg","RightFoot",
	"HumanoidRootPart"
}

-- ---------- small helpers ----------

local function shallowClone(t)        -- baby copy (1 level)
	local o = {}
	for k,v in pairs(t) do o[k] = v end
	return o
end

local function deepMerge(base, ext)   -- base <- ext (tables merge)
	local out = shallowClone(base)
	if ext then
		for k,v in pairs(ext) do
			if type(v) == "table" and type(out[k]) == "table" then
				out[k] = deepMerge(out[k], v) -- nested table go brr
			else
				out[k] = v                    -- override scalar
			end
		end
	end
	return out
end

local function partsFor(hum)          -- pick list by rig type
	return (hum and hum.RigType == Enum.HumanoidRigType.R6) and R6_PARTS or R15_PARTS
end

local function smoothToward(curr, target, rate, dt) -- cheap exp smoothing
	if not curr then return target end              -- first frame snap
	local a = 1 - math.exp(-rate * dt)              -- gain
	local d = target - curr
	if d.Magnitude < 0.01 then return curr end      -- close enough
	return curr + d * a
end

-- figure out a BasePart to use from whatever you hand me
local function pickBasePartFromInstance(inst)
	if inst:IsA("BasePart") then return inst end         -- already good
	if inst:IsA("Model") then
		local m = inst
		if m.PrimaryPart then return m.PrimaryPart end   -- primary if set
		local hrp = m:FindFirstChild("HumanoidRootPart") -- hrp if present
		if hrp and hrp:IsA("BasePart") then return hrp end
		for _, d in ipairs(m:GetDescendants()) do        -- anything that’s a part
			if d:IsA("BasePart") then return d end
		end
	end
	return nil
end

-- best-effort auto-bind: by name, tag, or attribute
local function resolveAIPartByName(name)
	-- 1) exact name anywhere under Workspace
	local inst = Workspace:FindFirstChild(name, true)
	if inst then
		local bp = pickBasePartFromInstance(inst)
		if bp then return bp end
	end
	-- 2) anything tagged "AI"
	for _, it in ipairs(CollectionService:GetTagged("AI")) do
		if it:IsDescendantOf(Workspace) then
			local bp = pickBasePartFromInstance(it)
			if bp then return bp end
		end
	end
	-- 3) any BasePart with IsAI=true attribute
	for _, d in ipairs(Workspace:GetDescendants()) do
		if d:IsA("BasePart") and d:GetAttribute("IsAI") == true then
			return d
		end
	end
	return nil -- fine, you win
end

-- volume + FOV math (nothing fancy)
local function insideCube(center, p, r)             -- axis-aligned cube check
	local d = p - center
	return math.abs(d.X) <= r and math.abs(d.Y) <= r and math.abs(d.Z) <= r
end
local function insideSphere(center, p, r)           -- ball check
	return (p - center).Magnitude <= r
end
local function inVolume(center, p, r, shape)        -- pick your poison
	if (shape == "sphere") then return insideSphere(center, p, r) end
	return insideCube(center, p, r)
end
local function inFOV(aiCf, targetPoint, halfAngleRad) -- 2D yaw-only FOV
	local aiPos = aiCf.Position
	local forward = Vector3.new(aiCf.LookVector.X, 0, aiCf.LookVector.Z) -- flatten Y
	if forward.Magnitude > 1e-3 then forward = forward.Unit else forward = Vector3.new(0,0,1) end
	local toT = Vector3.new(targetPoint.X - aiPos.X, 0, targetPoint.Z - aiPos.Z)
	if toT.Magnitude < 1e-3 then return true end     -- on top of us, sure
	return forward:Dot(toT.Unit) >= math.cos(halfAngleRad)
end

-- see-through raycast helpers
local function isPassThrough(hit, cfg)              -- decide if we ignore this part
	if cfg.passAttribute and hit:GetAttribute(cfg.passAttribute) == true then return true end
	if cfg.passMaterials and cfg.passMaterials[hit.Material] then return true end
	if hit.Transparency >= cfg.passAlphaThreshold then return true end
	return false
end

-- los with pass-through: ray, step through penetrables, bail on solid
local function losClear_withPass(origin, targetPoint, exclude, cfg)
	local dir = targetPoint - origin
	local totalDist = dir.Magnitude
	if totalDist < 1e-3 then return true end         -- same point
	local unit = dir.Unit
	local traveled, start, steps = 0, origin, 0

	-- copy exclude list (ai, target model, debug cube, etc)
	local filterList = {}
	for i = 1, #exclude do if exclude[i] then table.insert(filterList, exclude[i]) end end

	while traveled < totalDist and steps < (cfg.maxPenetrations or 12) do
		local rp = RaycastParams.new()
		rp.FilterType = Enum.RaycastFilterType.Exclude
		rp.FilterDescendantsInstances = filterList

		local result = Workspace:Raycast(start, unit * (totalDist - traveled), rp)
		if not result then return true end            -- nothing in the way

		local inst = result.Instance
		if inst and inst:IsA("BasePart") then
			if cfg.enabled and isPassThrough(inst, cfg) then
				table.insert(filterList, inst)        -- pretend it isn't there
				local advance = (result.Position - start).Magnitude
				traveled = traveled + advance + 0.01  -- nudge forward
				start = result.Position + unit * 0.01
				steps = steps + 1
			else
				local distToHit = (result.Position - origin).Magnitude
				return distToHit >= totalDist - 1e-3  -- if we hit past target, still good
			end
		else
			return true                                -- weird hit, ignore
		end
	end
	return true                                        -- hit nothing fatal
end

-- class-like thing (not actual OOP, just vibes)
local Vision = {}
Vision.__index = Vision

function Vision.new(userCfg)
	local self = setmetatable({}, Vision)
	self.cfg = deepMerge(DEFAULTS, userCfg or {})  -- merge overrides
	self.enabled = true                             -- master switch
	self.targets = {}                                -- model -> state
	self.ai = (userCfg and userCfg.aiInstance) or nil -- explicit bind if given
	self.sAI = nil                                   -- smoothed ai pos
	self.rangeCube = nil                             -- debug cube ref
	self._started = false                            -- guard
	self._renderConn = nil                           -- RenderStepped conn
	self._acc = 0                                    -- frame accumulator
	self._dtTarget = 1 / (self.cfg.updateHz or 60)   -- update period
	self._lastRescan = 0                             -- rescan timer
	self._rescanPeriod = 1 / (self.cfg.rescanHz or 5)-- rescan period
	self._halfFov = math.rad((self.cfg.fovDegrees or 120) * 0.5) -- cache half-angle
	return self
end

function Vision:Start()
	if self._started then return end                 -- no double start
	self._started = true
	if not self.ai and self.cfg.aiName then
		self.ai = resolveAIPartByName(self.cfg.aiName) -- try auto bind
	end
	self:_ensureRangeCube()                          -- make debug box if needed
	self._renderConn = RunService.RenderStepped:Connect(function(dt) -- per-frame-ish
		self:_onRender(dt)
	end)
	if self.cfg.hotkeys and self.cfg.hotkeys.enabled then
		self:_bindHotkeys()                           -- dev toggles
	end
end

function Vision:Stop()
	if not self._started then return end             -- already off
	self._started = false
	if self._renderConn then self._renderConn:Disconnect(); self._renderConn = nil end
	for model,_ in pairs(self.targets) do self:_destroyTarget(model) end -- clean beams/overlays
	if self.rangeCube then self.rangeCube:Destroy(); self.rangeCube = nil end
end

function Vision:Destroy() self:Stop() end           -- sugar

function Vision:SetEnabled(on)                       -- global toggle
	self.enabled = on
	for _, t in pairs(self.targets) do
		for _, r in ipairs(t.rays) do r.beam.Enabled = on end
		if t.seen then self:_fadeOverlay(t, on) else self:_fadeOverlay(t, false) end
	end
end

function Vision:SetShowRange(on)                     -- show/hide cube, keep part alive
	if self.rangeCube then
		self.rangeCube.Transparency = on and (self.cfg.rangeTransparency or 0.88) or 1
	end
end

function Vision:SetSeeThrough(on)                    -- flip passthrough mode
	self.cfg.seeThrough = self.cfg.seeThrough or deepMerge(DEFAULTS.seeThrough, {})
	self.cfg.seeThrough.enabled = on
end

function Vision:BindAIByName(name)                   -- rebind by name
	self.cfg.aiName = name; self.ai = resolveAIPartByName(name)
end
function Vision:BindAI(p)                            -- rebind directly
	self.cfg.aiName = nil; self.ai = p
end
function Vision:GetTargets()                         -- list of active target models
	local out = {}; for m,_ in pairs(self.targets) do table.insert(out, m) end; return out
end

-- overlays (Highlight setup + tweens)
function Vision:_ensureOverlay(t)
	if t.overlay and t.overlay.Parent then return end -- already made
	local ocfg = self.cfg.overlay
	local hl = Instance.new("Highlight")
	hl.Name = "AISeenOverlay"
	hl.Adornee = t.model
	hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop -- always visible
	hl.FillColor = ocfg.color
	hl.OutlineColor = ocfg.color
	hl.FillTransparency = 1        -- start hidden
	hl.OutlineTransparency = 1
	hl.Enabled = false
	hl.Parent = t.model
	t.overlay = hl
end

function Vision:_fadeOverlay(t, turnOn)              -- tween it in/out
	local ocfg = self.cfg.overlay
	if not (ocfg and ocfg.enabled) then return end
	self:_ensureOverlay(t); if not t.overlay then return end
	if t.overlayTween then pcall(function() t.overlayTween:Cancel() end) end
	t.overlay.Enabled = true
	local goal = {
		FillTransparency    = turnOn and ocfg.fillSeen or 1,
		OutlineTransparency = turnOn and ocfg.outlineSeen or 1,
	}
	local tw = TweenService:Create(t.overlay, TweenInfo.new(ocfg.fadeTime, ocfg.easing, Enum.EasingDirection.Out), goal)
	t.overlayTween = tw; tw:Play()
	if not turnOn then
		local conn; conn = tw.Completed:Connect(function()
			if t.overlay then t.overlay.Enabled = false end -- hide after fade
			if conn then conn:Disconnect() end
		end)
	end
end

-- beams (visual links per body part)
function Vision:_buildRaysForTarget(t)
	for _, r in ipairs(t.rays or {}) do if r.beam then r.beam:Destroy() end end -- nuke old
	t.rays = {}
	if not self.ai then return end                     -- no origin? bail

	local names = partsFor(t.hum)
	local parts = {}
	for _, n in ipairs(names) do                       -- collect actual parts we have
		local p = t.model:FindFirstChild(n)
		if p and p:IsA("BasePart") then table.insert(parts, p) end
	end
	if #parts == 0 then return end                     -- nothing to draw to

	local mid = (#parts + 1) * 0.5                      -- fan centering
	for i, part in ipairs(parts) do
		local a0 = Instance.new("Attachment"); a0.Name = ("AI_A0_%s"):format(part.Name); a0.Parent = self.ai
		local a1 = Instance.new("Attachment"); a1.Name = ("AI_A1_%s"):format(part.Name); a1.Parent = part

		local beam = Instance.new("Beam")
		beam.Name = ("AI_Beam_%s"):format(part.Name)
		beam.Attachment0 = a0; beam.Attachment1 = a1
		beam.Width0 = self.cfg.beamWidth; beam.Width1 = self.cfg.beamWidth
		beam.LightInfluence = 0; beam.FaceCamera = false
		beam.Transparency = NumberSequence.new(0)
		beam.Color = ColorSequence.new(self.cfg.beamColor)
		beam.Enabled = self.enabled
		beam.Parent = self.ai

		local off = Vector3.new((i - mid) * (self.cfg.fanSpacing or 0.2), 0, 0) -- small left/right spread
		table.insert(t.rays, {name = part.Name, targetPart = part, a0=a0, a1=a1, beam=beam, sEnd=part.Position, offsetStart=off})
	end
end

function Vision:_destroyTarget(model)                 -- cleanup everything for a target
	local t = self.targets[model]; if not t then return end
	for _, r in ipairs(t.rays) do if r.beam then r.beam:Destroy() end end
	if t.overlayTween then pcall(function() t.overlayTween:Cancel() end) end
	if t.overlay then t.overlay:Destroy() end
	self.targets[model] = nil
end

-- range cube (debug gizmo)
function Vision:_ensureRangeCube()
	if not self.cfg.showRangeCube then return end
	if self.rangeCube and self.rangeCube.Parent then return end
	local p = Instance.new("Part")
	p.Name = "AI_RangeCube"
	p.Anchored = true
	p.CanCollide, p.CanTouch, p.CanQuery = false, false, false -- visual only
	p.Material = Enum.Material.Neon
	p.Color = self.cfg.rangeColor
	p.Transparency = self.cfg.rangeTransparency
	p.CastShadow = false
	local r = self.cfg.detectionRange
	p.Size = Vector3.new(r*2, r*2, r*2)              -- cube sized to range
	p.CFrame = CFrame.new(0, -1e5, 0)                 -- park it offscreen until AI binds
	p.Parent = Workspace
	self.rangeCube = p
end

-- quick test: any body part inside AND (maybe) in FOV
local function anyBodyPartInside(model, hum, aiPos, shape, range, aiCf, useFov, halfFov)
	for _, name in ipairs(partsFor(hum)) do
		local part = model:FindFirstChild(name)
		if part and part:IsA("BasePart") then
			local p = part.Position
			if inVolume(aiPos, p, range, shape) and (not useFov or inFOV(aiCf, p, halfFov)) then
				return true                           -- one is enough
			end
		end
	end
	return false
end

-- hotkeys for dev poking (M/B/P)
function Vision:_bindHotkeys()
	local UIS = game:GetService("UserInputService")
	UIS.InputBegan:Connect(function(input, gp)
		if gp then return end
		if input.KeyCode == Enum.KeyCode.M then
			self:SetEnabled(not self.enabled)         -- mute beams/logic visuals
		elseif input.KeyCode == Enum.KeyCode.B then
			local on = self.rangeCube and (self.rangeCube.Transparency >= 1)
			self:SetShowRange(on)                     -- show cube
		elseif input.KeyCode == Enum.KeyCode.P then
			self:SetSeeThrough(not (self.cfg.seeThrough and self.cfg.seeThrough.enabled)) -- x-ray flip
			print((self.cfg.seeThrough and self.cfg.seeThrough.enabled) and "[Vision] See-through ON" or "[Vision] Opaque mode")
		end
	end)
end

-- main loop (runs on RenderStepped, throttled)
function Vision:_onRender(dt)
	self._acc = self._acc + dt
	if self._acc < self._dtTarget then return end     -- throttle to updateHz
	dt = self._acc; self._acc = 0

	-- AI acquire / keep alive
	if (not self.ai) or (not self.ai.Parent) then
		if self.cfg.aiName then self.ai = resolveAIPartByName(self.cfg.aiName) end -- try again
		if not self.ai then
			if self.rangeCube then self.rangeCube.CFrame = CFrame.new(0,-1e5,0) end -- hide cube
			return                                -- nothing to do without origin
		end
	end

	local ai = self.ai
	local aiPos = ai.Position
	self.sAI = smoothToward(self.sAI, aiPos, (self.cfg.smoothRate or 18), dt) -- smooth base
	if self.rangeCube then self.rangeCube.CFrame = CFrame.new(self.sAI) end   -- move cube

	-- rescan cadence (rebuild target list)
	self._lastRescan = self._lastRescan + dt
	if self._lastRescan >= self._rescanPeriod then
		self._lastRescan = 0

		local candidates = {}                         -- collect characters
		for _, pl in ipairs(Players:GetPlayers()) do
			if pl.Character then table.insert(candidates, pl.Character) end
		end
		if self.cfg.includeNPCs then                 -- and world NPC models
			for _, m in ipairs(Workspace:GetChildren()) do
				if m:IsA("Model") then
					local hum = m:FindFirstChildOfClass("Humanoid")
					local hrp = m:FindFirstChild("HumanoidRootPart")
					if hum and hrp then table.insert(candidates, m) end
				end
			end
		end

		local added = 0                               -- respect cap
		for _, model in ipairs(candidates) do
			local hum = model:FindFirstChildOfClass("Humanoid")
			local hrp = model:FindFirstChild("HumanoidRootPart")
			if hum and hrp and hum.Health > 0 then
				if anyBodyPartInside(model, hum, aiPos, (self.cfg.detectionShape or "cube"), (self.cfg.detectionRange or 120), ai.CFrame, (self.cfg.useFov ~= false), self._halfFov) then
					if not self.targets[model] then
						if (self.cfg.maxTargets == 0) or (added < (self.cfg.maxTargets or 8)) then
							local t = {                -- per-target state blob
								model = model, hum = hum, hrp = hrp,
								rays = {}, seen=false, losTimer=0,
								overlay=nil, overlayTween=nil
							}
							self.targets[model] = t
							self:_buildRaysForTarget(t) -- beams + attachments
							self:_ensureOverlay(t)      -- highlight ready
							added = added + 1
						end
					end
				end
			end
		end

		-- prune those who left the volume/FOV
		for model, t in pairs(self.targets) do
			local ok = model.Parent and t.hum.Health > 0 and t.hrp.Parent ~= nil
			local inside = ok and anyBodyPartInside(model, t.hum, aiPos, (self.cfg.detectionShape or "cube"), (self.cfg.detectionRange or 120), ai.CFrame, (self.cfg.useFov ~= false), self._halfFov)
			if not inside then
				if t.seen and self.cfg.onLost then pcall(self.cfg.onLost, model) end
				self:_fadeOverlay(t, false)
				self:_destroyTarget(model)
			end
		end
	end

	-- build a lateral basis so beams fan left/right from AI a bit
	local forward = Vector3.new(ai.CFrame.LookVector.X, 0, ai.CFrame.LookVector.Z)
	if forward.Magnitude < 1e-3 then forward = Vector3.new(0,0,1) end
	forward = forward.Unit
	local right = forward:Cross(Vector3.new(0,1,0))
	if right.Magnitude < 1e-3 then right = Vector3.new(1,0,0) else right = right.Unit end

	-- per-target updates (smooth endpoints, LOS, overlay state)
	for model, t in pairs(self.targets) do
		if (not model.Parent) or t.hum.Health <= 0 or (not t.hrp.Parent) then
			-- target died or despawned
			if t.seen and self.cfg.onLost then pcall(self.cfg.onLost, model) end
			self:_fadeOverlay(t, false)
			self:_destroyTarget(model)
		else
			local anyClear = false                     -- if any part has LOS, we count it
			for _, r in ipairs(t.rays) do
				if r.targetPart and r.targetPart.Parent then
					r.sEnd = smoothToward(r.sEnd, r.targetPart.Position, (self.cfg.smoothRate or 18), dt) -- smooth end
					local startWS = (self.sAI or aiPos) + right * r.offsetStart.X -- small fan offset
					local endWS   = r.sEnd
					r.a0.Position = ai.CFrame:PointToObjectSpace(startWS)         -- keep a0 local to AI
					r.a1.Position = r.targetPart.CFrame:PointToObjectSpace(endWS) -- keep a1 local to part

					local exclude = {t.model, ai}         -- don't hit self/ai
					if self.rangeCube then table.insert(exclude, self.rangeCube) end
					local clear = losClear_withPass(aiPos, endWS, exclude, self.cfg.seeThrough)

					if self.enabled and clear then
						r.beam.Enabled = true
						r.beam.Transparency = NumberSequence.new(0)
						anyClear = true                    -- one clear ray is enough
					else
						r.beam.Enabled = false             -- hide if blocked/disabled
					end
				end
			end

			-- debounce into "seen" / "lost" with a tiny buffer so it doesn't flicker
			if anyClear then
				t.losTimer = math.min((self.cfg.losDebounce or 0.08), t.losTimer + dt)
				if not t.seen and t.losTimer >= (self.cfg.losDebounce or 0.08) then
					t.seen = true
					if self.cfg.onSeen then pcall(self.cfg.onSeen, model) end
					self:_fadeOverlay(t, true)
				end
			else
				t.losTimer = math.max(-(self.cfg.losDebounce or 0.08), t.losTimer - dt)
				if t.seen and t.losTimer <= -(self.cfg.losDebounce or 0.08) then
					t.seen = false
					if self.cfg.onLost then pcall(self.cfg.onLost, model) end
					self:_fadeOverlay(t, false)
				end
			end
		end
	end
end

-- public module wrapper
local Module = {}
function Module.new(cfg) return Vision.new(cfg) end -- usage: local vision
return Module
