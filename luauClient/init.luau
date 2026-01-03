local HttpService = game:GetService("HttpService")

-- Service Dependencies
local ConfigService = require(script:WaitForChild("ConfigService"))

-- Wait for configuration to be ready
_ = ConfigService.getConfig() or ConfigService.ConfigAdded:Wait()
local Snapshot = ConfigService.getConfig()
local ConfigData: { key: string? } = Snapshot and Snapshot:GetValue("tixmemory") or {}

local BASE_URL = ConfigData.url or ""
local AUTHORIZATION_KEY = `Bearer {ConfigData.key or ""}`

--[=[
	Global configuration defaults for the client.
	Can be modified via `TixMemoryClient.Configure`.
]=]
local GlobalConfig = {
	DefaultExpiration = 60 * 5, -- Default TTL for items on the server (5 minutes)
	LocalCacheDefaultTTL = 60, -- Default TTL for items in the local cache (1 minute)
	LocalCachePruneInterval = 120, -- How often to clean up expired local cache items (2 minutes)
}

local Http = require(script:WaitForChild("Http"))
local TimeParser = require(script:WaitForChild("TimeParser"))

--[=[
	@class LocalCache
	@private
	
	A simple internal cache implementation with Time-To-Live (TTL) support.
	Used to cache `GetAsync` results and reduce API calls.
]=]
local LocalCache = {}
LocalCache.Storage = {}

--[=[
	Retrieves an item from the local cache if it exists and hasn't expired.
	
	@param key string -- The cache key
	@return any? -- The cached data or nil
]=]
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

--[=[
	Sets an item in the local cache with a specified TTL.
	
	@param key string -- The cache key
	@param data any -- The data to store
	@param ttl number? -- Time to live in seconds (defaults to GlobalConfig.LocalCacheDefaultTTL)
]=]
function LocalCache.Set(key, data, ttl)
	LocalCache.Storage[key] = {
		Data = data,
		Expiration = os.time() + (ttl or GlobalConfig.LocalCacheDefaultTTL)
	}
end

-- Background task for pruning expired items from LocalCache
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

--[=[
	@class ListInterface
	
	An iterator object for handling paginated responses from the API.
	Allows traversing through pages of data seamlessly.
]=]
local ListInterface = {}
ListInterface.__index = ListInterface

--[=[
	Creates a new ListInterface instance.
	@private
	@param controls table -- Internal control functions for fetching data
	@return TixList
]=]
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

--[=[
	Gets the items on the current page.
	
	@return { { key: string, value: any } } -- List of items
]=]
function ListInterface.GetCurrentPage(self: TixList)
	if self._response then
		return self._controls.getListFromResponse(self._response)
	end
	return {}
end

--[=[
	Internal method to fetch the current page data using the cursor.
	@private
]=]
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

--[=[
	Advances the iterator to the next page of results.
	Does nothing if `IsFinished` is true.
]=]
function ListInterface.AdvanceToNextPageAsync(self: TixList)
	if self.IsFinished then
		return
	end
	self._page += 1
	self:_fetchCurrentPageAsync()
end

--[=[
	@class HttpHashMap
	
	Represents a connection to a specific map/collection in the memory store.
	Provides methods for CRUD operations, batching, and sorting.
]=]
local HttpHashMap = {}
HttpHashMap.__index = HttpHashMap

