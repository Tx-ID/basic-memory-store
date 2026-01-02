local HttpService = game:GetService("HttpService")

--
local ConfigService = require(script:WaitForChild("ConfigService"))

_ = ConfigService.getConfig() or ConfigService.ConfigAdded:Wait()
local Snapshot = ConfigService.getConfig()
local ConfigData: { key: string? } = Snapshot and Snapshot:GetValue("tixmemory") or {}

local BASE_URL = ConfigData.url or ""
local AUTHORIZATION_KEY = `Bearer {ConfigData.key or ""}`
local GlobalConfig = {
	DefaultExpiration = 60 * 5,
	LocalCacheDefaultTTL = 60,
	LocalCachePruneInterval = 120,
}

local Http = require(script:WaitForChild("Http"))
local TimeParser = require(script:WaitForChild("TimeParser"))

--
local LocalCache = {}
LocalCache.Storage = {}

function LocalCache.Get(key)
	local item = LocalCache.Storage[key]
	if item then
		if os.time() < item.Expiration then
			return item.Data
		else
			LocalCache.Storage[key] = nil
		end
	end
	return nil
end

function LocalCache.Set(key, data, ttl)
	LocalCache.Storage[key] = {
		Data = data,
		Expiration = os.time() + (ttl or GlobalConfig.LocalCacheDefaultTTL)
	}
end

-- Auto-pruning
task.spawn(function()
	while true do
		task.wait(GlobalConfig.LocalCachePruneInterval)
		local now = os.time()
		for key, item in pairs(LocalCache.Storage) do
			if now >= item.Expiration then
				LocalCache.Storage[key] = nil
			end
		end
	end
end)

--
local ListInterface = {}
ListInterface.__index = ListInterface

function ListInterface.new(controls: {
	sizePerPage: number,
	getResponseByCursor: (maxSize: number, cursor: any?) -> any,
	isValidResponse: (any) -> boolean,
	getCursorFromResponse: (any) -> any?,
	getPageDataByResponse: (any) -> { IsFinished: boolean, TotalItems: number },
	getListFromResponse: (any) -> { { key: string, value: any } },
})
	local self = setmetatable({
		IsFinished = false,
		_response = nil,
		_page = 1,
		_controls = controls,
	}, ListInterface)

	self:_fetchCurrentPageAsync()
	return self
end
export type TixList = typeof(ListInterface.new(nil))

function ListInterface.GetCurrentPage(self: TixList)
	if self._response then
		return self._controls.getListFromResponse(self._response)
	end
	return {}
end

function ListInterface._fetchCurrentPageAsync(self: TixList)
	local cursor = nil
	if self._response then
		cursor = self._controls.getCursorFromResponse(self._response)
	end

	local response = self._controls.getResponseByCursor(self._controls.sizePerPage, cursor)
	if not self._controls.isValidResponse(response) then
		error(`Failed to fetch page data`)
	end
	self._response = response

	local page_data = self._controls.getPageDataByResponse(response)
	if page_data and page_data.IsFinished then
		self.IsFinished = true
	end
end

function ListInterface.AdvanceToNextPageAsync(self: TixList)
	if self.IsFinished then
		return
	end
	self._page += 1
	self:_fetchCurrentPageAsync()
end

--
local HttpHashMap = {}
HttpHashMap.__index = HttpHashMap

function HttpHashMap.new(id: string, useDb: boolean?)
	local self = setmetatable({
		Id = id,
		UseDb = useDb == true,
		_queue = {},
		_queueCount = 0,
		_queueTTL = nil,
		_lastFirstItemTime = 0,
		_batchConfig = {
			enabled = true,
			minSize = 1,
			maxSize = 100,
			waitTime = 1,
			delayPerBatch = 0,
			forceWaitTime = 0,
		},
	}, HttpHashMap)

	task.spawn(function()
		while true do
			task.wait(0.1)
			if self._batchConfig.enabled and self._queueCount > 0 then
				local shouldFlush = false
				local now = os.time()

				-- Check conditions
				if self._queueCount >= self._batchConfig.maxSize then
					shouldFlush = true
				elseif self._queueCount >= self._batchConfig.minSize then
					if now - self._lastFirstItemTime >= self._batchConfig.waitTime then
						shouldFlush = true
					end
				elseif self._batchConfig.forceWaitTime > 0 then
					if now - self._lastFirstItemTime >= self._batchConfig.forceWaitTime then
						shouldFlush = true
					end
				end

				if shouldFlush then
					local batch = self._queue
					local ttl = self._queueTTL

					self._queue = {}
					self._queueCount = 0
					self._queueTTL = nil
					self._lastFirstItemTime = 0

					task.spawn(function()
						self:BatchSetAsync(batch, ttl)
					end)
				end
			end
		end
	end)

	return self
