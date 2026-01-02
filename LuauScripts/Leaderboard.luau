local Leaderboard = {}
Leaderboard.__index = Leaderboard

local MemoryStoreClient = require(script.Parent.Parent:WaitForChild("luauClient"))

local DEFAULT_EXPIRATION = "90d"

export type LeaderboardEntry = {
	UserId: number,
	Username: string,
	DisplayName: string,
	Score: number,
}

export type RankResponse = {
	Rank: number?,
	Data: LeaderboardEntry?,
}

type TixList = MemoryStoreClient.TixList

export type Leaderboard = typeof(setmetatable({}, Leaderboard))

function Leaderboard.new(boardId: string, useDb: boolean?, useCache: boolean?)
	local self = setmetatable({}, Leaderboard)
	self._store = MemoryStoreClient:GetHashMap(boardId, useDb)

	-- Default batching configuration to reduce HTTP usage
	self._store:ConfigureBatching({
		enabled = true,
		minBatchSize = 5,
		maxBatchSize = 50,
		waitTime = 5, -- Wait up to 5 seconds before flushing if minBatchSize is met
		forceWaitTime = 60, -- Always flush after 60 seconds regardless of batch size
	})

	self._sortField = "Score" -- The JSON field used for ranking
	self._useCache = useCache
	self._cacheTtl = 60 -- Default cache duration
	return self
end

function Leaderboard.ConfigureBatching(self: Leaderboard, config: {
	enabled: boolean?,
	minBatchSize: number?,
	maxBatchSize: number?,
	waitTime: number?,
	delayPerBatch: number?,
	forceWaitTime: number?
})
	self._store:ConfigureBatching(config)
end

-- Sets the player's score (queued for batch update)
function Leaderboard.SetScore(self: Leaderboard, player: Player, score: number, expiration: (string | number)?)
	local key = tostring(player.UserId)
	local data = {
		UserId = player.UserId,
		Username = player.Name,
		DisplayName = player.DisplayName,
		Score = score,
	}

	-- Expires in 30 days by default to keep the board fresh, or adjust as needed
	self._store:QueueBatchSetAsync(key, data, expiration or DEFAULT_EXPIRATION)
end

-- Increments the player's existing score
function Leaderboard.IncrementScore(self: Leaderboard, player: Player, amount: number, expiration: (string | number)?)
	local key = tostring(player.UserId)

	self._store:UpdateAsync(key, function(oldData)
		local currentScore = 0
		if oldData and oldData.Score then
			currentScore = tonumber(oldData.Score) or 0
		end

		-- If data doesn't exist, start fresh
		if not oldData then
			oldData = {
				UserId = player.UserId,
			}
		end

		oldData.Score = currentScore + amount
		oldData.Username = player.Name
		oldData.DisplayName = player.DisplayName

		return oldData
	end, expiration or DEFAULT_EXPIRATION)
end

-- Gets the player's Rank and their Data
function Leaderboard.GetRank(self: Leaderboard, player: Player): RankResponse
	local key = tostring(player.UserId)
	
	local cacheOptions = nil
	if self._useCache then
		cacheOptions = { ttl = self._cacheTtl }
	end

	-- GetRankAsync(key, dataName, sortDirection, defaultValue, cacheOptions)
	-- Using defaultValue = 0 ensures players not on the board yet are ranked as if they have 0 score
	local rank = self._store:GetRankAsync(key, self._sortField, "desc", 0, cacheOptions)

	-- Also fetch the actual data to return (e.g., to show their current score)
	local data = self._store:GetAsync(key, cacheOptions)

	return {
		Rank = rank,
		Data = data,
	}
end

-- Returns a PagingObject for iterating through the top players
function Leaderboard.GetTop(self: Leaderboard, pageSize: number?): TixList
	local cacheOptions = nil
	if self._useCache then
		cacheOptions = { ttl = self._cacheTtl }
	end
	
	-- GetSortedAsync(dataName, sortDirection, sizePerPage, defaultValue, cacheOptions)
	return self._store:GetSortedAsync(self._sortField, "desc", pageSize or 50, 0, cacheOptions)
end

return Leaderboard
