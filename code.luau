print("--- SCRIPT [4.0.5-MegaBot] PARSING STARTED ---")

local SCRIPT_VERSION = "4.0.5-MegaBot"

-- --- Services ---
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TeleportService = game:GetService("TeleportService")
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")
local UserGameSettings = UserSettings():GetService("UserGameSettings")
local TextChatService = game:GetService("TextChatService")
local StarterGui = game:GetService("StarterGui")
local HttpService = game:GetService("HttpService")

-- --- Local Player / Character Cache ---
local LocalPlayer = Players.LocalPlayer
local Character = nil
local HumanoidRootPart = nil

-- --- Core Globals/Config ---
local BotSettings = {
	Owners = {
		["dumbr4ccoon"] = true,
	},
	Unlocked = false,
	FollowPlayerName = "",
	LoopGoToPlayerName = "",
}

-- --- Assignment/Whitelist FSM State (for secure trading) ---
local AllowedUserName = ""           -- The only user allowed to trade during an assignment
local Active = false                 -- Whether whitelist enforcement is active
local SessionEndsAt: number? = nil   -- Epoch ms when assignment should expire locally (advisory)
local CurrentOrderId = ""            -- Current assigned order id (string)
local AssignmentSecret = ""          -- Secret to report item receipts

-- ExpectedItems maps lowercase item name -> remaining quantity expected
local ExpectedItems: { [string]: number } = {}
-- ExpectedNameToPetId maps lowercase item name -> petId returned by assignment/poll
local ExpectedNameToPetId: { [string]: string } = {}

-- --- Bot & API Credentials (filled via chat command !token or by editing below) ---
local API_BASE = ""  -- e.g. "https://your-domain.com"
local BOT_ID = ""    -- external bot id (matches convex bot.id)
local BOT_KEY = ""   -- bot secret

-- --- Gift Queue System (legacy/stash/manual) ---
local giftQueue = {} -- Holds tables like {itemName = "...", senderName = "...", type = "..."}

-- --- Utility Functions ---

local function getPlayerInstance(name)
	if name:lower() == "me" then
		return LocalPlayer
	end
	for _, player in pairs(Players:GetPlayers()) do
		if player.Name:lower():find(name:lower(), 1, true) then
			return player
		end
	end
	return nil
end

local function updateCharacterReferences()
	Character = LocalPlayer.Character
	if Character then
		HumanoidRootPart = Character:FindFirstChild("HumanoidRootPart")
	else
		HumanoidRootPart = nil
	end
end

local function findRemoteEventOrFunction(remoteName, expectedParentName)
	for _, descendant in ipairs(ReplicatedStorage:GetDescendants()) do
		if
			descendant.Name == remoteName
			and (descendant:IsA("RemoteEvent") or descendant:IsA("RemoteFunction"))
		then
			if
				not expectedParentName
				or (descendant.Parent and descendant.Parent.Name == expectedParentName)
			then
				return descendant
			end
		end
	end
	return nil
end

-- --- HTTP Queue (best-effort; may fail if HttpService not allowed client-side) ---

type QueueItem = {
	method: string,
	path: string,
	body: any?,
	nextAttemptAt: number?,
	backoffMs: number?,
}

local requestQueue: { QueueItem } = {}
local queueBusy = false

