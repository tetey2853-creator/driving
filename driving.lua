local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local VirtualUser = game:GetService("VirtualUser")
local TeleportService = game:GetService("TeleportService")
local Workspace = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")
local RemotesFolder = ReplicatedStorage:WaitForChild("Remotes")

local function safeRequire(mod)
	if not mod then return nil end
	local ok, res = pcall(require, mod)
	return ok and res or nil
end

local Remotes = require(ReplicatedStorage.Modules.Shared.Remotes)
local DataModule = safeRequire(ReplicatedStorage.Modules.Shared:FindFirstChild("Data"))
local MathModule = safeRequire(ReplicatedStorage.Modules.Shared:FindFirstChild("Math"))
local GameConstants = safeRequire(ReplicatedStorage.Modules.Shared:FindFirstChild("Game") and ReplicatedStorage.Modules.Shared.Game:FindFirstChild("GameConstants"))
local JobsController = require(ReplicatedStorage.Modules.Client.Jobs.JobsController)
local JobsUtil = require(ReplicatedStorage.Modules.Shared.Jobs.JobsUtil)
local JobsConstants = require(ReplicatedStorage.Modules.Shared.Jobs.JobsConstants)
local DeliveryJobTask = require(ReplicatedStorage.Modules.Client.Jobs.Tasks.DeliveryJobTask)
local DeliveryConstants = require(ReplicatedStorage.Modules.Shared.Jobs.Delivery.DeliveryConstants)
local DeliveryUtil = require(ReplicatedStorage.Modules.Shared.Jobs.Delivery.DeliveryUtil)
local TowablesController = require(ReplicatedStorage.Modules.Client.Towables.TowablesController)
local CarTrailerUtil = require(ReplicatedStorage.Modules.Shared.Vehicles.CarTrailerUtil)
local VehicleUtil = require(ReplicatedStorage.Modules.Shared.Vehicles.VehicleUtil)

local Env = (type(getgenv) == "function" and getgenv()) or _G
local CurrentSessionId = os.clock()
Env.AutoDeliverySession = CurrentSessionId
Env.AutoDelivery = false

-- ล้าง Connection เก่าทั้งหมดหากมีการรันสคริปต์ซ้ำเพื่อป้องกันแรมรั่วสะสม
if type(Env.DE_Connections) == "table" then
	for _, conn in ipairs(Env.DE_Connections) do
		pcall(function() conn:Disconnect() end)
	end
end
Env.DE_Connections = {}

local function trackConnection(conn)
	table.insert(Env.DE_Connections, conn)
	return conn
end

local HIGH_RISK_MODE = (DeliveryConstants.DeliveryModes and (DeliveryConstants.DeliveryModes.HighRisk or DeliveryConstants.DeliveryModes.Risky)) or "HighRisk"
local MAIN_PLACE_ID = 3351674303
local AFK_PLACE_ID = (GameConstants and GameConstants.PlaceIds and GameConstants.PlaceIds.AFK) or 99421106727783

local CONFIG = {
	TruckId = "Ford-LTL9000-1989",
	TrailerId = "FlatBedSemi",
	DeliveryMode = HIGH_RISK_MODE,
	ExactPadRadius = 55,
	FallbackPadRadius = 165,
	InZoneRadiusXZ = 20, -- ระยะปลอดภัยในจุดรับ-ส่ง ห้ามวาร์ปซ้ำเด็ดขาด
	StallRetryTime = 8.0, -- รอเฉพาะกรณีที่หลอดเหลืองไม่ขึ้นและของไม่ขยับเกิน 8 วินาทีจริงๆ เท่านั้น
	AutoSpawnSetup = true,
	AntiAFK = true,
}

local RUNTIME = {
	isDeliveringLatch = false,
	hasEnforcedHighRisk = false,
	statusText = "ปิดใช้งาน",
	carried = 0,
	maxCap = 8,
	deliveriesDone = 0,
	startCash = nil,
	lastKnownCash = nil,
	sessionStart = os.clock(),
	trailerRelativeCF = CFrame.new(0, 0, 23),
}

-- ================= ระบบ Cache เบาเครื่อง (คุมเฉพาะ RootPart 2 ชิ้น) =================
local CACHE = {
	vehicle = nil,
	vehicleRoot = nil,
	vehicleSeat = nil,
	trailer = nil,
	trailerRoot = nil,
	hudCashLabel = nil,
	lastHudScan = 0,
	lastStreamPos = nil,
	lastStreamTime = 0,
}

local SharedRaycastParams = RaycastParams.new()
SharedRaycastParams.FilterType = Enum.RaycastFilterType.Exclude
SharedRaycastParams.RespectCanCollide = true

local function getRootPart(model)
	if not model or not model.Parent then return nil end
	local primary = model.PrimaryPart or model:FindFirstChild("Weight") or model:FindFirstChildWhichIsA("BasePart", true)
	if primary and primary.AssemblyRootPart then
		return primary.AssemblyRootPart
	end
	return primary
end

local function refreshVehicleCache(vehicle, trailer)
	if vehicle ~= CACHE.vehicle or not (CACHE.vehicleRoot and CACHE.vehicleRoot.Parent) then
		CACHE.vehicle = vehicle
		if vehicle and vehicle.Parent then
			CACHE.vehicleRoot = getRootPart(vehicle)
			CACHE.vehicleSeat = vehicle:FindFirstChildOfClass("VehicleSeat", true)
		else
			CACHE.vehicleRoot = nil
			CACHE.vehicleSeat = nil
		end
	elseif vehicle and vehicle.Parent and not (CACHE.vehicleSeat and CACHE.vehicleSeat.Parent) then
		CACHE.vehicleSeat = vehicle:FindFirstChildOfClass("VehicleSeat", true)
	end

	if trailer ~= CACHE.trailer or not (CACHE.trailerRoot and CACHE.trailerRoot.Parent) then
		CACHE.trailer = trailer
		if trailer and trailer.Parent then
			CACHE.trailerRoot = getRootPart(trailer)
		else
			CACHE.trailerRoot = nil
		end
	end
end

local function isValidPart(part)
	return part ~= nil and typeof(part) == "Instance" and part.Parent ~= nil and part:IsDescendantOf(Workspace)
end

local function flatDistanceXZ(posA, posB)
	local dx = posA.X - posB.X
	local dz = posA.Z - posB.Z
	return math.sqrt(dx * dx + dz * dz)
end

-- โหลดแมพแบบพื้นหลังโดยไม่ขยับรถไปลอยค้างให้กล้องสั่น
local function safeRequestStream(pos, timeoutWait)
	if not pos then return end
	local now = os.clock()
	if CACHE.lastStreamPos and (CACHE.lastStreamPos - pos).Magnitude < 35 and (now - CACHE.lastStreamTime) < 0.8 then
		return
	end
	CACHE.lastStreamPos = pos
	CACHE.lastStreamTime = now

	local done = false
	task.spawn(function()
		pcall(function()
			LocalPlayer:RequestStreamAroundAsync(pos, timeoutWait or 1.6)
		end)
		done = true
	end)
	local deadline = os.clock() + (timeoutWait or 1.4)
	while not done and os.clock() < deadline do
		task.wait(0.05)
	end
end

-- ================= ระบบบล็อกการย้ายไปด่าน AFK ของเกม =================
local function isAFKTeleportCall(remoteName, ...)
	local nameLower = tostring(remoteName):lower()
	if nameLower:find("afk") then
		return true
	end
	local count = select("#", ...)
	for i = 1, count do
		local v = select(i, ...)
		local s = tostring(v):lower()
		if s == "afk" or s:find("afk") or v == AFK_PLACE_ID or s == tostring(AFK_PLACE_ID) then
			return true
		end
	end
	return false
end

if Remotes and not Env.DE_AFKHooked then
	Env.DE_AFKHooked = true
	local oldFireServer = Remotes.fireServer
	if type(oldFireServer) == "function" then
		Remotes.fireServer = function(remoteName, ...)
			if CONFIG.AntiAFK and isAFKTeleportCall(remoteName, ...) then
				return
			end
			return oldFireServer(remoteName, ...)
		end
	end

	local oldInvokeServer = Remotes.invokeServer
	if type(oldInvokeServer) == "function" then
		Remotes.invokeServer = function(remoteName, ...)
			if CONFIG.AntiAFK and isAFKTeleportCall(remoteName, ...) then
				return nil
			end
			return oldInvokeServer(remoteName, ...)
		end
	end
