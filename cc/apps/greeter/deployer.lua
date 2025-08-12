-- deployer.lua — Greeter-only updater for ComputerCraft/Tweaked
-- Run ON THE GREETER COMPUTER:
--   deployer where
--   deployer install
--   deployer list
--   deployer rollback [n]

------------------------ CONFIG ------------------------
local CONFIG = {
  -- Raw base to your repo's cc/ folder
  BASE_URL = "https://raw.githubusercontent.com/Emsjas/cc-scripts/main/cc/",

  -- Map: [local path on THIS computer] = "remote path under cc/ in your repo"
  FILES = {
    ["/apps/greeter/greeter.lua"]         = "apps/greeter/greeter.lua",
    ["/apps/greeter/startup_greeter.lua"] = "apps/greeter/startup_greeter.lua",
    ["/libs/util.lua"]                     = "libs/util.lua",
    ["/startup.lua"]                       = "startup.lua",      -- optional: updater+launcher
  },

  -- Never overwrite these on install (your per-machine config/state)
  PRESERVE = {
    ["/config/"]    = true,
    ["/data/"]      = true,
    ["/.deployer/"] = true,  -- internal backups live here
  },

  BACKUP_DIR  = "/.deployer/backups",
  HISTORY     = 10,  -- keep last N backups
  REQUIRE_ALL_REMOTE_FILES = true,
}
--------------------- END CONFIG -----------------------

local args = { ... }
local function log(s) print(("[deployer] %s"):format(s)) end
local function err(s) printError(("[deployer] %s"):format(s)) end

local function mkdirs(path)
  local parts = {}
  for part in string.gmatch(path, "[^/]+") do table.insert(parts, part) end
  local cur = ""
  for i = 1, #parts - 1 do
    cur = cur .. "/" .. parts[i]
    if not fs.exists(cur) then fs.makeDir(cur) end
  end
end

local function copyFile(src, dst)
  mkdirs(dst)
  local ih = fs.open(src, "rb"); if not ih then return false, "open src: " .. src end
  local data = ih.readAll(); ih.close()
  local oh = fs.open(dst, "wb"); if not oh then return false, "open dst: " .. dst end
  oh.write(data); oh.close()
  return true
end

local function copyTree(src, dst)
  if fs.isDir(src) then
    for _, name in ipairs(fs.list(src)) do
      local ok, e = copyTree(fs.combine(src, name), fs.combine(dst, name))
      if not ok then return false, e end
    end
    return true
  else
    return copyFile(src, dst)
  end
end

local function deleteTree(path) if fs.exists(path) then fs.delete(path) end end

local function timestamp()
  local t = os.date("!*t")
  return string.format("%04d%02d%02d-%02d%02d%02d", t.year, t.month, t.day, t.hour, t.min, t.sec)
end

local function ensureHttp()
  if not http then return false, "http API disabled (enableAPI_http=true in server config)" end
  return true
end

local function httpGet(url)
  local ok, res = pcall(http.get, url, { ["Cache-Control"] = "no-cache" })
  if not ok or not res then return nil, "http.get failed: " .. tostring(url) end
  local body = res.readAll(); res.close()
  return body
end