local function httpRequest(method: string, path: string, bodyTable: any?, headersExtra: any?)
	-- Guard: only proceed if API_BASE and credentials are set
	if API_BASE == "" or BOT_ID == "" or BOT_KEY == "" then
		return false, { error = "API credentials not configured" }
	end

	local url = API_BASE .. path
	local headers = {
		["Content-Type"] = "application/json",
		["X-Bot-Id"] = BOT_ID,
		["X-Bot-Key"] = BOT_KEY,
	}
	if headersExtra then
		for k, v in pairs(headersExtra) do
			headers[k] = v
		end
	end

	local payload = {
		Url = url,
		Method = method,
		Headers = headers,
	}

	if bodyTable ~= nil then
		local okEnc, bodyOrErr = pcall(function()
			return HttpService:JSONEncode(bodyTable)
		end)
		if okEnc then
			payload.Body = bodyOrErr
		else
			return false, { error = "JSON encode failed" }
		end
	end

	local ok, res = pcall(function()
		return HttpService:RequestAsync(payload)
	end)

	if not ok then
		return false, { error = "RequestAsync failed" }
	end

	local parsed = res.Body
	if typeof(res.Body) == "string" and #res.Body > 0 then
		local okDec, j = pcall(function()
			return HttpService:JSONDecode(res.Body)
		end)
		if okDec then
			parsed = j
		end
	end

	local success = (res.StatusCode >= 200 and res.StatusCode < 300)
	return success, { status = res.StatusCode, body = parsed }
end

local function enqueueRequest(method: string, path: string, bodyTable: any?)
	table.insert(requestQueue, {
		method = method,
		path = path,
		body = bodyTable,
		nextAttemptAt = 0,
		backoffMs = 1000,
	})
end

task.spawn(function()
	while true do
		task.wait(0.25)
		if queueBusy then
			continue
		end
		if #requestQueue == 0 then
			continue
		end
		local now = os.clock() * 1000
		local item = requestQueue[1]
		if item.nextAttemptAt and now < item.nextAttemptAt then
			continue
		end

		queueBusy = true
		local ok, res = httpRequest(item.method, item.path, item.body, nil)
		queueBusy = false

		if ok then
			table.remove(requestQueue, 1)
		else
			-- Simple backoff and retry (cap at ~30s)
			local backoff = math.min((item.backoffMs or 1000) * 2, 30000)
			item.backoffMs = backoff
			item.nextAttemptAt = now + backoff
		end
	end
end)

-- --- Heartbeat and Assignment Poll Loops (best-effort) ---

local CurrentStatus = "online" -- "online" | "offline" | "maintenance" | "in-trade"

local function computeCapacityPct(): number
	local backpack = LocalPlayer:FindFirstChildOfClass("Backpack")
	if not backpack then return 0 end
	local count = 0
	for _, item in ipairs(backpack:GetChildren()) do
		if item:IsA("Tool") and item:GetAttribute("ItemType") == "Pet" then
			count += 1
		end
	end
	-- clamp to 100
	if count > 100 then count = 100 end
	return count
end

local function heartbeatLoop()
	task.spawn(function()
		while true do
			task.wait(20)
			if API_BASE == "" or BOT_ID == "" or BOT_KEY == "" then
				continue
			end
			local hb = {
				status = CurrentStatus,
				capacityPct = computeCapacityPct(),
				version = SCRIPT_VERSION,
			}
			enqueueRequest("POST", "/api/bot/heartbeat", hb)
		end
	end)
end

local function assignmentPollLoop()
	task.spawn(function()
		while true do
			task.wait(5)
			if API_BASE == "" or BOT_ID == "" or BOT_KEY == "" then
				continue
			end
			local ok, res = httpRequest("POST", "/api/bot/assignment/poll", {})
			if not ok then
				continue
			end
			local body = res.body
			if typeof(body) ~= "table" then
				continue
			end
			if body.assigned == true then
				-- expectedItems: array of { petId, name, qty }
				ExpectedItems = {}
				ExpectedNameToPetId = {}
				for _, it in ipairs(body.expectedItems or {}) do
					if typeof(it) == "table" and typeof(it.name) == "string" and typeof(it.qty) == "number" then
						local key = string.lower(it.name)
						ExpectedItems[key] = (ExpectedItems[key] or 0) + it.qty
						if typeof(it.petId) == "string" then
							ExpectedNameToPetId[key] = it.petId
						end
					end
				end
				CurrentOrderId = (typeof(body.orderId) == "string") and body.orderId or ""
				AssignmentSecret = (typeof(body.assignmentSecret) == "string") and body.assignmentSecret or ""
				SessionEndsAt = (typeof(body.assignedUntil) == "number") and body.assignedUntil or nil
				Active = true
				-- Note: AllowedUserName must be set by operator or external agent via !assign
				print(string.format("[ASSIGNMENT] Active=true, items=%d, order=%s", (function()
					local n = 0
					for _ in pairs(ExpectedItems) do n += 1 end
					return n
				end)(), CurrentOrderId))
			else
				-- Not assigned
				-- Keep Active as-is; operators can stop via !stop
			end
		end
	end)