end

pcall(function()
	local clientFolder = ReplicatedStorage.Modules:FindFirstChild("Client")
	if clientFolder then
		for _, desc in ipairs(clientFolder:GetDescendants()) do
			if desc:IsA("ModuleScript") and desc.Name:lower():find("afk") then
				local mod = safeRequire(desc)
				if type(mod) == "table" then
					for k, v in pairs(mod) do
						if type(v) == "function" and k ~= "FrameworkInit" and k ~= "FrameworkStart" then
							mod[k] = function() return false end
						end
					end
				end
			end
		end
		local ptc = clientFolder:FindFirstChild("PlaceTeleportController", true)
		local ptcMod = safeRequire(ptc)
		if type(ptcMod) == "table" and type(ptcMod.TeleportToPlace) == "function" and not ptcMod._afkHooked then
			ptcMod._afkHooked = true
			local oldTp = ptcMod.TeleportToPlace
			ptcMod.TeleportToPlace = function(placeKey, ...)
				if CONFIG.AntiAFK and tostring(placeKey):lower():find("afk") then
					return
				end
				return oldTp(placeKey, ...)
			end
		end
	end
end)

-- ================= ระบบ Multi-Source Smart Cash Sync =================
local function formatNumber(n)
	local str = tostring(math.floor(n or 0))
	return str:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
end

-- อ่านค่าเงินจากป้าย HUD บนหน้าจอของผู้เล่นโดยตรง (รองรับทั้งแบบเต็ม $1,234,567 และแบบย่อ)
local function parseHudCashText(text)
	if type(text) ~= "string" then return nil, false end
	local clean = text:gsub("%s+", "")
	-- รูปแบบตัวเลขเต็ม เช่น $1,234,567 หรือ $500
	local fullMatch = clean:match("^%$([%d,]+)$")
	if fullMatch then
		local digits = fullMatch:gsub(",", "")
		local num = tonumber(digits)
		if num and num >= 0 then
			return math.floor(num), true -- true = ค่าตรงทุกหลัก 100%
		end
	end
	-- รูปแบบตัวย่อ เช่น $1.25M, $450K, $2.1B (ใช้เทียบความใกล้เคียง)
	local numPart, suffix = clean:match("^%$([%d%.]+)([KMBTkmbt])$")
	if numPart and suffix then
		local base = tonumber(numPart)
		local mults = { K = 1e3, M = 1e6, B = 1e9, T = 1e12 }
		local mult = mults[suffix:upper()]
		if base and mult then
			return math.floor(base * mult), false
		end
	end
	return nil, false
end

local function getHudCashValue()
	if CACHE.hudCashLabel and CACHE.hudCashLabel.Parent and CACHE.hudCashLabel.Visible then
		local val, isExact = parseHudCashText(CACHE.hudCashLabel.Text)
		if val ~= nil then
			return val, isExact
		end
	end

	local now = os.clock()
	if (now - CACHE.lastHudScan) < 1.5 then
		return nil, false
	end
	CACHE.lastHudScan = now

	local bestVal, bestExact = nil, false
	for _, gui in ipairs(PlayerGui:GetChildren()) do
		if gui:IsA("ScreenGui") and gui.Name ~= "DE_AutoDelivery_UI" and gui.Enabled then
			for _, desc in ipairs(gui:GetDescendants()) do
				if desc:IsA("TextLabel") and desc.Visible then
					local val, isExact = parseHudCashText(desc.Text)
					if val ~= nil then
						if isExact then
							CACHE.hudCashLabel = desc
							return val, true
						elseif not bestVal then
							bestVal = val
							bestExact = false
							CACHE.hudCashLabel = desc
						end
					end
				end
			end
		end
	end
	return bestVal, bestExact
end

-- แปลงค่าตัวเลขดิบเป็นรายการค่าที่เป็นไปได้ (ทั้งค่าตรงและค่าที่ถอดรหัสผ่าน MathModule)
local function addCashCandidates(rawVal, list)
	local num = tonumber(rawVal)
	if not num then return end

	if MathModule and type(MathModule.decodeLargeNumber) == "function" then
		local ok, decoded = pcall(MathModule.decodeLargeNumber, num)
		if ok and type(decoded) == "number" and decoded == decoded and decoded >= 0 and decoded < 1e15 then
			table.insert(list, math.floor(decoded))
		end
	end

	if num >= 0 and num < 1e15 and num == num then
		table.insert(list, math.floor(num))
	end
end

local function getPlayerCash()
	-- 1. เช็กจากป้ายเงินสดบนหน้าจอเกมจริง (PlayerGui HUD)
	local hudVal, isHudExact = getHudCashValue()
	if isHudExact and hudVal ~= nil then
		RUNTIME.lastKnownCash = hudVal
		return hudVal
	end

	local candidates = {}

	-- 2. ดึงจาก DataModule โดยตรง (ไม่ล็อกติดกับ Object เก่าตัวเดียว)
	if DataModule then
		pcall(function()
			if type(DataModule.Get) == "function" then
				addCashCandidates(DataModule:Get("Cash") or DataModule.Get(LocalPlayer, "Cash"), candidates)
			end
			if type(DataModule.GetStat) == "function" then
				addCashCandidates(DataModule.GetStat(LocalPlayer, "Cash"), candidates)
			end
			local statsFolder = nil
			if type(DataModule.GetStatsFolder) == "function" then
				statsFolder = DataModule.GetStatsFolder(LocalPlayer)
			elseif type(DataModule.GetLoadedStatsFolder) == "function" then
				statsFolder = DataModule.GetLoadedStatsFolder(LocalPlayer)
			end
			if statsFolder and statsFolder:FindFirstChild("Cash") then
				addCashCandidates(statsFolder.Cash.Value, candidates)
			end
		end)
	end

	-- 3. ดึงจากทุกโฟลเดอร์ Stats / leaderstats / ReplicatedStorage.Stats
	for _, folderName in ipairs({ "Stats", "leaderstats" }) do
		local f = LocalPlayer:FindFirstChild(folderName)
		if f and f:FindFirstChild("Cash") then
			addCashCandidates(f.Cash.Value, candidates)
		end
	end

	local repStats = ReplicatedStorage:FindFirstChild("Stats")
	if repStats then
		local f = repStats:FindFirstChild(LocalPlayer.Name) or repStats:FindFirstChild(tostring(LocalPlayer.UserId))
		if f and f:FindFirstChild("Cash") then
			addCashCandidates(f.Cash.Value, candidates)
		end
	end

	-- 4. ดึงจาก Attribute ของผู้เล่น
	addCashCandidates(LocalPlayer:GetAttribute("Cash"), candidates)

	if #candidates == 0 then
		return hudVal or RUNTIME.lastKnownCash or 0
	end

	-- คัดกรองค่าที่ตรงกับความจริงมากที่สุด
	-- กรณีมีป้าย HUD แบบย่อ (เช่น $1.25M) ให้เลือกค่าที่ใกล้เคียงกับป้าย HUD ที่สุด
	if hudVal and hudVal > 0 then
		local closest = candidates[1]
		local minDiff = math.abs(closest - hudVal)
		for i = 2, #candidates do
			local c = candidates[i]
			local diff = math.abs(c - hudVal)
			if diff < minDiff then
				minDiff = diff
				closest = c
			end
		end
		RUNTIME.lastKnownCash = closest
		return closest
	end

	-- กรณีเทียบกับเงินก่อนหน้าหลังส่งของเสร็จ (เลือกค่าที่เปลี่ยนแปลงอย่างสมเหตุสมผลและมีการอัปเดตจริง)
	if RUNTIME.lastKnownCash and RUNTIME.lastKnownCash > 0 then
		local bestUpdated = nil
		local bestDelta = math.huge
		for _, c in ipairs(candidates) do
			local delta = c - RUNTIME.lastKnownCash
			-- รายได้ต่อรอบในการส่งของอยู่ในช่วงที่สมเหตุสมผล (เช่น +$1 ถึง +$10,000,000)
			if delta > 0 and delta < 1e7 and delta < bestDelta then
				bestDelta = delta
				bestUpdated = c
			end
		end
		if bestUpdated then
			RUNTIME.lastKnownCash = bestUpdated
			return bestUpdated
		end

		-- ถ้ายังไม่มีค่าที่เพิ่มขึ้น ให้เลือกค่าที่ใกล้เคียงกับเงินเดิมที่สุด (ป้องกันค่าเข้ารหัสกระโดดเป็นพันล้าน)
		local closestToLast = candidates[1]
		local smallestGap = math.abs(closestToLast - RUNTIME.lastKnownCash)
		for i = 2, #candidates do
			local gap = math.abs(candidates[i] - RUNTIME.lastKnownCash)
			if gap < smallestGap then
				smallestGap = gap
				closestToLast = candidates[i]
			end
		end
		RUNTIME.lastKnownCash = closestToLast
		return closestToLast
	end

	RUNTIME.lastKnownCash = candidates[1]
	return candidates[1]