end
export type TixHashMap = typeof(HttpHashMap.new("test-id"))
export type ValidValue = string | number | { [any]: any } | { any }
export type Expiration = number | string?

function HttpHashMap._getPath(self: TixHashMap, key: string?)
	local path = `{BASE_URL}/{self.Id}`
	if key then
		path ..= `/{HttpService:UrlEncode(key)}`
	end
	return path
end

function HttpHashMap._getParams(self: TixHashMap, extra: { [string]: any }?)
	local params = extra or {}
	if self.UseDb then
		params.useDb = "true"
	end
	return params
end

function HttpHashMap.SetAsync(self: TixHashMap, key: string, value: ValidValue, expiration: Expiration)
	local ttl = TimeParser.parse(expiration) or GlobalConfig.DefaultExpiration
	local http_response = Http.request(self:_getPath(key), {
		method = "POST",
		headers = {
			authorization = AUTHORIZATION_KEY,
			["content-type"] = "application/json",
		},
		params = self:_getParams(),
		data = {
			ttl = ttl,
			data = value,
			persist = self.UseDb,
		},
		deduplicationKey = self:_getPath(key),
	})
	if not http_response.Success then
		error(`Failed to post HttpMemoryStore: {http_response.StatusCode}`)
	end
end

function HttpHashMap.GetAsync(self: TixHashMap, key: string, cacheOptions: { id: string?, ttl: number }?)
	local cacheKey
	if cacheOptions and cacheOptions.ttl then
		cacheKey = cacheOptions.id or `Get_{self.Id}_{key}`
		local cached = LocalCache.Get(cacheKey)
		if cached then
			return cached
		end
	end

	local http_response = Http.request(self:_getPath(key), {
		method = "GET",
		headers = {
			authorization = AUTHORIZATION_KEY,
			["content-type"] = "application/json",
		},
		params = self:_getParams(),
	})
	if not http_response.Success then
		if http_response.StatusCode == 404 then
			return nil
		end
		error(`Failed to get HttpMemoryStore: {http_response.StatusCode}`)
	end

	if cacheKey then
		LocalCache.Set(cacheKey, http_response.Body.data, cacheOptions.ttl)
	end

	return http_response.Body.data
end

function HttpHashMap.ConfigureBatching(self: TixHashMap, config: {
	enabled: boolean?,
	minBatchSize: number?,
	maxBatchSize: number?,
	waitTime: number?,
	delayPerBatch: number?,
	forceWaitTime: number?
})
	if config.enabled ~= nil then self._batchConfig.enabled = config.enabled end
	if config.minBatchSize then self._batchConfig.minSize = config.minBatchSize end
	if config.maxBatchSize then self._batchConfig.maxSize = config.maxBatchSize end
	if config.waitTime then self._batchConfig.waitTime = config.waitTime end
	if config.delayPerBatch then self._batchConfig.delayPerBatch = config.delayPerBatch end
	if config.forceWaitTime then self._batchConfig.forceWaitTime = config.forceWaitTime end
end

function HttpHashMap.QueueBatchSetAsync(self: TixHashMap, key: string, value: ValidValue, expiration: Expiration)
	if not self._queue[key] then
		self._queueCount += 1
		if self._queueCount == 1 then
			self._lastFirstItemTime = os.time()
		end
	end
	self._queue[key] = value
	if expiration then
		self._queueTTL = expiration
	end

	-- Immediate flush if maxSize reached
	if self._batchConfig.enabled and self._queueCount >= self._batchConfig.maxSize then
		local batch = self._queue
		local ttl = self._queueTTL

		self._queue = {}
		self._queueCount = 0
		self._queueTTL = nil
		self._lastFirstItemTime = 0

		task.spawn(function()
			self:BatchSetAsync(batch, ttl)
		end)
	end
end

function HttpHashMap.BatchSetAsync(self: TixHashMap, items: { [string]: any }, expiration: Expiration)
	local ttl = TimeParser.parse(expiration) or GlobalConfig.DefaultExpiration
	local payloadItems = {}
	for k, v in pairs(items) do
		table.insert(payloadItems, { key = k, data = v })
	end

	local function sendBatch(batch)
		local path = `{BASE_URL}/{self.Id}/batch/set`
		local http_response = Http.request(path, {
			method = "POST",
			headers = {
				authorization = AUTHORIZATION_KEY,
				["content-type"] = "application/json",
			},
			params = self:_getParams(),
			data = {
				ttl = ttl,
				items = batch,
				persist = self.UseDb,
			},
		})
		if not http_response.Success then
			error(`Failed to batch set HttpMemoryStore: {http_response.StatusCode}`)
		end
	end

	local chunk = {}
	for _, item in ipairs(payloadItems) do
		table.insert(chunk, item)
		if #chunk >= 100 then
			sendBatch(chunk)
			chunk = {}
			if self._batchConfig.delayPerBatch > 0 then
				task.wait(self._batchConfig.delayPerBatch)
			end
		end
	end
	if #chunk > 0 then
		sendBatch(chunk)
	end