end

-- --- Command Definitions ---
local Commands = {}

function Commands.ping(player, args)
	print(
		string.format(
			"DEBUG [%s]: Ping command executed by %s. Pong!",
			SCRIPT_VERSION,
			player.Name
		)
	)
end

function Commands.unlock(player, args)
	local response
	if args[1] and args[1]:lower() == "true" then
		BotSettings.Unlocked = true
		response = "Permissions Unlocked for All!"
	elseif args[1] and args[1]:lower() == "false" then
		BotSettings.Unlocked = false
		response = "Permissions Locked to Owners Only!"
	else
		response = "Usage: !unlock true|false"
	end
	print(
		string.format(
			"DEBUG [%s]: Unlock command executed by %s. Result: %s",
			SCRIPT_VERSION,
			player.Name,
			response
		)
	)
end

function Commands.come(player, args)
	if not HumanoidRootPart then return end
	if not args[1] or args[1]:lower() == "stop" then
		BotSettings.LoopGoToPlayerName = ""
		return
	end
	local targetPlayer = getPlayerInstance(args[1])
	if
		targetPlayer
		and targetPlayer.Character
		and targetPlayer.Character:FindFirstChild("HumanoidRootPart")
	then
		BotSettings.LoopGoToPlayerName = targetPlayer.Name
		BotSettings.FollowPlayerName = ""
	end
end

function Commands.rejoin(player, args)
	task.wait(1)
	if #Players:GetPlayers() <= 1 then
		LocalPlayer:Kick("\nRejoining...")
	else
		TeleportService:TeleportToPlaceInstance(
			game.PlaceId,
			game.JobId,
			LocalPlayer
		)
	end
end

function Commands.follow(player, args)
	if not HumanoidRootPart then return end
	if not args[1] or args[1]:lower() == "stop" then
		BotSettings.FollowPlayerName = ""
		return
	end
	local targetPlayer = getPlayerInstance(args[1])
	if
		targetPlayer
		and targetPlayer.Character
		and targetPlayer.Character:FindFirstChild("HumanoidRootPart")
	then
		BotSettings.FollowPlayerName = targetPlayer.Name
		BotSettings.LoopGoToPlayerName = ""
	end
end

function Commands.help(player, args)
	print("--- Bot Commands ---")
	print("!ping - Test if commands are working.")
	print("!unlock true|false - Grant|revoke permissions for everyone.")
	print("!come (player)|stop - Teleport to player or stop looping.")
	print("!follow (player)|stop - Follow a player.")
	print("!rejoin - Rejoin the server.")
	print("!give (item name) - Bot gives you a specific item (name can be partial).")
	print("!givestash - Bot gives you all its pets.")
	print("!receive (item name) - Adds a 'Stash' request to the queue for any staff to fulfill.")
	print("!queuepurge (stash|transactions|all) - Clears pending gift requests.")
	print("!debloat - Apply performance optimizations.")
	print("!undebloat - Remove performance optimizations.")
	print("!assign (username) - Set the only username allowed to trade while Active.")
	print("!expect (item name) (qty) - Expect item x qty for whitelist acceptance.")
	print("!expectclear - Clear expected items and stop whitelist.")
	print("!status - Print current assignment/whitelist status.")
	print("!stop - Disable whitelist and clear session.")
	print("!token (botId) (botKey) (apiBase) - Configure API credentials.")
	print("!help - Show this help.")