end

local initialCash = getPlayerCash()
if initialCash > 0 then
	RUNTIME.startCash = initialCash
end

-- ================= ระบบควบคุมรถและฟิสิกส์แบบ Zero-Lag =================
local VehiclesFolder = Workspace:FindFirstChild("Vehicles")

local function getMyVehicle()
	local v = VehicleUtil.GetPlayerSpawnedVehicle(LocalPlayer)
	if not v then
		if not VehiclesFolder or not VehiclesFolder.Parent then
			VehiclesFolder = Workspace:FindFirstChild("Vehicles")
		end
		if VehiclesFolder then
			v = VehiclesFolder:FindFirstChild(LocalPlayer.Name)
		end
	end
	return v
end

local function isTrailerAttached(vehicle)
	if not vehicle or not vehicle.Parent then return false end
	local trailer = TowablesController.GetAttachedTrailer()
	if trailer and trailer.Parent then
		return true
	end
	local hitch = CarTrailerUtil.GetHitchPart(vehicle, false)
	return hitch and hitch:GetAttribute("IsAttached") == true
end

-- ล้างความเร็วเฉพาะที่ AssemblyRootPart เพียงชิ้นเดียว (ไม่วนลูป 150 ชิ้น)
local function zeroVelocity(model)
	if not model or not model.Parent then return end
	local root = getRootPart(model)
	if root and root.Parent then
		root.AssemblyLinearVelocity = Vector3.zero
		root.AssemblyAngularVelocity = Vector3.zero
	end
end

local function setVehicleAnchored(vehicle, trailer, anchored)
	refreshVehicleCache(vehicle, trailer)
	if CACHE.vehicleRoot and CACHE.vehicleRoot.Parent then
		CACHE.vehicleRoot.Anchored = anchored
	end
	if CACHE.trailerRoot and CACHE.trailerRoot.Parent then
		CACHE.trailerRoot.Anchored = anchored
	end
end

-- กระตุ้นฟิสิกส์เบาๆ หลังวาร์ป เพื่อให้ Server รับรู้ตำแหน่งรถทันที
local function wakeVehiclePhysics(vehicle, trailer)
	if not vehicle or not vehicle.Parent then return end
	refreshVehicleCache(vehicle, trailer)
	setVehicleAnchored(vehicle, trailer, false)

	local root = CACHE.vehicleRoot
	if root and root.Parent then
		root.AssemblyLinearVelocity = Vector3.new(0, -0.4, 0)
		root.AssemblyAngularVelocity = Vector3.zero
	end
	if CACHE.trailerRoot and CACHE.trailerRoot.Parent then
		CACHE.trailerRoot.AssemblyLinearVelocity = Vector3.new(0, -0.4, 0)
		CACHE.trailerRoot.AssemblyAngularVelocity = Vector3.zero
	end

	local seat = CACHE.vehicleSeat
	if seat and seat.Parent then
		pcall(function()
			seat.ThrottleFloat = 0.01
			task.delay(0.05, function()
				if seat and seat.Parent then
					seat.ThrottleFloat = 0
					seat.Throttle = 0
				end
			end)
		end)
	end
end

-- ประคองรถไม่ให้ไหลตกเนินโดยเช็กและคุมเฉพาะ RootPart 2 ชิ้น (ลื่น 100%)
local function dampSlidingIfNeeded()
	local vehicle = CACHE.vehicle or getMyVehicle()
	if not vehicle or not vehicle.Parent then return end
	local trailer = CACHE.trailer or TowablesController.GetAttachedTrailer()
	refreshVehicleCache(vehicle, trailer)

	local vRoot = CACHE.vehicleRoot
	if vRoot and vRoot.Parent then
		local vel = vRoot.AssemblyLinearVelocity
		local horizSpeedSq = (vel.X * vel.X) + (vel.Z * vel.Z)
		if horizSpeedSq > 4.0 or vRoot.AssemblyAngularVelocity.Magnitude > 1.0 then
			vRoot.AssemblyLinearVelocity = Vector3.new(0, vel.Y * 0.5, 0)
			vRoot.AssemblyAngularVelocity = Vector3.zero
			if CACHE.trailerRoot and CACHE.trailerRoot.Parent then
				local tVel = CACHE.trailerRoot.AssemblyLinearVelocity
				CACHE.trailerRoot.AssemblyLinearVelocity = Vector3.new(0, tVel.Y * 0.5, 0)
				CACHE.trailerRoot.AssemblyAngularVelocity = Vector3.zero
			end
		end
	end
end

local function ensurePlayerSeated(vehicle)
	if not vehicle or not vehicle.Parent then return false end
	local char = LocalPlayer.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not hum or hum.Health <= 0 then return false end

	refreshVehicleCache(vehicle, CACHE.trailer)
	local seat = CACHE.vehicleSeat
	if not seat or not seat.Parent then return false end

	if hum.SeatPart ~= seat then
		setVehicleAnchored(vehicle, TowablesController.GetAttachedTrailer(), false)
		zeroVelocity(vehicle)
		pcall(function() seat:Sit(hum) end)
		task.wait(0.08)
		if hum.SeatPart ~= seat then
			char:PivotTo(seat.CFrame)
			task.wait(0.08)
			pcall(function() seat:Sit(hum) end)
			task.wait(0.15)
		end
	end
	return hum.SeatPart == seat
end

