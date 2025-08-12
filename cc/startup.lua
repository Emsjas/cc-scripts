-- cc/startup.lua
-- Starter startup. Later we'll let deployer update + launch your app.

local colors = colors or {} -- compatibility if colors table is missing in stubs

local function say(msg, col)
  if term and term.setTextColor and col then term.setTextColor(col) end
  print(msg)
  if term and term.setTextColor then term.setTextColor(colors.white) end
end

say("CC Scripts: startup loaded", colors.cyan)

-- Uncomment these lines AFTER you place deployer.lua on the machine
-- if fs.exists("deployer.lua") then
--   shell.run("deployer", "install")
--   -- Then launch your main app:
--   -- shell.run("/apps/smartmine.lua")
-- else
--   say("Tip: Put deployer.lua on this computer, then enable auto-update here.", colors.yellow)
-- end
