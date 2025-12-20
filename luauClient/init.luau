local HttpService = game:GetService("HttpService")

--
local ConfigService = require(script:WaitForChild("ConfigService"))

_ = ConfigService.getConfig() or ConfigService.ConfigAdded:Wait()
local Snapshot = ConfigService.getConfig()
local ConfigData: { key: string? } = Snapshot and Snapshot:GetValue("tixmemory") or {}

local BASE_URL = ""
local AUTHORIZATION_KEY = `Bearer {ConfigData.key or ""}`
local DEFAULT_EXPIRATION = 60 * 5

local Http = require(script:WaitForChild("Http"))
local TimeParser = require(script:WaitForChild("TimeParser"))

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
	return setmetatable({
		Id = id,
		UseDb = useDb == true,
	}, HttpHashMap)
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
	local ttl = TimeParser.parse(expiration) or DEFAULT_EXPIRATION
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
	})
	if not http_response.Success then
		error(`Failed to post HttpMemoryStore: {http_response.StatusCode}`)
	end
end

function HttpHashMap.GetAsync(self: TixHashMap, key: string)
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
	return http_response.Body
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
	defaultValue: any?
)
	sizePerPage = sizePerPage or 50
	sortDirection = sortDirection or "desc"

	return ListInterface.new({
		sizePerPage = sizePerPage,
		getResponseByCursor = function(size: number, cursor: any?)
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
	defaultValue: any?
)
	sortDirection = sortDirection or "desc"
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
	})
	if not http_response.Success then
		error(`Failed to remove HttpMemoryStore: {http_response.StatusCode}`)
	end
end

--
local this = {}
local cache = { HashMap = {} }

function this:GetHashMap(id: string, useDb: boolean?)
	local cacheKey = `{id}_{useDb and "db" or "mem"}`
	if not cache.HashMap[cacheKey] then
		cache.HashMap[cacheKey] = HttpHashMap.new(id, useDb)
	end
	return cache.HashMap[cacheKey]
end

return this