-- คำนวณ CFrame ให้กึ่งกลางระหว่างหัวลากกับพ่วงทับจุดรับ-ส่งพอดี และขนานกับความลาดชันของพื้น
local function getSlopeAlignedGroundCFrame(targetCF, ignoreList, flipYaw)
	local pos = targetCF.Position
	local _, yaw, _ = targetCF:ToEulerAnglesYXZ()
	if flipYaw then
		yaw = yaw + math.pi
	end

	local exclusions = {}
	if ignoreList then
		for i = 1, #ignoreList do
			if ignoreList[i] then
				exclusions[#exclusions + 1] = ignoreList[i]
			end
		end
	end
	local taggedPads = CollectionService:GetTagged(DeliveryConstants.Tags.DeliveryLocation)
	for i = 1, #taggedPads do
		exclusions[#exclusions + 1] = taggedPads[i]
	end
	SharedRaycastParams.FilterDescendantsInstances = exclusions

	local function castGround(checkPos)
		local hit = Workspace:Raycast(checkPos + Vector3.new(0, 18, 0), Vector3.new(0, -80, 0), SharedRaycastParams)
		if not hit then
			hit = Workspace:Raycast(checkPos + Vector3.new(0, 55, 0), Vector3.new(0, -150, 0), SharedRaycastParams)
		end
		return hit and hit.Position.Y or checkPos.Y
	end

	local flatRot = CFrame.Angles(0, yaw, 0)
	local lookVec = flatRot.LookVector

	local frontCheck = pos + (lookVec * 6)
	local backCheck = pos - (lookVec * 17)
	local centerY = castGround(pos)
	local frontY = castGround(frontCheck)
	local backY = castGround(backCheck)

	local pitch = math.atan2(frontY - backY, 23)
	pitch = math.clamp(pitch, math.rad(-20), math.rad(20))

	local baseHeight = math.max(centerY, (frontY + backY) * 0.5) + 2.3
	-- เลื่อนหัวลากไปข้างหน้า 6 Studs เพื่อให้จุดเชื่อมต่อระหว่างรถกับพ่วงอยู่กลางวงรับ-ส่งพอดี
	return CFrame.new(pos.X, baseHeight, pos.Z) * CFrame.Angles(0, yaw, 0) * CFrame.Angles(pitch, 0, 0) * CFrame.new(0, 0, -6)
end

local function getDeliveryLocationPart(targetPos, customRadius)
	local locations = CollectionService:GetTagged(DeliveryConstants.Tags.DeliveryLocation)

	if targetPos then
		local closestPart = nil
		local closestDist = math.huge
		local radiusLimit = customRadius or CONFIG.ExactPadRadius

		for i = 1, #locations do
			local part = locations[i]
			if isValidPart(part) then
				local dist = flatDistanceXZ(part.Position, targetPos)
				if dist < closestDist then
					closestDist = dist
					closestPart = part
				end
			end
		end
		if closestPart and closestDist <= radiusLimit then
			return closestPart
		end
		return nil
	end

	local fallbackPart = nil
	for i = 1, #locations do
		local part = locations[i]
		if isValidPart(part) then
			local canInteract = DeliveryUtil.CanPlayerInteractWithDeliveryLocation(LocalPlayer, part)
			local isLast = DeliveryUtil.IsLastDeliveryLocation(LocalPlayer, part)
			local towableOk = part:GetAttribute(DeliveryConstants.LocationAttributes.TowableAllowed) == true
				or part:GetAttribute(DeliveryConstants.LocationAttributes.TowableExclusive) == true

			if canInteract and not isLast and towableOk then
				return part
			end
			if towableOk and not isLast then
				fallbackPart = fallbackPart or part
			end
		end
	end

	return fallbackPart or locations[1]
end

local function pivotTruckAndTrailerAligned(vehicle, trailer, cabCF)
	if not vehicle or not vehicle.Parent then return end
	refreshVehicleCache(vehicle, trailer)
	setVehicleAnchored(vehicle, trailer, false)

	zeroVelocity(vehicle)
	if trailer and trailer.Parent then
		zeroVelocity(trailer)
	end

	vehicle:PivotTo(cabCF)
	if trailer and trailer.Parent then
		trailer:PivotTo(cabCF * RUNTIME.trailerRelativeCF)
		zeroVelocity(trailer)
	end
	zeroVelocity(vehicle)
	wakeVehiclePhysics(vehicle, trailer)
end

-- วาร์ปแบบไร้แรงกระตุก: โหลดแมพปลายทางให้เสร็จก่อน แล้วค่อยวางรถลงพื้นครั้งเดียวจบ
local function teleportTruckAndTrailer(targetCFrame, waitForStreamPos, flipYaw)
	local vehicle = getMyVehicle()
	local trailer = TowablesController.GetAttachedTrailer()
	local char = LocalPlayer.Character
	local destPos = waitForStreamPos or targetCFrame.Position
	local ignore = { char, vehicle, trailer }

	refreshVehicleCache(vehicle, trailer)

	if vehicle then
		ensurePlayerSeated(vehicle)
	end

	-- ถ้าจุดรับ-ส่งโหลดพร้อมอยู่แล้ว ให้วางรถลงพื้นทันทีในครั้งเดียว
	local readyPart = getDeliveryLocationPart(destPos, CONFIG.ExactPadRadius)
	if isValidPart(readyPart) and vehicle then
		local cleanCabCF = getSlopeAlignedGroundCFrame(readyPart.CFrame, ignore, flipYaw)
		pivotTruckAndTrailerAligned(vehicle, trailer, cleanCabCF)
		return readyPart
	end

	-- ถ้าระยะไกลและแมพยังไม่โหลด ให้โหลดแมพในพื้นหลังขณะที่รถยังจอดนิ่งอยู่ที่เดิม (กล้องไม่สั่น)
	safeRequestStream(destPos, 1.8)

	local waitDeadline = os.clock() + 1.5
	local streamedPart = getDeliveryLocationPart(destPos, CONFIG.ExactPadRadius)
	while not isValidPart(streamedPart) and os.clock() < waitDeadline do
		task.wait(0.08)
		streamedPart = getDeliveryLocationPart(destPos, CONFIG.ExactPadRadius)
	end

	streamedPart = streamedPart or getDeliveryLocationPart(destPos, CONFIG.FallbackPadRadius)

	-- กรณีเซิร์ฟเวอร์ต้องเห็นตัวผู้เล่นใกล้จุดหมายถึงจะยอมสร้าง Pad ให้ย้ายไป Anchor นิ่งๆ ครั้งเดียว (ไม่วนลูป PivotTo)
	if not isValidPart(streamedPart) and vehicle and vehicle.Parent then
		local tempCF = CFrame.new(destPos + Vector3.new(0, 12, 0))
		vehicle:PivotTo(tempCF)
		if trailer and trailer.Parent then
			trailer:PivotTo(tempCF * RUNTIME.trailerRelativeCF)
		end
		zeroVelocity(vehicle)
		if trailer then zeroVelocity(trailer) end
		setVehicleAnchored(vehicle, trailer, true)

		local padWait = os.clock() + 1.2
		while not isValidPart(streamedPart) and os.clock() < padWait do
			task.wait(0.08)
			streamedPart = getDeliveryLocationPart(destPos, CONFIG.ExactPadRadius)
				or getDeliveryLocationPart(destPos, CONFIG.FallbackPadRadius)
		end
		setVehicleAnchored(vehicle, trailer, false)
	end

	if vehicle and vehicle.Parent then
		local finalTargetCF = isValidPart(streamedPart) and streamedPart.CFrame or CFrame.new(destPos)
		local cleanCabCF = getSlopeAlignedGroundCFrame(finalTargetCF, ignore, flipYaw)
		pivotTruckAndTrailerAligned(vehicle, trailer, cleanCabCF)
		return streamedPart
	elseif char then
		char:PivotTo(CFrame.new(destPos + Vector3.new(0, 6, 0)))
	end
	return nil
end

local function setupTruckAndTrailer()
	if not CONFIG.AutoSpawnSetup then return end
	local vehicle = getMyVehicle()

	if not vehicle or not vehicle.Parent or vehicle:GetAttribute("VehicleId") ~= CONFIG.TruckId then
		RUNTIME.statusText = "เสกรถบรรทุก"
		local args = {
			[1] = "Spawn",
			[2] = CONFIG.TruckId,
			[5] = Vector3.new(-0.1908005177974701, 0, -0.9816288352012634)
		}
		pcall(function()
			RemotesFolder:WaitForChild("VehicleEvent"):FireServer(unpack(args))
		end)

		local timeout = os.clock() + 10
		repeat
			task.wait(0.15)
			vehicle = getMyVehicle()
		until (vehicle and vehicle:FindFirstChild("Weight")) or os.clock() > timeout
		task.wait(0.4)
		CACHE.vehicle = nil
		refreshVehicleCache(vehicle, TowablesController.GetAttachedTrailer())
	end

	if vehicle then
		ensurePlayerSeated(vehicle)
	end

	if vehicle and not isTrailerAttached(vehicle) then
		RUNTIME.statusText = "เสกพ่วงหลัง"
		pcall(function()
			TowablesController.AttemptToSpawnTowable(CONFIG.TrailerId)
		end)

		local timeout = os.clock() + 8
		repeat
			task.wait(0.15)
		until isTrailerAttached(vehicle) or os.clock() > timeout
		task.wait(0.35)

		local trailer = TowablesController.GetAttachedTrailer()
		CACHE.trailer = nil
		refreshVehicleCache(vehicle, trailer)

		if vehicle and trailer and trailer.Parent then
			pcall(function()
				local rel = vehicle:GetPivot():ToObjectSpace(trailer:GetPivot())
				if rel.Position.Magnitude >= 12 and rel.Position.Magnitude <= 35 then
					RUNTIME.trailerRelativeCF = CFrame.new(0, rel.Position.Y, rel.Position.Z)
				end
			end)
		end
	end
end

local function getDeliveryMetrics(state)
	local carried = (state and state.ItemsCarried)
		or (DeliveryUtil.GetItemsCarried and DeliveryUtil.GetItemsCarried(LocalPlayer))
		or LocalPlayer:GetAttribute("ItemsCarried")
		or 0

	local maxCap = (state and state.MaxCapacity)
		or (DeliveryUtil.GetMaxCapacity and DeliveryUtil.GetMaxCapacity(LocalPlayer))
		or LocalPlayer:GetAttribute("MaxCapacity")
		or 8

	local remAtPickup = (state and state.PackagesRemainingAtPickup)
		or (DeliveryUtil.GetPackagesRemainingAtPickup and DeliveryUtil.GetPackagesRemainingAtPickup(LocalPlayer))
		or LocalPlayer:GetAttribute("PackagesRemainingAtPickup")

	RUNTIME.carried = tonumber(carried) or 0
	RUNTIME.maxCap = tonumber(maxCap) or 8

	return RUNTIME.carried, RUNTIME.maxCap, remAtPickup ~= nil and tonumber(remAtPickup) or nil
end

local function ensureDeliveryJobStarted()
	local state = DeliveryJobTask.GetCurrentDeliveryState()
	local carried = getDeliveryMetrics(state)

	local needInitialHighRisk = (not RUNTIME.hasEnforcedHighRisk and JobsUtil.DoesPlayerHaveJob(LocalPlayer, JobsConstants.JobIds.Delivery) and carried == 0 and RUNTIME.deliveriesDone == 0)

	if needInitialHighRisk then
		RUNTIME.statusText = "ตั้งค่าโหมด HighRisk เริ่มต้น"
		pcall(function()
			JobsController.RequestEndJobSession("jobPad")
		end)
		RUNTIME.isDeliveringLatch = false
		task.wait(0.8)
	end

	if not JobsUtil.DoesPlayerHaveJob(LocalPlayer, JobsConstants.JobIds.Delivery) then
		RUNTIME.statusText = "เริ่มงานส่งของ"
		pcall(function()
			Remotes.fireServer(
				JobsConstants.Remotes.RequestStartJobSession,
				JobsConstants.JobIds.Delivery,
				"jobPad",
				CONFIG.DeliveryMode
			)
		end)
		RUNTIME.hasEnforcedHighRisk = true
		RUNTIME.isDeliveringLatch = false
		task.wait(0.9)
	else
		RUNTIME.hasEnforcedHighRisk = true
	end

	if carried == 0 and DeliveryConstants.RemoteEvents and DeliveryConstants.RemoteEvents.SetDeliveryMode then
		pcall(function()
			Remotes.fireServer(DeliveryConstants.RemoteEvents.SetDeliveryMode, CONFIG.DeliveryMode)
		end)
	end
end

-- ================= UI =================
local OldGui = PlayerGui:FindFirstChild("DE_AutoDelivery_UI")
if OldGui then
	OldGui:Destroy()
end

local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name = "DE_AutoDelivery_UI"
ScreenGui.ResetOnSpawn = false
ScreenGui.IgnoreGuiInset = true
ScreenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
ScreenGui.DisplayOrder = 999
ScreenGui.Parent = PlayerGui

local FloatBtn = Instance.new("TextButton")
FloatBtn.Size = UDim2.fromOffset(42, 42)
FloatBtn.Position = UDim2.new(0, 18, 0.5, -21)
FloatBtn.BackgroundColor3 = Color3.fromRGB(20, 22, 30)
FloatBtn.Text = "UI"
FloatBtn.TextSize = 13
FloatBtn.Font = Enum.Font.GothamBold
FloatBtn.TextColor3 = Color3.fromRGB(240, 245, 255)
FloatBtn.Parent = ScreenGui
Instance.new("UICorner", FloatBtn).CornerRadius = UDim.new(0, 8)
local FloatStroke = Instance.new("UIStroke", FloatBtn)
FloatStroke.Color = Color3.fromRGB(55, 65, 90)
FloatStroke.Thickness = 1.5

local MainFrame = Instance.new("Frame")
MainFrame.Size = UDim2.fromOffset(400, 330)
MainFrame.Position = UDim2.new(0.5, -200, 0.5, -165)
MainFrame.BackgroundColor3 = Color3.fromRGB(15, 17, 24)
MainFrame.BorderSizePixel = 0
MainFrame.Parent = ScreenGui
Instance.new("UICorner", MainFrame).CornerRadius = UDim.new(0, 10)
local MainStroke = Instance.new("UIStroke", MainFrame)
MainStroke.Color = Color3.fromRGB(45, 55, 80)
MainStroke.Thickness = 1.5

local function makeDraggable(handle, frame)
	local dragging = false
	local dragInput = nil
	local dragStart = nil
	local startPos = nil

	trackConnection(handle.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			dragStart = input.Position
			startPos = frame.Position
		end
	end))

	trackConnection(handle.InputChanged:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
			dragInput = input
		end
	end))

	trackConnection(UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = false
		end
	end))

	trackConnection(UserInputService.InputChanged:Connect(function(input)
		if input == dragInput and dragging and dragStart and startPos then
			local delta = input.Position - dragStart
			frame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
		end
	end))
