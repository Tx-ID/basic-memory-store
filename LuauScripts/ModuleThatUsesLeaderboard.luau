
local Players = game:GetService("Players")

local Utility = require( game:GetService("ReplicatedStorage"):WaitForChild("Utility") )
local LeaderboardModule = require( game:GetService("ServerScriptService"):WaitForChild("events"):WaitForChild("EventUtility"):WaitForChild("TixLeaderboard") )

local Network = require( script.Parent:WaitForChild("Network") )
local Replica = require( script.Parent:WaitForChild("Replica") )
local Config = require( script.Parent:WaitForChild("Config") )

local PlayerManager: typeof( require( script.Parent:WaitForChild("PlayerManager") ) )

local Signal = Utility.Signals

local prefix = Utility.IsTestServer and "mmk-test" or "mmk"
local Leaderboards: {[string]: typeof(LeaderboardModule.new())} = {
	coins = LeaderboardModule.new(`{prefix}-lb-coins`, true, true),
	penguins = LeaderboardModule.new(`{prefix}-lb-penguins`, true, true),
}


--
local this = {}

function this.leaderboardActive(): boolean
	local yourUTC = -DateTime.fromLocalTime().UnixTimestamp
	local utcTime = os.time() - yourUTC

	return utcTime <= Config.LeaderboardEndUnix
end

function this.set(category: string, player: Player, score: number)
	local lb = Leaderboards[category]
	if (not lb) then error(`Unknown leaderboard "{category}"`) end
	
	if not this.leaderboardActive() then
		return
	end
	
	lb:SetScore(player, score)
end

function this.getRank(category: string, player: Player)
	local lb = Leaderboards[category]
	if (not lb) then error(`Unknown leaderboard "{category}"`) end
	
	return lb:GetRank(player)
end

function this.getTopPage(category: string, size: number?)
	local lb = Leaderboards[category]
	if (not lb) then error(`Unknown leaderboard "{category}"`) end
	
	return lb:GetTop(size)
end


--
local LeaderboardUpdated = Signal.new()
function this.updateLeaderboard()
	local list = {}
	for name, _ in pairs( Leaderboards ) do
		local top = this.getTopPage(name, 100)
		if (not top) then continue end
		
		local new_list = {}
		for _, data in pairs( top:GetCurrentPage() ) do
			local value = data.value :: LeaderboardModule.LeaderboardEntry
			if value and value.Score > 0 then
				table.insert(new_list, data)
			end
		end
		list[name] = new_list
	end
	this.Leaderboard = list
	LeaderboardUpdated:Fire()
end

function this.getLeaderboardUpdatedSignal()
	return LeaderboardUpdated
end

local LastLeaderboardUpdate = 0
function this.attemptUpdateLeaderboard()
	local dt = tick() - LastLeaderboardUpdate
	if dt >= 300 then
		LastLeaderboardUpdate = tick()
		this.updateLeaderboard()
	end
end

function this.getLeaderboard()
	return this.Leaderboard or {}
end


--
function this.init()
	if this._init then return end
	this._init = true
	
	Replica.updateSetting("LeaderboardEnd", Config.LeaderboardEndUnix)
end

task.spawn(this.init)


--
return this