end

-- --- New Integrated Commands (inventory gifting etc.) ---

function Commands.give(player, args)
	local itemName = table.concat(args, " "):lower()
	if #itemName == 0 then
		print(
			string.format("DEBUG [%s]: Usage: !give <item name>", SCRIPT_VERSION)
		)
		return
	end

	task.spawn(function()
		print(
			string.format(
				"DEBUG [%s]: Received give command for '%s' from %s.",
				SCRIPT_VERSION,
				itemName,
				player.Name
			)
		)

		local petGiftingService = findRemoteEventOrFunction(
			"PetGiftingService",
			"GameEvents"
		)
		if not petGiftingService then
			warn(
				string.format(
					"ERROR [%s]: give failed: PetGiftingService remote not found.",
					SCRIPT_VERSION
				)
			)
			return
		end

		local backpack = LocalPlayer:FindFirstChildOfClass("Backpack")
		if not backpack or not LocalPlayer.Character then return end

		-- Search for the item
		local itemToGive = nil
		-- 1. Check equipped item first
		local equippedTool = LocalPlayer.Character:FindFirstChildOfClass("Tool")
		if
			equippedTool
			and equippedTool.Name:lower():find(itemName, 1, true)
		then
			itemToGive = equippedTool
		end

		-- 2. If not equipped, check backpack
		if not itemToGive then
			for _, item in ipairs(backpack:GetChildren()) do
				if
					item:IsA("Tool")
					and item.Name:lower():find(itemName, 1, true)
				then
					itemToGive = item
					break
				end
			end
		end

		if not itemToGive then
			print(
				string.format(
					"DEBUG [%s]: Item containing '%s' not found in inventory.",
					SCRIPT_VERSION,
					itemName
				)
			)
			return
		end

		print(
			string.format(
				"DEBUG [%s]: Found item '%s'. Preparing to gift.",
				SCRIPT_VERSION,
				itemToGive.Name
			)
		)

		if itemToGive.Parent ~= LocalPlayer.Character then
			if equippedTool then
				equippedTool.Parent = backpack
				task.wait(0.5)
			end
			itemToGive.Parent = LocalPlayer.Character
		end

		task.wait(3.0)
		if LocalPlayer.Character:FindFirstChild(itemToGive.Name) then
			local ok, err = pcall(function()
				petGiftingService:FireServer("GivePet", player)
			end)
			if ok then
				print(
					string.format(
						"DEBUG [%s]: Fired GivePet for '%s' to %s.",
						SCRIPT_VERSION,
						itemToGive.Name,
						player.Name
					)
				)
			else
				warn(string.format("WARN [%s]: GivePet failed: %s", SCRIPT_VERSION, tostring(err)))
			end
		else
			warn(
				string.format(
					"WARN [%s]: Failed to equip '%s' to gift, aborting.",
					SCRIPT_VERSION,
					itemToGive.Name
				)
			)
		end
	end)
end

function Commands.givestash(player, args)
	task.spawn(function()
		local petGiftingService = findRemoteEventOrFunction(
			"PetGiftingService",
			"GameEvents"
		)
		if not petGiftingService then return end

		local backpack = LocalPlayer:FindFirstChildOfClass("Backpack")
		if not backpack then return end

		local equippedTool =
			LocalPlayer.Character and LocalPlayer.Character:FindFirstChildOfClass("Tool")
		if equippedTool then
			equippedTool.Parent = backpack
			task.wait(0.5)
		end

		local itemsToGift = backpack:GetChildren()
		for _, item in ipairs(itemsToGift) do
			if
				item:IsA("Tool")
				and item:GetAttribute("ItemType") == "Pet"
			then
				item.Parent = LocalPlayer.Character
				task.wait(4.0)

				if LocalPlayer.Character:FindFirstChild(item.Name) then
					local ok, _ = pcall(function()
						petGiftingService:FireServer("GivePet", player)
					end)
					if ok then
						task.wait(5.0)
					end
				end
			end
		end
	end)