end
makeDraggable(FloatBtn, FloatBtn)

local TopBar = Instance.new("Frame")
TopBar.Size = UDim2.new(1, 0, 0, 36)
TopBar.BackgroundColor3 = Color3.fromRGB(22, 25, 36)
TopBar.BorderSizePixel = 0
TopBar.Parent = MainFrame
Instance.new("UICorner", TopBar).CornerRadius = UDim.new(0, 10)
makeDraggable(TopBar, MainFrame)

local TitleLabel = Instance.new("TextLabel")
TitleLabel.Size = UDim2.new(1, -80, 1, 0)
TitleLabel.Position = UDim2.fromOffset(14, 0)
TitleLabel.BackgroundTransparency = 1
TitleLabel.Text = "Auto Delivery (Ultra Smooth & Smart Cash)"
TitleLabel.TextColor3 = Color3.fromRGB(240, 245, 255)
TitleLabel.Font = Enum.Font.GothamBold
TitleLabel.TextSize = 13
TitleLabel.TextXAlignment = Enum.TextXAlignment.Left
TitleLabel.Parent = TopBar

local MinBtn = Instance.new("TextButton")
MinBtn.Size = UDim2.fromOffset(24, 22)
MinBtn.Position = UDim2.new(1, -32, 0.5, -11)
MinBtn.BackgroundColor3 = Color3.fromRGB(35, 40, 58)
MinBtn.Text = "-"
MinBtn.TextColor3 = Color3.fromRGB(210, 220, 240)
MinBtn.Font = Enum.Font.GothamBold
MinBtn.TextSize = 14
MinBtn.Parent = TopBar
Instance.new("UICorner", MinBtn).CornerRadius = UDim.new(0, 5)

local function toggleWindow()
	MainFrame.Visible = not MainFrame.Visible
end
MinBtn.MouseButton1Click:Connect(toggleWindow)
FloatBtn.MouseButton1Click:Connect(toggleWindow)

local StatusCard = Instance.new("Frame")
StatusCard.Size = UDim2.new(1, -24, 0, 64)
StatusCard.Position = UDim2.fromOffset(12, 44)
StatusCard.BackgroundColor3 = Color3.fromRGB(21, 24, 34)
StatusCard.Parent = MainFrame
Instance.new("UICorner", StatusCard).CornerRadius = UDim.new(0, 8)
local CardStroke = Instance.new("UIStroke", StatusCard)
CardStroke.Color = Color3.fromRGB(45, 55, 80)
CardStroke.Thickness = 1

