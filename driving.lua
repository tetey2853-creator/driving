local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local VirtualUser = game:GetService("VirtualUser")
local TeleportService = game:GetService("TeleportService")
local Workspace = game:GetService("Workspace")
local Lighting = game:GetService("Lighting")
local MaterialService = game:GetService("MaterialService")
local HttpService = game:GetService("HttpService")

local VirtualInputManager = nil
pcall(function()
	VirtualInputManager = game:GetService("VirtualInputManager")
end)

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

local HIGH_RISK_MODE = (DeliveryConstants.DeliveryModes and (DeliveryConstants.DeliveryModes.HighRisk or DeliveryConstants.DeliveryModes.Risky)) or "HighRisk"
local MAIN_PLACE_ID = 3351674303
local AFK_PLACE_ID = (GameConstants and GameConstants.PlaceIds and GameConstants.PlaceIds.AFK) or 99421106727783

local CONFIG = {
	TruckId = "Ford-LTL9000-1989",
	TrailerId = "FlatBedSemi",
	DeliveryMode = HIGH_RISK_MODE,
	ExactPadRadius = 50,
	FallbackPadRadius = 160,
	InZoneRadiusXZ = 18, -- ถ้ารถอยู่ในระยะ 18 Studs แนวราบ จะห้ามวาร์ปซ้ำเด็ดขาดเพื่อไม่ให้หลอดสีเหลืองรีเซ็ต
	StallRetryTime = 5.0, -- รอให้หลอดหมุนเต็มที่ 5 วินาที ถ้าของไม่ขยับเลยจริงๆ ถึงจะจัดตำแหน่งใหม่
	SafeStreamAnchor = true,
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
	sessionStart = os.clock(),
	trailerRelativeCF = CFrame.new(0, 0, 23), -- เก็บ CFrame สัมพัทธ์จริงระหว่างรถกับพ่วง
}

local function isValidPart(part)
	return part ~= nil and typeof(part) == "Instance" and part.Parent ~= nil and part:IsDescendantOf(Workspace)
end

local function flatDistanceXZ(posA, posB)
	local dx = posA.X - posB.X
	local dz = posA.Z - posB.Z
	return math.sqrt(dx * dx + dz * dz)
end

-- โหลดแมพแบบไม่บล็อกลูปหลัก
local function safeRequestStream(pos, timeoutWait)
	if not pos then return end
	local done = false
	task.spawn(function()
		pcall(function()
			LocalPlayer:RequestStreamAroundAsync(pos, timeoutWait or 1.8)
		end)
		done = true
	end)
	local deadline = os.clock() + (timeoutWait or 1.5)
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
	local args = { ... }
	for _, v in ipairs(args) do
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

local function formatNumber(n)
	local str = tostring(math.floor(n or 0))
	return str:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
end

local function decodeCashValue(val)
	local num = tonumber(val)
	if not num then return nil end
	if num >= 1e16 and MathModule and type(MathModule.decodeLargeNumber) == "function" then
		local ok, decoded = pcall(MathModule.decodeLargeNumber, num)
		if ok and type(decoded) == "number" then
			return math.floor(decoded)
		end
	end
	return math.floor(num)
end

local function getPlayerCash()
	if DataModule then
		local ok, statsFolder = pcall(function()
			if type(DataModule.GetStatsFolder) == "function" then
				return DataModule.GetStatsFolder(LocalPlayer)
			elseif type(DataModule.GetLoadedStatsFolder) == "function" then
				return DataModule.GetLoadedStatsFolder(LocalPlayer)
			end
			return nil
		end)
		if ok and statsFolder then
			local cashObj = statsFolder:FindFirstChild("Cash")
			if cashObj then
				local val = decodeCashValue(cashObj.Value)
				if val then return val end
			end
		end
	end

	for _, parent in ipairs({ LocalPlayer, ReplicatedStorage:FindFirstChild("Stats") }) do
		if parent then
			local folder = (parent == LocalPlayer) and (parent:FindFirstChild("Stats") or parent:FindFirstChild("leaderstats"))
				or (parent:FindFirstChild(LocalPlayer.Name) or parent:FindFirstChild(tostring(LocalPlayer.UserId)))
			if folder and folder:FindFirstChild("Cash") then
				local val = decodeCashValue(folder.Cash.Value)
				if val then return val end
			end
		end
	end

	local attrCash = decodeCashValue(LocalPlayer:GetAttribute("Cash"))
	if attrCash then return attrCash end

	return 0
end

local initialCash = getPlayerCash()
if initialCash > 0 then
	RUNTIME.startCash = initialCash
end