end

function HttpHashMap.BatchGetAsync(self: TixHashMap, keys: { string }, cacheOptions: { id: string?, ttl: number }?)
	local results = {}
	local keysToFetch = {}

	if cacheOptions and cacheOptions.ttl then
		for _, key in pairs(keys) do
			local cacheKey = cacheOptions.id and `{cacheOptions.id}_{key}` or `Get_{self.Id}_{key}`
			local cached = LocalCache.Get(cacheKey)
			if cached then
				results[key] = cached
			else
				table.insert(keysToFetch, key)
			end
		end
	else
		keysToFetch = keys
	end

	local function fetchBatch(batchKeys)
		local path = `{BASE_URL}/{self.Id}/batch/get`
		local http_response = Http.request(path, {
			method = "POST",
			headers = {
				authorization = AUTHORIZATION_KEY,
				["content-type"] = "application/json",
			},
			params = self:_getParams(),
			data = {
				keys = batchKeys,
				useDb = self.UseDb,
			},
		})

		if not http_response.Success then
			error(`Failed to batch get HttpMemoryStore: {http_response.StatusCode}`)
		end

		local data = http_response.Body.data or {}
		for _, item in pairs(data) do
			results[item.key] = item.data

			if cacheOptions and cacheOptions.ttl then
				local cacheKey = cacheOptions.id and `{cacheOptions.id}_{item.key}` or `Get_{self.Id}_{item.key}`
				LocalCache.Set(cacheKey, item.data, cacheOptions.ttl)
			end
		end
	end

	if #keysToFetch > 0 then
		local chunk = {}
		for _, key in pairs(keysToFetch) do
			table.insert(chunk, key)
			if #chunk >= 100 then
				fetchBatch(chunk)
				chunk = {}
			end
		end
		if #chunk > 0 then
			fetchBatch(chunk)
		end
	end

	return results
end

function HttpHashMap.AllItemsAsync(self: TixHashMap)
	local http_response = Http.request(self:_getPath(), {
		method = "GET",
		headers = { authorization = AUTHORIZATION_KEY },
		params = self:_getParams({ pageSize = 5000 }),
	})
	if not http_response.Success then
		error(`Failed to get all HttpMemoryStore: {http_response.StatusCode}`)
	end

	local get = http_response.Body.data or {}
	local list = {}
	for _, data in pairs(get) do
		table.insert(list, {
			key = data.key,
			value = data.data,
		})
	end
	return list
end

function HttpHashMap.ListItemsAsync(self: TixHashMap, sizePerPage: number)
	sizePerPage = sizePerPage or 50
	return ListInterface.new({
		sizePerPage = sizePerPage,
		getResponseByCursor = function(size: number, cursor: any?)
			local query = { pageSize = size }
			if cursor then
				query.cursor = tostring(cursor)
			end

			local http_response = Http.request(self:_getPath(), {
				method = "GET",
				headers = {
					authorization = AUTHORIZATION_KEY,
					["content-type"] = "application/json",
				},
				params = self:_getParams(query),
			})
			if not http_response.Success then
				warn(`Failed to get page HttpMemoryStore: {http_response.StatusCode}`)
				return { Success = false }
			end
			return http_response
		end,
		getCursorFromResponse = function(response: any)
			return response.Body and response.Body.meta and response.Body.meta.nextCursor
		end,
		isValidResponse = function(response: any)
			return type(response) == "table" and response.Success and response.Body and response.Body.data
		end,
		getPageDataByResponse = function(response: any)
			local meta = response.Body.meta
			return {
				IsFinished = not meta.hasMore,
				TotalItems = meta.totalItems,
			}
		end,
		getListFromResponse = function(response: any)
			local get = response.Body.data or {}
			local list = {}
			for _, data in pairs(get) do
				table.insert(list, {
					key = data.key,
					value = data.data,
				})
			end
			return list
		end,
	})
end

