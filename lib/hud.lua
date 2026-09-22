local HUD = {}

local MON_W, MON_H = 48, 20
local SCALE = 0.5

local function ensureMonitor(mon)
    if not mon then return false end
    pcall(function()
        mon.setTextScale(SCALE)
    end)
    return true
end

local function clear(mon)
    mon.setBackgroundColor(colors.black)
    mon.setTextColor(colors.white)
    mon.clear()
    mon.setCursorPos(1, 1)
end

local function drawBox(mon, x, y, w, h, color)
    mon.setBackgroundColor(color)
    for dy = 0, h - 1 do
        mon.setCursorPos(x, y + dy)
        mon.write(string.rep(" ", w))
    end
    mon.setBackgroundColor(colors.black)
end

local function drawText(mon, x, y, text, fg, bg)
    mon.setCursorPos(x, y)
    if fg then mon.setTextColor(fg) end
    if bg then
        mon.setBackgroundColor(bg)
        mon.write(text)
        mon.setBackgroundColor(colors.black)
    else
        mon.write(text)
    end
end

local function drawHLine(mon, x, y, w, color)
    mon.setBackgroundColor(color)
    mon.setCursorPos(x, y)
    mon.write(string.rep(" ", w))
    mon.setBackgroundColor(colors.black)
end

local function drawVLine(mon, x, y, h, color)
    mon.setBackgroundColor(color)
    for dy = 0, h - 1 do
        mon.setCursorPos(x, y + dy)
        mon.write(" ")
    end
    mon.setBackgroundColor(colors.black)
end

local function bar(value, max_val, width)
    local ratio = math.max(0, math.min(1, value / max_val))
    local filled = math.floor(ratio * width + 0.5)
    local empty = width - filled
    return string.rep(string.char(219), filled) .. string.rep(string.char(176), empty)
end