local function getMyVehicle()
	return VehicleUtil.GetPlayerSpawnedVehicle(LocalPlayer)
		or (Workspace:FindFirstChild("Vehicles") and Workspace.Vehicles:FindFirstChild(LocalPlayer.Name))
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

local function zeroVelocity(model)
	if not model or not model.Parent then return end
	for _, part in ipairs(model:GetDescendants()) do
		if part:IsA("BasePart") then
			part.AssemblyLinearVelocity = Vector3.zero
			part.AssemblyAngularVelocity = Vector3.zero
		end
	end
end

local function setVehicleAnchored(vehicle, trailer, anchored)
	if vehicle and vehicle.Parent then
		local root = vehicle.PrimaryPart or vehicle:FindFirstChild("Weight") or vehicle:FindFirstChildWhichIsA("BasePart", true)
		if root then root.Anchored = anchored end
	end
	if trailer and trailer.Parent then
		local tRoot = trailer.PrimaryPart or trailer:FindFirstChild("Weight") or trailer:FindFirstChildWhichIsA("BasePart", true)
		if tRoot then tRoot.Anchored = anchored end
	end
end

-- กระตุ้นฟิสิกส์เบาๆ หลังวาร์ป เพื่อให้ Client ส่งแพ็กเก็ตอัปเดตตำแหน่งรถไปที่ Server ทันที (ป้องกันฟิสิกส์หลับ)
local function wakeVehiclePhysics(vehicle, trailer)
	if not vehicle or not vehicle.Parent then return end
	setVehicleAnchored(vehicle, trailer, false)
	local root = vehicle.PrimaryPart or vehicle:FindFirstChild("Weight") or vehicle:FindFirstChildWhichIsA("BasePart", true)
	if root then
		root.AssemblyLinearVelocity = Vector3.new(0, -0.5, 0)
	end
	local seat = vehicle:FindFirstChildOfClass("VehicleSeat", true)
	if seat then
		pcall(function()
			seat.ThrottleFloat = 0.02
			task.delay(0.06, function()
				if seat and seat.Parent then
					seat.ThrottleFloat = 0
					seat.Throttle = 0
				end
			end)
		end)
	end
end

-- ประคองรถไม่ให้ไหลตกเนินโดยไม่ทำให้ฟิสิกส์หลับ
local function dampSlidingIfNeeded()
	local vehicle = getMyVehicle()
	local trailer = TowablesController.GetAttachedTrailer()
	if vehicle and vehicle.Parent then
		local root = vehicle.PrimaryPart or vehicle:FindFirstChild("Weight") or vehicle:FindFirstChildWhichIsA("BasePart", true)
		if root then
			local horizSpeed = Vector3.new(root.AssemblyLinearVelocity.X, 0, root.AssemblyLinearVelocity.Z).Magnitude
			if horizSpeed > 2.2 or root.AssemblyAngularVelocity.Magnitude > 1.2 then
				for _, part in ipairs(vehicle:GetDescendants()) do
					if part:IsA("BasePart") then
						part.AssemblyLinearVelocity = Vector3.new(0, part.AssemblyLinearVelocity.Y * 0.5, 0)
						part.AssemblyAngularVelocity = Vector3.zero
					end
				end
				if trailer and trailer.Parent then
					for _, part in ipairs(trailer:GetDescendants()) do
						if part:IsA("BasePart") then
							part.AssemblyLinearVelocity = Vector3.new(0, part.AssemblyLinearVelocity.Y * 0.5, 0)
							part.AssemblyAngularVelocity = Vector3.zero
						end
					end
				end
			end
		end
	end
end

local function ensurePlayerSeated(vehicle)
	if not vehicle or not vehicle.Parent then return false end
	local char = LocalPlayer.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not hum or hum.Health <= 0 then return false end

	local seat = vehicle:FindFirstChildOfClass("VehicleSeat", true)
	if not seat then return false end

	if hum.SeatPart ~= seat then
		setVehicleAnchored(vehicle, TowablesController.GetAttachedTrailer(), false)
		zeroVelocity(vehicle)
		char:PivotTo(seat.CFrame)
		task.wait(0.1)
		pcall(function() seat:Sit(hum) end)
		task.wait(0.25)
	end
	return hum.SeatPart == seat
end

