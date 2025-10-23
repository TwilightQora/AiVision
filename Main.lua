local Players            = game:GetService("Players")
local RunService         = game:GetService("RunService")
local Workspace          = game:GetService("Workspace")
local CollectionService  = game:GetService("CollectionService")
local TweenService       = game:GetService("TweenService")

-- ---------- defaults ----------
local DEFAULTS = {
	aiName = "AI",
	detectionRange = 120,
	detectionShape = "cube",      -- "cube" or "sphere"
	useFov = true,
	fovDegrees = 120,

	includeNPCs = true,
	rescanHz = 5,
	updateHz = 60,
	smoothRate = 18,
	losDebounce = 0.08,

	beamWidth = 0.09,
	fanSpacing = 0.20,
	beamColor = Color3.new(1,1,1),

	showRangeCube = true,
	rangeColor = Color3.fromRGB(255,90,140),
	rangeTransparency = 0.88,

	seeThrough = {
		enabled = true,
		maxPenetrations = 12,
		passAlphaThreshold = 0.5,
		passMaterials = { [Enum.Material.Glass] = true, [Enum.Material.ForceField] = true },
		passAttribute = "SeeThroughVision",
	},

	overlay = {
		enabled = true,
		color = Color3.fromRGB(0,255,0),
		fillSeen = 0.75,
		outlineSeen = 0.0,
		fadeTime = 0.25,
		easing = Enum.EasingStyle.Sine,
	},

	hotkeys = { enabled = false },
	maxTargets = 8,

	onSeen = nil, -- function(model) end
	onLost = nil, -- function(model) end
}

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
local function shallowClone(t)
	local o = {}
	for k,v in pairs(t) do o[k] = v end
	return o
end

local function deepMerge(base, ext)
	local out = shallowClone(base)
	if ext then
		for k,v in pairs(ext) do
			if type(v) == "table" and type(out[k]) == "table" then
				out[k] = deepMerge(out[k], v)
			else
				out[k] = v
			end
		end
	end
	return out
end

local function partsFor(hum)
	return (hum and hum.RigType == Enum.HumanoidRigType.R6) and R6_PARTS or R15_PARTS
end

local function smoothToward(curr, target, rate, dt)
	if not curr then return target end
	local a = 1 - math.exp(-rate * dt)
	local d = target - curr
	if d.Magnitude < 0.01 then return curr end
	return curr + d * a
end

local function pickBasePartFromInstance(inst)
	if inst:IsA("BasePart") then return inst end
	if inst:IsA("Model") then
		local m = inst
		if m.PrimaryPart then return m.PrimaryPart end
		local hrp = m:FindFirstChild("HumanoidRootPart")
		if hrp and hrp:IsA("BasePart") then return hrp end
		for _, d in ipairs(m:GetDescendants()) do
			if d:IsA("BasePart") then return d end
		end
	end
	return nil
end

local function resolveAIPartByName(name)
	-- exact name
	local inst = Workspace:FindFirstChild(name, true)
	if inst then
		local bp = pickBasePartFromInstance(inst)
		if bp then return bp end
	end
	-- tag "AI"
	for _, it in ipairs(CollectionService:GetTagged("AI")) do
		if it:IsDescendantOf(Workspace) then
			local bp = pickBasePartFromInstance(it)
			if bp then return bp end
		end
	end
	-- attribute IsAI=true
	for _, d in ipairs(Workspace:GetDescendants()) do
		if d:IsA("BasePart") and d:GetAttribute("IsAI") == true then
			return d
		end
	end
	return nil
end

-- volume + FOV
local function insideCube(center, p, r)
	local d = p - center
	return math.abs(d.X) <= r and math.abs(d.Y) <= r and math.abs(d.Z) <= r
end
local function insideSphere(center, p, r)
	return (p - center).Magnitude <= r
end
local function inVolume(center, p, r, shape)
	if (shape == "sphere") then return insideSphere(center, p, r) end
	return insideCube(center, p, r)
