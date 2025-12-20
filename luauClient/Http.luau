local HttpService = game:GetService("HttpService")
local RequestQueue = require(script.Parent:WaitForChild("RequestQueue"))
local DEBUG = false

--
local http = {}

type HttpConfig = {
	url: string?,
	method: ("GET" | "POST" | "PUT" | "DELETE" | "PATCH" | "HEAD" | "OPTIONS")?,
	headers: { [string]: any }?,
	data: ({ [string]: any } | string)?,
	params: { [string]: any }?,
	deduplicationKey: string?,
}

export type HttpResult = {
	Success: boolean,
	StatusCode: number,
	StatusMessage: string,
	Headers: { [string]: string },
	Body: any,
}

function http.formatParams(params: { [string]: any })
	local formatted = {}
	for key, value in pairs(params) do
		if type(value) ~= "table" and value ~= nil then
			table.insert(formatted, `{HttpService:UrlEncode(key)}={HttpService:UrlEncode(tostring(value))}`)
		end
	end
	return table.concat(formatted, "&")
end

function http.formatBody(body: { [string]: any })
	local formatted = {}
	for key, value in pairs(body) do
		table.insert(formatted, `{key}={HttpService:UrlEncode(tostring(value))}`)
	end
	return table.concat(formatted, "&")
end

function http.request(v: string | HttpConfig, request_config: HttpConfig?): HttpResult
	local config: HttpConfig = request_config or {
		url = "",
		method = "GET",
	}

	if type(v) == "table" then
		config.url = v["url"]
		for index, value in pairs(v) do
			config[index] = value
		end
	elseif type(v) == "string" then
		config.url = v
	end

	assert(config.url, `Missing url for request.`)
	if config.url then
		if string.sub(config.url, #config.url) == "/" then
			config.url = string.sub(config.url, 1, #config.url - 1)
		end
	end

	local params = config.params and `?{http.formatParams(config.params)}` or ""
	local get_header = (config.headers or {}) :: { [string]: string }

	-- Auto-detect content type / serialization
	local body = config.data
	if type(body) == "table" then
		local contentType = get_header["content-type"] or get_header["Content-Type"]
		
		if not contentType or contentType:lower():find("application/json") then
			-- Default to JSON
			if not contentType then
				get_header["Content-Type"] = "application/json"
			end
			body = HttpService:JSONEncode(body)
		elseif contentType:lower():find("application/x-www-form-urlencoded") then
			body = http.formatBody(body)
		end
	end

	local payload = {
		Url = `{config.url}{params}`,
		Method = config.method,
		Headers = get_header,
		Body = body,
		--Compress = Enum.HttpCompression.None
	}
	if DEBUG then
		print(payload)
	end

	local response = RequestQueue.enqueue(function()
		return HttpService:RequestAsync(payload)
	end, config.deduplicationKey)

	if response.Body then
		local is_json, json = pcall(function()
			return HttpService:JSONDecode(response.Body)
		end)
		if is_json then
			response.Body = json
		end
	end

	if DEBUG then
		print(response)
	end

	return response
end

return http
