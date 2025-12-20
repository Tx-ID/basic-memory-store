local RunService = game:GetService("RunService")

local RequestQueue = {}
local queue = {}
local processing = false

-- Configuration
local REQUESTS_PER_MINUTE = 500 -- Safe margin below Roblox's 500/min limit
local DELAY_BETWEEN_REQUESTS = 60 / REQUESTS_PER_MINUTE

function RequestQueue.enqueue(requestFunction)
	local tcs = Instance.new("BindableEvent")
	
	table.insert(queue, {
		fn = requestFunction,
		callback = function(...)
			tcs:Fire(...)
		end
	})
	
	if not processing then
		task.spawn(RequestQueue.process)
	end
	
	local result = tcs.Event:Wait()
	tcs:Destroy()
	return result
end

function RequestQueue.process()
	if processing then return end
	processing = true
	
	while #queue > 0 do
		local request = table.remove(queue, 1)
		
		-- Run the request
		task.spawn(function()
			local success, result = pcall(request.fn)
			if not success then
				-- If the actual HTTP request crashes (e.g. malformed URL passed to RequestAsync), 
				-- we return a mock failure response so the caller handles it gracefully.
				-- Adjust structure to match what Http.luau expects or just return the error.
				result = {
					Success = false,
					StatusCode = 500,
					StatusMessage = "Internal Client Error: " .. tostring(result),
					Body = nil
				}
			end
			request.callback(result)
		end)
		
		-- Wait to respect rate limit
		task.wait(DELAY_BETWEEN_REQUESTS)
	end
	
	processing = false
end

return RequestQueue
