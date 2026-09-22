local HUD = {}

-- Monitor: 3x2 at scale 0.5 = 48x20 chars
local MON_W, MON_H = 48, 20
local SCALE = 0.5

-- Colors
local C = {
    bg       = colors.black,
    header   = colors.blue,
    sidebar  = colors.blue,
    text     = colors.lightBlue,
    bright   = colors.white,
    dim      = colors.gray,
    good     = colors.green,
    warn     = colors.yellow,
    bad      = colors.red,
    accent   = colors.cyan,
    bar      = colors.blue,
    barempty = colors.darkGray,
    panel    = colors.black,
}

local function setup(mon)
    pcall(function() mon.setTextScale(SCALE) end)
    mon.setBackgroundColor(C.bg)
    mon.clear()
end

local function box(mon, x, y, w, h, color)
    mon.setBackgroundColor(color)
    for dy = 0, h - 1 do
        mon.setCursorPos(x, y + dy)
        mon.write(string.rep(" ", w))
    end
    mon.setBackgroundColor(C.bg)
end

local function txt(mon, x, y, text, color)
    mon.setCursorPos(x, y)
    mon.setTextColor(color or C.text)
    mon.setBackgroundColor(C.bg)
    mon.write(text)
end

local function hline(mon, x, y, w, color)
    mon.setBackgroundColor(color)
    mon.setCursorPos(x, y)
    mon.write(string.rep(" ", w))
    mon.setBackgroundColor(C.bg)
end

local function bar(val, max_val, width)
    local ratio = math.max(0, math.min(1, val / max_val))
    local filled = math.floor(ratio * width + 0.5)
    return string.rep(string.char(219), filled) .. string.rep(string.char(176), width - filled)
end

