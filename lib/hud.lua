local HUD = {}

-- 3x2 monitor at scale 0.5 = 48x20 chars
local MON_W, MON_H = 48, 20
local SCALE = 0.5

-- Colors
local C_BORDER  = colors.lightBlue
local C_STRIPE  = colors.lightBlue
local C_BG      = colors.black
local C_TITLE   = colors.white
local C_TEXT    = colors.lightBlue
local C_DIM     = colors.gray
local C_BRIGHT  = colors.white
local C_GOOD    = colors.green
local C_WARN    = colors.yellow
local C_BAD     = colors.red
local C_ACCENT  = colors.cyan

-- Layout (inside 1-char border)
-- Columns 2-31:  Left panel (30 chars)
-- Columns 32-39: Blue stripe (8 chars)
-- Columns 40-47: Right panel (8 chars)
-- Rows 2-19:     Usable height (18 chars)
local LP_X, LP_W = 2, 30
local ST_X, ST_W = 32, 8
local RP_X, RP_W = 40, 8

local active_tab = "flight"

local function setup(mon)
    pcall(function() mon.setTextScale(SCALE) end)
    mon.setBackgroundColor(C_BG)
    mon.clear()
end

-- Draw a single character at position
local function pixel(mon, x, y, color)
    mon.setBackgroundColor(color)
    mon.setCursorPos(x, y)
    mon.write(" ")
end

-- Draw a horizontal line of characters
local function hline(mon, x, y, w, color)
    mon.setBackgroundColor(color)
    mon.setCursorPos(x, y)
    mon.write(string.rep(" ", w))
end

-- Draw text at position
local function txt(mon, x, y, text, color)
    mon.setCursorPos(x, y)
    mon.setTextColor(color or C_TEXT)
    mon.setBackgroundColor(C_BG)
    mon.write(text)
end

-- Draw text with background
local function txtbg(mon, x, y, text, fg, bg)
    mon.setCursorPos(x, y)
    mon.setTextColor(fg)
    mon.setBackgroundColor(bg)
    mon.write(text)
    mon.setBackgroundColor(C_BG)
end

-- Fill a rectangle
local function fill(mon, x, y, w, h, color)
    mon.setBackgroundColor(color)
    for dy = 0, h - 1 do
        mon.setCursorPos(x, y + dy)
        mon.write(string.rep(" ", w))
    end
    mon.setBackgroundColor(C_BG)
end

