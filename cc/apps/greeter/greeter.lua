-- Environmental + Power Monitor (Advanced Peripherals + CC:Tweaked)
-- Adds Utilization with either Fixed Cap (e.g., 2160 FE/t) or Auto-scale (5 min rolling max)
-- Keeps your existing Time/Environment/Players UI intact

--==== CONFIG =======================================================
local PD_SIDE   = "bottom"  -- player detector
local ENV_SIDE  = "left"    -- environment detector
local MON_SIDE  = "right"   -- monitor

-- Power config
local USE_FIXED_CAP = true         -- true = use FIXED_CAP_FE, false = auto-scale to 5 min rolling max
local FIXED_CAP_FE  = 2160         -- 3 windmills * 720 FE/t each
local SHOW_JOULES   = true         -- also show J/t (Mekanism) (1 FE = 2.5 J)

-- Stats windows (seconds, assuming 1s loop)
local AVG_WINDOW_S   = 60          -- average window
local PEAK_WINDOW_S  = 60          -- peak window
local AUTOSCALE_S    = 300         -- 5 minutes rolling max for auto-scale
--===================================================================

-- Wrap required peripherals
local pd  = peripheral.wrap(PD_SIDE)
local env = peripheral.wrap(ENV_SIDE)
local mon = peripheral.wrap(MON_SIDE)

-- Setup monitor
mon.setTextScale(0.75)
mon.setBackgroundColor(colors.black)
mon.setTextColor(colors.white)
mon.clear()
local width, height = mon.getSize()

-- Track state for smart updates
local firstRun = true
local lastPlayerData = {}

-- ===== Formatting / Helpers =====
local function formatTime(t)
    t = math.floor(t)
    local hours = math.floor((t / 1000 + 6) % 24)
    local minutes = math.floor((t % 1000) / 1000 * 60)
    return string.format("%02d:%02d", hours, minutes)
end

-- Sleep logic (Minecraft day/night)
local function canSleep(t)
    local time = t % 24000
    if time >= 23460 or time < 12542 then
        return false  -- Daytime, cannot sleep
    else
        return true   -- Nighttime, can sleep
    end
end

local function getTimeUntilNext(t)
    local currentTime = t % 24000
    if currentTime >= 23460 or currentTime < 12542 then
        local untilSleep
        if currentTime >= 23460 then
            untilSleep = 24000 - currentTime + 12542
        else
            untilSleep = 12542 - currentTime
        end
        local minutes = math.floor(untilSleep / 1000 * 60)
        return "Bedtime in " .. minutes .. "m", colors.orange
    else
        local untilDay
        if currentTime >= 12542 then
            untilDay = 24000 - currentTime + 23460
        else
            untilDay = 23460 - currentTime
        end
        local minutes = math.floor(untilDay / 1000 * 60)
        return "Morning in " .. minutes .. "m", colors.yellow
    end
end

local function getMoonPhase(day)
    local phases = {
        [0] = "Full Moon",
        [1] = "Waning Gibbous",
        [2] = "Last Quarter",
        [3] = "Waning Crescent",
        [4] = "New Moon",
        [5] = "Waxing Crescent",
        [6] = "First Quarter",
        [7] = "Waxing Gibbous"
    }
    return phases[day % 8]
end

local function formatBiome(biome)
    biome = biome:gsub("minecraft:", "")
    biome = biome:gsub("_", " ")
    biome = biome:gsub("(%a)([%w_']*)", function(first, rest)
        return first:upper() .. rest:lower()
    end)
    return biome
end

local function lightColor(level)
    if level > 12 then return colors.lime
    elseif level > 8 then return colors.yellow
    elseif level > 4 then return colors.orange
    else return colors.red end
end

-- Clear a specific line
local function clearLine(y)
    mon.setCursorPos(1, y)
    mon.setBackgroundColor(colors.black)
    mon.write(string.rep(" ", width))
end

