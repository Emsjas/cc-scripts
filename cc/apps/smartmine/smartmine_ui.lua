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