local StatusMainLabel = Instance.new("TextLabel")
StatusMainLabel.Size = UDim2.new(1, -20, 0, 18)
StatusMainLabel.Position = UDim2.fromOffset(10, 5)
StatusMainLabel.BackgroundTransparency = 1
StatusMainLabel.Text = "สถานะ: ปิดใช้งาน"
StatusMainLabel.TextColor3 = Color3.fromRGB(0, 210, 255)
StatusMainLabel.Font = Enum.Font.GothamBold
StatusMainLabel.TextSize = 12
StatusMainLabel.TextXAlignment = Enum.TextXAlignment.Left
StatusMainLabel.Parent = StatusCard

local CargoLabel = Instance.new("TextLabel")
CargoLabel.Size = UDim2.new(1, -20, 0, 18)
CargoLabel.Position = UDim2.fromOffset(10, 23)
CargoLabel.BackgroundTransparency = 1
CargoLabel.Text = "ของบนพ่วง: 0/8 | โหมด: รอรับของ"
CargoLabel.TextColor3 = Color3.fromRGB(210, 215, 230)
CargoLabel.Font = Enum.Font.GothamMedium
CargoLabel.TextSize = 11
CargoLabel.TextXAlignment = Enum.TextXAlignment.Left
CargoLabel.Parent = StatusCard

local ProfitLabel = Instance.new("TextLabel")
ProfitLabel.Size = UDim2.new(1, -20, 0, 18)
ProfitLabel.Position = UDim2.fromOffset(10, 41)
ProfitLabel.BackgroundTransparency = 1
ProfitLabel.Text = "รอบส่ง: 0 | กำไร: $0 | เงิน: $0 | เวลา: 00:00:00"
ProfitLabel.TextColor3 = Color3.fromRGB(120, 235, 160)
ProfitLabel.Font = Enum.Font.GothamMedium
ProfitLabel.TextSize = 11
ProfitLabel.TextXAlignment = Enum.TextXAlignment.Left
ProfitLabel.Parent = StatusCard

local Scroll = Instance.new("ScrollingFrame")
Scroll.Size = UDim2.new(1, -24, 1, -120)
Scroll.Position = UDim2.fromOffset(12, 114)
Scroll.BackgroundTransparency = 1
Scroll.ScrollBarThickness = 3
Scroll.ScrollBarImageColor3 = Color3.fromRGB(80, 95, 130)
Scroll.CanvasSize = UDim2.fromOffset(0, 0)
Scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
Scroll.Parent = MainFrame

local Layout = Instance.new("UIListLayout", Scroll)
Layout.Padding = UDim.new(0, 6)
Layout.SortOrder = Enum.SortOrder.LayoutOrder

local ToggleTweenInfo = TweenInfo.new(0.15)

local function addToggle(title, defaultVal, callback)
	local Row = Instance.new("Frame")
	Row.Size = UDim2.new(1, -6, 0, 34)
	Row.BackgroundColor3 = Color3.fromRGB(22, 25, 36)
	Row.Parent = Scroll
	Instance.new("UICorner", Row).CornerRadius = UDim.new(0, 6)

	local T = Instance.new("TextLabel")
	T.Size = UDim2.new(1, -70, 1, 0)
	T.Position = UDim2.fromOffset(12, 0)
	T.BackgroundTransparency = 1
	T.Text = title
	T.TextColor3 = Color3.fromRGB(235, 240, 255)
	T.Font = Enum.Font.GothamMedium
	T.TextSize = 12
	T.TextXAlignment = Enum.TextXAlignment.Left
	T.Parent = Row

	local Sw = Instance.new("TextButton")
	Sw.Size = UDim2.fromOffset(42, 20)
	Sw.Position = UDim2.new(1, -52, 0.5, -10)
	Sw.BackgroundColor3 = defaultVal and Color3.fromRGB(0, 190, 125) or Color3.fromRGB(50, 55, 75)
	Sw.Text = ""
	Sw.Parent = Row
	Instance.new("UICorner", Sw).CornerRadius = UDim.new(1, 0)

	local Knob = Instance.new("Frame")
	Knob.Size = UDim2.fromOffset(14, 14)
	Knob.Position = defaultVal and UDim2.fromOffset(25, 3) or UDim2.fromOffset(3, 3)
	Knob.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	Knob.Parent = Sw
	Instance.new("UICorner", Knob).CornerRadius = UDim.new(1, 0)

	local state = defaultVal
	Sw.MouseButton1Click:Connect(function()
		state = not state
		TweenService:Create(Sw, ToggleTweenInfo, {
			BackgroundColor3 = state and Color3.fromRGB(0, 190, 125) or Color3.fromRGB(50, 55, 75)
		}):Play()
		TweenService:Create(Knob, ToggleTweenInfo, {
			Position = state and UDim2.fromOffset(25, 3) or UDim2.fromOffset(3, 3)
		}):Play()
		callback(state)
	end)
end

local function addButton(title, btnLabel, callback)
	local Row = Instance.new("Frame")
	Row.Size = UDim2.new(1, -6, 0, 34)
	Row.BackgroundColor3 = Color3.fromRGB(22, 25, 36)
	Row.Parent = Scroll
	Instance.new("UICorner", Row).CornerRadius = UDim.new(0, 6)

	local T = Instance.new("TextLabel")
	T.Size = UDim2.new(1, -120, 1, 0)
	T.Position = UDim2.fromOffset(12, 0)
	T.BackgroundTransparency = 1
	T.Text = title
	T.TextColor3 = Color3.fromRGB(235, 240, 255)
	T.Font = Enum.Font.GothamMedium
	T.TextSize = 12
	T.TextXAlignment = Enum.TextXAlignment.Left
	T.Parent = Row

	local B = Instance.new("TextButton")
	B.Size = UDim2.fromOffset(96, 22)
	B.Position = UDim2.new(1, -106, 0.5, -11)
	B.BackgroundColor3 = Color3.fromRGB(40, 95, 180)
	B.Text = btnLabel
	B.TextColor3 = Color3.fromRGB(255, 255, 255)
	B.Font = Enum.Font.GothamBold
	B.TextSize = 11
	B.Parent = Row
	Instance.new("UICorner", B).CornerRadius = UDim.new(0, 5)

	B.MouseButton1Click:Connect(function()
		callback(B)
	end)
end

addToggle("ออโต้ส่งของ", Env.AutoDelivery, function(val)
	Env.AutoDelivery = val
	if not val then
		RUNTIME.statusText = "ปิดใช้งาน"
		local v = getMyVehicle()
		local t = TowablesController.GetAttachedTrailer()
		setVehicleAnchored(v, t, false)
	end
end)

addToggle("เสกรถและพ่วงอัตโนมัติ", CONFIG.AutoSpawnSetup, function(val)
	CONFIG.AutoSpawnSetup = val
end)

addToggle("ป้องกันด่าน AFK", CONFIG.AntiAFK, function(val)
	CONFIG.AntiAFK = val
end)

addButton("บังคับไปจุดส่งทันที", "ส่งทันที", function(btn)
	RUNTIME.isDeliveringLatch = true
	btn.Text = "สำเร็จ"
	task.delay(0.8, function()
		if btn and btn.Parent then btn.Text = "ส่งทันที" end
	end)
end)

addButton("เสกรถและพ่วง", "เสกใหม่", function(btn)
	btn.Text = "กำลังเสก"
	task.spawn(function()
		setupTruckAndTrailer()
		if btn and btn.Parent then btn.Text = "เสกใหม่" end
	end)
end)

addButton("รีเซ็ตอาชีพใหม่", "รีเซ็ต", function(btn)
	btn.Text = "รอสักครู่"
	task.spawn(function()
		pcall(function() JobsController.RequestEndJobSession("jobPad") end)
		RUNTIME.hasEnforcedHighRisk = false
		RUNTIME.isDeliveringLatch = false
		task.wait(0.8)
		ensureDeliveryJobStarted()
		if btn and btn.Parent then btn.Text = "รีเซ็ต" end
	end)
end)

-- ================= ลูปป้องกันด่าน AFK (ไร้การกดปุ่มกวนหน้าจอ) =================
trackConnection(LocalPlayer.Idled:Connect(function()
	if CONFIG.AntiAFK then
		pcall(function()
			VirtualUser:CaptureController()
			VirtualUser:ClickButton2(Vector2.zero)
		end)
	end
end))