-- Enhanced progress bar with frame
local function drawProgressBar(x, y, totalWidth, value, maxValue, label, barColor)
    clearLine(y)
    mon.setCursorPos(x, y)
    mon.setTextColor(colors.lightGray)
    mon.write(label)

    local barWidth = totalWidth - #label - 8
    if barWidth < 10 then barWidth = 10 end

    local ratio = 0
    if maxValue > 0 then ratio = math.min(1, math.max(0, value / maxValue)) end
    local filled = math.floor(ratio * barWidth)

    mon.setCursorPos(x + #label + 1, y)
    mon.setTextColor(colors.gray)
    mon.write("[")

    mon.setBackgroundColor(barColor or colors.green)
    mon.write(string.rep(" ", filled))

    mon.setBackgroundColor(colors.gray)
    mon.write(string.rep(" ", barWidth - filled))
    mon.setBackgroundColor(colors.black)

    mon.setTextColor(colors.gray)
    mon.write("]")

    local percent = math.floor(ratio * 100 + 0.5)
    mon.setTextColor(colors.white)
    mon.write(string.format(" %3d%%", percent))
end

local function drawHeader(title, color)
    mon.setCursorPos(1, 1)
    mon.setBackgroundColor(color or colors.gray)
    mon.setTextColor(colors.white)
    mon.write(string.rep(" ", width))
    mon.setCursorPos(math.floor((width - #title) / 2), 1)
    mon.write(title)
    mon.setBackgroundColor(colors.black)
end

local function drawDivider(y, char)
    mon.setCursorPos(1, y)
    mon.setTextColor(colors.gray)
    mon.write(string.rep(char or "-", width))
end

local function drawClock(x, y, time)
    local hour = math.floor((time / 1000 + 6) % 24)
    local clockChar = ""
    if hour >= 6 and hour < 12 then
        clockChar = "\24"  -- Morning
    elseif hour >= 12 and hour < 18 then
        clockChar = "\26"  -- Afternoon
    elseif hour >= 18 and hour < 24 then
        clockChar = "\25"  -- Evening
    else
        clockChar = "\27"  -- Night
    end
    mon.setCursorPos(x, y); mon.setTextColor(colors.white); mon.write(clockChar)
end

-- Draw static elements
local function drawStaticElements()
    drawHeader("=[ Environmental Monitor ]=", colors.blue)
    drawDivider(2, "=")
    drawDivider(7, "-")

    mon.setCursorPos(2, 8)
    mon.setTextColor(colors.yellow); mon.write("< Environment >")

    drawDivider(12, "-")
    mon.setCursorPos(2, 13)
    mon.setTextColor(colors.yellow); mon.write("< Players >")
end

-- Players change detection
local function hasPlayerDataChanged(newData)
    if #newData ~= #lastPlayerData then return true end
    for i, player in ipairs(newData) do
        local last = lastPlayerData[i]
        if not last or last.name ~= player.name or last.x ~= player.x or last.y ~= player.y or last.z ~= player.z then
            return true
        end
    end
    return false
end

-- ===== Power stats (buffers) =====
local samples = {}      -- newest at end
local function pushSample(v)
    table.insert(samples, v or 0)
    -- keep last AUTOSCALE_S seconds max
    while #samples > AUTOSCALE_S do table.remove(samples, 1) end
end

local function avgLast(n)
    local sum, count = 0, 0
    for i = math.max(1, #samples - n + 1), #samples do
        sum = sum + samples[i]; count = count + 1
    end
    if count == 0 then return 0 end
    return math.floor((sum / count) + 0.5)
end

local function peakLast(n)
    local maxv = 0
    for i = math.max(1, #samples - n + 1), #samples do
        if samples[i] > maxv then maxv = samples[i] end
    end
    return maxv
end

local function autoScaleMax()
    local m = 0
    for i = 1, #samples do
        if samples[i] > m then m = samples[i] end
    end
    return math.max(m, 1) -- avoid zero
end

-- Attempt to find an energy detector anywhere on the wired network
local function getEnergyDetector()
    -- try cached names first
    local ed = peripheral.find("energy_detector") or peripheral.find("energyDetector")
    -- AP uses "energy_detector" as type; some packs may expose "energyDetector" via wrappers
    return ed
end

-- ===== Main loop =====
while true do
    if firstRun then drawStaticElements(); firstRun = false end

    -- --- Time & sleep ---
    local t = env.getTime()
    local timeStr = formatTime(t)
    local biome = formatBiome(env.getBiome())
    local skyLight = env.getDayLightLevel()
    local timeUntil, untilColor = getTimeUntilNext(t)
    local day = math.floor(env.getTime() / 24000)
    local moonPhase = getMoonPhase(day)
    local sleepable = canSleep(t)

    clearLine(3)
    mon.setCursorPos(2, 3); drawClock(2, 3, t)
    mon.setCursorPos(4, 3); mon.setTextColor(colors.lightGray); mon.write("Time: ")
    mon.setTextColor(colors.white); mon.write(timeStr)
    if sleepable then
        mon.setTextColor(colors.blue); mon.write("  [\127 Night - Can Sleep]")
    else
        mon.setTextColor(colors.yellow); mon.write("  [\2 Day - Can't Sleep]")
    end

    clearLine(4); mon.setCursorPos(2, 4); mon.setTextColor(untilColor); mon.write(timeUntil)

    local timeProgress = t % 24000
    drawProgressBar(2, 5, width - 2, timeProgress, 24000, "Day Cycle", colors.cyan)

    clearLine(6)
    if sleepable then
        mon.setCursorPos(2, 6); mon.setTextColor(colors.lightGray); mon.write("Moon: ")
        mon.setTextColor(colors.lightBlue); mon.write(moonPhase)
    else
        mon.setCursorPos(2, 6); mon.setTextColor(colors.lightGray); mon.write("Day ")
        mon.setTextColor(colors.white); mon.write(tostring(day))
    end

    -- --- Environment ---
    clearLine(9)
    mon.setCursorPos(2, 9); mon.setTextColor(colors.lightGray); mon.write("Biome: ")
    mon.setTextColor(colors.green); mon.write(biome)

    clearLine(10)
    mon.setCursorPos(2, 10); mon.setTextColor(colors.lightGray); mon.write("Sky Light: ")
    mon.setTextColor(lightColor(skyLight)); mon.write(tostring(skyLight) .. "/15")
    if sleepable and skyLight <= 7 then
        mon.setTextColor(colors.orange); mon.write("  [Dark outside]")
    elseif not sleepable then
        if skyLight >= 13 then mon.setTextColor(colors.lime); mon.write("  [Bright daylight]")
        else mon.setTextColor(colors.yellow); mon.write("  [Overcast/shaded]") end
    end

    clearLine(11)
    if skyLight <= 7 and not sleepable then
        mon.setCursorPos(2, 11); mon.setTextColor(colors.gray); mon.write("(Can't detect torches)")
    end

    -- --- Power section ---
    drawDivider(12, "-")
    -- Section title
    clearLine(13); mon.setCursorPos(2, 13); mon.setTextColor(colors.yellow); mon.write("< Power >")

    local ed = getEnergyDetector()
    local feNow = 0
    if ed and ed.getTransferRate then
        -- pcall in case of network hiccup
        local ok, val = pcall(ed.getTransferRate)
        if ok and type(val) == "number" then feNow = math.floor(val + 0.5) end
    end
    pushSample(feNow)

    -- Decide cap for utilization
    local capFE = USE_FIXED_CAP and FIXED_CAP_FE or autoScaleMax()

    -- Line 14: Flow + Cap
    clearLine(14)
    mon.setCursorPos(2, 14)
    mon.setTextColor(colors.lightGray); mon.write("Flow: ")
    mon.setTextColor(colors.white); mon.write(tostring(feNow) .. " FE/t")
    if SHOW_JOULES then
        mon.setTextColor(colors.gray); mon.write("  (")
        mon.setTextColor(colors.white); mon.write(tostring(math.floor(feNow * 2.5 + 0.5)) .. " J/t")
        mon.setTextColor(colors.gray); mon.write(")")
    end
    mon.setTextColor(colors.lightGray); mon.write("   Cap: ")
    mon.setTextColor(colors.yellow); mon.write(tostring(capFE))

    -- Line 15: Utilization bar (value vs cap)
    local utilColor = colors.lime
    local utilPct = (capFE > 0) and (feNow / capFE) or 0
    if utilPct > 0.85 then utilColor = colors.red
    elseif utilPct > 0.65 then utilColor = colors.orange
    elseif utilPct > 0.35 then utilColor = colors.yellow
    else utilColor = colors.lime end
    drawProgressBar(2, 15, width - 2, feNow, capFE, "Utilization ", utilColor)

    -- Line 16: Avg/Peak (60s)
    local avg60 = avgLast(AVG_WINDOW_S)
    local peak60 = peakLast(PEAK_WINDOW_S)
    clearLine(16); mon.setCursorPos(2, 16)
    mon.setTextColor(colors.lightGray); mon.write("Avg(" .. AVG_WINDOW_S .. "s): ")
    mon.setTextColor(colors.white); mon.write(tostring(avg60))
    mon.setTextColor(colors.lightGray); mon.write("   Peak(" .. PEAK_WINDOW_S .. "s): ")
    mon.setTextColor(colors.white); mon.write(tostring(peak60))

    -- --- Players (update only if changed) ---
    local players = pd.getPlayersInRange(64) or {}
    local currentPlayerData = {}
    for _, name in ipairs(players) do
        local pos = pd.getPlayerPos(name)
        if pos then
            table.insert(currentPlayerData, { name = name, x = math.floor(pos.x), y = math.floor(pos.y), z = math.floor(pos.z) })
        else
            table.insert(currentPlayerData, { name = name, x = 0, y = 0, z = 0 })
        end
    end

    if hasPlayerDataChanged(currentPlayerData) then
        for i = 17, height - 1 do clearLine(i) end
        if #currentPlayerData > 0 then
            local yPos = 17
            for _, player in ipairs(currentPlayerData) do
                if yPos > height - 2 then break end
                mon.setCursorPos(2, yPos)
                mon.setTextColor(colors.cyan); mon.write("\7 ")
                mon.setTextColor(colors.white); mon.write(player.name)
                if player.x ~= 0 or player.y ~= 0 or player.z ~= 0 then
                    mon.setTextColor(colors.gray)
                    mon.write(string.format(" @ %d, %d, %d", player.x, player.y, player.z))
                else
                    mon.setTextColor(colors.red); mon.write(" [position unknown]")
                end
                yPos = yPos + 1
            end
            mon.setCursorPos(width - 10, 16)
            mon.setTextColor(colors.lightGray)
            mon.write("[" .. #currentPlayerData .. " online]")
        else
            mon.setCursorPos(2, 17)
            mon.setTextColor(colors.gray); mon.write("No players in range")
        end
        lastPlayerData = currentPlayerData
    end

    -- Footer
    mon.setCursorPos(1, height)
    mon.setBackgroundColor(colors.gray); mon.setTextColor(colors.black)
    mon.write(string.rep(" ", width))
    mon.setCursorPos(2, height); mon.write("Updated: " .. os.date("%H:%M:%S"))
    mon.setBackgroundColor(colors.black)

    sleep(1)
end

Here is the smartmine.lua

-- smartmine — Combined Turtle server + miner
-- Exposes rednet API (ping/scan/start) AND runs the ore miner.
-- Fixes:
--  • Robust ore-family parsing (deepslate, poor/rich, color, etc.)
--  • Dock message matches UI: cmd="dock", includes counts + left + ore
--  • Target is a base "family" key; miner includes all variants of that family
--  • Chest calibration has radius fallback
--  • Server remains responsive while mining
--  • Arg handling moved to top-level (no vararg in functions)
--  • Minor call/loop fixes

-------------------- Top-level args (valid place for ...) --------------------
local PROGRAM_ARGS = {...}

-------------------- Config --------------------
local PROTOCOL          = "smartmine"
local RADIUS            = 8           -- geo.scan radius per slice
local DESCENT_STEP      = 12          -- step down per empty slice
local VEIN_MAX          = 256         -- safety limit per vein
local INCLUDE_DEEPSLATE = true

-- Fuel/inventory thresholds
local START_MIN         = 700
local REFUEL_TARGET     = 700
local LOW_TRIP          = 500
local SLOTS_SOFT_FULL   = 13
local REFUEL_CHUNK      = 5
local SUCK_CHUNK        = 5

-------------------- Logging --------------------
local fsExists, makeDir = fs.exists, fs.makeDir
if not fsExists("/logs") then makeDir("/logs") end
local function epoch() local ok,ms=pcall(os.epoch,"utc"); if ok then return ms end local ok2,t=pcall(os.time); return ok2 and (t*1000) or 0 end
local SESSION_LOG = ("/logs/ironminer-%d.log"):format(epoch())
local LAST_LOG    = "/logs/last.log"
local function append(p,ln) local f=fs.open(p,"a"); if f then f.writeLine(ln) f.close() end end
local function log(m) print(m); append(SESSION_LOG,m); local s=fs.open(SESSION_LOG,"r"); local d=fs.open(LAST_LOG,"w"); if s and d then d.write(s.readAll() or "") s.close() d.close() end end
local function logf(fmt,...) log(string.format(fmt,...)) end

-------------------- Peripherals --------------------
local function findGeo()
  local p = peripheral.find("geo_scanner") or peripheral.find("geoScanner")
  if p then return p end
  for _,s in ipairs({"left","right","top","bottom","front","back"}) do
    if peripheral.isPresent(s) then local w=peripheral.wrap(s); if w and type(w.scan)=="function" then return w end end
  end
  for _,n in ipairs(peripheral.getNames()) do local w=peripheral.wrap(n); if w and type(w.scan)=="function" then return w end end
end
local geo = findGeo(); if not geo then error("No geo scanner found.",0) end

-------------------- Utils --------------------
local function lower(s) return string.lower(s or "") end
local function pretty(n) n=(n or ""):gsub("^.-:",""):gsub("_"," "); return (n:gsub("^%l",string.upper):gsub(" %l",string.upper)) end
local function isFuel(d) if not d then return false end local n=d.name or ""; return n=="minecraft:coal" or n=="minecraft:charcoal" or n=="minecraft:lava_bucket" end
local function isChestName(n) n=tostring(n or ""); return (n:find("chest") or n:find("barrel")) end
local function usedSlots() local c=0 for i=1,16 do if turtle.getItemCount(i)>0 then c=c+1 end end return c end
local function manh(a,b) return math.abs(a.f-b.f)+math.abs(a.r-b.r)+math.abs(a.u-b.u) end

-- Base family extractor: strip namespace; allow deepslate + poor/rich prefixes; drop "_ore.*" suffix
local function oreFamilyBase(id)
  if not id then return nil end
  local s = tostring(id):gsub("^.+:","")            -- drop namespace
  s = s:gsub("^deepslate_","")                      -- deepslate variant
  s = s:gsub("^poor_",""):gsub("^rich_","")         -- leading qualifiers
  s = s:gsub("_ore.*$","")                          -- remove "_ore" and any suffix after (e.g., _poor/_rich/_red)
  -- handle some known raw/gem/ingot items (in case inventory parsing needs it)
  local RAW = { raw_iron="iron", raw_copper="copper", raw_gold="gold" }
  local G  = { diamond="diamond", emerald="emerald", redstone="redstone", lapis_lazuli="lapis", coal="coal" }
  return RAW[s] or G[s] or s
end

-- Aliases accepted from console/manual args (keep minimal)
local ALIASES = {
  iron="iron", fe="iron", gold="gold", au="gold",
  copper="copper", cu="copper", coal="coal",
  diamond="diamond", dia="diamond", diamonds="diamond",
  emerald="emerald", redstone="redstone", red="redstone",
  lapis="lapis", lazuli="lapis",
  uraninite="uraninite", uranium="uraninite",
  xy="xychorium", xychorium="xychorium",
}
local function normalizeChoice(s) s=lower((s or ""):gsub("%s+","")); return ALIASES[s] or s end

-------------------- Fuel --------------------
local function refuelFromInv(target)
  if turtle.getFuelLevel()=="unlimited" then return true end
  target = target or REFUEL_TARGET
  for s=1,16 do
    if turtle.getFuelLevel() >= target then break end
    local d=turtle.getItemDetail(s)
    if isFuel(d) then
      turtle.select(s)
      while turtle.getFuelLevel()<target and turtle.getItemCount(s)>0 do
        turtle.refuel(math.min(REFUEL_CHUNK, turtle.getItemCount(s)))
      end
    end
  end
  turtle.select(1); return turtle.getFuelLevel()>=target
end
local function dropNonFuel(s) local d=turtle.getItemDetail(s); if d and not isFuel(d) and turtle.getItemCount(s)>0 then turtle.select(s); turtle.drop() end end
local function refuelFromChest(target)
  target = target or REFUEL_TARGET
  if refuelFromInv(target) then return true end
  local dryPulls=0
  for _=1,64 do
    if turtle.getFuelLevel()>=target then break end
    local before=0; for i=1,16 do before=before+turtle.getItemCount(i) end
    turtle.suck(SUCK_CHUNK)
    local after=0; for i=1,16 do after=after+turtle.getItemCount(i) end
    if after==before then dryPulls=dryPulls+1 else dryPulls=0 end
    for s=1,16 do
      if turtle.getFuelLevel()>=target then break end
      local d=turtle.getItemDetail(s)
      if isFuel(d) and turtle.getItemCount(s)>0 then
        turtle.select(s)
        while turtle.getFuelLevel()<target and turtle.getItemCount(s)>0 do
          turtle.refuel(math.min(REFUEL_CHUNK, turtle.getItemCount(s)))
        end
      end
    end
    for s=1,16 do dropNonFuel(s) end
    if dryPulls>=3 then break end
  end
  turtle.select(1); return turtle.getFuelLevel()>=target
end

-------------------- Pose / Movement --------------------
-- HOME: (f=0,r=0,u=0). heading: 0=+F (toward chest), 1=+R, 2=−F, 3=−R
local loc={f=0,r=0,u=0}; local heading=0
local function turnL() turtle.turnLeft();  heading=(heading+3)%4 end
local function turnR() turtle.turnRight(); heading=(heading+1)%4 end
local function face(h) while heading~=h do local d=(h-heading)%4 if d==1 then turnR() elseif d==2 then turnR();turnR() else turnL() end end end
local function faceChest() for i=1,4 do local ok,d=turtle.inspect(); if ok and d and isChestName(d.name) then return true end turnL() end return false end
local function chestAhead() local ok,inf=turtle.inspect(); return ok and inf and isChestName(inf.name) end

local blocked={}
local function bkey(f,u,r) return f..","..u..","..r end
local function markFrontBlocked()
  local df=(heading==0 and 1) or (heading==2 and -1) or 0
  local dr=(heading==1 and 1) or (heading==3 and -1) or 0
  blocked[bkey(loc.f+df,loc.u,loc.r+dr)]=true
end

local refueling=false
local function needReturn() return turtle.getFuelLevel()~="unlimited" and (turtle.getFuelLevel()<LOW_TRIP or usedSlots()>=SLOTS_SOFT_FULL) end

local function forward()
  if chestAhead() then return false,"chest_guard" end
  while not turtle.forward() do
    turtle.attack()
    if chestAhead() then return false,"chest_guard" end
    if not turtle.dig() then markFrontBlocked(); return false,"blocked" end
  end
  if heading==0 then loc.f=loc.f+1 elseif heading==1 then loc.r=loc.r+1 elseif heading==2 then loc.f=loc.f-1 else loc.r=loc.r-1 end
  return true
end
local function up()
  if loc.u+1>0 then return false,"above_chest_plane" end
  while not turtle.up() do if not turtle.digUp() then blocked[bkey(loc.f,loc.u+1,loc.r)]=true; return false,"blocked" end end
  loc.u=loc.u+1; return true
end
local function down()
  while not turtle.down() do if not turtle.digDown() then blocked[bkey(loc.f,loc.u-1,loc.r)]=true; return false,"blocked" end end
  loc.u=loc.u-1; return true
end

-- A*
local function key(n) return n.f..","..n.u..","..n.r end
local function neighbors(n)
  local out={{f=n.f+1,u=n.u,r=n.r},{f=n.f-1,u=n.u,r=n.r},{f=n.f,u=n.u+1,r=n.r},{f=n.f,u=n.u-1,r=n.r},{f=n.f,u=n.u,r=n.r+1},{f=n.f,u=n.u,r=n.r-1}}
  local i=1; while i<=#out do local nb=out[i]; if nb.u>0 or blocked[bkey(nb.f,nb.u,nb.r)] then table.remove(out,i) else i=i+1 end end
  return out
end
local function astar(start,goal)
  local open,inOpen,came,g,f={}, {}, {}, {}, {}
  local function push(n) local k=key(n); if not inOpen[k] then table.insert(open,n); inOpen[k]=true end end
  local function pop() local bi,bf=nil,1e18; for i,n in ipairs(open) do local fn=f[key(n)] or 1e18; if fn<bf then bf=fn; bi=i end end; local n=table.remove(open,bi); inOpen[key(n)]=nil; return n end
  push(start); g[key(start)]=0; f[key(start)]=manh(start,goal)
  while #open>0 do
    local cur=pop()
    if cur.f==goal.f and cur.u==goal.u and cur.r==goal.r then
      local path={cur}; while came[key(cur)] do cur=came[key(cur)]; table.insert(path,1,cur) end; return path
    end
    for _,nb in ipairs(neighbors(cur)) do
      local t=(g[key(cur)] or 1e18)+1; local k=key(nb)
      if t < (g[k] or 1e18) then came[k]=cur; g[k]=t; f[k]=t+manh(nb,goal); push(nb) end
    end
  end
  return nil
end
local function follow(path)
  for i=2,#path do
    if needReturn() and not refueling then return false,"need_return" end
    local a,b = path[i-1], path[i]
    local df,du,dr = b.f-a.f, b.u-a.u, b.r-a.r
    local ok=true
    if     df== 1 then face(0); ok=forward()
    elseif df==-1 then face(2); ok=forward()
    elseif dr== 1 then face(1); ok=forward()
    elseif dr==-1 then face(3); ok=forward()
    elseif du== 1 then ok=up()
    elseif du==-1 then ok=down()
    end
    if not ok then return false,"blocked" end
  end
  return true
end
local function goTo(goal)
  blocked={}
  local path = astar({f=loc.f,u=loc.u,r=loc.r}, goal)
  if not path then return false,"no_path" end
  return follow(path)
end
local function greedyTo(goal)
  while loc.u > goal.u do if not down() then return false,"blocked" end end
  while loc.u < goal.u do if not up()   then return false,"blocked" end end
  while loc.f < goal.f do face(0); if not forward() then return false,"blocked" end end
  while loc.f > goal.f do face(2); if not forward() then return false,"blocked" end end
  while loc.r < goal.r do face(1); if not forward() then return false,"blocked" end end
  while loc.r > goal.r do face(3); if not forward() then return false,"blocked" end end
  return true
end

-------------------- Wired modem --------------------
local function openWiredModem()
  for _,side in ipairs({"left","right","top","bottom","front","back"}) do
    if peripheral.getType(side)=="modem" then
      local m = peripheral.wrap(side)
      if m and not m.isWireless() then if not rednet.isOpen(side) then rednet.open(side) end; return true end
    end
  end
  for _,name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name)=="modem" then local m=peripheral.wrap(name); if m and not m.isWireless() then if not rednet.isOpen(name) then rednet.open(name) end; return true end end
  end
  return false
end

-------------------- Targets / scanning --------------------
local projectToLocal -- set in calibrateBasis
local currentTargetFamily = nil
local TARGET_SET = nil
local SCANS_TOTAL, SCANS_TRIP = 0, 0
local VEINS_TOTAL, VEINS_TRIP = 0, 0

local function isTargetName(name) if not name or not TARGET_SET then return false end return TARGET_SET[name]==true end
local function safeScan(r)
  for i=1,5 do local ok,res=pcall(geo.scan,r); if ok and type(res)=="table" then SCANS_TOTAL=SCANS_TOTAL+1; SCANS_TRIP=SCANS_TRIP+1; return res end sleep(0.6) end
  error("geo.scan failed",0)
end
local function chunkAnalyzeTable()
  local ok,t=pcall(geo.chunkAnalyze)
  if ok and type(t)=="table" then return t end
  return {}
end

local function buildFamilyCountsBase(tbl)
  local fam={}
  for id,c in pairs(tbl) do
    local f=oreFamilyBase(id)
    if f and id:find("_ore") then
      fam[f]=(fam[f] or 0)+(tonumber(c) or 0)
    end
  end
  return fam
end

local function buildTargetSetFromChunk(tbl, familyWanted)
  local set={}
  for id,_ in pairs(tbl) do
    if id:find("_ore") and oreFamilyBase(id)==familyWanted then set[id]=true end
  end
  -- vanilla fallback (present in many packs)
  set["minecraft:"..familyWanted.."_ore"]=true
  if INCLUDE_DEEPSLATE then set["minecraft:deepslate_"..familyWanted.."_ore"]=true end
  return set
end

local function chunkTargetCount()
  local sum=0
  local tbl=chunkAnalyzeTable()
  for id,c in pairs(tbl) do
    if isTargetName(id) then sum = sum + (tonumber(c) or 0) end
  end
  return sum
end

local function nearestTargetThisScan()
  local t=safeScan(RADIUS); local best,bd
  for _,b in ipairs(t) do
    if b.name and isTargetName(b.name) and b.x and b.y and b.z then
      local rel = projectToLocal({x=b.x,y=b.y,z=b.z})
      local abs = {f=rel.f, r=rel.r, u=rel.u + loc.u, name=b.name}
      if abs.u<=0 then
        local d=math.abs(abs.f)+math.abs(abs.r)+math.abs(abs.u)
        if not bd or d<bd then bd=d; best=abs end
      end
    end
  end
  return best
end

-------------------- Vein mining --------------------
local function isFrontTarget() local ok,i=turtle.inspect();     return ok and i and isTargetName(i.name) end
local function isUpTarget()   local ok,i=turtle.inspectUp();   return ok and i and isTargetName(i.name) end
local function isDownTarget() local ok,i=turtle.inspectDown(); return ok and i and isTargetName(i.name) end
local function bedrockBelow() local ok,i=turtle.inspectDown(); return ok and i and tostring(i.name):find("bedrock",1,true)~=nil end

local visited={} local function vkey(f,u,r) return f..","..u..","..r end
local function seen(f,u,r) return visited[vkey(f,u,r)] end
local function markHere() visited[vkey(loc.f,loc.u,loc.r)]=true end
local mined=0
local function stepInto(dir)
  if dir==4 then if loc.u+1>0 then return false end if isUpTarget() then turtle.digUp() end;   return up()
  elseif dir==5 then if isDownTarget() then turtle.digDown() end; return down()
  else face(dir); if isFrontTarget() then turtle.dig() end;       return forward() end
end
local function stepOut(dir) if dir==4 then return down() elseif dir==5 then return up() else face((dir+2)%4); return forward() end end
local function flood(maxNodes)
  markHere()
  local dirs={0,1,2,3,4,5}
  for _,d in ipairs(dirs) do
    if mined>=maxNodes then return end
    local nf,nu,nr=loc.f,loc.u,loc.r
    if d==0 then nf=nf+1 elseif d==2 then nf=nf-1 elseif d==1 then nr=nr+1 elseif d==3 then nr=nr-1 elseif d==4 then nu=nu+1 else nu=nu-1 end
    if nu<=0 and not seen(nf,nu,nr) then
      if (d==4 and isUpTarget()) or (d==5 and isDownTarget()) or (d<=3 and (face(d) or true) and isFrontTarget()) then
        if needReturn() then return end
        if stepInto(d) then mined=mined+1; flood(maxNodes); stepOut(d); face(0) end
      end
    end
  end
end

-------------------- Anchoring --------------------
local anchor=nil
local function setAnchorHere() anchor={f=loc.f,r=loc.r,u=loc.u}; face(0); logf("Anchor set @ (f=%d,u=%d,r=%d)",anchor.f,anchor.u,anchor.r) end
local function atAnchor() return anchor and loc.f==anchor.f and loc.r==anchor.r and loc.u==anchor.u end
local function returnToAnchor()
  if not anchor then return true end
  if atAnchor() then face(0); return true end
  logf("Returning to anchor (now f=%d,u=%d,r=%d → f=%d,u=%d,r=%d)",loc.f,loc.u,loc.r,anchor.f,anchor.u,anchor.r)
  local ok=goTo({f=anchor.f,u=anchor.u,r=anchor.r})
  if not ok then log("A* return failed; greedy fallback..."); ok=greedyTo({f=anchor.f,u=anchor.u,r=anchor.r}) end
  face(0); local d=manh(loc,anchor); if d==0 then log("Anchor return verified.") return true else logf("WARNING: anchor mismatch Δ=%d",d) return false end
end

-------------------- Calibration + Chest --------------------
local CHEST_NAME=nil
local function getFrontChestName() for i=1,4 do local ok,d=turtle.inspect(); if ok and d and isChestName(d.name) then return d.name end turnL() end end

local function chestOffsetStrict(chestName, rad)
  local t = geo.scan(rad or 8) or {}; local best,score=nil,1e9
  for _,b in ipairs(t) do
    if b.name==chestName then
      local s = math.abs((b.y or 0)-1)*100 + math.abs(b.x or 0) + math.abs(b.z or 0)
      if s<score then score=s; best=b end
    end
  end
  return best and {x=best.x,y=best.y,z=best.z} or nil
end

local function calibrateBasis()
  local frontChest=getFrontChestName(); if not frontChest then error("No chest/barrel adjacent.",0) end
  CHEST_NAME = frontChest
  if loc.u==0 then assert(down(),"Couldn't drop to u=-1") end

  local function findC()
    return chestOffsetStrict(frontChest,8) or chestOffsetStrict(frontChest,16) or chestOffsetStrict(frontChest,24) or {x=0,y=1,z=1}
  end

  local C0=findC()

  face(0); assert(forward(),"Calib +F failed"); local C1=findC(); face(2); forward()
  local F={x=C0.x-C1.x,y=C0.y-C1.y,z=C0.z-C1.z}

  face(1); assert(forward(),"Calib +R failed"); local C2=findC(); face(3); forward()
  local R={x=C0.x-C2.x,y=C0.y-C2.y,z=C0.z-C2.z}

  assert(down(),"Calib down failed"); local C3=findC(); assert(up(),"Calib up failed")
  local U={x=C3.x-C0.x,y=C3.y-C0.y,z=C3.z-C0.z}

  local function comp(B,g) if B.x~=0 then return (B.x>0) and g.x or -g.x elseif B.y~=0 then return (B.y>0) and g.y or -g.y elseif B.z~=0 then return (B.z>0) and g.z or -g.z else return 0 end end
  local function project(g) return {f=comp(F,g), r=comp(R,g), u=comp(U,g)} end

  logf("Basis F=(%d,%d,%d) R=(%d,%d,%d) U=(%d,%d,%d)", F.x,F.y,F.z, R.x,R.y,R.z, U.x,U.y,U.z)
  return project
end

-------------------- Dump / Refuel (dock message) --------------------
local function inventoryFamilyCounts()
  local counts={}
  for s=1,16 do
    local d=turtle.getItemDetail(s)
    if d and d.name and turtle.getItemCount(s)>0 then
      local fam=oreFamilyBase(d.name)
      if fam then counts[fam]=(counts[fam] or 0)+(turtle.getItemCount(s) or 0) end
    end
  end
  return counts
end

local function openWiredAndBroadcast(msg)
  if openWiredModem() then rednet.broadcast(msg, PROTOCOL) end
end

local function dumpToChest()
  while loc.u < 0 do if not up() then break end end
  faceChest()
  local beforeFuel = (turtle.getFuelLevel() == "unlimited") and 0 or (turtle.getFuelLevel() or 0)
  -- DROP
  for s=1,16 do if turtle.getItemCount(s)>0 then local d=turtle.getItemDetail(s); if not isFuel(d) then turtle.select(s); turtle.drop() end end end
  -- REFUEL
  turtle.select(1); refuelFromChest(REFUEL_TARGET)
  -- STATUS payload for UI
  local counts = buildFamilyCountsBase(chunkAnalyzeTable())
  local left = currentTargetFamily and chunkTargetCount() or 0
  openWiredAndBroadcast({
    cmd="dock",
    ore=currentTargetFamily,
    counts=counts,
    left=left,
    tripDeliveries=inventoryFamilyCounts(),
    fuelBefore=beforeFuel,
    fuelAfterDump=turtle.getFuelLevel(),
    veinsThisTrip=VEINS_TRIP, veinsTotal=VEINS_TOTAL,
    scansTrip=SCANS_TRIP, scansTotal=SCANS_TOTAL,
    depth=-loc.u, anchor=anchor and {f=anchor.f,u=anchor.u,r=anchor.r} or nil,
  })
  SCANS_TRIP, VEINS_TRIP = 0, 0
end

-------------------- Travel helper with replanning --------------
local function ensureTripFuel()
  if not (turtle.getFuelLevel()~="unlimited" and (turtle.getFuelLevel()<LOW_TRIP or usedSlots()>=SLOTS_SOFT_FULL)) or refueling then return end
  refueling=true
  local resume={f=loc.f,u=loc.u,r=loc.r,h=heading}
  logf("Fuel/inv threshold: return HOME (fuel=%d, slots=%d).", turtle.getFuelLevel(), usedSlots())

  local home={f=0,u=-1,r=0}
  local ok=goTo(home); if not ok then ok=greedyTo(home) end
  if not ok then
    -- emergency homing by scan
    log("Path failed; scan-guided homing…")
    -- settle to u=-1 plane
    while loc.u < -1 do if not up() then break end end
    while loc.u > -1 do if not down() then break end end
    for step=1,200 do
      local C = (CHEST_NAME and chestOffsetStrict(CHEST_NAME,16)) or nil
      if C then
        local rel = projectToLocal({x=C.x,y=C.y,z=C.z})
        if math.abs(rel.f)<=0 and math.abs(rel.r)<=0 then break end
        if math.abs(rel.f) >= math.abs(rel.r) then
          face(rel.f>0 and 0 or 2); forward()
        else
          face(rel.r>0 and 1 or 3); forward()
        end
      else
        face((step%4==1) and 1 or (step%4==2) and 2 or (step%4==3) and 3 or 0)
        forward()
      end
    end
  end
  dumpToChest()
  if loc.u==0 then down() end
  local ok2=goTo({f=resume.f,u=resume.u,r=resume.r}); if not ok2 then greedyTo({f=resume.f,u=resume.u,r=resume.r}) end
  face(resume.h or 0)
  log("Resume complete.")
  refueling=false
end

-------------------- Miner main --------------------
local function runMiner(targetFamilyKey)
  -- prepare
  term.clear(); term.setCursorPos(1,1)
  faceChest()
  if not refuelFromChest(START_MIN) then log("Need fuel (coal/charcoal/lava). Aborting."); return end

  local tfam = normalizeChoice(targetFamilyKey)
  if not tfam or tfam=="" then log("No target provided. Aborting."); return end
  currentTargetFamily = tfam

  -- Build target set from current chunk table
  TARGET_SET = buildTargetSetFromChunk(chunkAnalyzeTable(), currentTargetFamily)
  logf("Target selected: %s (all variants incl. deepslate)", currentTargetFamily)

  local left = chunkTargetCount()
  logf("Chunk reports %d %s ore(s).", left, currentTargetFamily)
  if left==0 then log("Nothing to mine for that target here. Done."); return end

  -- Calibrate & anchor
  local project = calibrateBasis(); projectToLocal = project
  setAnchorHere()

  while true do
    ensureTripFuel()

    left = chunkTargetCount()
    logf("Anchor @ (f=%d,u=%d,r=%d) — %s left in chunk: %d", anchor.f,anchor.u,anchor.r, currentTargetFamily, left)
    if left==0 then log("Chunk shows no more target ore. Finishing up."); break end

    local target = nearestTargetThisScan()
    if target then
      logf("FOUND %s at (f=%d,u=%d,r=%d)", pretty(target.name or "?"), target.f,target.u,target.r)
      local ok=goTo({f=target.f,u=target.u,r=target.r}); if not ok then ok=greedyTo({f=target.f,u=target.u,r=target.r}) end
      if not ok then log("Path to vein failed; stopping."); break end
      visited={}; mined=1; flood(VEIN_MAX); VEINS_TOTAL=VEINS_TOTAL+1; VEINS_TRIP=VEINS_TRIP+1
      logf("  mined %d blocks; returning to anchor...", mined)
      local ok2=returnToAnchor(); if not ok2 then log("Could not verify anchor return; stopping for safety."); break end
    else
      if bedrockBelow() then log("Bedrock below; bottom reached."); break end
      logf("No %s here; stepping down %d...", currentTargetFamily, DESCENT_STEP)
      local moved=false
      for i=1,DESCENT_STEP do
        if bedrockBelow() then log("Bedrock below; bottom reached."); moved=true; break end
        if not down() then break end
        moved=true
        ensureTripFuel()
      end
      if moved then setAnchorHere() else if bedrockBelow() then break end end
    end
  end

  -- HOME & dump
  local home={f=0,u=-1,r=0}
  logf("Returning HOME from (f=%d,u=%d,r=%d)...", loc.f,loc.u,loc.r)
  local ok=goTo(home); if not ok then ok=greedyTo(home) end
  if not ok then
    log("Final return path failed; using scan-guided homing.")
    while loc.u < -1 do if not up() then break end end
    while loc.u > -1 do if not down() then break end end
    for step=1,240 do
      local C = CHEST_NAME and chestOffsetStrict(CHEST_NAME,16) or nil
      if C then
        local rel = projectToLocal({x=C.x,y=C.y,z=C.z})
        if math.abs(rel.f)<=0 and math.abs(rel.r)<=0 then break end
        if math.abs(rel.f) >= math.abs(rel.r) then
          face(rel.f>0 and 0 or 2); forward()
        else
          face(rel.r>0 and 1 or 3); forward()
        end
      else
        face((step%4==1) and 1 or (step%4==2) and 2 or (step%4==3) and 3 or 0)
        forward()
      end
    end
  end
  while loc.u < 0 do up() end
  while loc.u > 0 do down() end
  faceChest()
  dumpToChest()
  logf("Done. Logs: %s (latest: %s)", SESSION_LOG, LAST_LOG)
end

-------------------- Server (rednet API) --------------------
local busy = false
local pendingStart = nil

local function familyCountsFromChunkAnalyze()
  return buildFamilyCountsBase(chunkAnalyzeTable())
end

local function serverLoop()
  openWiredModem()
  while true do
    -- rednet.receive(PROTOCOL) already filters by protocol
    local sender, msg, proto = rednet.receive(PROTOCOL)
    if type(msg)=="table" then
      if msg.cmd=="ping" then
        rednet.send(sender, {cmd="pong", id=os.getComputerID()}, PROTOCOL)

      elseif msg.cmd=="scan" then
        rednet.send(sender, {cmd="scan_result", counts=familyCountsFromChunkAnalyze()}, PROTOCOL)

      elseif msg.cmd=="start" then
        local target = normalizeChoice(msg.ore or "")
        if target=="" then
          rednet.send(sender, {cmd="error", error="empty_target"}, PROTOCOL)
        elseif busy then
          rednet.send(sender, {cmd="error", error="busy"}, PROTOCOL)
        else
          pendingStart = target
          rednet.send(sender, {cmd="ack_start", ore=target}, PROTOCOL)
        end
      end
    end
  end
end

-------------------- Orchestrator --------------------
local function controllerLoop()
  -- manual run via args (called at top level)
  if #PROGRAM_ARGS>=2 and PROGRAM_ARGS[1]=="mine" then
    local target = normalizeChoice(PROGRAM_ARGS[2])
    if not target or target=="" then
      log("Usage: smartmine mine <family>")
    else
      busy=true; runMiner(target); busy=false
    end
  end

  -- legacy /data/target.txt at boot
  if not busy and fsExists("/data/target.txt") then
    local f=fs.open("/data/target.txt","r"); local t=(f.readAll() or ""):gsub("%s+",""):lower(); f.close(); pcall(fs.delete,"/data/target.txt")
    if t~="" then pendingStart = normalizeChoice(t) end
  end

  -- idle-control loop
  while true do
    if pendingStart and not busy then
      busy=true
      local t = pendingStart; pendingStart=nil
      pcall(function() runMiner(t) end)
      busy=false
    end
    sleep(0.05)
  end
end

-------------------- Boot --------------------
term.clear(); term.setCursorPos(1,1)
print("smartmine: server+miner starting…")
openWiredModem()  -- actually call it
parallel.waitForAny(serverLoop, controllerLoop)


and here is smartmine_ui.lua

-- smartmine_ui.lua — Advanced Computer UI for SmartMine
-- Uses base family keys end-to-end. START sends the "key" (e.g., "iron").
-- Updates on 'dock' (cmd + counts + left + ore), pagination intact.

---------------- Config ----------------
local PROTOCOL = "smartmine"

-- Colors
local HEADER_BG = colors.blue
local HEADER_FG = colors.white
local LIST_BG   = colors.black
local LIST_FG   = colors.white
local SEL_BG    = colors.lime
local SEL_FG    = colors.black
local BTN_START = colors.lime
local BTN_SCAN  = colors.orange
local BTN_QUIT  = colors.red
local PANEL_BG  = colors.black
local PANEL_FG  = colors.white
local DIM_FG    = colors.lightGray

-- Optional per-ore colors
local ORE_COL = {
  Iron=colors.lightGray, Gold=colors.yellow, Copper=colors.orange, Coal=colors.gray,
  Diamond=colors.cyan, Emerald=colors.green, Redstone=colors.red, Lapis=colors.blue,
}

---------------- Peripherals ----------------
local function openWired()
  for _,n in ipairs(peripheral.getNames()) do
    if peripheral.getType(n)=="modem" then
      local m=peripheral.wrap(n); if m and not m.isWireless() then rednet.open(n); return true end
    end
  end; return false
end

local mon = peripheral.find("monitor")
if not mon then print("No monitor found.") return end
if not openWired() then print("No wired modem on this computer.") return end

pcall(mon.setTextScale, 0.5)
local W,H = mon.getSize()

---------------- Layout ----------------
local headerH = 2
local footerH = 1
local pageH   = 1

local leftPaneW = math.floor(W*0.48)

local listX1 = 2
local countCol = leftPaneW - 2
local listX2 = countCol - 2
local listY1 = headerH + 2
local listY2 = H - (footerH + pageH + 2)

local pageY  = H - footerH - 0
local btnY   = H
local btnW   = math.floor(W/3)
local btn1X  = 1
local btn2X  = btn1X + btnW + 1
local btn3X  = btn2X + btnW + 1

---------------- State ----------------
local turtleId = nil
local entries  = {}       -- { {name=disp, key=familyKey, n=cnt}, ... }
local sel      = 1
local page     = 1
local pages    = 1
local rows     = (listY2 - listY1 + 1)
local target   = "No target"
local leftCount= "-"
local tripNote = ""

---------------- Helpers ----------------
local function clr(bg, fg) mon.setBackgroundColor(bg or colors.black); mon.setTextColor(fg or colors.white) end
local function fill(x1,y1,x2,y2,bg) clr(bg,nil); for y=y1,y2 do mon.setCursorPos(x1,y); mon.write(string.rep(" ", math.max(0,x2-x1+1))) end end
local function rjust(x2,y,s,bg,fg) s=tostring(s or ""); clr(bg,fg); mon.setCursorPos(x2-#s,y); mon.write(s) end
local function btn(x,y,w,label,bg,fg) fill(x,y,x+w-1,y,bg); clr(bg,fg); mon.setCursorPos(x+math.max(0, math.floor((w-#label)/2)), y); mon.write(label) end

local function friendlyName(key)
  key = tostring(key or ""):lower()
  local map = {
    lapis="Lapis", redstone="Redstone", diamond="Diamond", emerald="Emerald",
    iron="Iron", gold="Gold", copper="Copper", coal="Coal",
    uraninite="Uraninite", xychorium="XYchorium",
  }
  local known = map[key]
  if known then return known end
  local s = key:gsub("_"," ")
  s = s:gsub("^%l", string.upper):gsub(" %l", string.upper)
  return s
end

local function toEntries(map)
  local t={}
  for famKey,cnt in pairs(map or {}) do
    table.insert(t,{name=friendlyName(famKey), key=famKey, n=tonumber(cnt) or 0})
  end
  table.sort(t, function(a,b) return a.name:lower()<b.name:lower() end)
  return t
end

---------------- Networking ----------------
local function pingTurtle(timeout)
  timeout = timeout or 2
  rednet.broadcast({cmd="ping"}, PROTOCOL)
  local t=os.startTimer(timeout)
  while true do
    local ev={os.pullEvent()}
    if ev[1]=="rednet_message" then
      local id,msg,proto=ev[2],ev[3],ev[4]
      if proto==PROTOCOL and type(msg)=="table" and msg.cmd=="pong" then return id end
    elseif ev[1]=="timer" and ev[2]==t then return nil end
  end
end

local function requestScan(id, timeout)
  timeout = timeout or 6
  rednet.send(id, {cmd="scan"}, PROTOCOL)
  local t=os.startTimer(timeout)
  while true do
    local ev={os.pullEvent()}
    if ev[1]=="rednet_message" then
      local sid,msg,proto=ev[2],ev[3],ev[4]
      if sid==id and proto==PROTOCOL and type(msg)=="table" then
        if msg.cmd=="scan_result" or msg.cmd=="dock" then
          return msg.counts or {}
        end
      end
    elseif ev[1]=="timer" and ev[2]==t then
      return {}
    end
  end
end

local function startMining(id, familyKey)
  rednet.send(id, {cmd="start", ore=familyKey}, PROTOCOL)
  return true
end

---------------- Render ----------------
local function drawHeader()
  clr(HEADER_BG, HEADER_FG)
  fill(1,1,W,headerH,HEADER_BG)
  local title = "SMARTMINE 3  |  Chunk Ore Browser"
  mon.setCursorPos(math.max(1, math.floor((W-#title)/2)), 1); mon.write(title)
  mon.setCursorPos(2,2)
  mon.write(("Turtle ID: %s  |  Target: %s  |  Left: %s"):format(tostring(turtleId or "?"), target, tostring(leftCount)))
end

local function drawRight()
  local x0 = leftPaneW + 1
  clr(PANEL_BG,PANEL_FG)
  mon.setCursorPos(x0, headerH+1); mon.write("Status:")
  mon.setCursorPos(x0, headerH+3); mon.write("Docked / Ready")
  mon.setCursorPos(x0, headerH+5); mon.write("This trip:")
  mon.setCursorPos(x0, headerH+6); mon.write(tripNote~="" and tripNote or "(no deliveries yet)")
  mon.setCursorPos(x0, headerH+10); mon.write("Session:")
end

local function drawList()
  fill(1, headerH+1, leftPaneW, H-(footerH+pageH+1), LIST_BG)

  if #entries==0 then
    clr(LIST_BG, DIM_FG)
    mon.setCursorPos(2, headerH+3); mon.write("No ores reported in this chunk.")
    return
  end

  pages = math.max(1, math.ceil(#entries / rows))
  if page>pages then page=pages end
  if page<1 then page=1 end
  local base = (page-1)*rows

  for r=0, rows-1 do
    local i = base + r + 1
    local y = listY1 + r
    if i<=#entries then
      local it = entries[i]
      local selRow = (i==sel)
      local bg = selRow and SEL_BG or LIST_BG
      local fg = selRow and SEL_FG or (ORE_COL[it.name] or LIST_FG)
      clr(bg,fg); mon.setCursorPos(listX1,y)
      local nameCell = it.name
      local maxw = listX2 - listX1 + 1
      if #nameCell>maxw then nameCell = nameCell:sub(1,maxw) end
      mon.write(nameCell .. string.rep(" ", math.max(0, maxw-#nameCell)))
      rjust(countCol, y, "("..it.n..")", bg, DIM_FG)
    else
      clr(LIST_BG, LIST_FG); mon.setCursorPos(listX1,y); mon.write(string.rep(" ", listX2-listX1+1))
    end
  end
end

local pageZones = {}

local function drawPagination()
  pageZones={}
  fill(1,pageY,W,pageY,LIST_BG)
  if pages<=1 then return end

  local parts = {}
  table.insert(parts, {txt="◀", kind="prev"})
  for p=1,pages do table.insert(parts, {txt=tostring(p), page=p}) end
  table.insert(parts, {txt="▶", kind="next"})

  local total = 0
  for _,p in ipairs(parts) do total = total + #p.txt + 1 end
  local x = math.max(2, math.floor((W - total)/2))
  for _,p in ipairs(parts) do
    local bg = LIST_BG
    local fg = DIM_FG
    if p.page then
      if p.page==page then bg=SEL_BG; fg=SEL_FG end
    end
    clr(bg,fg)
    mon.setCursorPos(x, pageY); mon.write(p.txt)
    local x1,x2 = x, x + #p.txt - 1
    if p.page then table.insert(pageZones, {x1=x1,x2=x2, page=p.page})
    elseif p.kind=="prev" then table.insert(pageZones, {x1=x1,x2=x2, page=math.max(1,page-1)})
    elseif p.kind=="next" then table.insert(pageZones, {x1=x1,x2=x2, page=math.min(pages,page+1)}) end
    x = x + #p.txt + 1
  end
end

local function drawButtons()
  btn(btn1X, btnY, btnW, "START", BTN_START, colors.black)
  btn(btn2X, btnY, btnW, "RESCAN", BTN_SCAN,  colors.black)
  btn(btn3X, btnY, btnW, "QUIT",  BTN_QUIT,  colors.black)
end

local function render()
  clr(colors.black, colors.white); mon.clear()
  drawHeader()
  drawRight()
  drawList()
  drawPagination()
  drawButtons()
end

---------------- Data refresh --------------
local function refreshEntries()
  rednet.broadcast({cmd="ping"}, PROTOCOL)
  local raw = {}
  if turtleId then raw = requestScan(turtleId, 6) end
  entries = toEntries(raw or {})
  pages = math.max(1, math.ceil(#entries / rows))
  if sel>#entries then sel=#entries end
  if sel<1 then sel=1 end
  if page>pages then page=pages end
  if page<1 then page=1 end
end

---------------- Startup -------------------
turtleId = pingTurtle(2)
refreshEntries()
render()

---------------- Event loop ----------------
while true do
  local ev = {os.pullEvent()}
  if ev[1]=="monitor_touch" then
    local _,x,y = table.unpack(ev)

    if y==btnY then
      if x>=btn1X and x<btn1X+btnW then
        if entries[sel] and turtleId then
          target = entries[sel].name; leftCount=entries[sel].n; tripNote="Mining "..target.."..."
          render()
          startMining(turtleId, entries[sel].key)
        end
      elseif x>=btn2X and x<btn2X+btnW then
        tripNote="Rescanning..."
        render()
        refreshEntries()
        tripNote=""
        render()
      elseif x>=btn3X and x<btn3X+btnW then
        term.redirect(term.native()) return
      end

    elseif y==pageY and #pageZones>0 then
      for _,z in ipairs(pageZones) do
        if x>=z.x1 and x<=z.x2 then page=z.page; render(); break end
      end

    elseif x>=listX1 and x<=listX2 and y>=listY1 and y<=listY2 then
      local i = (page-1)*rows + (y - listY1) + 1
      if entries[i] then sel=i; render() end
    end

  elseif ev[1]=="rednet_message" then
    local id,msg,proto = ev[2],ev[3],ev[4]
    if (not turtleId) and proto==PROTOCOL and type(msg)=="table" and msg.cmd=="pong" then
      turtleId = id; render()
    elseif turtleId and id==turtleId and proto==PROTOCOL and type(msg)=="table" and msg.cmd=="dock" then
      entries = toEntries(msg.counts or {})
      pages = math.max(1, math.ceil(#entries / rows))
      if type(msg.ore)=="string" then target = friendlyName(msg.ore) end
      leftCount = msg.left or leftCount
      tripNote = "Returned."
      render()
    end
  end
end