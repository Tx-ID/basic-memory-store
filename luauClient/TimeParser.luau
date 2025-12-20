local TimeParser = {}

local SECOND = 1
local MINUTE = 60 * SECOND
local HOUR = 60 * MINUTE
local DAY = 24 * HOUR
local WEEK = 7 * DAY
local MONTH = 30 * DAY -- Approximation
local YEAR = 365 * DAY

local UNITS = {
	s = SECOND,
	m = MINUTE,
	h = HOUR,
	d = DAY,
	w = WEEK,
	M = MONTH, -- Capital M for Month to distinguish from minute (though m is usually minute)
	y = YEAR,
}

-- Handle both 'm' (minute) and 'M' (month) but allow case insensitive for others
function TimeParser.parse(input: string | number?): number?
	if type(input) == "number" then
		return input
	end
	if type(input) ~= "string" then
		return nil
	end

	local amountStr, unit = input:match("^(%d+)([smhdwMy])$")
	if not amountStr or not unit then
		-- Try case insensitive if no match (e.g., '3W')
		amountStr, unit = input:lower():match("^(%d+)([smhdwy])$")
		if not amountStr or not unit then
			return tonumber(input) -- Fallback to raw number string
		end
	end

	local amount = tonumber(amountStr)
	local multiplier = UNITS[unit] or UNITS[unit:lower()]
	
	if amount and multiplier then
		return amount * multiplier
	end

	return tonumber(input)
end

return TimeParser
