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