-- คำนวณ CFrame ให้ขนานไปกับความลาดชันของพื้นดิน (Slope-Aligned) เพื่อไม่ให้หางพ่วงจมเนินดิน
local function getSlopeAlignedGroundCFrame(targetCF, ignoreList, flipYaw)
	local pos = targetCF.Position
	local _, yaw, _ = targetCF:ToEulerAnglesYXZ()
	if flipYaw then
		yaw = yaw + math.pi
	end

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.RespectCanCollide = true

	local exclusions = {}
	if ignoreList then
		for _, inst in ipairs(ignoreList) do
			if inst then table.insert(exclusions, inst) end
		end
	end
	for _, locPart in ipairs(CollectionService:GetTagged(DeliveryConstants.Tags.DeliveryLocation)) do
		table.insert(exclusions, locPart)
	end
	params.FilterDescendantsInstances = exclusions

	local function castGround(checkPos)
		local hit = Workspace:Raycast(checkPos + Vector3.new(0, 15, 0), Vector3.new(0, -75, 0), params)
		if not hit then
			hit = Workspace:Raycast(checkPos + Vector3.new(0, 55, 0), Vector3.new(0, -150, 0), params)
		end
		return hit and hit.Position.Y or checkPos.Y
	end

	local flatRot = CFrame.Angles(0, yaw, 0)
	local lookVec = flatRot.LookVector

	-- วัดความสูงพื้นตรงหน้ารถ (+5 Studs) และท้ายพ่วง (-18 Studs) เพื่อเอียงรถตามเนินดิน
	local frontCheck = pos + (lookVec * 5)
	local backCheck = pos - (lookVec * 18)
	local centerY = castGround(pos)
	local frontY = castGround(frontCheck)
	local backY = castGround(backCheck)

	local pitch = math.atan2(frontY - backY, 23)
	pitch = math.clamp(pitch, math.rad(-22), math.rad(22))

	local baseHeight = math.max(centerY, (frontY + backY) * 0.5) + 2.8
	-- ขยับหัวรถไปด้านหน้า 4 Studs เพื่อให้จุดกึ่งกลางรถและพ่วงอยู่ในวงกลมพอดี
	return CFrame.new(pos.X, baseHeight, pos.Z) * CFrame.Angles(0, yaw, 0) * CFrame.Angles(pitch, 0, 0) * CFrame.new(0, 0, -4)
end

local function getDeliveryLocationPart(targetPos, customRadius)
	local locations = CollectionService:GetTagged(DeliveryConstants.Tags.DeliveryLocation)

	if targetPos then
		local closestPart = nil
		local closestDist = math.huge
		local radiusLimit = customRadius or CONFIG.ExactPadRadius

		for _, part in ipairs(locations) do
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
	for _, part in ipairs(locations) do
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

-- ย้ายรถและพ่วงด้วย Relative CFrame จริงตามแนวความชันของถนน
local function pivotTruckAndTrailerAligned(vehicle, trailer, cabCF)
	if not vehicle or not vehicle.Parent then return end
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

local function teleportTruckAndTrailer(targetCFrame, waitForStreamPos, flipYaw)
	local vehicle = getMyVehicle()
	local trailer = TowablesController.GetAttachedTrailer()
	local char = LocalPlayer.Character
	local destPos = waitForStreamPos or targetCFrame.Position
	local ignore = { char, vehicle, trailer }

	if vehicle then
		ensurePlayerSeated(vehicle)
	end

	local readyPart = getDeliveryLocationPart(destPos, CONFIG.ExactPadRadius)
	if isValidPart(readyPart) and vehicle then
		local cleanCabCF = getSlopeAlignedGroundCFrame(readyPart.CFrame, ignore, flipYaw)
		pivotTruckAndTrailerAligned(vehicle, trailer, cleanCabCF)
		return readyPart
	end

	local currentPos = (vehicle and vehicle:GetPivot().Position) or (char and char:GetPivot().Position) or destPos
	local distToTarget = (currentPos - destPos).Magnitude

	if distToTarget > 1800 then
		local midPos = currentPos:Lerp(destPos, 0.5)
		RUNTIME.statusText = string.format("โหลดแมพ (%d m)", math.floor(distToTarget))
		safeRequestStream(midPos, 1.2)
	end

	safeRequestStream(destPos, 2.0)

	if vehicle and vehicle.Parent then
		local streamWait = os.clock() + 2.2
		while os.clock() < streamWait do
			if isValidPart(getDeliveryLocationPart(destPos, CONFIG.ExactPadRadius)) then
				break
			end
			-- ย้ายรถไปลอยรอเหนือจุดหมายโดยไม่ต้องล็อก Anchored ค้างนาน
			local hoverCF = CFrame.new(destPos + Vector3.new(0, 18, 0))
			vehicle:PivotTo(hoverCF)
			if trailer and trailer.Parent then
				trailer:PivotTo(hoverCF * RUNTIME.trailerRelativeCF)
			end
			zeroVelocity(vehicle)
			if trailer then zeroVelocity(trailer) end
			task.wait(0.1)
		end

		local streamedPart = getDeliveryLocationPart(destPos, CONFIG.ExactPadRadius)
			or getDeliveryLocationPart(destPos, CONFIG.FallbackPadRadius)
		local finalTargetCF = isValidPart(streamedPart) and streamedPart.CFrame or CFrame.new(destPos)
		local cleanCabCF = getSlopeAlignedGroundCFrame(finalTargetCF, ignore, flipYaw)

		pivotTruckAndTrailerAligned(vehicle, trailer, cleanCabCF)
		return streamedPart
	elseif char then
		char:PivotTo(CFrame.new(destPos + Vector3.new(0, 8, 0)))
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
		task.wait(0.5)
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
		task.wait(0.4)

		-- บันทึกตำแหน่งพ่วงสัมพัทธ์กับตัวรถตอนเสกเสร็จใหม่ๆ เพื่อไม่ให้ข้อต่อพ่วงบิดตอนวาร์ป
		local trailer = TowablesController.GetAttachedTrailer()
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
		task.wait(1.0)
	else
		RUNTIME.hasEnforcedHighRisk = true
	end

	if carried == 0 and DeliveryConstants.RemoteEvents and DeliveryConstants.RemoteEvents.SetDeliveryMode then
		pcall(function()
			Remotes.fireServer(DeliveryConstants.RemoteEvents.SetDeliveryMode, CONFIG.DeliveryMode)
		end)
	end