--[=[
	Creates a new HttpHashMap instance.
	
	@param id string -- The unique identifier for this map/collection
	@param useDb boolean? -- If true, enables persistent storage (if supported by server backend)
	@return TixHashMap
]=]
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

	-- Background task for processing the auto-batching queue
	task.spawn(function()
		while true do
			task.wait(0.1)
			if self._batchConfig.enabled and self._queueCount > 0 then
				local shouldFlush = false
				local now = os.time()

				-- Check flush conditions based on queue size and wait time
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

--[=[
	Constructs the API path for a given key.
	@private
]=]
function HttpHashMap._getPath(self: TixHashMap, key: string?)
	local path = `{BASE_URL}/{self.Id}`
	if key then
		path ..= `/{HttpService:UrlEncode(key)}`
	end
	return path
end

--[=[
	Constructs the URL parameters for requests.
	@private
]=]
function HttpHashMap._getParams(self: TixHashMap, extra: { [string]: any }?)
	local params = extra or {}
	if self.UseDb then
		params.useDb = "true"
	end
	return params
end

--[=[
	Sets a value for a specific key in the memory store.
	
	@param key string -- The key to set
	@param value ValidValue -- The value to store
	@param expiration Expiration -- TTL in seconds or a time string (e.g. "5m")
]=]
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

--[=[
	Retrieves a value for a specific key.
	
	@param key string -- The key to retrieve
	@param cacheOptions { id: string?, ttl: number }? -- Optional local caching settings. 
		If provided, checks local cache first and caches the result on success.
	@return any? -- The retrieved value or nil
]=]
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

--[=[
	Configures the automatic batching behavior for `QueueBatchSetAsync`.
	
	@param config table
		- enabled: boolean?
		- minBatchSize: number?
		- maxBatchSize: number?
		- waitTime: number? -- Seconds to wait before flushing if minBatchSize reached
		- delayPerBatch: number? -- Throttle between batch requests
		- forceWaitTime: number? -- Max seconds to wait before forcing a flush
]=]
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

--[=[
	Queues a Set operation to be executed in a batch.
	Highly recommended for high-frequency writes to reduce API calls.
	
	@param key string
	@param value ValidValue
	@param expiration Expiration
]=]
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

--[=[
	Immediately executes a batch Set operation for multiple items.
	
	@param items { [string]: any } -- Map of key-value pairs to set
	@param expiration Expiration
]=]
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

	-- Chunk requests to avoid hitting payload limits (max 100 per chunk)
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

--[=[
	Performs a batch Get operation for multiple keys.
	
	@param keys { string } -- List of keys to retrieve
	@param cacheOptions { id: string?, ttl: number }? -- Optional local caching
	@return { [string]: any } -- Map of retrieved key-value pairs
]=]
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

--[=[
	Retrieves all items in the map (paginated internally, returns simple list).
	Warning: Can be slow for very large collections.
	
	@return { { key: string, value: any } }
]=]
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

--[=[
	Returns a ListInterface iterator to paginate through items.
	
	@param sizePerPage number -- Items per page
	@return TixList
]=]
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

--[=[
	Retrieves a sorted list of items based on a specific data field.
	
	@param dataName string -- The field name within the stored data objects to sort by
	@param sortDirection "asc" | "desc"
	@param sizePerPage number
	@param defaultValue any? -- Default value if the field is missing
	@param cacheOptions table?
	@return TixList
]=]
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

--[=[
	Gets the rank of a specific key within a sorted context.
	
	@param key string -- The item key to rank
	@param dataName string -- The field to sort by
	@param sortDirection "asc" | "desc"
	@param defaultValue any?
	@param cacheOptions table?
	@return number? -- The rank (0-indexed usually) or nil if not found/error
]=]
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

--[=[
	Updates an existing item by applying a transformation function.
	This is a read-modify-write operation (not atomic server-side).
	
	@param key string
	@param transform_function (data: any) -> any -- Function that takes old data and returns new data
	@param expiration Expiration
]=]
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

--[=[
	Removes a key from the memory store.
	
	@param key string
]=]
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

-- Global Batching Logic
local GlobalBatch = {
	Queue = {}, -- Key: "index::key", Value: {index, key, data, useDb}
	Count = 0,
	TTL = nil,
	LastFirstItemTime = 0,
	Config = {
		enabled = true,
		minSize = 1,
		maxSize = 200,
		waitTime = 1,
		delayPerBatch = 0,
		forceWaitTime = 0,
	},
}

-- Background task for Global Batch
task.spawn(function()
	while true do
		task.wait(0.1)
		if GlobalBatch.Config.enabled and GlobalBatch.Count > 0 then
			local shouldFlush = false
			local now = os.time()

			if GlobalBatch.Count >= GlobalBatch.Config.maxSize then
				shouldFlush = true
			elseif GlobalBatch.Count >= GlobalBatch.Config.minSize then
				if now - GlobalBatch.LastFirstItemTime >= GlobalBatch.Config.waitTime then
					shouldFlush = true
				end
			elseif GlobalBatch.Config.forceWaitTime > 0 then
				if now - GlobalBatch.LastFirstItemTime >= GlobalBatch.Config.forceWaitTime then
					shouldFlush = true
				end
			end

			if shouldFlush then
				local queue = GlobalBatch.Queue
				local ttl = GlobalBatch.TTL

				GlobalBatch.Queue = {}
				GlobalBatch.Count = 0
				GlobalBatch.TTL = nil
				GlobalBatch.LastFirstItemTime = 0

				task.spawn(function()
					-- Split into mem and db batches
					local memItems = {}
					local dbItems = {}

					for _, item in pairs(queue) do
						if item.useDb then
							table.insert(dbItems, item)
						else
							table.insert(memItems, item)
						end
					end

					if #memItems > 0 then
						this:GlobalBatchSetAsync(memItems, ttl, false)
					end
					if #dbItems > 0 then
						this:GlobalBatchSetAsync(dbItems, ttl, true)
					end
				end)
			end
		end
	end
end)

--[=[
	Configures global batching behavior.
]=]
function this:ConfigureGlobalBatching(config: {
	enabled: boolean?,
	minBatchSize: number?,
	maxBatchSize: number?,
	waitTime: number?,
	delayPerBatch: number?,
	forceWaitTime: number?
})
	if config.enabled ~= nil then GlobalBatch.Config.enabled = config.enabled end
	if config.minBatchSize then GlobalBatch.Config.minSize = config.minBatchSize end
	if config.maxBatchSize then GlobalBatch.Config.maxSize = config.maxBatchSize end
	if config.waitTime then GlobalBatch.Config.waitTime = config.waitTime end
	if config.delayPerBatch then GlobalBatch.Config.delayPerBatch = config.delayPerBatch end
	if config.forceWaitTime then GlobalBatch.Config.forceWaitTime = config.forceWaitTime end
end

--[=[
	Queues an item for the global batch.
]=]
function this:QueueGlobalBatchSetAsync(index: string, key: string, value: ValidValue, expiration: Expiration, useDb: boolean?)
	local compositeKey = `{index}::{key}`
	if not GlobalBatch.Queue[compositeKey] then
		GlobalBatch.Count += 1
		if GlobalBatch.Count == 1 then
			GlobalBatch.LastFirstItemTime = os.time()
		end
	end
	
	GlobalBatch.Queue[compositeKey] = {
		index = index,
		key = key,
		data = value,
		useDb = useDb
	}

	if expiration then
		GlobalBatch.TTL = expiration
	end

	-- Check for immediate flush
	if GlobalBatch.Config.enabled and GlobalBatch.Count >= GlobalBatch.Config.maxSize then
		local queue = GlobalBatch.Queue
		local ttl = GlobalBatch.TTL

		GlobalBatch.Queue = {}
		GlobalBatch.Count = 0
		GlobalBatch.TTL = nil
		GlobalBatch.LastFirstItemTime = 0

		task.spawn(function()
			local memItems = {}
			local dbItems = {}
			for _, item in pairs(queue) do
				if item.useDb then
					table.insert(dbItems, item)
				else
					table.insert(memItems, item)
				end
			end
			if #memItems > 0 then
				this:GlobalBatchSetAsync(memItems, ttl, false)
			end
			if #dbItems > 0 then
				this:GlobalBatchSetAsync(dbItems, ttl, true)
			end
		end)
	end
end

--[=[
	Executes a global batch set.
]=]
function this:GlobalBatchSetAsync(items: { { index: string, key: string, data: any } }, expiration: Expiration, useDb: boolean?)
	local ttl = TimeParser.parse(expiration) or GlobalConfig.DefaultExpiration
	local payloadItems = items

	local function sendBatch(batch)
		local path = `{BASE_URL}/batch/buffered`
		local http_response = Http.request(path, {
			method = "POST",
			headers = {
				authorization = AUTHORIZATION_KEY,
				["content-type"] = "application/json",
			},
			params = {},
			data = {
				ttl = ttl,
				items = batch,
				persist = useDb,
			},
		})
		if not http_response.Success then
			error(`Failed to global batch set HttpMemoryStore: {http_response.StatusCode}`)
		end
	end

	local chunk = {}
	for _, item in ipairs(payloadItems) do
		table.insert(chunk, item)
		if #chunk >= 200 then
			sendBatch(chunk)
			chunk = {}
			if GlobalBatch.Config.delayPerBatch > 0 then
				task.wait(GlobalBatch.Config.delayPerBatch)
			end
		end
	end
	if #chunk > 0 then
		sendBatch(chunk)
	end
end

--[=[
	Forcefully flushes the global batch queue.
	Useful for game shutdown (BindToClose) to ensure data is saved.
]=]
function this:FlushGlobalBatchAsync()
	if GlobalBatch.Count == 0 then return end

	local queue = GlobalBatch.Queue
	local ttl = GlobalBatch.TTL

	GlobalBatch.Queue = {}
	GlobalBatch.Count = 0
	GlobalBatch.TTL = nil
	GlobalBatch.LastFirstItemTime = 0

	local memItems = {}
	local dbItems = {}

	for _, item in pairs(queue) do
		if item.useDb then
			table.insert(dbItems, item)
		else
			table.insert(memItems, item)
		end
	end

	-- Run synchronously for BindToClose
	if #memItems > 0 then
		this:GlobalBatchSetAsync(memItems, ttl, false)
	end
	if #dbItems > 0 then
		this:GlobalBatchSetAsync(dbItems, ttl, true)
	end
end

--[=[
	Configures global settings for the TixMemory client.
	
	@param config table
		- DefaultExpiration: number? -- Default TTL for items
		- LocalCacheDefaultTTL: number? -- Default local cache duration
		- LocalCachePruneInterval: number? -- How often to clean local cache
]=]
function this.Configure(config: {
	DefaultExpiration: number?,
	LocalCacheDefaultTTL: number?,
	LocalCachePruneInterval: number?
})
	if config.DefaultExpiration then GlobalConfig.DefaultExpiration = config.DefaultExpiration end
	if config.LocalCacheDefaultTTL then GlobalConfig.LocalCacheDefaultTTL = config.LocalCacheDefaultTTL end
	if config.LocalCachePruneInterval then GlobalConfig.LocalCachePruneInterval = config.LocalCachePruneInterval end
end

--[=[
	Gets (or creates) an HttpHashMap instance for a specific collection ID.
	Instances are cached, so calling this with the same ID returns the same object.
	
	@param id string -- The collection/map ID
	@param useDb boolean? -- Whether to use persistent storage
	@return TixHashMap
]=]
function this:GetHashMap(id: string, useDb: boolean?)
	local cacheKey = `{id}_{useDb and "db" or "mem"}`
	if not cache.HashMap[cacheKey] then
		cache.HashMap[cacheKey] = HttpHashMap.new(id, useDb)
	end
	return cache.HashMap[cacheKey]
end

-- Automatic shutdown handling
game:BindToClose(function()
	-- Flush global buffered writes
	this:FlushGlobalBatchAsync()
	
	-- Also flush per-instance queues if any items remain
	for _, instance in pairs(cache.HashMap) do
		if instance._queueCount > 0 then
			local batch = instance._queue
			local ttl = instance._queueTTL
			instance:BatchSetAsync(batch, ttl)
		end
	end
end)

return this