local function rpad(text, width)
    if #text >= width then return text:sub(1, width) end
    return text .. string.rep(" ", width - #text)
end

local function lpad(text, width)
    if #text >= width then return text:sub(1, width) end
    return string.rep(" ", width - #text) .. text
end

-- ============================================================
-- Tab definitions
-- ============================================================

local tabs = {
    { id = "flight",  label = "FLT",  icon = ">" },
    { id = "engine",  label = "ENG",  icon = "#" },
    { id = "systems", label = "SYS",  icon = "*" },
}

local active_tab = "flight"

-- ============================================================
-- Sidebar (left 8 chars)
-- ============================================================

local function drawSidebar(mon)
    -- ArtCorp logo area
    box(mon, 1, 1, 8, 2, C.header)
    txt(mon, 2, 1, "ART", C.bright)
    txt(mon, 2, 2, "CORP", C.bright)

    -- Separator line
    hline(mon, 1, 3, 8, C.dim)

    -- Tab list
    for i, tab in ipairs(tabs) do
        local y = 3 + i
        if tab.id == active_tab then
            box(mon, 1, y, 8, 1, C.header)
            txt(mon, 1, y, " " .. tab.icon .. " " .. tab.label, C.bright)
        else
            txt(mon, 1, y, "   " .. tab.label, C.dim)
        end
    end

    -- Bottom separator
    hline(mon, 1, 7, 8, C.dim)

    -- System info at bottom of sidebar
    txt(mon, 1, 8,  "        ", C.dim)
    txt(mon, 1, 9,  " ALT    ", C.dim)
    txt(mon, 1, 10, " SPD    ", C.dim)
    txt(mon, 1, 11, " CLB    ", C.dim)
    txt(mon, 1, 12, "        ", C.dim)
    txt(mon, 1, 13, " MODE   ", C.dim)
end

-- ============================================================
-- Tab: Flight
-- ============================================================

local function drawFlightTab(mon, status)
    local sx = 9  -- content start x

    -- Altitude
    local alt = status.altitude or 0
    local tgt = status.target_altitude or 0
    txt(mon, sx, 8, "ALT ", C.dim)
    txt(mon, sx + 4, 8, lpad(string.format("%.0f", alt), 5), C.accent)
    txt(mon, sx + 10, 8, "/" .. string.format("%.0f", tgt), C.dim)

    -- Speed
    local spd = status.speed or 0
    txt(mon, sx, 9, "SPD ", C.dim)
    txt(mon, sx + 4, 9, lpad(string.format("%.0f", spd), 5), C.accent)
    txt(mon, sx + 10, 9, "m/s", C.dim)

    -- Climb
    local climb = status.climb_rate or 0
    local climb_c = C.good
    if climb < -2 then climb_c = C.bad
    elseif climb < 0 then climb_c = C.warn
    end
    txt(mon, sx, 10, "CLB ", C.dim)
    txt(mon, sx + 4, 10, lpad(string.format("%+.1f", climb), 5), climb_c)

    -- Mode
    local mode = status.mode or "???"
    local mode_c = mode == "HOVER" and C.good or C.warn
    txt(mon, sx, 12, "MODE ", C.dim)
    txt(mon, sx + 5, 12, rpad(mode, 6), mode_c)

    -- Altitude bar
    hline(mon, sx, 14, 16, C.barempty)
    local alt_diff = tgt - alt
    local bar_val = 8 + alt_diff * 0.5
    local filled = math.floor(math.max(0, math.min(bar_val, 16)))
    for i = 1, filled do
        txt(mon, sx + i - 1, 14, string.char(219), C.bar)
    end
end

-- ============================================================
-- Tab: Engine (propeller outputs)
-- ============================================================

local function drawEngineTab(mon, status)
    local sx = 9
    local outputs = status.outputs or {}

    txt(mon, sx, 8, "--- PROPELLERS ---", C.text)

    local props = {"FL", "FR", "RL", "RR"}
    for i, p in ipairs(props) do
        local tilt = outputs[p .. "_tilt"] or 0
        local tc = C.good
        if math.abs(tilt) > 8 then tc = C.bad
        elseif math.abs(tilt) > 4 then tc = C.warn
        end
        txt(mon, sx, 8 + i, p .. ":", C.dim)
        txt(mon, sx + 4, 8 + i, string.format("%+5.1f", tilt), tc)
    end

    -- Thrust bar
    txt(mon, sx, 13, "THR:", C.dim)
    txt(mon, sx + 4, 13, bar(outputs.speed or 0, 15, 10), C.good)

    -- Rear thrusters
    txt(mon, sx, 14, "RFW:", C.dim)
    txt(mon, sx + 4, 14, bar(outputs.rear_fw or 0, 15, 10), C.good)
    txt(mon, sx, 15, "RBW:", C.dim)
    txt(mon, sx + 4, 15, bar(outputs.rear_bw or 0, 15, 10), C.good)
end

-- ============================================================
-- Tab: Systems (PID gains, attitude)
-- ============================================================

local function drawSystemsTab(mon, status)
    local sx = 9

    -- Attitude
    txt(mon, sx, 8, "PITCH", C.dim)
    local pitch = status.pitch or 0
    local pc = C.good
    if math.abs(pitch) > 10 then pc = C.bad
    elseif math.abs(pitch) > 5 then pc = C.warn
    end
    txt(mon, sx + 6, 8, string.format("%+6.1f", pitch), pc)

    txt(mon, sx, 9, "ROLL ", C.dim)
    local roll = status.roll or 0
    local rc = C.good
    if math.abs(roll) > 10 then rc = C.bad
    elseif math.abs(roll) > 5 then rc = C.warn
    end
    txt(mon, sx + 6, 9, string.format("%+6.1f", roll), rc)

    txt(mon, sx, 10, "YAW  ", C.dim)
    txt(mon, sx + 6, 10, string.format("%+6.1f", status.yaw or 0), C.text)

    -- PID gains
    hline(mon, sx, 11, 16, C.dim)
    txt(mon, sx, 12, "--- PID ---", C.text)

    local pid = {
        { label = "ALT", gains = (status.pid_gains or {}).altitude },
        { label = "PIT", gains = (status.pid_gains or {}).pitch },
        { label = "ROL", gains = (status.pid_gains or {}).roll },
        { label = "YAW", gains = (status.pid_gains or {}).yaw },
    }

    for i, p in ipairs(pid) do
        local g = p.gains or {}
        txt(mon, sx, 12 + i, p.label, C.dim)
        txt(mon, sx + 4, 12 + i,
            string.format("P%.1f I%.2f D%.1f",
                g.kp or 0, g.ki or 0, g.kd or 0), C.text)
    end
end

-- ============================================================
-- Main render
-- ============================================================

function HUD.render(mon, status, config, status_msg)
    if not mon then return end
    setup(mon)

    drawSidebar(mon)

    if active_tab == "flight" then
        drawFlightTab(mon, status)
    elseif active_tab == "engine" then
        drawEngineTab(mon, status)
    elseif active_tab == "systems" then
        drawSystemsTab(mon, status)
    end

    -- Status bar at bottom
    box(mon, 9, MON_H - 1, MON_W - 8, 1, C.header)
    if status_msg and status_msg ~= "" then
        txt(mon, 9, MON_H - 1, " " .. status_msg, C.bright)
    else
        local hint = "Q/E:ALT  M:MODE  X:STOP  T:TUNE"
        txt(mon, 9, MON_H - 1, " " .. hint, C.bright)
    end
end

function HUD.nextTab()
    for i, tab in ipairs(tabs) do
        if tab.id == active_tab then
            active_tab = tabs[(i % #tabs) + 1].id
            return
        end
    end
end

function HUD.setTab(id)
    for _, tab in ipairs(tabs) do
        if tab.id == id then
            active_tab = id
            return
        end
    end
end

function HUD.getTab()
    return active_tab
end

return HUD