task.spawn(function()
	while ScreenGui and ScreenGui.Parent and Env.AutoDeliverySession == CurrentSessionId do
		if CONFIG.AntiAFK then
			if game.PlaceId == AFK_PLACE_ID then
				RUNTIME.statusText = "พบด่าน AFK กำลังกลับแมพหลัก"
				pcall(function()
					TeleportService:Teleport(MAIN_PLACE_ID, LocalPlayer)
				end)
				task.wait(5)
			end

			local vehicle = CACHE.vehicle or getMyVehicle()
			if vehicle and vehicle.Parent then
				if vehicle:GetAttribute("IdleStartedTimestamp") ~= nil then
					pcall(vehicle.SetAttribute, vehicle, "IdleStartedTimestamp", nil)
				end
				if vehicle:GetAttribute("AFKTimestamp") ~= nil then
					pcall(vehicle.SetAttribute, vehicle, "AFKTimestamp", nil)
				end
			end

			if LocalPlayer:GetAttribute("IdleStartedTimestamp") ~= nil then
				pcall(LocalPlayer.SetAttribute, LocalPlayer, "IdleStartedTimestamp", nil)
			end
			if LocalPlayer:GetAttribute("IsAFK") ~= nil then
				pcall(LocalPlayer.SetAttribute, LocalPlayer, "IsAFK", false)
			end
		end
		task.wait(4)
	end
end)

-- ================= ลูปอัปเดต UI และซิงก์ค่าเงินสด =================
task.spawn(function()
	local lastStatusStr = ""
	local lastCargoStr = ""
	local lastProfitStr = ""
	local lastCashVal = -1
	local cachedCashStr = "0"
	local cachedProfitStr = "0"

	while ScreenGui and ScreenGui.Parent and Env.AutoDeliverySession == CurrentSessionId do
		local curCash = getPlayerCash()
		if (not RUNTIME.startCash or RUNTIME.startCash <= 0) and curCash > 0 then
			RUNTIME.startCash = curCash
		end

		if MainFrame.Visible then
			if curCash ~= lastCashVal then
				lastCashVal = curCash
				cachedCashStr = formatNumber(curCash)
				local profit = RUNTIME.startCash and math.max(0, curCash - RUNTIME.startCash) or 0
				cachedProfitStr = formatNumber(profit)
			end

			local newStatusStr = "สถานะ: " .. RUNTIME.statusText
			if newStatusStr ~= lastStatusStr then
				lastStatusStr = newStatusStr
				StatusMainLabel.Text = newStatusStr
			end

			local newCargoStr = string.format(
				"ของบนพ่วง: %d/%d | โหมด: %s",
				RUNTIME.carried,
				RUNTIME.maxCap,
				RUNTIME.isDeliveringLatch and "กำลังส่งของ" or "กำลังรับของ"
			)
			if newCargoStr ~= lastCargoStr then
				lastCargoStr = newCargoStr
				CargoLabel.Text = newCargoStr
			end

			local elapsed = math.floor(os.clock() - RUNTIME.sessionStart)
			local hours = math.floor(elapsed / 3600)
			local mins = math.floor((elapsed % 3600) / 60)
			local secs = elapsed % 60
			local newProfitStr = string.format(
				"รอบส่ง: %d | กำไร: $%s | เงิน: $%s | เวลา: %02d:%02d:%02d",
				RUNTIME.deliveriesDone,
				cachedProfitStr,
				cachedCashStr,
				hours,
				mins,
				secs
			)
			if newProfitStr ~= lastProfitStr then
				lastProfitStr = newProfitStr
				ProfitLabel.Text = newProfitStr
			end
		end
		task.wait(0.35)
	end
end)