end

-- ================= ฟังก์ชันเสริม: Boost FPS & ย้ายเซิร์ฟคนน้อย =================
local isFpsBoosted = false
local function runExtremeFPSBooster()
	if isFpsBoosted then return end
	isFpsBoosted = true

	local Terrain = Workspace:FindFirstChildOfClass("Terrain")
	local BoostConfig = {
		RemoveParticles = true,      -- ปิดควัน ไฟ แสงสกิล Trail Beam
		RemoveDecals = true,         -- ซ่อนรูปภาพแปะพื้นผิว
		RemoveMeshTextures = true,   -- ลบสีพื้นผิวโมเดล 3D และ PBR (ลดภาระการ์ดจอหนักมาก)
		DisablePointLights = true,   -- ปิดไฟหลอดเล็กๆ ตามแมพ
		RemoveClothes = true,        -- ลบเสื้อผ้าและเครื่องประดับตัวละครในเซิร์ฟ
		AutoOptimizeNewItems = true  -- ดักจับและลดกราฟิกของที่เกิดใหม่ตลอดเวลา
	}

	-- 1. ปรับแต่งระดับ Engine และ Quality
	pcall(function()
		settings().Rendering.QualityLevel = Enum.QualityLevel.Level01
		settings().Rendering.MeshPartDetailLevel = Enum.MeshPartDetailLevel.Level04
	end)

	-- 2. ปิดระบบแสงและเงาขั้นสูง (ใช้ sethiddenproperty สำหรับ Executor ที่รองรับ)
	Lighting.GlobalShadows = false
	Lighting.FogEnd = 9e9
	Lighting.ShadowSoftness = 0
	pcall(function()
		sethiddenproperty(Lighting, "Technology", Enum.Technology.Voxel)
	end)

	for _, v in ipairs(Lighting:GetChildren()) do
		if v:IsA("PostEffect") or v:IsA("Sky") or v:IsA("Atmosphere") or v:IsA("Clouds") then
			v:Destroy()
		end
	end

	-- 3. ลบ Material พิเศษของแมพ
	for _, v in ipairs(MaterialService:GetChildren()) do
		v:Destroy()
	end
	MaterialService.Use2022Materials = false

	-- 4. ปิดเอฟเฟกต์น้ำและหญ้า 3D
	if Terrain then
		Terrain.WaterWaveSize = 0
		Terrain.WaterWaveSpeed = 0
		Terrain.WaterTransparency = 1
		Terrain.WaterReflectance = 0
		pcall(function()
			sethiddenproperty(Terrain, "Decoration", false) -- ปิดหญ้า 3D ที่ขยับได้
		end)
	end

	-- 5. ฟังก์ชันจัดการวัตถุแต่ละชิ้น (แยก if ไม่ให้ทับซ้อนกัน)
	local function optimizeInstance(v)
		if v:IsA("BasePart") then
			v.Material = Enum.Material.SmoothPlastic
			v.Reflectance = 0
			v.CastShadow = false -- สำคัญมาก: ปิดการคำนวณเงาของแต่ละชิ้น
		end

		if v:IsA("MeshPart") then
			if BoostConfig.RemoveMeshTextures then
				v.TextureID = ""
			end
			pcall(function()
				sethiddenproperty(v, "RenderFidelity", Enum.RenderFidelity.Performance)
			end)
		elseif v:IsA("SpecialMesh") and BoostConfig.RemoveMeshTextures then
			v.TextureId = ""
		elseif v:IsA("SurfaceAppearance") and BoostConfig.RemoveMeshTextures then
			v:Destroy() -- ลบพื้นผิว PBR ที่กิน GPU สูง
		elseif (v:IsA("Decal") or v:IsA("Texture")) and BoostConfig.RemoveDecals then
			v.Transparency = 1
		elseif (v:IsA("ParticleEmitter") or v:IsA("Trail") or v:IsA("Beam") or v:IsA("Fire") or v:IsA("Smoke") or v:IsA("Sparkles")) and BoostConfig.RemoveParticles then
			v.Enabled = false
		elseif v:IsA("Explosion") and BoostConfig.RemoveParticles then
			v.BlastPressure = 1
			v.BlastRadius = 1
			v.Visible = false
		elseif (v:IsA("PointLight") or v:IsA("SpotLight") or v:IsA("SurfaceLight")) and BoostConfig.DisablePointLights then
			v.Enabled = false
			v.Shadows = false
		elseif BoostConfig.RemoveClothes and (v:IsA("Clothing") or v:IsA("SurfaceGui") or v:IsA("ShirtGraphic")) then
			v:Destroy()
		end
	end

	-- 6. ล้างทั้งแมพแบบแบ่งจังหวะ (Batching) ป้องกันอาการเกมค้างตอนกดรัน
	task.spawn(function()
		local descendants = Workspace:GetDescendants()
		for i = 1, #descendants do
			optimizeInstance(descendants[i])
			-- พักทุกๆ 750 ชิ้น เพื่อไม่ให้เฟรมเรตตกวูบจนเกมหลุด
			if i % 750 == 0 then
				task.wait()
			end
		end
		print("🚀 Extreme FPS Booster V2: เคลียร์แมพเสร็จสมบูรณ์ (" .. #descendants .. " ชิ้น)!")
	end)

	-- 7. ดักจับของที่เพิ่งเกิดใหม่ในเกม (เช่น สกิลคนอื่น มอนสเตอร์เกิดใหม่)
	if BoostConfig.AutoOptimizeNewItems then
		Workspace.DescendantAdded:Connect(function(v)
			task.defer(optimizeInstance, v)
		end)
	end

	-- 8. ปลดล็อก FPS และเคลียร์ขยะใน Memory เบื้องต้น
	pcall(function()
		if setfpscap then
			setfpscap(999)
		end
	end)
end

local function hopToLowServer(btn)
	print("กำลังค้นหาเซิร์ฟเวอร์คนน้อย...")
	if btn and btn.Parent then btn.Text = "กำลังค้นหา..." end

	local success, result = pcall(function()
		local url = "https://games.roblox.com/v1/games/" .. game.PlaceId .. "/servers/Public?sortOrder=Asc&limit=100"
		return HttpService:JSONDecode(game:HttpGet(url))
	end)

	if success and result and result.data then
		for _, server in ipairs(result.data) do
			-- เช็คว่าเป็นคนละห้องกับห้องปัจจุบัน และห้องไม่เต็ม
			if server.id ~= game.JobId and server.playing < server.maxPlayers then
				print("กำลังย้ายไปเซิร์ฟเวอร์ผู้เล่น: " .. server.playing .. "/" .. server.maxPlayers)
				if btn and btn.Parent then btn.Text = "กำลังย้าย..." end
				TeleportService:TeleportToPlaceInstance(game.PlaceId, server.id, LocalPlayer)
				return
			end
		end
		warn("ไม่พบเซิร์ฟเวอร์อื่นที่ว่างในขณะนี้")
		if btn and btn.Parent then btn.Text = "ไม่พบเซิฟว่าง" end
	else
		warn("ไม่สามารถดึงข้อมูลเซิร์ฟเวอร์ได้")
		if btn and btn.Parent then btn.Text = "ดึงข้อมูลล้มเหลว" end
	end

	task.delay(1.5, function()
		if btn and btn.Parent then btn.Text = "ย้ายเซิฟ" end
	end)
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
	local dragging, dragInput, dragStart, startPos
	handle.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			dragStart = input.Position
			startPos = frame.Position
			input.Changed:Connect(function()
				if input.UserInputState == Enum.UserInputState.End then dragging = false end
			end)
		end
	end)
	handle.InputChanged:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
			dragInput = input
		end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if input == dragInput and dragging then
			local delta = input.Position - dragStart
			frame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
		end
	end)
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
TitleLabel.Text = "Auto Delivery (Smooth Sync 24H)"
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
ProfitLabel.Text = "รอบส่ง: 0 | กำไร: $0 | เวลา: 00:00:00"
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
		TweenService:Create(Sw, TweenInfo.new(0.15), {
			BackgroundColor3 = state and Color3.fromRGB(0, 190, 125) or Color3.fromRGB(50, 55, 75)
		}):Play()
		TweenService:Create(Knob, TweenInfo.new(0.15), {
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

addButton("ลดกราฟิกเพิ่มเฟรมเรต (Potato V2)", "Boost FPS", function(btn)
	if isFpsBoosted then
		btn.Text = "เปิดใช้งานแล้ว"
		return
	end
	btn.Text = "กำลังเคลียร์..."
	task.spawn(function()
		runExtremeFPSBooster()
		if btn and btn.Parent then
			btn.Text = "เปิดใช้งานแล้ว"
			btn.BackgroundColor3 = Color3.fromRGB(0, 160, 110)
		end
	end)
end)

addButton("ย้ายไปเซิร์ฟเวอร์คนน้อย", "ย้ายเซิฟ", function(btn)
	task.spawn(function()
		hopToLowServer(btn)
	end)
end)

-- ================= ลูปป้องกันด่าน AFK =================
LocalPlayer.Idled:Connect(function()
	if CONFIG.AntiAFK then
		pcall(function()
			VirtualUser:CaptureController()
			VirtualUser:ClickButton2(Vector2.zero)
		end)
	end
end)

task.spawn(function()
	local lastInputSim = 0
	while ScreenGui and ScreenGui.Parent and Env.AutoDeliverySession == CurrentSessionId do
		if CONFIG.AntiAFK then
			if game.PlaceId == AFK_PLACE_ID then
				RUNTIME.statusText = "พบด่าน AFK กำลังกลับแมพหลัก"
				pcall(function()
					TeleportService:Teleport(MAIN_PLACE_ID, LocalPlayer)
				end)
				task.wait(5)
			end

			local vehicle = getMyVehicle()
			if vehicle then
				pcall(function()
					if vehicle:GetAttribute("IdleStartedTimestamp") ~= nil then
						vehicle:SetAttribute("IdleStartedTimestamp", nil)
					end
					if vehicle:GetAttribute("AFKTimestamp") ~= nil then
						vehicle:SetAttribute("AFKTimestamp", nil)
					end
				end)
			end
			pcall(function()
				if LocalPlayer:GetAttribute("IdleStartedTimestamp") ~= nil then
					LocalPlayer:SetAttribute("IdleStartedTimestamp", nil)
				end
				if LocalPlayer:GetAttribute("IsAFK") ~= nil then
					LocalPlayer:SetAttribute("IsAFK", false)
				end
			end)

			if (os.clock() - lastInputSim) >= 20 then
				lastInputSim = os.clock()
				pcall(function()
					VirtualUser:CaptureController()
					VirtualUser:ClickButton2(Vector2.zero)
				end)
				if VirtualInputManager then
					pcall(function()
						VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.LeftShift, false, game)
						task.wait(0.05)
						VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.LeftShift, false, game)
					end)
				end
			end
		end
		task.wait(4)
	end
end)