end
local function inFOV(aiCf, targetPoint, halfAngleRad)
	local aiPos = aiCf.Position
	local forward = Vector3.new(aiCf.LookVector.X, 0, aiCf.LookVector.Z)
	if forward.Magnitude > 1e-3 then forward = forward.Unit else forward = Vector3.new(0,0,1) end
	local toT = Vector3.new(targetPoint.X - aiPos.X, 0, targetPoint.Z - aiPos.Z)
	if toT.Magnitude < 1e-3 then return true end
	return forward:Dot(toT.Unit) >= math.cos(halfAngleRad)
end

-- see-through raycast
local function isPassThrough(hit, cfg)
	if cfg.passAttribute and hit:GetAttribute(cfg.passAttribute) == true then return true end
	if cfg.passMaterials and cfg.passMaterials[hit.Material] then return true end
	if hit.Transparency >= cfg.passAlphaThreshold then return true end
	return false
end

local function losClear_withPass(origin, targetPoint, exclude, cfg)
	local dir = targetPoint - origin
	local totalDist = dir.Magnitude
	if totalDist < 1e-3 then return true end
	local unit = dir.Unit
	local traveled, start, steps = 0, origin, 0

	local filterList = {}
	for i = 1, #exclude do if exclude[i] then table.insert(filterList, exclude[i]) end end

	while traveled < totalDist and steps < (cfg.maxPenetrations or 12) do
		local rp = RaycastParams.new()
		rp.FilterType = Enum.RaycastFilterType.Exclude
		rp.FilterDescendantsInstances = filterList

		local result = Workspace:Raycast(start, unit * (totalDist - traveled), rp)
		if not result then return true end

		local inst = result.Instance
		if inst and inst:IsA("BasePart") then
			if cfg.enabled and isPassThrough(inst, cfg) then
				table.insert(filterList, inst)
				local advance = (result.Position - start).Magnitude
				traveled = traveled + advance + 0.01
				start = result.Position + unit * 0.01
				steps = steps + 1
			else
				local distToHit = (result.Position - origin).Magnitude
				return distToHit >= totalDist - 1e-3
			end
		else
			return true
		end
	end
	return true
end

-- class-like table
local Vision = {}
Vision.__index = Vision

function Vision.new(userCfg)
	local self = setmetatable({}, Vision)
	self.cfg = deepMerge(DEFAULTS, userCfg or {})
	self.enabled = true
	self.targets = {}
	self.ai = (userCfg and userCfg.aiInstance) or nil
	self.sAI = nil
	self.rangeCube = nil
	self._started = false
	self._renderConn = nil
	self._acc = 0
	self._dtTarget = 1 / (self.cfg.updateHz or 60)
	self._lastRescan = 0
	self._rescanPeriod = 1 / (self.cfg.rescanHz or 5)
	self._halfFov = math.rad((self.cfg.fovDegrees or 120) * 0.5)
	return self
end

function Vision:Start()
	if self._started then return end
	self._started = true
	if not self.ai and self.cfg.aiName then
		self.ai = resolveAIPartByName(self.cfg.aiName)
	end
	self:_ensureRangeCube()
	self._renderConn = RunService.RenderStepped:Connect(function(dt)
		self:_onRender(dt)
	end)
	if self.cfg.hotkeys and self.cfg.hotkeys.enabled then
		self:_bindHotkeys()
	end
end

function Vision:Stop()
	if not self._started then return end
	self._started = false
	if self._renderConn then self._renderConn:Disconnect(); self._renderConn = nil end
	for model,_ in pairs(self.targets) do self:_destroyTarget(model) end
	if self.rangeCube then self.rangeCube:Destroy(); self.rangeCube = nil end
end

function Vision:Destroy() self:Stop() end
function Vision:SetEnabled(on)
	self.enabled = on
	for _, t in pairs(self.targets) do
		for _, r in ipairs(t.rays) do r.beam.Enabled = on end
		if t.seen then self:_fadeOverlay(t, on) else self:_fadeOverlay(t, false) end
	end
end

function Vision:SetShowRange(on)
	if self.rangeCube then
		self.rangeCube.Transparency = on and (self.cfg.rangeTransparency or 0.88) or 1
	end
end

function Vision:SetSeeThrough(on)
	self.cfg.seeThrough = self.cfg.seeThrough or deepMerge(DEFAULTS.seeThrough, {})
	self.cfg.seeThrough.enabled = on