-- ================= ลูปฟาร์มส่งของหลัก =================
task.spawn(function()
	while ScreenGui and ScreenGui.Parent and Env.AutoDeliverySession == CurrentSessionId do
		if not Env.AutoDelivery then
			task.wait(0.3)
			continue
		end

		local success, err = pcall(function()
			local vehicle = getMyVehicle()
			if not vehicle or not isTrailerAttached(vehicle) then
				setupTruckAndTrailer()
				vehicle = getMyVehicle()
			end
			refreshVehicleCache(vehicle, TowablesController.GetAttachedTrailer())

			if vehicle then
				ensurePlayerSeated(vehicle)
			end

			ensureDeliveryJobStarted()

			local state = DeliveryJobTask.GetCurrentDeliveryState()

			-- รอจังหวะเปลี่ยนผ่าน State สั้นๆ หลังส่งของเสร็จ เพื่อไม่ให้สคริปต์เข้าใจผิดว่างานหลุด
			if not state and JobsUtil.DoesPlayerHaveJob(LocalPlayer, JobsConstants.JobIds.Delivery) then
				local waitTransition = os.clock() + 1.2
				while Env.AutoDelivery and not state and os.clock() < waitTransition do
					task.wait(0.15)
					state = DeliveryJobTask.GetCurrentDeliveryState()
				end
			end

			-- กรณีเริ่มงานครั้งแรกสุดและยังไม่มี State งาน
			if not state then
				RUNTIME.isDeliveringLatch = false
				RUNTIME.statusText = "หาจุดรับงานเริ่มต้น"
				local startPart = getDeliveryLocationPart(nil)
				if isValidPart(startPart) and vehicle then
					if flatDistanceXZ(vehicle:GetPivot().Position, startPart.Position) > CONFIG.InZoneRadiusXZ then
						teleportTruckAndTrailer(startPart.CFrame, startPart.Position, false)
						task.wait(0.2)
					end
					DeliveryJobTask.InteractWithDeliveryLocation(startPart)
					local waitStart = os.clock() + 2.5
					while Env.AutoDelivery and os.clock() < waitStart do
						if DeliveryJobTask.GetCurrentDeliveryState() ~= nil then
							break
						end
						dampSlidingIfNeeded()
						task.wait(0.15)
					end
				else
					task.wait(0.4)
				end
				return
			end

			local carried, maxCap, remAtPickup = getDeliveryMetrics(state)

			if carried == 0 then
				RUNTIME.isDeliveringLatch = false
			end

			local isCargoReadyToDeliver = carried > 0 and (
				carried >= maxCap
				or (remAtPickup ~= nil and remAtPickup <= 0)
				or (state.PickupPosition == nil and state.DestinationPosition ~= nil)
			)

			if isCargoReadyToDeliver and state.DestinationPosition ~= nil then
				RUNTIME.isDeliveringLatch = true
			end

			-- ================= 1. โหมดไปจุดส่งของ =================
			if RUNTIME.isDeliveringLatch and state.DestinationPosition ~= nil then
				local destPos = state.DestinationPosition
				RUNTIME.statusText = string.format("ไปจุดส่งของ (%d/%d)", carried, maxCap)

				local dropoffPart = getDeliveryLocationPart(destPos, CONFIG.ExactPadRadius)
				local curVeh = getMyVehicle()

				if not curVeh or flatDistanceXZ(curVeh:GetPivot().Position, destPos) > CONFIG.InZoneRadiusXZ then
					local targetCF = isValidPart(dropoffPart) and dropoffPart.CFrame or CFrame.new(destPos)
					local streamedDrop = teleportTruckAndTrailer(targetCF, destPos, false)
					dropoffPart = isValidPart(streamedDrop) and streamedDrop or getDeliveryLocationPart(destPos, CONFIG.FallbackPadRadius)
					task.wait(0.2)
				else
					dropoffPart = dropoffPart or getDeliveryLocationPart(destPos, CONFIG.FallbackPadRadius)
				end

				if isValidPart(dropoffPart) then
					DeliveryJobTask.InteractWithDeliveryLocation(dropoffPart)
				end

				local lastDropCarried = carried
				local lastProgressTime = os.clock()
				local lastInteractTime = os.clock()
				local dropTimeout = os.clock() + 32
				local flipDropYaw = false

				while Env.AutoDelivery and Env.AutoDeliverySession == CurrentSessionId and os.clock() < dropTimeout do
					dampSlidingIfNeeded()

					local current = DeliveryJobTask.GetCurrentDeliveryState()
					local curCarried, curMaxCap = getDeliveryMetrics(current)
					RUNTIME.statusText = string.format("กำลังส่งของ (%d/%d)", curCarried, curMaxCap)

					if not current or curCarried == 0 then
						RUNTIME.deliveriesDone += 1
						RUNTIME.statusText = "ส่งของสำเร็จ"
						RUNTIME.isDeliveringLatch = false
						task.wait(0.3)
						getPlayerCash() -- บังคับซิงก์ค่าเงินทันทีหลังส่งเสร็จ
						break
					end

					if curCarried < lastDropCarried then
						lastDropCarried = curCarried
						lastProgressTime = os.clock()
						dropTimeout = os.clock() + 18
					end

					-- ถ้าระบบกำลังหมุนหลอดเหลืองส่งของอยู่ ห้ามนับว่าค้างเด็ดขาด
					if current.IsDropping then
						lastProgressTime = os.clock()
					end

					local curDestPos = current.DestinationPosition or destPos
					if not isValidPart(dropoffPart) and curDestPos then
						dropoffPart = getDeliveryLocationPart(curDestPos, CONFIG.ExactPadRadius)
							or getDeliveryLocationPart(curDestPos, CONFIG.FallbackPadRadius)
					end

					curVeh = getMyVehicle()
					if isValidPart(dropoffPart) and curVeh then
						ensurePlayerSeated(curVeh)

						if not current.IsDropping then
							if flatDistanceXZ(curVeh:GetPivot().Position, dropoffPart.Position) > CONFIG.InZoneRadiusXZ then
								teleportTruckAndTrailer(dropoffPart.CFrame, curDestPos, flipDropYaw)
								task.wait(0.2)
								lastProgressTime = os.clock()
								lastInteractTime = os.clock()
								DeliveryJobTask.InteractWithDeliveryLocation(dropoffPart)
							elseif (os.clock() - lastProgressTime) >= CONFIG.StallRetryTime then
								lastProgressTime = os.clock()
								flipDropYaw = not flipDropYaw
								teleportTruckAndTrailer(dropoffPart.CFrame, curDestPos, flipDropYaw)
								task.wait(0.22)
								lastInteractTime = os.clock()
								DeliveryJobTask.InteractWithDeliveryLocation(dropoffPart)
							elseif (os.clock() - lastInteractTime) >= 1.5 then
								lastInteractTime = os.clock()
								DeliveryJobTask.InteractWithDeliveryLocation(dropoffPart)
							end
						end
					elseif curDestPos and curVeh and not current.IsDropping then
						safeRequestStream(curDestPos, 1.4)
						if flatDistanceXZ(curVeh:GetPivot().Position, curDestPos) > 25 then
							teleportTruckAndTrailer(CFrame.new(curDestPos), curDestPos, flipDropYaw)
							task.wait(0.2)
						end
					end
					task.wait(0.15)
				end

			-- ================= 2. โหมดไปจุดรับของ =================
			elseif state.PickupPosition ~= nil then
				local pickupPos = state.PickupPosition
				RUNTIME.statusText = string.format("ไปจุดรับของ (%d/%d)", carried, maxCap)

				local pickupPart = getDeliveryLocationPart(pickupPos, CONFIG.ExactPadRadius)
				local curVeh = getMyVehicle()

				if not curVeh or flatDistanceXZ(curVeh:GetPivot().Position, pickupPos) > CONFIG.InZoneRadiusXZ then
					local targetCF = isValidPart(pickupPart) and pickupPart.CFrame or CFrame.new(pickupPos)
					local streamedPick = teleportTruckAndTrailer(targetCF, pickupPos, false)
					pickupPart = isValidPart(streamedPick) and streamedPick or getDeliveryLocationPart(pickupPos, CONFIG.FallbackPadRadius)
					task.wait(0.2)
				else
					pickupPart = pickupPart or getDeliveryLocationPart(pickupPos, CONFIG.FallbackPadRadius)
				end

				if isValidPart(pickupPart) and not state.IsCollecting then
					DeliveryJobTask.InteractWithDeliveryLocation(pickupPart)
				end

				local lastCarried = carried
				local lastIncreaseTime = os.clock()
				local lastInteractTime = os.clock()
				local collectTimeout = os.clock() + 34
				local preStreamedDest = false
				local flipPickupYaw = false

				while Env.AutoDelivery and Env.AutoDeliverySession == CurrentSessionId and os.clock() < collectTimeout do
					dampSlidingIfNeeded()

					local current = DeliveryJobTask.GetCurrentDeliveryState()
					if not current then break end

					local curCarried, curMaxCap, curRem = getDeliveryMetrics(current)
					RUNTIME.statusText = string.format("รับของขึ้นพ่วง (%d/%d)", curCarried, curMaxCap)

					if curCarried > lastCarried then
						lastCarried = curCarried
						lastIncreaseTime = os.clock()
						collectTimeout = os.clock() + 20
					end

					-- ถ้าระบบกำลังหมุนหลอดเหลืองรับของอยู่ ห้ามนับว่าค้างและห้ามวาร์ปซ้ำเด็ดขาด
					if current.IsCollecting then
						lastIncreaseTime = os.clock()
					end

					-- โหลดแมพจุดส่งล่วงหน้าในพื้นหลังเมื่อของใกล้เต็มพ่วง
					if not preStreamedDest and curCarried >= (curMaxCap - 1) and current.DestinationPosition then
						preStreamedDest = true
						local dPos = current.DestinationPosition
						task.spawn(function()
							safeRequestStream(dPos, 1.8)
						end)
					end

					local fullNow = (curCarried >= curMaxCap)
					local pickupDepleted = (curRem ~= nil and curRem <= 0 and curCarried > 0)
					local noPickupPos = (curCarried > 0 and current.PickupPosition == nil)

					if (fullNow or pickupDepleted or noPickupPos) and current.DestinationPosition ~= nil then
						RUNTIME.isDeliveringLatch = true
						task.wait(0.18)
						break
					end

					local curPickPos = current.PickupPosition or pickupPos
					if not isValidPart(pickupPart) and curPickPos then
						pickupPart = getDeliveryLocationPart(curPickPos, CONFIG.ExactPadRadius)
							or getDeliveryLocationPart(curPickPos, CONFIG.FallbackPadRadius)
					end

					curVeh = getMyVehicle()
					if isValidPart(pickupPart) and curVeh then
						ensurePlayerSeated(curVeh)

						if not current.IsCollecting then
							if flatDistanceXZ(curVeh:GetPivot().Position, pickupPart.Position) > CONFIG.InZoneRadiusXZ then
								teleportTruckAndTrailer(pickupPart.CFrame, curPickPos, flipPickupYaw)
								task.wait(0.2)
								lastIncreaseTime = os.clock()
								lastInteractTime = os.clock()
								DeliveryJobTask.InteractWithDeliveryLocation(pickupPart)
							elseif (os.clock() - lastIncreaseTime) >= CONFIG.StallRetryTime then
								lastIncreaseTime = os.clock()
								flipPickupYaw = not flipPickupYaw
								teleportTruckAndTrailer(pickupPart.CFrame, curPickPos, flipPickupYaw)
								task.wait(0.22)
								lastInteractTime = os.clock()
								DeliveryJobTask.InteractWithDeliveryLocation(pickupPart)
							elseif (os.clock() - lastInteractTime) >= 1.5 then
								lastInteractTime = os.clock()
								DeliveryJobTask.InteractWithDeliveryLocation(pickupPart)
							end
						end
					elseif curPickPos and curVeh and not current.IsCollecting then
						safeRequestStream(curPickPos, 1.4)
						if flatDistanceXZ(curVeh:GetPivot().Position, curPickPos) > 25 then
							teleportTruckAndTrailer(CFrame.new(curPickPos), curPickPos, flipPickupYaw)
							task.wait(0.2)
						end
					end
					task.wait(0.15)
				end
			end
		end)

		if not success then
			local v = getMyVehicle()
			local t = TowablesController.GetAttachedTrailer()
			setVehicleAnchored(v, t, false)
			warn("[AutoDelivery Error]:", err)
		end
		task.wait(0.12)
	end
end)
