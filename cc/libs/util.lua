-- cc/libs/util.lua
local util = {}
function util.log(msg)
  local stamp = textutils and textutils.formatTime and textutils.formatTime(os.time(), true) or os.clock()
  print(('[util %s] %s'):format(stamp, tostring(msg)))
end
return util