-- ================= ลูปอัปเดต UI =================
task.spawn(function()
	while ScreenGui and ScreenGui.Parent and Env.AutoDeliverySession == CurrentSessionId do
		local curCash = getPlayerCash()
		if not RUNTIME.startCash and curCash > 0 then
			RUNTIME.startCash = curCash
		end

		StatusMainLabel.Text = "สถานะ: " .. RUNTIME.statusText
		CargoLabel.Text = string.format(
			"ของบนพ่วง: %d/%d | โหมด: %s",
			RUNTIME.carried,
			RUNTIME.maxCap,
			RUNTIME.isDeliveringLatch and "กำลังส่งของ" or "กำลังรับของ"
		)

		local profit = RUNTIME.startCash and math.max(0, curCash - RUNTIME.startCash) or 0
		local elapsed = math.floor(os.clock() - RUNTIME.sessionStart)
		local hours = math.floor(elapsed / 3600)
		local mins = math.floor((elapsed % 3600) / 60)
		local secs = elapsed % 60
		ProfitLabel.Text = string.format(
			"รอบส่ง: %d | กำไร: $%s | เงิน: $%s | เวลา: %02d:%02d:%02d",
			RUNTIME.deliveriesDone,
			formatNumber(profit),
			formatNumber(curCash),
			hours,
			mins,
			secs
		)
		task.wait(0.25)
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
			if vehicle then
				ensurePlayerSeated(vehicle)
			end

			ensureDeliveryJobStarted()

			local state = DeliveryJobTask.GetCurrentDeliveryState()

			-- กรณีเริ่มงานครั้งแรกสุดและยังไม่มี State งาน
			if not state then
				RUNTIME.isDeliveringLatch = false
				RUNTIME.statusText = "หาจุดรับงานเริ่มต้น"
				local startPart = getDeliveryLocationPart(nil)
				if isValidPart(startPart) and vehicle then
					if flatDistanceXZ(vehicle:GetPivot().Position, startPart.Position) > CONFIG.InZoneRadiusXZ then
						teleportTruckAndTrailer(startPart.CFrame, startPart.Position, false)
						task.wait(0.25)
					end
					DeliveryJobTask.InteractWithDeliveryLocation(startPart)
					-- รอให้ State งานถูกสร้างขึ้นมาก่อน เพื่อไม่ให้วาร์ปซ้ำ
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

			-- ================= 1. โหมดไปจุดส่งของ (เข้าเมื่อมี DestinationPosition เท่านั้น) =================
			if RUNTIME.isDeliveringLatch and state.DestinationPosition ~= nil then
				local destPos = state.DestinationPosition
				RUNTIME.statusText = string.format("ไปจุดส่งของ (%d/%d)", carried, maxCap)

				local dropoffPart = getDeliveryLocationPart(destPos, CONFIG.ExactPadRadius)
				local curVeh = getMyVehicle()

				-- วาร์ปเฉพาะเมื่อรถยังไม่ได้อยู่ในวงกลมจุดส่งเท่านั้น!
				if not curVeh or flatDistanceXZ(curVeh:GetPivot().Position, destPos) > CONFIG.InZoneRadiusXZ then
					local targetCF = isValidPart(dropoffPart) and dropoffPart.CFrame or CFrame.new(destPos)
					local streamedDrop = teleportTruckAndTrailer(targetCF, destPos, false)
					dropoffPart = isValidPart(streamedDrop) and streamedDrop or getDeliveryLocationPart(destPos, CONFIG.FallbackPadRadius)
					task.wait(0.22)
				else
					dropoffPart = dropoffPart or getDeliveryLocationPart(destPos, CONFIG.FallbackPadRadius)
				end

				if isValidPart(dropoffPart) then
					DeliveryJobTask.InteractWithDeliveryLocation(dropoffPart)
				end

				local lastDropCarried = carried
				local lastProgressTime = os.clock()
				local lastInteractTime = os.clock()
				local dropTimeout = os.clock() + 28
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
						-- รอ 0.25 วินาทีให้เซิร์ฟเวอร์อัปเดตจุดรับรอบถัดไปให้เสร็จก่อน
						task.wait(0.25)
						break
					end

					if curCarried < lastDropCarried then
						lastDropCarried = curCarried
						lastProgressTime = os.clock()
						dropTimeout = os.clock() + 16
					end

					local curDestPos = current.DestinationPosition or destPos
					if not isValidPart(dropoffPart) and curDestPos then
						dropoffPart = getDeliveryLocationPart(curDestPos, CONFIG.ExactPadRadius)
							or getDeliveryLocationPart(curDestPos, CONFIG.FallbackPadRadius)
					end

					curVeh = getMyVehicle()
					if isValidPart(dropoffPart) and curVeh then
						ensurePlayerSeated(curVeh)

						-- ถ้ารถไหลหลุดออกจากวงเกิน 18 Studs ให้ดึงกลับเข้าวง
						if flatDistanceXZ(curVeh:GetPivot().Position, dropoffPart.Position) > CONFIG.InZoneRadiusXZ then
							teleportTruckAndTrailer(dropoffPart.CFrame, curDestPos, flipDropYaw)
							task.wait(0.2)
							lastInteractTime = os.clock()
							DeliveryJobTask.InteractWithDeliveryLocation(dropoffPart)
						-- ถ้าของไม่ลดเลยเกิน 5 วินาทีเต็ม ค่อยกลับหัวรถ 180 องศาเพื่อเปลี่ยนมุมบนเนิน
						elseif (os.clock() - lastProgressTime) >= CONFIG.StallRetryTime then
							lastProgressTime = os.clock()
							flipDropYaw = not flipDropYaw
							RUNTIME.statusText = "ปรับมุมรถบนเนินส่งของ..."
							teleportTruckAndTrailer(dropoffPart.CFrame, curDestPos, flipDropYaw)
							task.wait(0.25)
							lastInteractTime = os.clock()
							DeliveryJobTask.InteractWithDeliveryLocation(dropoffPart)
						-- ห้ามกดซ้ำเด็ดขาดถ้าหลอดกำลังหมุนอยู่ (current.IsDropping == true)
						elseif not current.IsDropping and (os.clock() - lastInteractTime) >= 1.6 then
							lastInteractTime = os.clock()
							DeliveryJobTask.InteractWithDeliveryLocation(dropoffPart)
						end
					elseif curDestPos and curVeh then
						safeRequestStream(curDestPos, 1.5)
						if flatDistanceXZ(curVeh:GetPivot().Position, curDestPos) > 25 then
							teleportTruckAndTrailer(CFrame.new(curDestPos), curDestPos, flipDropYaw)
							task.wait(0.2)
						end
					end
					task.wait(0.15)
				end

			-- ================= 2. โหมดไปจุดรับของ (และรอจนกว่าพิกัดจุดส่งจะมาครบ) =================
			elseif state.PickupPosition ~= nil then
				local pickupPos = state.PickupPosition
				RUNTIME.statusText = string.format("ไปจุดรับของ (%d/%d)", carried, maxCap)

				local pickupPart = getDeliveryLocationPart(pickupPos, CONFIG.ExactPadRadius)
				local curVeh = getMyVehicle()

				-- สำคัญที่สุด: ถ้ารถจอดอยู่ในวงรับของอยู่แล้ว ห้ามสั่งวาร์ปซ้ำเด็ดขาด!
				if not curVeh or flatDistanceXZ(curVeh:GetPivot().Position, pickupPos) > CONFIG.InZoneRadiusXZ then
					local targetCF = isValidPart(pickupPart) and pickupPart.CFrame or CFrame.new(pickupPos)
					local streamedPick = teleportTruckAndTrailer(targetCF, pickupPos, false)
					pickupPart = isValidPart(streamedPick) and streamedPick or getDeliveryLocationPart(pickupPos, CONFIG.FallbackPadRadius)
					task.wait(0.22)
				else
					pickupPart = pickupPart or getDeliveryLocationPart(pickupPos, CONFIG.FallbackPadRadius)
				end

				if isValidPart(pickupPart) and not state.IsCollecting then
					DeliveryJobTask.InteractWithDeliveryLocation(pickupPart)
				end

				local lastCarried = carried
				local lastIncreaseTime = os.clock()
				local lastInteractTime = os.clock()
				local collectTimeout = os.clock() + 30
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
						collectTimeout = os.clock() + 18
					end

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

					-- ต้องทั้งของครบ (fullNow / pickupDepleted / noPickupPos) และเซิร์ฟเวอร์ส่ง DestinationPosition มาแล้วเท่านั้น ถึงจะออกจากจุดรับ!
					if (fullNow or pickupDepleted or noPickupPos) and current.DestinationPosition ~= nil then
						RUNTIME.isDeliveringLatch = true
						task.wait(0.2) -- รอให้เซิร์ฟเวอร์ปิดสถานะจุดรับให้สมบูรณ์ก่อนวาร์ปออก
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

						-- ถ้ารถไหลออกจากวงเกิน 18 Studs ค่อยดึงกลับเข้าวง
						if flatDistanceXZ(curVeh:GetPivot().Position, pickupPart.Position) > CONFIG.InZoneRadiusXZ then
							teleportTruckAndTrailer(pickupPart.CFrame, curPickPos, flipPickupYaw)
							task.wait(0.2)
							lastInteractTime = os.clock()
							DeliveryJobTask.InteractWithDeliveryLocation(pickupPart)
						-- ถ้าของไม่เพิ่มเกิน 5 วินาทีเต็ม ค่อยปรับมุมรถใหม่
						elseif (os.clock() - lastIncreaseTime) >= CONFIG.StallRetryTime then
							lastIncreaseTime = os.clock()
							flipPickupYaw = not flipPickupYaw
							RUNTIME.statusText = "ปรับมุมรถจุดรับของ..."
							teleportTruckAndTrailer(pickupPart.CFrame, curPickPos, flipPickupYaw)
							task.wait(0.25)
							lastInteractTime = os.clock()
							DeliveryJobTask.InteractWithDeliveryLocation(pickupPart)
						-- ห้ามกดซ้ำถ้าหลอดรับของกำลังหมุนอยู่ (current.IsCollecting == true)
						elseif not current.IsCollecting and (os.clock() - lastInteractTime) >= 1.6 then
							lastInteractTime = os.clock()
							DeliveryJobTask.InteractWithDeliveryLocation(pickupPart)
						end
					elseif curPickPos and curVeh then
						safeRequestStream(curPickPos, 1.5)
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
			RUNTIME.statusText = "ซ่อมแซมลูปอัตโนมัติ"
			local v = getMyVehicle()
			local t = TowablesController.GetAttachedTrailer()
			setVehicleAnchored(v, t, false)
			warn("[AutoDelivery Error]:", err)
		end
		task.wait(0.12)
	end
end)