end

function Vision:BindAIByName(name) self.cfg.aiName = name; self.ai = resolveAIPartByName(name) end
function Vision:BindAI(p) self.cfg.aiName = nil; self.ai = p end
function Vision:GetTargets()
	local out = {}; for m,_ in pairs(self.targets) do table.insert(out, m) end; return out
end

-- overlays
function Vision:_ensureOverlay(t)
	if t.overlay and t.overlay.Parent then return end
	local ocfg = self.cfg.overlay
	local hl = Instance.new("Highlight")
	hl.Name = "AISeenOverlay"
	hl.Adornee = t.model
	hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	hl.FillColor = ocfg.color
	hl.OutlineColor = ocfg.color
	hl.FillTransparency = 1
	hl.OutlineTransparency = 1
	hl.Enabled = false
	hl.Parent = t.model
	t.overlay = hl
end

function Vision:_fadeOverlay(t, turnOn)
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
			if t.overlay then t.overlay.Enabled = false end
			if conn then conn:Disconnect() end
		end)
	end
end

-- beams
function Vision:_buildRaysForTarget(t)
	for _, r in ipairs(t.rays or {}) do if r.beam then r.beam:Destroy() end end
	t.rays = {}
	if not self.ai then return end

	local names = partsFor(t.hum)
	local parts = {}
	for _, n in ipairs(names) do
		local p = t.model:FindFirstChild(n)
		if p and p:IsA("BasePart") then table.insert(parts, p) end
	end
	if #parts == 0 then return end

	local mid = (#parts + 1) * 0.5
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

		local off = Vector3.new((i - mid) * (self.cfg.fanSpacing or 0.2), 0, 0)
		table.insert(t.rays, {name = part.Name, targetPart = part, a0=a0, a1=a1, beam=beam, sEnd=part.Position, offsetStart=off})
	end
end

function Vision:_destroyTarget(model)
	local t = self.targets[model]; if not t then return end
	for _, r in ipairs(t.rays) do if r.beam then r.beam:Destroy() end end
	if t.overlayTween then pcall(function() t.overlayTween:Cancel() end) end
	if t.overlay then t.overlay:Destroy() end
	self.targets[model] = nil
end

-- range cube
function Vision:_ensureRangeCube()
	if not self.cfg.showRangeCube then return end
	if self.rangeCube and self.rangeCube.Parent then return end
	local p = Instance.new("Part")
	p.Name = "AI_RangeCube"
	p.Anchored = true
	p.CanCollide, p.CanTouch, p.CanQuery = false, false, false
	p.Material = Enum.Material.Neon
	p.Color = self.cfg.rangeColor
	p.Transparency = self.cfg.rangeTransparency
	p.CastShadow = false
	local r = self.cfg.detectionRange
	p.Size = Vector3.new(r*2, r*2, r*2)
	p.CFrame = CFrame.new(0, -1e5, 0)
	p.Parent = Workspace
	self.rangeCube = p
end

local function anyBodyPartInside(model, hum, aiPos, shape, range, aiCf, useFov, halfFov)
	for _, name in ipairs(partsFor(hum)) do
		local part = model:FindFirstChild(name)
		if part and part:IsA("BasePart") then
			local p = part.Position
			if inVolume(aiPos, p, range, shape) and (not useFov or inFOV(aiCf, p, halfFov)) then
				return true
			end
		end
	end
	return false
end

-- hotkeys
function Vision:_bindHotkeys()
	local UIS = game:GetService("UserInputService")
	UIS.InputBegan:Connect(function(input, gp)
		if gp then return end
		if input.KeyCode == Enum.KeyCode.M then
			self:SetEnabled(not self.enabled)
		elseif input.KeyCode == Enum.KeyCode.B then
			local on = self.rangeCube and (self.rangeCube.Transparency >= 1)
			self:SetShowRange(on)
		elseif input.KeyCode == Enum.KeyCode.P then
			self:SetSeeThrough(not (self.cfg.seeThrough and self.cfg.seeThrough.enabled))
			print((self.cfg.seeThrough and self.cfg.seeThrough.enabled) and "[Vision] See-through ON" or "[Vision] Opaque mode")
		end
	end)
end

-- main loop
function Vision:_onRender(dt)
	self._acc = self._acc + dt
	if self._acc < self._dtTarget then return end
	dt = self._acc; self._acc = 0

	-- AI acquire
	if (not self.ai) or (not self.ai.Parent) then
		if self.cfg.aiName then self.ai = resolveAIPartByName(self.cfg.aiName) end
		if not self.ai then
			if self.rangeCube then self.rangeCube.CFrame = CFrame.new(0,-1e5,0) end
			return
		end
	end

	local ai = self.ai
	local aiPos = ai.Position
	self.sAI = smoothToward(self.sAI, aiPos, (self.cfg.smoothRate or 18), dt)
	if self.rangeCube then self.rangeCube.CFrame = CFrame.new(self.sAI) end

	-- rescan
	self._lastRescan = self._lastRescan + dt
	if self._lastRescan >= self._rescanPeriod then
		self._lastRescan = 0

		local candidates = {}
		for _, pl in ipairs(Players:GetPlayers()) do
			if pl.Character then table.insert(candidates, pl.Character) end
		end
		if self.cfg.includeNPCs then
			for _, m in ipairs(Workspace:GetChildren()) do
				if m:IsA("Model") then
					local hum = m:FindFirstChildOfClass("Humanoid")
					local hrp = m:FindFirstChild("HumanoidRootPart")
					if hum and hrp then table.insert(candidates, m) end
				end
			end
		end

		local added = 0
		for _, model in ipairs(candidates) do
			local hum = model:FindFirstChildOfClass("Humanoid")
			local hrp = model:FindFirstChild("HumanoidRootPart")
			if hum and hrp and hum.Health > 0 then
				if anyBodyPartInside(model, hum, aiPos, (self.cfg.detectionShape or "cube"), (self.cfg.detectionRange or 120), ai.CFrame, (self.cfg.useFov ~= false), self._halfFov) then
					if not self.targets[model] then
						if (self.cfg.maxTargets == 0) or (added < (self.cfg.maxTargets or 8)) then
							local t = {model = model, hum = hum, hrp = hrp, rays = {}, seen=false, losTimer=0, overlay=nil, overlayTween=nil}
							self.targets[model] = t
							self:_buildRaysForTarget(t)
							self:_ensureOverlay(t)
							added = added + 1
						end
					end
				end
			end
		end

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

	-- lateral basis (avoid Vector3.xAxis/zAxis for old builds)
	local forward = Vector3.new(ai.CFrame.LookVector.X, 0, ai.CFrame.LookVector.Z)
	if forward.Magnitude < 1e-3 then forward = Vector3.new(0,0,1) end
	forward = forward.Unit
	local right = forward:Cross(Vector3.new(0,1,0))
	if right.Magnitude < 1e-3 then right = Vector3.new(1,0,0) else right = right.Unit end

	for model, t in pairs(self.targets) do
		if (not model.Parent) or t.hum.Health <= 0 or (not t.hrp.Parent) then
			if t.seen and self.cfg.onLost then pcall(self.cfg.onLost, model) end
			self:_fadeOverlay(t, false)
			self:_destroyTarget(model)
		else
			local anyClear = false
			for _, r in ipairs(t.rays) do
				if r.targetPart and r.targetPart.Parent then
					r.sEnd = smoothToward(r.sEnd, r.targetPart.Position, (self.cfg.smoothRate or 18), dt)
					local startWS = (self.sAI or aiPos) + right * r.offsetStart.X
					local endWS   = r.sEnd
					r.a0.Position = ai.CFrame:PointToObjectSpace(startWS)
					r.a1.Position = r.targetPart.CFrame:PointToObjectSpace(endWS)

					local exclude = {t.model, ai}
					if self.rangeCube then table.insert(exclude, self.rangeCube) end
					local clear = losClear_withPass(aiPos, endWS, exclude, self.cfg.seeThrough)

					if self.enabled and clear then
						r.beam.Enabled = true
						r.beam.Transparency = NumberSequence.new(0)
						anyClear = true
					else
						r.beam.Enabled = false
					end
				end
			end

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

local Module = {}
function Module.new(cfg) return Vision.new(cfg) end
return Module