local function alignRight(text, width)
    if #text >= width then return text:sub(1, width) end
    return string.rep(" ", width - #text) .. text
end

function HUD.render(mon, status, config, status_msg)
    if not ensureMonitor(mon) then return end
    clear(mon)

    local alt = status.altitude or 0
    local tgt_alt = status.target_altitude or 0
    local pitch = status.pitch or 0
    local roll = status.roll or 0
    local yaw = status.yaw or 0
    local spd = status.speed or 0
    local climb = status.climb_rate or 0
    local mode = status.mode or "???"
    local outputs = status.outputs or {}
    local gains = status.pid_gains or {}

    -- Title bar
    drawBox(mon, 1, 1, MON_W, 1, colors.blue)
    drawText(mon, 2, 1, "ARTCORPOS", colors.white, colors.blue)
    drawText(mon, 30, 1, mode, colors.yellow, colors.blue)

    -- Altitude column (left side)
    local alt_x = 2
    drawText(mon, alt_x, 3, "ALT", colors.cyan)
    drawText(mon, alt_x, 4, string.format("%5.0f", alt), colors.white)
    drawText(mon, alt_x + 6, 4, "/" .. string.format("%.0f", tgt_alt), colors.gray)

    local alt_bar_w = 20
    local alt_diff = tgt_alt - alt
    local alt_bar_val = 10 + alt_diff * 0.5
    drawText(mon, alt_x, 6, "ALT", colors.gray)
    drawHLine(mon, alt_x, 7, alt_bar_w, colors.darkGray)
    local filled = math.floor(math.max(0, math.min(alt_bar_val, 20)))
    for i = 1, filled do
        drawText(mon, alt_x + i - 1, 7, string.char(219), colors.green)
    end

    -- Speed column
    local spd_x = 15
    drawText(mon, spd_x, 3, "SPD", colors.cyan)
    drawText(mon, spd_x, 4, string.format("%5.0f", spd), colors.white)
    drawText(mon, spd_x, 5, "m/s", colors.gray)

    -- Climb rate
    drawText(mon, spd_x, 7, "CLB", colors.cyan)
    local climb_color = colors.green
    if climb < -2 then climb_color = colors.red
    elseif climb < 0 then climb_color = colors.yellow
    end
    drawText(mon, spd_x, 8, string.format("%+5.1f", climb), climb_color)

    -- Attitude indicator (center)
    local att_x = 26
    local att_y = 3
    drawText(mon, att_x, att_y, "--- ATTITUDE ---", colors.white)

    local pitch_bar = string.rep("=", 20)
    local roll_bar = string.rep("=", 20)

    drawText(mon, att_x, att_y + 2, "P:", colors.gray)
    local p_str = string.format("%+6.1f", pitch)
    local p_color = colors.green
    if math.abs(pitch) > 10 then p_color = colors.red
    elseif math.abs(pitch) > 5 then p_color = colors.yellow
    end
    drawText(mon, att_x + 3, att_y + 2, p_str, p_color)

    drawText(mon, att_x, att_y + 3, "R:", colors.gray)
    local r_str = string.format("%+6.1f", roll)
    local r_color = colors.green
    if math.abs(roll) > 10 then r_color = colors.red
    elseif math.abs(roll) > 5 then r_color = colors.yellow
    end
    drawText(mon, att_x + 3, att_y + 3, r_str, r_color)

    drawText(mon, att_x, att_y + 4, "Y:", colors.gray)
    drawText(mon, att_x + 3, att_y + 4, string.format("%+7.1f", yaw), colors.white)

    -- Output signals
    local out_x = 26
    local out_y = 8
    drawText(mon, out_x, out_y, "--- OUTPUTS ---", colors.white)

    drawText(mon, out_x, out_y + 1, "THR:", colors.gray)
    drawText(mon, out_x + 5, out_y + 1, bar(outputs.speed or 0, 15, 8), colors.green)

    local tilt_labels = {"FL", "FR", "RL", "RR"}
    for i, label in ipairs(tilt_labels) do
        local tilt_val = outputs[label .. "_tilt"] or 0
        local tilt_color = colors.green
        if math.abs(tilt_val) > 8 then tilt_color = colors.red
        elseif math.abs(tilt_val) > 4 then tilt_color = colors.yellow
        end
        drawText(mon, out_x, out_y + 1 + i, label .. ":", colors.gray)
        drawText(mon, out_x + 5, out_y + 1 + i, string.format("%+5.1f", tilt_val), tilt_color)
    end

    drawText(mon, out_x, out_y + 6, "RFW:", colors.gray)
    drawText(mon, out_x + 5, out_y + 6, bar(outputs.rear_fw or 0, 15, 8), colors.green)
    drawText(mon, out_x, out_y + 7, "RBW:", colors.gray)
    drawText(mon, out_x + 5, out_y + 7, bar(outputs.rear_bw or 0, 15, 8), colors.green)

    -- PID gains (right sidebar)
    local pid_x = 39
    local pid_y = 3
    drawText(mon, pid_x, pid_y, "--- PID ---", colors.white)

    local pid_labels = {"altitude", "pitch", "roll", "yaw"}
    local pid_short = {"ALT", "PIT", "ROL", "YAW"}
    for i, key in ipairs(pid_labels) do
        local g = gains[key] or {}
        drawText(mon, pid_x, pid_y + 1 + i, pid_short[i], colors.gray)
        drawText(mon, pid_x + 4, pid_y + 1 + i,
            string.format("K%.1f I%.2f D%.1f",
                g.kp or 0, g.ki or 0, g.kd or 0), colors.white)
    end

    -- Status line
    if status_msg and status_msg ~= "" then
        drawBox(mon, 1, MON_H, MON_W, 1, colors.yellow)
        drawText(mon, 2, MON_H, status_msg, colors.black, colors.yellow)
    else
        drawBox(mon, 1, MON_H, MON_W, 1, colors.darkGray)
        local fuel_str = ""
        if config and config.fuel then
            fuel_str = string.format(" | FUEL: %s %ds",
                config.fuel.type or "?",
                config.fuel.tank_capacity or 0)
        end
        drawText(mon, 2, MON_H, "HOLD:Q/E | MODE:M | STOP:X" .. fuel_str, colors.lightGray, colors.darkGray)
    end
end

return HUD
