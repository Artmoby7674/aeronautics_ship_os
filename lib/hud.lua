local HUD = {}

-- 3x2 monitor at scale 0.5 = 57x26 chars
local MON_W, MON_H = 57, 26
local SCALE = 0.5

-- Colors
local C_BORDER  = colors.cyan
local C_STRIPE  = colors.cyan
local C_BG      = colors.black
local C_TITLE   = colors.white
local C_TEXT    = colors.lightBlue
local C_DIM     = colors.gray
local C_BRIGHT  = colors.white
local C_GOOD    = colors.green
local C_WARN    = colors.yellow
local C_BAD     = colors.red
local C_ACCENT  = colors.cyan

-- Layout: 1-char border, content fills 57x26
-- Left panel: cols 2-40 (39 chars)
-- Stripe: cols 41-42 (2 chars)
-- Right panel: cols 43-56 (14 chars)
-- Rows 2-25 (24 rows)
local LP_X, LP_W = 2, 39
local ST_X, ST_W = 41, 2
local RP_X, RP_W = 43, 14

local active_tab = "flight"

local function setup(mon)
    pcall(function() mon.setTextScale(SCALE) end)
    mon.setBackgroundColor(C_BG)
    mon.clear()
end

local function txt(mon, x, y, text, color)
    mon.setCursorPos(x, y)
    mon.setTextColor(color or C_TEXT)
    mon.setBackgroundColor(C_BG)
    mon.write(text)
end

local function hline(mon, x, y, w, color)
    mon.setBackgroundColor(color)
    mon.setCursorPos(x, y)
    mon.write(string.rep(" ", w))
    mon.setBackgroundColor(C_BG)
end

local function pixel(mon, x, y, color)
    mon.setBackgroundColor(color)
    mon.setCursorPos(x, y)
    mon.write(" ")
    mon.setBackgroundColor(C_BG)
end

local function fill(mon, x, y, w, h, color)
    mon.setBackgroundColor(color)
    for dy = 0, h - 1 do
        mon.setCursorPos(x, y + dy)
        mon.write(string.rep(" ", w))
    end
    mon.setBackgroundColor(C_BG)
end

