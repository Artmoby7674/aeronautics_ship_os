local HUD = {}

-- 3x2 monitor at scale 0.5 = 48x20 chars
local MON_W, MON_H = 48, 20
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

-- Layout: 1-char border, content fills the rest
-- Left panel: cols 2-33 (32 chars)
-- Stripe: cols 34-35 (2 chars)
-- Right panel: cols 36-47 (12 chars)
-- Rows 2-19 (18 rows)
local LP_X, LP_W = 2, 32
local ST_X, ST_W = 34, 2
local RP_X, RP_W = 36, 12

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

local function txtbg(mon, x, y, text, fg, bg)
    mon.setCursorPos(x, y)
    mon.setTextColor(fg)
    mon.setBackgroundColor(bg)
    mon.write(text)
    mon.setBackgroundColor(C_BG)
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
    -- Top border
    hline(mon, 1, 1, MON_W, C_BORDER)
    -- Bottom border
    hline(mon, 1, MON_H, MON_W, C_BORDER)
    -- Left border
    for y = 2, MON_H - 1 do pixel(mon, 1, y, C_BORDER) end
    -- Right border
    for y = 2, MON_H - 1 do pixel(mon, MON_W, y, C_BORDER) end
    -- Thin vertical stripe
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
        local y = 6 + (i - 1) * 2
        if id == active_tab then
            txtbg(mon, ST_X, y, ">", C_BRIGHT, C_STRIPE)
        else
            txtbg(mon, ST_X, y, " ", C_DIM, C_BG)
        end
        txtbg(mon, ST_X + 1, y, tab_labels[i], id == active_tab and C_BRIGHT or C_DIM, C_BG)
    end
end

-- ============================================================
-- Left panel: tab content
-- ============================================================

local function drawFlight(mon, s)
    local x = LP_X
    local o = s.outputs or {}

    txt(mon, x, 2, "ALT", C_DIM)
    txt(mon, x + 4, 2, lpad(string.format("%.1f", s.altitude or 0), 8), C_ACCENT)
    txt(mon, x + 13, 2, "/" .. string.format("%.0f", s.target_altitude or 0), C_DIM)

    txt(mon, x, 4, "SPD", C_DIM)
    txt(mon, x + 4, 4, lpad(string.format("%.1f", s.speed or 0), 8), C_ACCENT)
    txt(mon, x + 13, 4, "m/s", C_DIM)

    txt(mon, x, 6, "CLB", C_DIM)
    local clb = s.climb_rate or 0
    local cc = C_GOOD
    if clb < -2 then cc = C_BAD elseif clb < 0 then cc = C_WARN end
    txt(mon, x + 4, 6, lpad(string.format("%+.1f", clb), 8), cc)

    txt(mon, x, 8, "MOD", C_DIM)
    local mode = s.mode or "???"
    txt(mon, x + 4, 8, rpad(mode, 8), mode == "HOVER" and C_GOOD or C_WARN)

    txt(mon, x, 10, "THRUST", C_DIM)
    hline(mon, x, 11, 20, C_DIM)
    txt(mon, x, 11, bar(o.speed or 0, 15, 20), C_GOOD)

    txt(mon, x, 13, "TILT", C_DIM)
    local labels = {"FL", "FR", "RL", "RR"}
    for i, p in ipairs(labels) do
        local t = o[p .. "_tilt"] or 0
        local tc = C_GOOD
        if math.abs(t) > 8 then tc = C_BAD elseif math.abs(t) > 4 then tc = C_WARN end
        txt(mon, x, 13 + i, p, C_DIM)
        txt(mon, x + 3, 13 + i, string.format("%+5.1f", t), tc)
    end
end