end

function Commands.receive(player, args)
	local itemName = table.concat(args, " ")
	if not itemName or #itemName == 0 then return end

	local newRequest = {
		itemName = itemName:lower(),
		senderName = "staff",
		type = "Stash",
	}
	table.insert(giftQueue, newRequest)
end

function Commands.queuepurge(player, args)
	local purgeType = args[1] and args[1]:lower()
	if purgeType == "all" then
		giftQueue = {}
	elseif purgeType == "stash" then
		local newQueue = {}
		for _, req in ipairs(giftQueue) do
			if req.type ~= "Stash" then
				table.insert(newQueue, req)
			end
		end
		giftQueue = newQueue
	elseif purgeType == "transactions" then
		local newQueue = {}
		for _, req in ipairs(giftQueue) do
			if req.type ~= "Transaction" then
				table.insert(newQueue, req)
			end
		end
		giftQueue = newQueue
	end
end

-- --- Whitelist & Assignment Commands ---

function Commands.assign(player, args)
	if not args[1] or #args[1] == 0 then
		print("Usage: !assign <username>")
		return
	end
	AllowedUserName = args[1]
	Active = true
	print(string.format("Whitelist enabled for user: %s", AllowedUserName))
end

function Commands.expect(player, args)
	if not args[1] or not args[2] then
		print("Usage: !expect <item name> <qty>")
		return
	end
	local qty = tonumber(args[2])
	if not qty or qty <= 0 then
		print("Quantity must be > 0")
		return
	end
	local itemName = string.lower(args[1])
	ExpectedItems[itemName] = (ExpectedItems[itemName] or 0) + qty
	print(string.format("Expecting %s x%d (total now %d)", itemName, qty, ExpectedItems[itemName]))
end

function Commands.expectclear(player, args)
	ExpectedItems = {}
	ExpectedNameToPetId = {}
	Active = false
	AllowedUserName = ""
	CurrentOrderId = ""
	AssignmentSecret = ""
	SessionEndsAt = nil
	print("Whitelist expectations cleared and disabled.")
end

function Commands.status(player, args)
	print("--- Status ---")
	print("Active:", Active)
	print("AllowedUserName:", AllowedUserName ~= "" and AllowedUserName or "(none)")
	print("CurrentOrderId:", CurrentOrderId ~= "" and CurrentOrderId or "(none)")
	print("SessionEndsAt:", SessionEndsAt or "(none)")
	local count = 0
	for k, v in pairs(ExpectedItems) do
		print(string.format("  %s -> %d", k, v))
		count += 1
	end
	if count == 0 then
		print("  (no expected items)")
	end
end

function Commands.stop(player, args)
	Active = false
	print("Whitelist disabled (Active=false).")
end

function Commands.token(player, args)
	-- Usage: !token <botId> <botKey> [apiBase]
	if not args[1] or not args[2] then
		print("Usage: !token <botId> <botKey> [apiBase]")
		return
	end
	BOT_ID = args[1]
	BOT_KEY = args[2]
	if args[3] then
		API_BASE = args[3]
	end
	print("API credentials set.")
end