local function pathIsPreserved(path)
  for preserved, _ in pairs(CONFIG.PRESERVE) do
    if preserved:sub(-1) == "/" then
      if path:sub(1, #preserved) == preserved then return true end
    else
      if path == preserved then return true end
    end
  end
  return false
end

local function makeBackup()
  local stamp = timestamp()
  local dest = fs.combine(CONFIG.BACKUP_DIR, stamp)
  mkdirs(dest .. "/.")
  local manifest = { files = {}, created = stamp }
  for localPath, _ in pairs(CONFIG.FILES) do
    if fs.exists(localPath) then
      local ok, e = copyTree(localPath, fs.combine(dest, localPath))
      if not ok then return nil, ("backup failed: %s -> %s (%s)"):format(localPath, dest, e) end
      table.insert(manifest.files, localPath)
    end
  end
  local mh = fs.open(fs.combine(dest, "/.manifest"), "w")
  mh.write(textutils.serialize(manifest)); mh.close()
  log("Backup created: " .. stamp)
  return stamp
end

local function listBackups()
  if not fs.exists(CONFIG.BACKUP_DIR) then return {} end
  local entries = fs.list(CONFIG.BACKUP_DIR)
  table.sort(entries, function(a,b) return a > b end) -- newest first
  return entries
end

local function enforceHistoryLimit()
  local entries = listBackups()
  for i = CONFIG.HISTORY + 1, #entries do
    deleteTree(fs.combine(CONFIG.BACKUP_DIR, entries[i]))
  end
end

local function restoreBackup(index)
  local entries = listBackups()
  if #entries == 0 then return false, "no backups present" end
  index = tonumber(index) or 1
  if index < 1 or index > #entries then return false, ("invalid index 1..%d"):format(#entries) end
  local srcRoot = fs.combine(CONFIG.BACKUP_DIR, entries[index])

  local manifestPath = fs.combine(srcRoot, "/.manifest")
  if fs.exists(manifestPath) then
    local mh = fs.open(manifestPath, "r")
    local manifest = textutils.unserialize(mh.readAll()); mh.close()
    for _, p in ipairs(manifest.files or {}) do
      if not pathIsPreserved(p) then
        deleteTree(p)
        local ok, e = copyTree(fs.combine(srcRoot, p), p)
        if not ok then return false, ("restore failed for %s: %s"):format(p, e) end
      end
    end
  else
    local ok, e = copyTree(srcRoot, "/")
    if not ok then return false, ("restore failed: %s"):format(e) end
  end
  log(("Restored backup %s"):format(entries[index])); return true
end

local function remoteExists(remoteName)
  local url = CONFIG.BASE_URL .. remoteName
  local body, e = httpGet(url)
  if not body then return false, e end
  return true
end

local function fetchAndWrite(remoteName, localPath)
  local url = CONFIG.BASE_URL .. remoteName
  local body, e = httpGet(url)
  if not body then return false, e end
  mkdirs(localPath)
  local fh = fs.open(localPath, "wb"); if not fh then return false, "open fail: "..localPath end
  fh.write(body); fh.close()
  return true
end

local function verifyAllRemote()
  for _, remoteName in pairs(CONFIG.FILES) do
    local exists, e = remoteExists(remoteName)
    if not exists then return false, ("remote missing: %s (%s)"):format(remoteName, e or "unknown") end
  end
  return true
end

local function install()
  local ok, why = ensureHttp(); if not ok then return false, why end
  if CONFIG.REQUIRE_ALL_REMOTE_FILES then
    local okAll, eAll = verifyAllRemote(); if not okAll then return false, eAll end
  end
  makeBackup(); enforceHistoryLimit()
  for localPath, remoteName in pairs(CONFIG.FILES) do
    if pathIsPreserved(localPath) then
      log("Preserved (skipped): " .. localPath)
    else
      local ok2, e2 = fetchAndWrite(remoteName, localPath)
      if not ok2 then return false, ("download failed %s -> %s (%s)"):format(remoteName, localPath, e2) end
      log("Updated: " .. localPath)
    end
  end
  log("Install complete."); return true
end

local function printHelp()
  print([[
Usage: deployer <command> [args]
  install           Backup current files and install latest from BASE_URL
  list              Show available backups (newest first)
  rollback [n]      Restore the nth most-recent backup (default 1)
  prune             Enforce history limit
  where             Show BASE_URL and managed file map
]])
end

local function cmdInstall() local ok,e=install(); if not ok then err(e) os.exit(1) end end
local function cmdList() local t=listBackups(); if #t==0 then print("No backups found.") return end for i,s in ipairs(t) do print(("%2d  %s"):format(i,s)) end end
local function cmdRollback(n) local ok,e=restoreBackup(n); if not ok then err(e) os.exit(1) end end
local function cmdPrune() enforceHistoryLimit(); print("Pruned old backups beyond HISTORY = "..CONFIG.HISTORY) end
local function cmdWhere()
  print("BASE_URL: "..CONFIG.BASE_URL); print("Managed files:")
  for localPath, remoteName in pairs(CONFIG.FILES) do print(("  %-34s  <-  %s"):format(localPath, remoteName)) end
  print("Preserved:"); for p,_ in pairs(CONFIG.PRESERVE) do print("  "..p) end
end

local cmd = args[1]
if cmd=="install" then cmdInstall()
elseif cmd=="list" then cmdList()
elseif cmd=="rollback" then cmdRollback(args[2])
elseif cmd=="prune" then cmdPrune()
elseif cmd=="where" then cmdWhere()
else printHelp() end