local function drawEngine(mon, s)
    local x = LP_X
    local o = s.outputs or {}

    txt(mon, x, 2, "PROPELLERS", C_DIM)
    hline(mon, x, 3, 28, C_DIM)

    local labels = {"FL", "FR", "RL", "RR"}
    for i, p in ipairs(labels) do
        local t = o[p .. "_tilt"] or 0
        local tc = C_GOOD
        if math.abs(t) > 8 then tc = C_BAD elseif math.abs(t) > 4 then tc = C_WARN end
        txt(mon, x, 4 + (i - 1) * 2, p .. " " .. string.format("%+6.1f", t), tc)
    end

    txt(mon, x, 12, "REAR", C_DIM)
    hline(mon, x, 13, 28, C_DIM)
    txt(mon, x, 14, "FW " .. bar(o.rear_fw or 0, 15, 16), C_GOOD)
    txt(mon, x, 16, "BW " .. bar(o.rear_bw or 0, 15, 16), C_GOOD)

    txt(mon, x, 18, "TOTAL " .. bar(o.speed or 0, 15, 18), C_GOOD)
end

local function drawSystems(mon, s)
    local x = LP_X

    txt(mon, x, 2, "ATTITUDE", C_DIM)
    hline(mon, x, 3, 28, C_DIM)

    local pitch = s.pitch or 0
    local pc = C_GOOD
    if math.abs(pitch) > 10 then pc = C_BAD elseif math.abs(pitch) > 5 then pc = C_WARN end
    txt(mon, x, 4, "P " .. string.format("%+7.1f", pitch), pc)

    local roll = s.roll or 0
    local rc = C_GOOD
    if math.abs(roll) > 10 then rc = C_BAD elseif math.abs(roll) > 5 then rc = C_WARN end
    txt(mon, x, 6, "R " .. string.format("%+7.1f", roll), rc)

    txt(mon, x, 8, "Y " .. string.format("%+7.1f", s.yaw or 0), C_TEXT)

    txt(mon, x, 10, "PID GAINS", C_DIM)
    hline(mon, x, 11, 28, C_DIM)

    local pid = {
        {"ALT", (s.pid_gains or {}).altitude},
        {"PIT", (s.pid_gains or {}).pitch},
        {"ROL", (s.pid_gains or {}).roll},
        {"YAW", (s.pid_gains or {}).yaw},
    }
    for i, p in ipairs(pid) do
        local g = p[2] or {}
        txt(mon, x, 11 + i * 2, p[1] .. " K" .. string.format("%.1f", g.kp or 0) ..
            " I" .. string.format("%.2f", g.ki or 0) ..
            " D" .. string.format("%.1f", g.kd or 0), C_TEXT)
    end
end

-- ============================================================
-- Right panel: compact summary
-- ============================================================

local function drawRight(mon, s)
    local x = RP_X

    txt(mon, x, 2, "ALT", C_DIM)
    txt(mon, x, 3, lpad(string.format("%.0f", s.altitude or 0), RP_W), C_ACCENT)

    txt(mon, x, 5, "SPD", C_DIM)
    txt(mon, x, 6, lpad(string.format("%.0f", s.speed or 0), RP_W), C_ACCENT)

    txt(mon, x, 8, "CLB", C_DIM)
    local clb = s.climb_rate or 0
    local cc = C_GOOD
    if clb < -2 then cc = C_BAD elseif clb < 0 then cc = C_WARN end
    txt(mon, x, 9, lpad(string.format("%+.0f", clb), RP_W), cc)

    txt(mon, x, 11, "MOD", C_DIM)
    local mode = s.mode or "???"
    txt(mon, x, 12, rpad(mode:sub(1, RP_W), RP_W), mode == "HOVER" and C_GOOD or C_WARN)

    txt(mon, x, 14, "THR", C_DIM)
    local thr = s.outputs or {}
    local pct = math.floor((thr.speed or 0) / 15 * 100 + 0.5)
    txt(mon, x, 15, lpad(pct .. "%", RP_W), C_GOOD)

    txt(mon, x, 17, "YAW", C_DIM)
    txt(mon, x, 18, lpad(string.format("%.0f", s.yaw or 0), RP_W), C_TEXT)
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

function HUD.setTab(id)
    active_tab = id
end

function HUD.getTab()
    return active_tab
end

return HUD
