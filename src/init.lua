-- SmartThings Edge driver: iRobot Roomba (local).
-- The hub talks to the robot's own MQTT broker (TLS, port 8883) on the LAN: no cloud, no bridge.
--   discovery  UDP "irobotmcs" on port 5678 (broadcast and a sweep of the hub's /24)
--   password   fetched once from the robot while HOME is held for 2 s on the dock, stored on the hub
--   state      pushed by the robot (shadow updates), merged and mapped to SmartThings
--   commands   start / pause / resume / stop / dock / evac on topic "cmd"
-- No secrets in the code: the password lives in a persistent device field (or a device setting).
local Driver = require "st.driver"
local capabilities = require "st.capabilities"

-- Connection status as a capability, so routines can notify when this device loses its connection
-- (SmartThings itself has no "device offline" trigger for routines).
-- Short drops (a reconnect, one missed poll) are ignored: Offline is only emitted after the "Offline after" setting (default 5 min) down.
-- Every drop is remembered (time, duration, reason) and shown as "Last drop" once the connection is back.
local conn_cap = capabilities["silvervalley08660.connectionStatus"]
local drop_cap = capabilities["silvervalley08660.connectionLog"]
local CONN_GRACE = 300
local function conn_grace(dev)
  -- setting "Offline after (minutes)": a router or network update at night takes a few minutes
  local m = tonumber(dev.preferences and dev.preferences.offlineAfter)
  if m and m >= 1 then return math.floor(m * 60) end
  return CONN_GRACE
end
-- connection status and log live in their own "connection" component, so the app shows them at the bottom
-- (in main the app put them above the cleaner card, whatever the order in the profile)
local function conn_comp(dev)
  local c = dev.profile and dev.profile.components and dev.profile.components.connection
  return c, c and c.id or "main"
end
local function conn_event(dev, ev)
  local c = conn_comp(dev)
  if c then dev:emit_component_event(c, ev) else dev:emit_event(ev) end
end
local function emit_conn(dev, v)
  if dev:get_field("conn_status") == v then return end
  local ok = pcall(function() conn_event(dev, conn_cap.status(v)) end)
  if ok then dev:set_field("conn_status", v) end
end
local function fmt_secs(s)
  if s < 120 then return string.format("%d s", s) end
  if s < 7200 then return string.format("%d min", s // 60) end
  return string.format("%.1f h", s / 3600)
end
local function note_drop(dev, reason)
  if dev:get_field("conn_drop") then return end
  dev:set_field("conn_drop", { at = os.time(), reason = tostring(reason or "unknown"):sub(1, 120) }, { persist = true })
end
local function report_drop(dev)
  local d = dev:get_field("conn_drop")
  if type(d) ~= "table" or not d.at then return end
  dev:set_field("conn_drop", nil, { persist = true })
  local txt = string.format("%s UTC, %s: %s", os.date("!%Y-%m-%d %H:%M:%S", d.at), fmt_secs(math.max(0, os.time() - d.at)), tostring(d.reason))
  require("log").info("[conn] " .. tostring(dev.label) .. " back after drop at " .. txt)
  pcall(function() conn_event(dev, drop_cap.lastDrop(txt:sub(1, 200))) end)
end
local function set_conn(dev, up, reason)
  if up then
    dev:set_field("conn_down_since", nil)
    if not dev:get_field("drop_seen") then
      -- the app wants a value for every attribute ("not all status information updated yet" otherwise)
      dev:set_field("drop_seen", true)
      local _, cid = conn_comp(dev)
      local ok, v = pcall(dev.get_latest_state, dev, cid, drop_cap.ID, "lastDrop")
      if ok and v == nil and not dev:get_field("conn_drop") then
        pcall(function() conn_event(dev, drop_cap.lastDrop("No drops yet")) end)
      end
    end
    report_drop(dev)
    emit_conn(dev, "online")
    return
  end
  note_drop(dev, reason)
  if dev:get_field("conn_down_since") then return end
  local since = os.time()
  dev:set_field("conn_down_since", since)
  local ok = pcall(function()
    dev.thread:call_with_delay(conn_grace(dev), function()
      if dev:get_field("conn_down_since") == since then emit_conn(dev, "offline") end
    end)
  end)
  if not ok then emit_conn(dev, "offline") end
end
local log = require "log"
local cosock = require "cosock"
local json = require "st.json"
local mqtt = require "mqtt"
local model = require "roomba_model"
local net = require "transport"

local BUILD = "2026-11-08g"
local KEEPALIVE = 60
local PING_AFTER = 30
local DEAD_AFTER = 120
local PW_RETRY = 5
local RECONNECT_MIN, RECONNECT_MAX = 5, 120

local rcm = capabilities.robotCleanerMovement
local switch = capabilities.switch
local battery = capabilities.battery
local momentary = capabilities.momentary
local modecap = capabilities.mode
local favcap = capabilities["silvervalley08660.robotFavorites"] -- favorites list on the main card
local bincap = capabilities["silvervalley08660.robotBin"]        -- own "Empty bin" card: bin state + button

local WHOLE_HOME = "Whole home"
local IDLE = "Idle"
local MAX_PROGRAMS = 12

local sessions = {} -- device.id -> session state

-- helpers -------------------------------------------------------------------------

local function blid_of(device)
  return device:get_field("blid") or (device.device_network_id or ""):match("^roomba%-(.+)$")
end

local function pref(device, name)
  local v = (device.preferences or {})[name]
  if type(v) == "string" then v = v:match("^%s*(.-)%s*$") end
  return v
end

local function address(device)
  local ip = pref(device, "ipAddress")
  if ip and ip ~= "" and ip ~= "auto" then return ip end
  return device:get_field("ip")
end

local function password(device)
  local p = pref(device, "password")
  if p and p ~= "" then return p, "setting" end
  local f = device:get_field("pw")
  if f and f ~= "" then return f, "field" end
end

local function parse_reply(data)
  local ok, j = pcall(json.decode, data)
  if not ok or type(j) ~= "table" then return nil end
  local blid = type(j.hostname) == "string" and j.hostname:match("^%a+%-(%w+)$")
  if not blid or (j.proto and j.proto ~= "mqtt") then return nil end
  return { blid = blid, ip = j.ip, name = j.robotname, sku = j.sku, sw = j.sw, ver = j.ver }
end

local function hub_prefix(driver)
  local ip = driver.environment_info and driver.environment_info.hub_ipv4
  if not ip then
    local ok, addr = pcall(function()
      local s = cosock.socket.udp()
      s:setpeername("8.8.8.8", 53)
      local a = s:getsockname()
      s:close()
      return a
    end)
    if ok then ip = addr end
  end
  return type(ip) == "string" and ip:match("^(%d+%.%d+%.%d+%.)") or nil
end

local function find_robots(driver, window)
  local found = {}
  for _, r in ipairs(net.discover(hub_prefix(driver), window)) do
    local info = parse_reply(r.data)
    if info then
      info.ip = info.ip or r.ip
      found[info.blid] = info
    end
  end
  return found
end

-- state -> events -------------------------------------------------------------------

local function try_emit(device, make, component)
  local ok, err = pcall(function()
    local ev = make()
    if component then device:emit_component_event(component, ev) else device:emit_event(ev) end
  end)
  if not ok then log.warn("[roomba] " .. tostring(device.label) .. ": " .. tostring(err)) end
end

local function emit_state(device, s)
  local v = model.view(s.reported)
  if v.phase == "" and v.battery == nil then return end -- nothing useful yet
  try_emit(device, function() return rcm.robotCleanerMovement[v.movement]() end)
  try_emit(device, function() return v.active and switch.switch.on() or switch.switch.off() end)
  if v.battery then
    try_emit(device, function() return battery.battery(math.max(0, math.min(100, math.floor(v.battery)))) end)
  end
  local sig = v.phase .. "/" .. v.cycle .. "/" .. v.error .. "/" .. tostring(v.bin_full)
  if sig ~= s.last_sig then
    s.last_sig = sig
    log.info(string.format("[roomba] %s: phase=%s cycle=%s battery=%s%s%s", device.label, v.phase, v.cycle,
      tostring(v.battery), v.error_text and (" error: " .. v.error_text) or "", v.bin_full and " bin full" or ""))
  end
  s.view = v
  local bin = v.phase == "evac" and "emptying" or (v.bin_full and "full" or "ok")
  if bin ~= s.bin_state then
    s.bin_state = bin
    try_emit(device, function() return bincap.binStatus(bin) end)
  end
  if s.emit_programs then s.emit_programs(device, s) end
end

-- favorites ------------------------------------------------------------------------------
-- The iRobot app keeps favorites (names, rooms) in the cloud. Two sources, the first one that has any wins:
--   1. a Stoeckie Bridge on the LAN with an iRobot login: names and rooms straight from the account
--   2. learned locally: the robot reports its last command, so a favorite is stored the first time it runs;
--      names then come from the "Favorite names" setting, in the order learned.

local function programs(device)
  local raw = device:get_field("programs")
  local ok, list = pcall(json.decode, raw or "[]")
  return (ok and type(list) == "table") and list or {}
end

local function program_names(device)
  local names = {}
  for n in (pref(device, "favoriteNames") or ""):gmatch("[^,]+") do
    names[#names + 1] = n:match("^%s*(.-)%s*$")
  end
  local out = {}
  for i, _ in ipairs(programs(device)) do
    local n = names[i]
    if not n or n == "" then n = "Favorite " .. i end
    out[i] = n
  end
  return out
end

local function cloud_favorites(device)
  local ok, list = pcall(json.decode, device:get_field("cloud_favs") or "[]")
  return (ok and type(list) == "table") and list or {}
end

--- All favorites as {name, command, params, key}.
local function entries(device)
  local out = {}
  for _, f in ipairs(cloud_favorites(device)) do
    local params = type(f.params) == "table" and f.params or {}
    local p = model.program_from({ command = f.command or "start", pmap_id = params.pmap_id, regions = params.regions })
    out[#out + 1] = { name = f.name, command = f.command or "start", params = params, key = p and p.key }
  end
  if #out > 0 then return out end
  local names = program_names(device)
  for i, q in ipairs(programs(device)) do
    out[#out + 1] = { name = names[i], command = "start", key = q.key,
                      params = { pmap_id = q.pmap_id, regions = q.regions, ordered = q.ordered or 1,
                                 user_pmapv_id = q.user_pmapv_id } }
  end
  return out
end

local function has_favcap(device)
  if device.supports_capability_by_id then return device:supports_capability_by_id(favcap.ID) end
  return true
end

local function emit_programs(device, s)
  local comp = device.profile and device.profile.components and device.profile.components.favorites
  local main = has_favcap(device)
  if not comp and not main then return end
  local list = { IDLE, WHOLE_HOME }
  local seen = { [IDLE] = true, [WHOLE_HOME] = true }
  for _, e in ipairs(entries(device)) do
    if not seen[e.name] then list[#list + 1] = e.name; seen[e.name] = true end
  end
  local enc = table.concat(list, "\n")
  if s.programs_sig ~= enc then
    s.programs_sig = enc
    if comp then
      try_emit(device, function() return modecap.supportedModes(list, { visibility = { displayed = false } }) end, comp)
    end
    if main then
      try_emit(device, function() return favcap.supportedFavorites(list, { visibility = { displayed = false } }) end)
    end
  end
  -- what is running now
  local v = s.view or model.view(s.reported)
  local now = IDLE
  if v.active then
    now = WHOLE_HOME
    local p = model.program_from(s.reported.lastCommand)
    if p then
      for _, e in ipairs(entries(device)) do
        if e.key == p.key then now = e.name end
      end
    end
  end
  if comp then try_emit(device, function() return modecap.mode(now) end, comp) end
  if main and s.favorite_now ~= now then
    s.favorite_now = now
    try_emit(device, function() return favcap.favorite(now) end)
  end
end

local function learn_program(device, s)
  local p = model.program_from(s.reported.lastCommand)
  if not p then return end
  local list = programs(device)
  for _, q in ipairs(list) do
    if q.key == p.key then return end
  end
  if #list >= MAX_PROGRAMS then return end
  list[#list + 1] = p
  device:set_field("programs", json.encode(list), { persist = true })
  log.info(string.format("[roomba] %s: learned favorite %d (%d room(s)); name it in the settings",
    device.label, #list, #p.regions))
end

-- favorites from a Stoeckie Bridge ------------------------------------------------------

local BRIDGE_PORT = 8787
local CLOUD_EVERY = 6 * 3600

local function bridge_info(ip)
  local data = net.http_get(ip, BRIDGE_PORT, "/stbridge/info", 2)
  local ok, j = pcall(json.decode, data or "")
  return ok and type(j) == "table" and j.service == "stoeckie-bridge"
end

local function find_bridge(driver, device)
  local fixed = pref(device, "bridgeAddress")
  if fixed and fixed:match("^%d+%.%d+%.%d+%.%d+$") then return fixed end
  if fixed == "off" then return nil end
  local known = device:get_field("bridge")
  if known and bridge_info(known) then return known end
  local last = device:get_field("bridge_scan") or 0
  if os.time() - last < 600 then return nil end
  device:set_field("bridge_scan", os.time())
  local prefix = hub_prefix(driver)
  if not prefix then return nil end
  local found, next_host, pending = nil, 1, 0
  local function worker()
    while not found and next_host <= 254 do
      local ip = prefix .. next_host
      next_host = next_host + 1
      if bridge_info(ip) then found = ip end
    end
    pending = pending - 1
  end
  for i = 1, 16 do
    pending = pending + 1
    cosock.spawn(worker, "roomba-bridge-scan-" .. i)
  end
  while pending > 0 do net.sleep(0.5) end
  if found then
    device:set_field("bridge", found, { persist = true })
    log.info("[roomba] " .. device.label .. ": Stoeckie Bridge found at " .. found)
  end
  return found
end

local function fetch_cloud_favorites(driver, device, force)
  local blid = blid_of(device)
  local ip = blid and find_bridge(driver, device)
  if not ip then return end
  local path = "/stbridge/irobot/" .. blid .. (force and "?refresh=1" or "")
  local data, err = net.http_get(ip, BRIDGE_PORT, path, 5)
  local ok, j = pcall(json.decode, data or "")
  if not ok or type(j) ~= "table" or type(j.favorites) ~= "table" then
    if err then log.debug("[roomba] bridge: " .. tostring(err)) end
    return
  end
  local enc = json.encode(j.favorites)
  if enc ~= device:get_field("cloud_favs") then
    device:set_field("cloud_favs", enc, { persist = true })
    local names = {}
    for _, f in ipairs(j.favorites) do names[#names + 1] = tostring(f.name) end
    log.info(string.format("[roomba] %s: %d favorite(s) from the iRobot account: %s", device.label,
      #j.favorites, table.concat(names, ", ")))
    local s = sessions[device.id]
    if s then s.programs_sig = nil; emit_programs(device, s) end
  end
end

local function schedule_cloud(driver, device)
  local function run(force)
    cosock.spawn(function()
      local okc, e = pcall(fetch_cloud_favorites, driver, device, force)
      if not okc then log.warn("[roomba] favorites from bridge failed: " .. tostring(e)) end
    end, "roomba-cloud-favs")
  end
  device.thread:call_with_delay(10, function() run(false) end)
  device.thread:call_on_schedule(CLOUD_EVERY, function() run(false) end, "roomba-cloud-favs")
  return run
end

-- password ----------------------------------------------------------------------------

local PASSWORD_REQUEST = string.char(0xf0, 0x05, 0xef, 0xcc, 0x3b, 0x29, 0x00)
local UNSUPPORTED = string.char(0xf0, 0x05, 0xef, 0xcc, 0x3b, 0x29, 0x03)

--- Ask the robot for its password. Only answers while HOME was just held for 2 s on the dock.
local function fetch_password(ip)
  local sock, err = net.connect_tls(ip, net.PORT, 6)
  if not sock then return nil, err end
  local ok, serr = sock:send(PASSWORD_REQUEST)
  if not ok then sock:close(); return nil, serr end
  sock:settimeout(6)
  local raw, want = "", 35
  while #raw < want + 2 do
    local data, rerr, partial = sock:receive(1)
    data = data or (partial ~= "" and partial or nil)
    if not data then break end
    raw = raw .. data
    if raw == UNSUPPORTED then sock:close(); return nil, "unsupported" end
    if #raw >= 2 then want = raw:byte(2) end
  end
  sock:close()
  if #raw <= 7 then return nil, "no answer" end
  local pw = raw:sub(8):gsub("%z+$", "")
  if pw == "" then return nil, "empty" end
  return pw
end

-- session -------------------------------------------------------------------------------

local function enqueue(device, command, delay, params)
  local s = sessions[device.id]
  if not s then return end
  s.queue[#s.queue + 1] = { command = command, at = net.now() + (delay or 0), params = params }
end

local function command_payload(command, params)
  local msg = { command = command, time = os.time(), initiator = "localApp" }
  for k, v in pairs(params or {}) do msg[k] = v end
  return json.encode(msg)
end

local function flush_queue(s, session)
  local now = net.now()
  local keep = {}
  for _, item in ipairs(s.queue) do
    if item.at <= now then
      local payload = command_payload(item.command, item.params)
      log.info("[roomba] command " .. (item.params and payload or item.command))
      local ok, err = session:publish("cmd", payload)
      if not ok then return nil, err end
      s.last_tx = now
    else
      keep[#keep + 1] = item
    end
  end
  s.queue = keep
  return true
end

local function run_session(driver, device)
  local s = sessions[device.id]
  local backoff = RECONNECT_MIN
  while s.running do
    local ip = address(device)
    local blid = blid_of(device)
    if not ip then
      local found = find_robots(driver, 4)[blid or ""]
      if found and found.ip then
        device:set_field("ip", found.ip, { persist = true })
        ip = found.ip
      else
        log.warn("[roomba] " .. device.label .. ": robot not found on the network, set its IP in the settings")
        net.sleep(60)
      end
    end
    local pw, source = password(device)
    if ip and not pw then
      if not s.hinted then
        log.info("[roomba] " .. device.label .. ": no password yet. Put the robot on its dock and hold HOME "
          .. "for 2 seconds until it plays tones; the hub then fetches the password")
        s.hinted = true
      end
      local got, err = fetch_password(ip)
      if got then
        device:set_field("pw", got, { persist = true })
        log.info("[roomba] " .. device.label .. ": password received from the robot and stored on the hub")
        pw, source = got, "field"
      else
        if err == "unsupported" then
          log.warn("[roomba] " .. device.label .. ": this robot only gives its password to the iRobot cloud")
        end
        net.sleep(PW_RETRY)
      end
    end
    if ip and pw then
      local ok_session = false
      local sock, cerr = net.connect_tls(ip, net.PORT, 10, pw, device)
      if not sock then
        log.warn(string.format("[roomba] %s: cannot connect to %s: %s", device.label, ip, tostring(cerr)))
        s.drop_reason = "cannot connect: " .. tostring(cerr)
        -- the IP may have changed: look again when not fixed in the settings
        if not (pref(device, "ipAddress") or ""):match("%d") then
          local found = find_robots(driver, 3)[blid or ""]
          if found and found.ip and found.ip ~= ip then
            device:set_field("ip", found.ip, { persist = true })
            log.info("[roomba] " .. device.label .. " moved to " .. found.ip)
          end
        end
      else
        local session = mqtt.new(sock)
        local ok, err, rc = session:connect(blid, blid, pw, KEEPALIVE, 10)
        if not ok then
          log.warn(string.format("[roomba] %s: MQTT connect failed: %s", device.label, tostring(err)))
          s.drop_reason = "MQTT connect failed: " .. tostring(err)
          if rc == 4 or rc == 5 then
            if source == "field" then
              device:set_field("pw", nil, { persist = true })
              s.hinted = false
              log.warn("[roomba] " .. device.label .. ": stored password rejected, hold HOME again")
            else
              log.warn("[roomba] " .. device.label .. ": the password in the settings is wrong")
              net.sleep(60)
            end
          elseif rc == 3 then
            log.warn("[roomba] " .. device.label .. ": robot busy (only one local connection at a time)")
          end
          session:close()
        else
          session:subscribe("#")
          s.connected, ok_session = true, true
          s.last_rx, s.last_tx = net.now(), net.now()
          device:online(); set_conn(device, true)
          backoff = RECONNECT_MIN
          log.info(string.format("[roomba] %s: connected to %s", device.label, ip))
          while s.running do
            local fok, ferr = flush_queue(s, session)
            if not fok then log.warn("[roomba] send failed: " .. tostring(ferr)); break end
            local p, rerr = session:read(1, 10)
            local now = net.now()
            if p then
              s.last_rx = now
              session:ack(p)
              if p.type == "publish" then
                local dok, msg = pcall(json.decode, p.payload)
                local rep = dok and model.reported(msg)
                if rep then
                  if rep.lastCommand then s.reported.lastCommand = nil end -- replace, never merge
                  model.merge(s.reported, rep)
                  if rep.lastCommand then learn_program(device, s) end
                  emit_state(device, s)
                end
              end
            elseif rerr == "timeout" then
              if now - s.last_tx > PING_AFTER then
                if not session:ping() then note_drop(device, "ping failed"); break end
                s.last_tx = now
              end
              if now - s.last_rx > DEAD_AFTER then
                log.warn("[roomba] " .. device.label .. ": no data for " .. DEAD_AFTER .. " s, reconnecting")
                note_drop(device, "no data for " .. DEAD_AFTER .. " s")
                break
              end
            else
              log.warn("[roomba] " .. device.label .. ": connection lost: " .. tostring(rerr))
              note_drop(device, "connection lost: " .. tostring(rerr))
              break
            end
          end
          session:close()
          s.connected = false
        end
      end
      if s.running then
        if not ok_session then set_conn(device, false, s.drop_reason); device:offline() end
        net.sleep(backoff)
        backoff = math.min(RECONNECT_MAX, backoff * 2)
      end
    end
  end
end

local function start_session(driver, device)
  local old = sessions[device.id]
  if old then old.running = false end
  local s = { running = true, queue = {}, reported = {}, connected = false, emit_programs = emit_programs }
  sessions[device.id] = s
  cosock.spawn(function()
    local ok, err = pcall(run_session, driver, device)
    if not ok then log.error("[roomba] session crashed: " .. tostring(err)) end
  end, "roomba-" .. device.id)
end

-- commands --------------------------------------------------------------------------------

local function current(device)
  local s = sessions[device.id]
  return s and s.view or model.view({})
end

local function do_start(device)
  local v = current(device)
  if v.active and (v.movement == "pause" or v.phase == "stop" or v.phase == "pause") then
    enqueue(device, "resume")
  elseif v.movement ~= "cleaning" then
    enqueue(device, "start")
  end
end

local function do_dock(device)
  local v = current(device)
  if v.movement == "cleaning" then
    enqueue(device, "pause")
    enqueue(device, "dock", 3)
  else
    enqueue(device, "dock")
  end
end

local function handle_on(_, device) do_start(device) end
local function handle_off(_, device) do_dock(device) end

local function handle_movement(_, device, cmd)
  local m = cmd.args.mode or cmd.args.robotCleanerMovement
  local s = sessions[device.id]
  local now = s and s.view and s.view.movement
  if now ~= nil and m == now then -- shown value sent again (list opened and closed): nothing to do
    log.info(string.format("[roomba] %s: already %s, nothing sent", device.label, tostring(m)))
    return
  end
  if m == "cleaning" then do_start(device)
  elseif m == "homing" or m == "charging" then do_dock(device)
  elseif m == "pause" then enqueue(device, "pause")
  elseif m == "idle" or m == "powerOff" then enqueue(device, "stop")
  else log.warn("[roomba] unsupported movement " .. tostring(m)) end
end

local function handle_empty_bin(_, device) enqueue(device, "evac") end

local function start_favorite(device, want)
  -- the app sends the shown favorite again when the list is opened and closed without a choice: that must
  -- not dock or restart the robot
  local s = sessions[device.id]
  if s and s.favorite_now ~= nil and want == s.favorite_now then
    log.info(string.format("[roomba] %s: favorite already '%s', nothing sent", device.label, tostring(want)))
    pcall(function() device:emit_event(favcap.favorite(want)) end)
    return
  end
  if want == IDLE then
    do_dock(device)
    return
  elseif want == WHOLE_HOME then
    enqueue(device, "start")
    return
  end
  for _, e in ipairs(entries(device)) do
    if e.name == want then
      local params = {}
      for k, v in pairs(e.params or {}) do params[k] = v end
      local s = sessions[device.id]
      -- keep the map version the favorite was made with (the app sends that one); the robot's own
      -- list is only a fallback for favorites without one. Overriding it gave "Smart Map problem".
      if params.pmap_id and not params.user_pmapv_id then
        params.user_pmapv_id = s and model.map_version(s.reported, params.pmap_id)
      end
      log.info(string.format("[roomba] %s: start favorite '%s'", device.label, want))
      enqueue(device, e.command or "start", 0, params)
      return
    end
  end
  log.warn("[roomba] unknown favorite " .. tostring(want))
end

local function handle_set_mode(_, device, cmd) start_favorite(device, cmd.args.mode) end
local function handle_set_favorite(_, device, cmd) start_favorite(device, cmd.args.favorite) end

local cloud_runs = {}

local function handle_refresh(driver, device)
  if cloud_runs[device.id] then
    device:set_field("bridge_scan", nil) -- Refresh always looks for the bridge again
    cloud_runs[device.id](true)
    device.thread:call_with_delay(20, function() cloud_runs[device.id](false) end)
  end
  local s = sessions[device.id]
  if s and s.connected then
    s.last_sig = nil
    emit_state(device, s)
  else
    start_session(driver, device)
  end
end

-- lifecycle --------------------------------------------------------------------------------

local discovered = {}

local function device_init(driver, device)
  if not sessions[device.id] or not sessions[device.id].running then start_session(driver, device) end
  local s = sessions[device.id]
  if s then s.programs_sig = nil; s.favorite_now = nil; pcall(emit_programs, device, s) end -- the app needs a value at once
  if s and not s.bin_state then try_emit(device, function() return bincap.binStatus("ok") end) end
  if not cloud_runs[device.id] then cloud_runs[device.id] = schedule_cloud(driver, device) end
end

local function device_added(driver, device)
  local info = discovered[device.device_network_id]
  if info then
    device:set_field("blid", info.blid, { persist = true })
    if info.ip then device:set_field("ip", info.ip, { persist = true }) end
  end
  device_init(driver, device)
end

local function info_changed(driver, device, event, args)
  local old = args and args.old_st_store and args.old_st_store.preferences or {}
  local p = device.preferences or {}
  if p.resetPassword and not old.resetPassword then
    device:set_field("pw", nil, { persist = true })
    log.info("[roomba] " .. device.label .. ": stored password forgotten, hold HOME on the docked robot")
  end
  if p.resetFavorites and not old.resetFavorites then
    device:set_field("programs", nil, { persist = true })
    log.info("[roomba] " .. device.label .. ": learned favorites forgotten")
  end
  if p.favoriteNames ~= old.favoriteNames or (p.resetFavorites and not old.resetFavorites) then
    local s = sessions[device.id]
    if s then s.programs_sig = nil; emit_programs(device, s) end
  end
  if p.bridgeAddress ~= old.bridgeAddress and cloud_runs[device.id] then
    device:set_field("bridge_scan", nil)
    if p.bridgeAddress == "off" then
      device:set_field("cloud_favs", nil, { persist = true })
      local s = sessions[device.id]
      if s then s.programs_sig = nil; emit_programs(device, s) end
    else
      cloud_runs[device.id](false)
    end
  end
  if p.ipAddress ~= old.ipAddress or p.password ~= old.password or (p.resetPassword and not old.resetPassword) then
    start_session(driver, device)
  end
end

local function device_removed(_, device)
  cloud_runs[device.id] = nil
  local s = sessions[device.id]
  if s then s.running = false end
  sessions[device.id] = nil
end

local function discovery(driver, opts, should_continue)
  local existing = {}
  for _, d in ipairs(driver:get_devices()) do existing[d.device_network_id] = d end
  local found = find_robots(driver, 5)
  local n = 0
  for blid, info in pairs(found) do
    n = n + 1
    local dni = "roomba-" .. blid
    discovered[dni] = info
    local dev = existing[dni]
    if dev then
      if info.ip and dev:get_field("ip") ~= info.ip then dev:set_field("ip", info.ip, { persist = true }) end
    else
      log.info(string.format("[roomba] found %s (%s) at %s", tostring(info.name), tostring(info.sku), tostring(info.ip)))
      driver:try_create_device({
        type = "LAN",
        device_network_id = dni,
        label = info.name or "Roomba",
        profile = "roomba",
        manufacturer = "iRobot",
        model = info.sku or "Roomba",
        vendor_provided_label = info.name or "Roomba",
      })
    end
  end
  log.info(string.format("[roomba] discovery done, %d robot(s) answered", n))
end

local driver = Driver("irobot-roomba-local", {
  discovery = discovery,
  lifecycle_handlers = {
    init = device_init,
    added = device_added,
    infoChanged = info_changed,
    removed = device_removed,
  },
  capability_handlers = {
    [capabilities.refresh.ID] = {
      [capabilities.refresh.commands.refresh.NAME] = handle_refresh,
    },
    [switch.ID] = {
      [switch.commands.on.NAME] = handle_on,
      [switch.commands.off.NAME] = handle_off,
    },
    [rcm.ID] = {
      [rcm.commands.setRobotCleanerMovement.NAME] = handle_movement,
    },
    [momentary.ID] = {
      [momentary.commands.push.NAME] = handle_empty_bin,
    },
    [modecap.ID] = {                       -- older profile with the Favorites component
      [modecap.commands.setMode.NAME] = handle_set_mode,
    },
    [bincap.ID] = {
      [bincap.commands.emptyBin.NAME] = handle_empty_bin,
    },
    [favcap.ID] = {
      [favcap.commands.setFavorite.NAME] = handle_set_favorite,
      [favcap.commands.emptyBin.NAME] = handle_empty_bin,
    },
  },
})

log.info("[roomba] iRobot Roomba (local) driver starting, build " .. BUILD)
-- certificate pinning: which robot device owns an address
require("certpin").lookup = function(host)
  for _, d in ipairs(driver:get_devices()) do
    if address(d) == host then return d end
  end
end

driver:run()