-- Centered text in a region
local function centered(mon, x, y, w, text, color)
    local padding = math.floor((w - #text) / 2)
    if padding < 0 then padding = 0 end
    txt(mon, x + padding, y, text, color)
end

-- Truncated or padded text
local function rpad(text, width)
    if #text >= width then return text:sub(1, width) end
    return text .. string.rep(" ", width - #text)
end

local function lpad(text, width)
    if #text >= width then return text:sub(1, width) end
    return string.rep(" ", width - #text) .. text
end

-- Bar made of block characters
local function bar(val, max_val, width)
    local ratio = math.max(0, math.min(1, val / max_val))
    local filled = math.floor(ratio * width + 0.5)
    local empty = width - filled
    return string.rep(string.char(219), filled) .. string.rep(string.char(176), empty)
end

-- ============================================================
-- Draw frame: border + blue stripe separator
-- ============================================================

local function drawFrame(mon)
    -- Top border
    hline(mon, 1, 1, MON_W, C_BORDER)
    -- Bottom border
    hline(mon, 1, MON_H, MON_W, C_BORDER)
    -- Left border
    for y = 2, MON_H - 1 do
        pixel(mon, 1, y, C_BORDER)
    end
    -- Right border
    for y = 2, MON_H - 1 do
        pixel(mon, MON_W, y, C_BORDER)
    end
    -- Blue stripe
    fill(mon, ST_X, 2, ST_W, MON_H - 2, C_STRIPE)
end

-- ============================================================
-- Tab definitions
-- ============================================================

local tabs = {
    { id = "flight",  label = "FLT" },
    { id = "engine",  label = "ENG" },
    { id = "systems", label = "SYS" },
}

-- ============================================================
-- Blue stripe: tab labels
-- ============================================================

local function drawStripe(mon)
    -- Title at top of stripe
    centered(mon, ST_X, 2, ST_W, "ART", C_BRIGHT)
    centered(mon, ST_X, 3, ST_W, "CORP", C_BRIGHT)

    -- Separator line
    hline(mon, ST_X, 4, ST_W, C_DIM)

    -- Tab list
    for i, tab in ipairs(tabs) do
        local y = 5 + (i - 1) * 2
        if tab.id == active_tab then
            txtbg(mon, ST_X + 1, y, rpad(">" .. tab.label, ST_W - 2), C_BRIGHT, C_STRIPE)
        else
            txtbg(mon, ST_X + 1, y, rpad(" " .. tab.label, ST_W - 2), C_DIM, C_STRIPE)
        end
    end

    -- Separator line
    hline(mon, ST_X, 12, ST_W, C_DIM)
end

-- ============================================================
-- Left panel: tab content
-- ============================================================

local function drawFlightTab(mon)
    local x, w = LP_X, LP_W

    -- Altitude
    txt(mon, x, 2, "ALTITUDE", C_DIM)
    txt(mon, x, 3, lpad(string.format("%.1f", 0), 10), C_ACCENT)
    txt(mon, x + 11, 3, "m", C_DIM)

    -- Speed
    txt(mon, x, 5, "SPEED", C_DIM)
    txt(mon, x, 6, lpad(string.format("%.1f", 0), 10), C_ACCENT)
    txt(mon, x + 11, 6, "m/s", C_DIM)

    -- Climb
    txt(mon, x, 8, "CLIMB", C_DIM)
    txt(mon, x, 9, lpad(string.format("%+.1f", 0), 10), C_GOOD)

    -- Mode
    txt(mon, x, 11, "MODE", C_DIM)
    txt(mon, x, 12, "HOVER", C_GOOD)

    -- PID output bars
    txt(mon, x, 14, "PID OUTPUT", C_DIM)
    txt(mon, x, 15, "P " .. bar(0, 15, 16), C_GOOD)
    txt(mon, x, 16, "R " .. bar(0, 15, 16), C_GOOD)
    txt(mon, x, 17, "Y " .. bar(0, 15, 16), C_GOOD)
end

local function drawFlightTabData(mon, status)
    local x, w = LP_X, LP_W

    local alt = status.altitude or 0
    local tgt = status.target_altitude or 0
    local spd = status.speed or 0
    local climb = status.climb_rate or 0
    local mode = status.mode or "???"
    local outputs = status.outputs or {}

    -- Altitude
    txt(mon, x, 2, "ALTITUDE", C_DIM)
    txt(mon, x, 3, lpad(string.format("%.1f", alt), 10), C_ACCENT)
    txt(mon, x + 11, 3, "/" .. string.format("%.0f", tgt), C_DIM)

    -- Speed
    txt(mon, x, 5, "SPEED", C_DIM)
    txt(mon, x, 6, lpad(string.format("%.1f", spd), 10), C_ACCENT)
    txt(mon, x + 11, 6, "m/s", C_DIM)

    -- Climb
    txt(mon, x, 8, "CLIMB", C_DIM)
    local cc = C_GOOD
    if climb < -2 then cc = C_BAD
    elseif climb < 0 then cc = C_WARN
    end
    txt(mon, x, 9, lpad(string.format("%+.1f", climb), 10), cc)

    -- Mode
    txt(mon, x, 11, "MODE", C_DIM)
    local mc = mode == "HOVER" and C_GOOD or C_WARN
    txt(mon, x, 12, rpad(mode, 10), mc)

    -- PID output bars
    txt(mon, x, 14, "PID OUTPUT", C_DIM)
    local pitch_tilt = outputs.FL_tilt or 0
    local roll_tilt = outputs.FR_tilt or 0
    local yaw_val = outputs.rear_fw or 0

    txt(mon, x, 15, "P " .. bar(math.abs(pitch_tilt), 15, 16), C_GOOD)
    txt(mon, x, 16, "R " .. bar(math.abs(roll_tilt), 15, 16), C_GOOD)
    txt(mon, x, 17, "Y " .. bar(yaw_val, 15, 16), C_GOOD)
end

local function drawEngineTab(mon)
    local x, w = LP_X, LP_W

    txt(mon, x, 2, "PROPELLERS", C_DIM)

    local props = {"FL", "FR", "RL", "RR"}
    for i, p in ipairs(props) do
        txt(mon, x, 3 + (i - 1) * 2, p, C_DIM)
    end

    txt(mon, x, 11, "REAR THRUST", C_DIM)
    txt(mon, x, 12, "FW", C_DIM)
    txt(mon, x, 14, "BW", C_DIM)

    -- Thrust bar placeholder
    txt(mon, x, 16, "TOTAL THRUST", C_DIM)
end

local function drawEngineTabData(mon, status)
    local x, w = LP_X, LP_W
    local outputs = status.outputs or {}

    txt(mon, x, 2, "PROPELLERS", C_DIM)

    local props = {"FL", "FR", "RL", "RR"}
    for i, p in ipairs(props) do
        local tilt = outputs[p .. "_tilt"] or 0
        local tc = C_GOOD
        if math.abs(tilt) > 8 then tc = C_BAD
        elseif math.abs(tilt) > 4 then tc = C_WARN
        end
        txt(mon, x, 3 + (i - 1) * 2, p .. " " .. string.format("%+5.1f", tilt), tc)
    end

    -- Rear thrusters
    txt(mon, x, 11, "REAR THRUST", C_DIM)
    txt(mon, x, 12, "FW " .. bar(outputs.rear_fw or 0, 15, 14), C_GOOD)
    txt(mon, x, 14, "BW " .. bar(outputs.rear_bw or 0, 15, 14), C_GOOD)

    -- Total thrust
    txt(mon, x, 16, "TOTAL THRUST", C_DIM)
    txt(mon, x, 17, bar(outputs.speed or 0, 15, 16), C_GOOD)
end

local function drawSystemsTab(mon)
    local x, w = LP_X, LP_W

    txt(mon, x, 2, "ATTITUDE", C_DIM)
    txt(mon, x, 3, "PITCH", C_DIM)
    txt(mon, x, 5, "ROLL", C_DIM)
    txt(mon, x, 7, "YAW", C_DIM)

    txt(mon, x, 9, "PID GAINS", C_DIM)
    txt(mon, x, 10, "ALT", C_DIM)
    txt(mon, x, 12, "PIT", C_DIM)
    txt(mon, x, 14, "ROL", C_DIM)
    txt(mon, x, 16, "YAW", C_DIM)
end

local function drawSystemsTabData(mon, status)
    local x, w = LP_X, LP_W

    -- Attitude
    txt(mon, x, 2, "ATTITUDE", C_DIM)

    local pitch = status.pitch or 0
    local pc = C_GOOD
    if math.abs(pitch) > 10 then pc = C_BAD
    elseif math.abs(pitch) > 5 then pc = C_WARN
    end
    txt(mon, x, 3, string.format("%+7.1f", pitch), pc)

    local roll = status.roll or 0
    local rc = C_GOOD
    if math.abs(roll) > 10 then rc = C_BAD
    elseif math.abs(roll) > 5 then rc = C_WARN
    end
    txt(mon, x, 5, string.format("%+7.1f", roll), rc)

    txt(mon, x, 7, string.format("%+7.1f", status.yaw or 0), C_TEXT)

    -- PID gains
    txt(mon, x, 9, "PID GAINS", C_DIM)

    local pid = {
        { label = "ALT", gains = (status.pid_gains or {}).altitude },
        { label = "PIT", gains = (status.pid_gains or {}).pitch },
        { label = "ROL", gains = (status.pid_gains or {}).roll },
        { label = "YAW", gains = (status.pid_gains or {}).yaw },
    }

    for i, p in ipairs(pid) do
        local g = p.gains or {}
        txt(mon, x, 9 + i * 2,
            string.format("K%.1f I%.2f D%.1f",
                g.kp or 0, g.ki or 0, g.kd or 0), C_TEXT)
    end
end

-- ============================================================
-- Right panel: summary values
-- ============================================================

local function drawRightPanel(mon, status)
    local x, w = RP_X, RP_W

    -- Alt
    txt(mon, x, 2, "ALT", C_DIM)
    txt(mon, x, 3, lpad(string.format("%.0f", status.altitude or 0), 6), C_ACCENT)

    -- SPD
    txt(mon, x, 5, "SPD", C_DIM)
    txt(mon, x, 6, lpad(string.format("%.0f", status.speed or 0), 6), C_ACCENT)

    -- CLB
    txt(mon, x, 8, "CLB", C_DIM)
    local climb = status.climb_rate or 0
    local cc = C_GOOD
    if climb < -2 then cc = C_BAD elseif climb < 0 then cc = C_WARN end
    txt(mon, x, 9, lpad(string.format("%+.0f", climb), 6), cc)

    -- MODE
    txt(mon, x, 11, "MODE", C_DIM)
    local mode = status.mode or "???"
    txt(mon, x, 12, rpad(mode:sub(1, 6), 6), mode == "HOVER" and C_GOOD or C_WARN)

    -- THR
    txt(mon, x, 14, "THR", C_DIM)
    local thr = status.outputs or {}
    txt(mon, x, 15, lpad(string.format("%.0f", (thr.speed or 0) / 15 * 100), 5) .. "%", C_GOOD)
end

-- ============================================================
-- Main render
-- ============================================================

function HUD.render(mon, status, config, status_msg)
    if not mon then return end
    setup(mon)

    drawFrame(mon)
    drawStripe(mon)

    -- Left panel content
    if active_tab == "flight" then
        drawFlightTabData(mon, status)
    elseif active_tab == "engine" then
        drawEngineTabData(mon, status)
    elseif active_tab == "systems" then
        drawSystemsTabData(mon, status)
    end

    -- Right panel summary
    drawRightPanel(mon, status)
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
