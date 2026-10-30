-- Roomba reported state -> SmartThings values.
local M = {}

-- error codes as shown in the iRobot app (subset; others shown as "error <n>")
M.ERRORS = {
  [1] = "Left wheel off floor", [2] = "Main brushes stuck", [3] = "Right wheel off floor",
  [4] = "Left wheel stuck", [5] = "Right wheel stuck", [6] = "Stuck near a cliff",
  [7] = "Left wheel error", [8] = "Bin error", [9] = "Bumper stuck", [10] = "Right wheel error",
  [11] = "Bin error", [12] = "Cliff sensor issue", [13] = "Both wheels off floor", [14] = "Bin missing",
  [15] = "Robot rebooted", [16] = "Bumped unexpectedly", [17] = "Path blocked", [18] = "Docking issue",
  [19] = "Undocking issue", [20] = "Docking issue", [21] = "Navigation problem", [22] = "Navigation problem",
  [23] = "Battery issue", [24] = "Navigation problem", [25] = "Reboot required", [26] = "Vacuum problem",
  [27] = "Vacuum problem", [29] = "Software update needed", [30] = "Vacuum problem",
  [31] = "Reboot required", [32] = "Smart map problem", [33] = "Path blocked", [34] = "Reboot required",
  [36] = "Bin full", [38] = "Robot error", [39] = "Reboot required", [40] = "Navigation problem",
  [41] = "Timed out", [42] = "Localization problem", [43] = "Navigation problem", [46] = "Low battery",
  [47] = "Reboot required", [48] = "Path blocked", [62] = "Stop button pushed", [63] = "Hardware error",
  [65] = "Hardware problem detected", [66] = "Low memory", [67] = "Handle lifted", [68] = "Dead camera",
  [85] = "Path to charging station blocked", [86] = "Path to charging station blocked",
}

--- Deep merge `src` into `dst` (tables merge, everything else replaces).
function M.merge(dst, src)
  for k, v in pairs(src) do
    if type(v) == "table" and type(dst[k]) == "table" and next(v) ~= nil and v[1] == nil then
      M.merge(dst[k], v)
    else
      dst[k] = v
    end
  end
  return dst
end

--- Extract `state.reported` from a shadow update payload (decoded JSON), or nil.
function M.reported(msg)
  return type(msg) == "table" and type(msg.state) == "table" and type(msg.state.reported) == "table"
    and msg.state.reported or nil
end

local CLEANING = { run = true, new = true, resume = true, spot = true }
local HOMING = { hmUsrDock = true, hmPostMsn = true, hmMidMsn = true, dock = true, dockend = true }

--- Flatten the merged reported state into what the driver emits.
function M.view(r)
  local cms = type(r.cleanMissionStatus) == "table" and r.cleanMissionStatus or {}
  local phase = cms.phase or ""
  local cycle = cms.cycle or "none"
  local err = tonumber(cms.error) or 0
  local active = cycle ~= "none" and cycle ~= "" and phase ~= "evac"
  local movement
  if err ~= 0 or phase == "stuck" or phase == "chargingerror" then
    movement = "alarm"
  elseif CLEANING[phase] then
    movement = "cleaning"
  elseif HOMING[phase] then
    movement = "homing"
  elseif phase == "pause" or (phase == "stop" and active) then
    movement = "pause"
  elseif phase == "charge" or phase == "recharge" or phase == "evac" then
    movement = "charging"
  else
    movement = "idle"
  end
  local bin = type(r.bin) == "table" and r.bin or {}
  return {
    movement = movement,
    phase = phase,
    cycle = cycle,
    active = active,
    battery = tonumber(r.batPct),
    error = err,
    error_text = err ~= 0 and (M.ERRORS[err] or ("error " .. err)) or nil,
    bin_full = bin.full == true,
    mission_minutes = tonumber(cms.mssnM),
    name = r.name,
    sku = r.sku,
    software = r.softwareVer,
  }
end

--- A cleaning job for chosen rooms (a favorite started in the iRobot app) from `lastCommand`, or nil.
--- Returns {key=..., pmap_id=..., regions={...}, ordered=..., user_pmapv_id=...}.
function M.program_from(last)
  if type(last) ~= "table" then return nil end
  if last.command ~= "start" and last.command ~= "clean" then return nil end
  if type(last.regions) ~= "table" or #last.regions == 0 or not last.pmap_id then return nil end
  local regions, ids = {}, {}
  for _, r in ipairs(last.regions) do
    if type(r) == "table" and r.region_id ~= nil then
      local t = { region_id = tostring(r.region_id), type = r.type or "rid" }
      if r.params ~= nil then t.params = r.params end
      regions[#regions + 1] = t
      ids[#ids + 1] = t.type .. ":" .. t.region_id
    end
  end
  if #regions == 0 then return nil end
  return {
    key = tostring(last.pmap_id) .. "|" .. table.concat(ids, ","),
    pmap_id = tostring(last.pmap_id),
    regions = regions,
    ordered = last.ordered,
    user_pmapv_id = last.user_pmapv_id,
  }
end

--- Current map version for `pmap_id` from the reported `pmaps` list ([{pmap_id = pmapv_id}, ...]).
function M.map_version(r, pmap_id)
  for _, m in ipairs(type(r.pmaps) == "table" and r.pmaps or {}) do
    if type(m) == "table" and m[pmap_id] then return m[pmap_id] end
  end
end

return M