-- --- Performance Optimization / Debloater ---
local debloatActive = false
function Commands.debloat(player, args)
	if debloatActive then return end
	debloatActive = true
	if setfpscap then setfpscap(15) end
	StarterGui:SetCoreGuiEnabled("PlayerList", false)
	UserGameSettings.MasterVolume = 0
	settings().Rendering.QualityLevel = 1
	workspace.CurrentCamera.FieldOfView = 15
	local Terrain = workspace:FindFirstChildOfClass("Terrain")
	if Terrain then
		Terrain.WaterWaveSize, Terrain.WaterWaveSpeed, Terrain.WaterReflectance, Terrain.WaterTransparency = 0, 0, 0, 0
	end
	Lighting.GlobalShadows = false
	Lighting.FogEnd = 9e9
	for _, v in pairs(game:GetDescendants()) do
		if v:IsA("BasePart") then v.Material, v.Reflectance = "Plastic", 0
		elseif v:IsA("Decal") then v.Transparency = 1
		elseif v:IsA("Explosion") then v.BlastPressure, v.BlastRadius = 1, 1
		elseif v:IsA("BlurEffect") or v:IsA("SunRaysEffect") or v:IsA("ColorCorrectionEffect") or v:IsA("BloomEffect") or v:IsA("DepthOfFieldEffect") then
			v:Remove()
		end
	end
end

function Commands.undebloat(player, args)
	if not debloatActive then return end
	debloatActive = false
	if setfpscap then setfpscap(60) end
	StarterGui:SetCoreGuiEnabled("PlayerList", true)
	UserGameSettings.MasterVolume = 0.5
	settings().Rendering.QualityLevel = 3
	workspace.CurrentCamera.FieldOfView = 70
	Lighting.GlobalShadows = true
	Lighting.FogEnd = 0
end

-- --- Main Control Loop for Movement ---
local function startControlLoops()
	task.spawn(function()
		while true do
			task.wait(0.1)
			if not Character or not HumanoidRootPart then updateCharacterReferences() continue end

			if BotSettings.LoopGoToPlayerName ~= "" then
				local targetPlayer = getPlayerInstance(BotSettings.LoopGoToPlayerName)
				if targetPlayer and targetPlayer.Character and targetPlayer.Character:FindFirstChild("HumanoidRootPart") then
					HumanoidRootPart.CFrame = targetPlayer.Character.HumanoidRootPart.CFrame * CFrame.new(math.random(-3, 3), 0, math.random(-3, 3))
				else
					BotSettings.LoopGoToPlayerName = ""
				end
			end
			if BotSettings.FollowPlayerName ~= "" then
				local targetPlayer = getPlayerInstance(BotSettings.FollowPlayerName)
				if targetPlayer and targetPlayer.Character and targetPlayer.Character:FindFirstChild("HumanoidRootPart") then
					LocalPlayer.Character.Humanoid:MoveTo(targetPlayer.Character.HumanoidRootPart.Position)
				else
					BotSettings.FollowPlayerName = ""
				end
			end
		end
	end)
end

-- --- Event Listener Setup ---

local function processCommandMessage(message, speaker)
	if message:sub(1, 1) ~= "!" then return end
	local commandString = message:sub(2)
	local args = {}
	for arg in string.gmatch(commandString, "[^%s]+") do
		table.insert(args, arg)
	end
	local commandName = table.remove(args, 1)
	if not commandName then return end
	commandName = commandName:lower()
	local commandFunc = Commands[commandName]
	if commandFunc then
		if BotSettings.Owners[speaker.Name] or BotSettings.Unlocked then
			commandFunc(speaker, args)
		end
	end
end

local function setupCommandListener()
	if not TextChatService then return end
	TextChatService.MessageReceived:Connect(function(messageData)
		if not messageData.TextSource then return end
		local speaker = Players:GetPlayerByUserId(messageData.TextSource.UserId)
		if not speaker then return end
		processCommandMessage(messageData.Text, speaker)
	end)
end