function HttpHashMap.GetSortedAsync(
	self: TixHashMap,
	dataName: string,
	sortDirection: "asc" | "desc",
	sizePerPage: number,
	defaultValue: any?,
	cacheOptions: { id: string?, ttl: number }?
)
	sizePerPage = sizePerPage or 50
	sortDirection = sortDirection or "desc"

	return ListInterface.new({
		sizePerPage = sizePerPage,
		getResponseByCursor = function(size: number, cursor: any?)
			local cacheKey
			if cacheOptions and cacheOptions.ttl then
				local base = cacheOptions.id or `Sorted_{self.Id}_{dataName}_{sortDirection}_{defaultValue or "nil"}_{size}`
				cacheKey = `{base}_{tostring(cursor or "start")}`

				local cached = LocalCache.Get(cacheKey)
				if cached then
					return cached
				end
			end

			local query = {
				pageSize = size,
				dataName = dataName,
				sortDirection = sortDirection,
				defaultValue = defaultValue and tostring(defaultValue) or nil,
			}
			if cursor then
				query.cursor = tostring(cursor)
			end

			local http_response = Http.request(self:_getPath("sorted"), {
				method = "GET",
				headers = {
					authorization = AUTHORIZATION_KEY,
					["content-type"] = "application/json",
				},
				params = self:_getParams(query),
			})

			if cacheKey and http_response.Success then
				LocalCache.Set(cacheKey, http_response, cacheOptions.ttl)
			end

			if not http_response.Success then
				warn(`Failed to get sorted page HttpMemoryStore: {http_response.StatusCode}`)
				return { Success = false }
			end
			return http_response
		end,
		getCursorFromResponse = function(response: any)
			return response.Body and response.Body.meta and response.Body.meta.nextCursor
		end,
		isValidResponse = function(response: any)
			return type(response) == "table" and response.Success and response.Body and response.Body.data
		end,
		getPageDataByResponse = function(response: any)
			local meta = response.Body.meta
			return {
				IsFinished = not meta.hasMore,
				TotalItems = meta.totalItems,
			}
		end,
		getListFromResponse = function(response: any)
			local get = response.Body.data or {}
			local list = {}
			for _, data in pairs(get) do
				table.insert(list, {
					key = data.key,
					value = data.data,
				})
			end
			return list
		end,
	})
end

function HttpHashMap.GetRankAsync(
	self: TixHashMap,
	key: string,
	dataName: string,
	sortDirection: "asc" | "desc",
	defaultValue: any?,
	cacheOptions: { id: string?, ttl: number }?
)
	sortDirection = sortDirection or "desc"

	local cacheKey
	if cacheOptions and cacheOptions.ttl then
		cacheKey = cacheOptions.id or `Rank_{self.Id}_{key}_{dataName}_{sortDirection}_{defaultValue or "nil"}`
		local cached = LocalCache.Get(cacheKey)
		if cached then
			return cached
		end
	end

	local path = `{self:_getPath()}/rank/{HttpService:UrlEncode(key)}`

	local http_response = Http.request(path, {
		method = "GET",
		headers = {
			authorization = AUTHORIZATION_KEY,
			["content-type"] = "application/json",
		},
		params = self:_getParams({
			dataName = dataName,
			sortDirection = sortDirection,
			defaultValue = defaultValue and tostring(defaultValue) or nil,
		}),
	})

	if not http_response.Success then
		if http_response.StatusCode == 404 then
			return nil
		end
		error(`Failed to get rank HttpMemoryStore: {http_response.StatusCode}`)
	end

	if cacheKey then
		LocalCache.Set(cacheKey, http_response.Body.data.rank, cacheOptions.ttl)
	end

	return http_response.Body.data.rank
end

function HttpHashMap.UpdateAsync(
	self: TixHashMap,
	key: string,
	transform_function: (data: any) -> any,
	expiration: Expiration
)
	local get = self:GetAsync(key)
	local new = transform_function(get)
	if new == nil then
		return
	end
	self:SetAsync(key, new, expiration)
end

function HttpHashMap.RemoveAsync(self: TixHashMap, key: string)
	local http_response = Http.request(self:_getPath(key), {
		method = "DELETE",
		headers = {
			authorization = AUTHORIZATION_KEY,
			["content-type"] = "application/json",
		},
		params = self:_getParams(),
		deduplicationKey = self:_getPath(key),
	})
	if not http_response.Success then
		error(`Failed to remove HttpMemoryStore: {http_response.StatusCode}`)
	end
end

--
local this = {}
local cache = { HashMap = {} }

function this.Configure(config: {
	DefaultExpiration: number?,
	LocalCacheDefaultTTL: number?,
	LocalCachePruneInterval: number?
})
	if config.DefaultExpiration then GlobalConfig.DefaultExpiration = config.DefaultExpiration end
	if config.LocalCacheDefaultTTL then GlobalConfig.LocalCacheDefaultTTL = config.LocalCacheDefaultTTL end
	if config.LocalCachePruneInterval then GlobalConfig.LocalCachePruneInterval = config.LocalCachePruneInterval end
end

function this:GetHashMap(id: string, useDb: boolean?)
	local cacheKey = `{id}_{useDb and "db" or "mem"}`
	if not cache.HashMap[cacheKey] then
		cache.HashMap[cacheKey] = HttpHashMap.new(id, useDb)
	end
	return cache.HashMap[cacheKey]
end

return this