local function rpad(text, width)
    if #text >= width then return text:sub(1, width) end
    return text .. string.rep(" ", width - #text)
end

local function lpad(text, width)
    if #text >= width then return text:sub(1, width) end
    return string.rep(" ", width - #text) .. text
end

local function centered(mon, x, y, w, text, color)
    local pad = math.floor((w - #text) / 2)
    if pad < 0 then pad = 0 end
    txt(mon, x + pad, y, text, color)
end

local function bar(val, max_val, width)
    local ratio = math.max(0, math.min(1, val / max_val))
    local filled = math.floor(ratio * width + 0.5)
    return string.rep(string.char(219), filled) .. string.rep(string.char(176), width - filled)
end

-- ============================================================
-- Frame: thin cyan border + vertical stripe
-- ============================================================

local function drawFrame(mon)
    hline(mon, 1, 1, MON_W, C_BORDER)
    hline(mon, 1, MON_H, MON_W, C_BORDER)
    for y = 2, MON_H - 1 do pixel(mon, 1, y, C_BORDER) end
    for y = 2, MON_H - 1 do pixel(mon, MON_W, y, C_BORDER) end
    for y = 2, MON_H - 1 do
        pixel(mon, ST_X, y, C_STRIPE)
        pixel(mon, ST_X + 1, y, C_STRIPE)
    end
end

-- ============================================================
-- Stripe: title + tabs
-- ============================================================

local function drawStripe(mon)
    centered(mon, ST_X, 2, ST_W, "A", C_BRIGHT)
    centered(mon, ST_X, 3, ST_W, "C", C_BRIGHT)
    centered(mon, ST_X, 4, ST_W, "O", C_DIM)

    local tab_ids = {"flight", "engine", "systems"}
    local tab_labels = {"F", "E", "S"}
    for i, id in ipairs(tab_ids) do
        local y = 7 + (i - 1) * 3
        if id == active_tab then
            pixel(mon, ST_X, y, C_STRIPE)
            pixel(mon, ST_X + 1, y, C_STRIPE)
            txt(mon, ST_X, y + 1, ">", C_BRIGHT)
        else
            txt(mon, ST_X, y + 1, " ", C_DIM)
        end
        txt(mon, ST_X + 1, y + 1, tab_labels[i], id == active_tab and C_BRIGHT or C_DIM)
    end
end

-- ============================================================
-- Left panel: tab content
-- ============================================================

local function drawFlight(mon, s)
    local x = LP_X
    local o = s.outputs or {}
    local row = 2

    txt(mon, x, row, "ALTITUDE", C_DIM)
    row = row + 1
    txt(mon, x, row, lpad(string.format("%.1f", s.altitude or 0), 12), C_ACCENT)
    txt(mon, x + 13, row, "/" .. string.format("%.0f", s.target_altitude or 0), C_DIM)
    row = row + 2

    txt(mon, x, row, "SPEED", C_DIM)
    row = row + 1
    txt(mon, x, row, lpad(string.format("%.1f", s.speed or 0), 12), C_ACCENT)
    txt(mon, x + 13, row, "m/s", C_DIM)
    row = row + 2

    txt(mon, x, row, "CLIMB", C_DIM)
    row = row + 1
    local clb = s.climb_rate or 0
    local cc = C_GOOD
    if clb < -2 then cc = C_BAD elseif clb < 0 then cc = C_WARN end
    txt(mon, x, row, lpad(string.format("%+.1f", clb), 12), cc)
    row = row + 2

    txt(mon, x, row, "MODE", C_DIM)
    row = row + 1
    local mode = s.mode or "???"
    txt(mon, x, row, rpad(mode, 12), mode == "HOVER" and C_GOOD or C_WARN)
    row = row + 3

    txt(mon, x, row, "THRUST", C_DIM)
    row = row + 1
    hline(mon, x, row, LP_W, C_DIM)
    row = row + 1
    txt(mon, x, row, bar(o.speed or 0, 15, LP_W), C_GOOD)
    row = row + 2

    txt(mon, x, row, "TILT", C_DIM)
    row = row + 1
    local labels = {"FL", "FR", "RL", "RR"}
    for i, p in ipairs(labels) do
        local t = o[p .. "_tilt"] or 0
        local tc = C_GOOD
        if math.abs(t) > 8 then tc = C_BAD elseif math.abs(t) > 4 then tc = C_WARN end
        txt(mon, x, row, p, C_DIM)
        txt(mon, x + 3, row, string.format("%+6.1f", t), tc)
        row = row + 1
    end
    row = row + 1

    txt(mon, x, row, "REAR", C_DIM)
    row = row + 1
    txt(mon, x, row, "FW " .. bar(o.rear_fw or 0, 15, LP_W - 4), C_GOOD)
    row = row + 1
    txt(mon, x, row, "BW " .. bar(o.rear_bw or 0, 15, LP_W - 4), C_GOOD)
end

local function drawEngine(mon, s)
    local x = LP_X
    local o = s.outputs or {}
    local row = 2

    txt(mon, x, row, "PROPELLERS", C_DIM)
    row = row + 1
    hline(mon, x, row, LP_W, C_DIM)
    row = row + 2

    local labels = {"FL", "FR", "RL", "RR"}
    for i, p in ipairs(labels) do
        local t = o[p .. "_tilt"] or 0
        local tc = C_GOOD
        if math.abs(t) > 8 then tc = C_BAD elseif math.abs(t) > 4 then tc = C_WARN end
        txt(mon, x, row, p .. " " .. string.format("%+8.1f", t), tc)
        row = row + 2
    end
    row = row + 1

    txt(mon, x, row, "REAR THRUST", C_DIM)
    row = row + 1
    hline(mon, x, row, LP_W, C_DIM)
    row = row + 1
    txt(mon, x, row, "FW " .. bar(o.rear_fw or 0, 15, LP_W - 4), C_GOOD)
    row = row + 2
    txt(mon, x, row, "BW " .. bar(o.rear_bw or 0, 15, LP_W - 4), C_GOOD)
    row = row + 2

    txt(mon, x, row, "TOTAL THRUST", C_DIM)
    row = row + 1
    txt(mon, x, row, bar(o.speed or 0, 15, LP_W), C_GOOD)
end

local function drawSystems(mon, s)
    local x = LP_X
    local row = 2

    txt(mon, x, row, "ATTITUDE", C_DIM)
    row = row + 1
    hline(mon, x, row, LP_W, C_DIM)
    row = row + 2

    local pitch = s.pitch or 0
    local pc = C_GOOD
    if math.abs(pitch) > 10 then pc = C_BAD elseif math.abs(pitch) > 5 then pc = C_WARN end
    txt(mon, x, row, "PITCH " .. string.format("%+8.1f", pitch), pc)
    row = row + 2

    local roll = s.roll or 0
    local rc = C_GOOD
    if math.abs(roll) > 10 then rc = C_BAD elseif math.abs(roll) > 5 then rc = C_WARN end
    txt(mon, x, row, "ROLL  " .. string.format("%+8.1f", roll), rc)
    row = row + 2

    txt(mon, x, row, "YAW   " .. string.format("%+8.1f", s.yaw or 0), C_TEXT)
    row = row + 3

    txt(mon, x, row, "PID GAINS", C_DIM)
    row = row + 1
    hline(mon, x, row, LP_W, C_DIM)
    row = row + 2

    local pid = {
        {"ALT", (s.pid_gains or {}).altitude},
        {"PIT", (s.pid_gains or {}).pitch},
        {"ROL", (s.pid_gains or {}).roll},
        {"YAW", (s.pid_gains or {}).yaw},
    }
    for _, p in ipairs(pid) do
        local g = p[2] or {}
        txt(mon, x, row, p[1] .. " K" .. string.format("%.1f", g.kp or 0) ..
            " I" .. string.format("%.2f", g.ki or 0) ..
            " D" .. string.format("%.1f", g.kd or 0), C_TEXT)
        row = row + 2
    end
end

-- ============================================================
-- Right panel: compact summary
-- ============================================================

local function drawRight(mon, s)
    local x = RP_X
    local row = 2

    txt(mon, x, row, "ALT", C_DIM)
    row = row + 1
    txt(mon, x, row, lpad(string.format("%.0f", s.altitude or 0), RP_W), C_ACCENT)
    row = row + 2

    txt(mon, x, row, "SPD", C_DIM)
    row = row + 1
    txt(mon, x, row, lpad(string.format("%.0f", s.speed or 0), RP_W), C_ACCENT)
    row = row + 2

    txt(mon, x, row, "CLB", C_DIM)
    row = row + 1
    local clb = s.climb_rate or 0
    local cc = C_GOOD
    if clb < -2 then cc = C_BAD elseif clb < 0 then cc = C_WARN end
    txt(mon, x, row, lpad(string.format("%+.0f", clb), RP_W), cc)
    row = row + 2

    txt(mon, x, row, "MOD", C_DIM)
    row = row + 1
    local mode = s.mode or "???"
    txt(mon, x, row, rpad(mode:sub(1, RP_W), RP_W), mode == "HOVER" and C_GOOD or C_WARN)
    row = row + 2

    txt(mon, x, row, "THR", C_DIM)
    row = row + 1
    local thr = s.outputs or {}
    local pct = math.floor((thr.speed or 0) / 15 * 100 + 0.5)
    txt(mon, x, row, lpad(pct .. "%", RP_W), C_GOOD)
    row = row + 2

    txt(mon, x, row, "YAW", C_DIM)
    row = row + 1
    txt(mon, x, row, lpad(string.format("%.0f", s.yaw or 0), RP_W), C_TEXT)
    row = row + 2

    txt(mon, x, row, "PIT", C_DIM)
    row = row + 1
    txt(mon, x, row, lpad(string.format("%.0f", s.pitch or 0), RP_W), C_TEXT)
    row = row + 2

    txt(mon, x, row, "ROL", C_DIM)
    row = row + 1
    txt(mon, x, row, lpad(string.format("%.0f", s.roll or 0), RP_W), C_TEXT)
end

-- ============================================================
-- Main render
-- ============================================================

function HUD.render(mon, status, config, status_msg)
    if not mon then return end
    setup(mon)
    drawFrame(mon)
    drawStripe(mon)

    if active_tab == "flight" then
        drawFlight(mon, status)
    elseif active_tab == "engine" then
        drawEngine(mon, status)
    elseif active_tab == "systems" then
        drawSystems(mon, status)
    end

    drawRight(mon, status)
end

function HUD.nextTab()
    local tabs = {"flight", "engine", "systems"}
    for i, id in ipairs(tabs) do
        if id == active_tab then
            active_tab = tabs[(i % #tabs) + 1]
            return
        end
    end
end

function HUD.setTab(id) active_tab = id end
function HUD.getTab() return active_tab end

return HUD