local function setupGiftListener()
	local giftEvent = findRemoteEventOrFunction("GiftPet", "GameEvents")
	local acceptEvent = findRemoteEventOrFunction("AcceptPetGift", "GameEvents")
	if not giftEvent or not acceptEvent then return end

	giftEvent.OnClientEvent:Connect(function(transactionId, itemDescription, senderUsername)
		local descLower = tostring(itemDescription):lower()
		local shouldAccept = false
		local matchedQueueIndex = nil
		local whitelistMatchedNameLower = nil

		-- Whitelist enforcement (preferred)
		if Active and AllowedUserName ~= "" and senderUsername == AllowedUserName then
			for nameLower, remaining in pairs(ExpectedItems) do
				if remaining > 0 and descLower:find(nameLower, 1, true) then
					shouldAccept = true
					whitelistMatchedNameLower = nameLower
					break
				end
			end
		end

		-- Legacy queue fallback (stash/transactions)
		if not shouldAccept then
			for i, request in ipairs(giftQueue) do
				local senderIsStaff = BotSettings.Owners[senderUsername] == true
				local senderMatch = (request.senderName == "staff" and senderIsStaff)
					or (request.senderName == senderUsername)
				local itemMatch = descLower:find(request.itemName, 1, true)
				if senderMatch and itemMatch then
					shouldAccept = true
					matchedQueueIndex = i
					break
				end
			end
		end

		if shouldAccept then
			local ok, err = pcall(function()
				acceptEvent:FireServer(true, transactionId)
			end)
			if not ok then
				warn(string.format("WARN [%s]: AcceptPetGift(true) failed: %s", SCRIPT_VERSION, tostring(err)))
				return
			end

			-- If matched via whitelist, decrement local expectations and report item received
			if whitelistMatchedNameLower ~= nil then
				local prev = ExpectedItems[whitelistMatchedNameLower] or 0
				if prev > 0 then
					ExpectedItems[whitelistMatchedNameLower] = prev - 1
				end

				-- Report item received (best-effort)
				if API_BASE ~= "" and BOT_ID ~= "" and BOT_KEY ~= "" and CurrentOrderId ~= "" and AssignmentSecret ~= "" then
					-- Bots report by itemName; server resolves to petId for the assigned order
					enqueueRequest("POST", "/api/bot/item-received", {
						orderId = CurrentOrderId,
						itemName = whitelistMatchedNameLower,
						quantity = 1,
						password = AssignmentSecret,
					})
				end

				-- If all expected consumed, end Active
				local anyRemaining = false
				for _, remaining in pairs(ExpectedItems) do
					if remaining > 0 then
						anyRemaining = true
						break
					end
				end
				if not anyRemaining then
					Active = false
					print("All expected items received. Whitelist deactivated; awaiting payment.")
				end
			end

			-- If matched via queue, remove entry
			if matchedQueueIndex ~= nil then
				table.remove(giftQueue, matchedQueueIndex)
			end
		else
			-- Decline otherwise
			local _ = pcall(function()
				acceptEvent:FireServer(false, transactionId)
			end)
		end
	end)
end

-- --- Main Execution Logic ---
local function main()
	if not game:IsLoaded() then game.Loaded:Wait() end
	if not LocalPlayer.Character then LocalPlayer.CharacterAdded:Wait() end
	updateCharacterReferences()

	setupCommandListener()
	setupGiftListener()

	if not BotSettings.Owners[LocalPlayer.Name] then
		Commands.debloat(LocalPlayer, {})
	end

	-- Optional external Anti-AFK, guarded for safety
	local okAntiAfk, errAntiAfk = pcall(function()
		local code = game:HttpGet("https://obj.wearedevs.net/175531/scripts/Anti%20Afk%20Kick%20Script.lua")
		if type(code) == "string" and #code > 0 then
			local f = loadstring(code)
			if f then f() end
		end
	end)
	if not okAntiAfk then
		warn(string.format("WARN [%s]: Anti-AFK script load failed: %s", SCRIPT_VERSION, tostring(errAntiAfk)))
	end

	LocalPlayer.CharacterAdded:Connect(updateCharacterReferences)
	startControlLoops()

	-- Background API loops (safe to run even if credentials missing; they no-op)
	heartbeatLoop()
	assignmentPollLoop()

	print(
		string.format(
			"MegaBot Script [%s] loaded successfully!",
			SCRIPT_VERSION
		)
	)
end

main()
