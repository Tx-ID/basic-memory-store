local ConfigService = game:GetService("ConfigService")
local ConfigSnapshot

--
local module = {}

module.ConfigAdded = script.Added.Event
module.ConfigUpdated = script.Updated.Event

function module.reloadConfig()
	local tries = 10
	for i = 1, tries do
		local success = pcall(function()
			if ConfigSnapshot then
				ConfigSnapshot:Refresh()
				script.Updated:Fire()
			else
				ConfigSnapshot = ConfigService:GetConfigAsync()
				script.Added:Fire()

				ConfigSnapshot.UpdateAvailable:Connect(module.reloadConfig)
			end
		end)
		if success then
			break
		end
		if i == tries then
			script.Added:Fire()
			break
		end
		task.wait(i * 4)
	end
end

function module.getConfig(): ConfigSnapshot?
	return ConfigSnapshot
end

if not module._init then
	task.spawn(module.reloadConfig)
end

return module
