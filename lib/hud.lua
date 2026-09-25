-- ArtCorpOS HUD - CC:Graphics mode 2 (256 colors)
-- Layout: left content panel, right vertical tab strip.
-- Coordinates are 0-based pixels. Design canvas: 348x216 (58x24 chars @ scale 0.5).

local function loadLib(name)
    local ok, mod = pcall(require, name)
    if ok then return mod end
    local path = (name:gsub("%.", "/")) .. ".lua"
    local fn = loadfile(path)
    if fn then
        local ok2, res = pcall(fn)
        if ok2 then return res end
        error(res, 0)
    end
    error(mod, 0)
end

local Gfx = loadLib("lib.gfx")
local Font = loadLib("lib.font")

local HUD = {}

local SCALE = 0.5

local C = {
    bg       = 15,
    panel    = 7,
    border   = 9,
    title    = 0,
    dim      = 8,
    text     = 3,
    accent   = 9,
    good     = 13,
    warn     = 4,
    bad      = 14,
    tab_on_bg  = 9,
    tab_on_fg  = 15,
    tab_off_bg = 7,
    tab_off_fg = 8,
    bar_bg   = 7,
    power_on   = 14, -- red
    power_off  = 8,  -- gray
    boot_bg    = 9,
    boot_fg    = 15,
}

local TABS = {
    { id = "flight",  label = "FLIGHT" },
    { id = "engines", label = "ENGINES" },
    { id = "systems", label = "SYSTEMS" },
    { id = "nav",     label = "NAV" },
    { id = "alarms",  label = "ALARMS" },
    { id = "actions", label = "ACTIONS" },
}

local active_tab = "flight"
local initialized = false
local chrome_dirty = true
local content_dirty = true
local power_dirty = true
local ship_label = "FLIGHT OS"
local render_config = nil -- last config passed to HUD.render (features for ACTIONS)

local L = {}

-- hit rects
local shutdown_rect = nil -- {x,y,w,h,armed}
local boot_rect = nil
local splash_active = false -- boot_rect only hit-tests on splash/boot screens

local function applyLayout()
    local W, H = Gfx.W, Gfx.H
    L.W, L.H = W, H
    L.border = 2
    L.header_h = 20
    L.strip_w = 72
    L.body_y = L.border + L.header_h + 4
    L.body_h = H - L.body_y - L.border - 2
    L.strip_x = W - L.border - L.strip_w
    L.content_x = L.border + 4
    L.content_w = L.strip_x - L.content_x - 4
    L.tab_h = 24
    L.tab_gap = 5
    L.tab_y0 = L.body_y + 4

    -- shutdown circle: top-left of header
    local d = 12
    shutdown_rect = { x = L.border + 4, y = L.border + 4, w = d, h = d, d = d }
    -- boot button under splash title (leave room for 3x logo + subtitle)
    local bw, bh = 64, 18
    boot_rect = {
        x = math.floor((W - bw) / 2),
        y = math.min(H - 70, math.floor(H * 0.58)),
        w = bw,
        h = bh,
    }
end

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

local function fit(str, w)
    return Font.fit(tostring(str or ""), w)
end

local function slotText(x, y, w, str, color, align)
    if w < 1 or x >= L.W then return end
    if y < 0 or y + Font.height > L.H then return end
    Gfx.fillRect(x, y, w, Font.height, C.bg)
    str = fit(str, w)
    if str == "" then return end
    local tw = Font.textWidth(str)
    local tx = x
    if align == "right" then
        tx = x + w - tw
    elseif align == "center" then
        tx = x + math.floor((w - tw) / 2)
    end
    if tx < x then tx = x end
    if tx + tw > x + w then tx = math.max(x, x + w - tw) end
    Gfx.text(tx, y, str, color or C.text)
end

local function drawBar(x, y, w, h, ratio, fg)
    Gfx.fillRect(x, y, w, h, C.bar_bg)
    local fill = math.floor(w * clamp(ratio or 0, 0, 1) + 0.5)
    if fill > 0 then
        Gfx.fillRect(x, y, fill, h, fg or C.good)
    end
end

local function label(x, y, str)
    local max_w = L.strip_x - 4 - x
    if max_w < 1 then return end
    Gfx.text(x, y, fit(str, max_w), C.dim)
end

local function tabRect(i)
    local y = L.tab_y0 + (i - 1) * (L.tab_h + L.tab_gap)
    return L.strip_x, y, L.strip_w, L.tab_h
end

local function inRect(rx, ry, rw, rh, x, y)
    return x >= rx and x < rx + rw and y >= ry and y < ry + rh
end

local function drawCircle(cx, cy, r, color)
    for dy = -r, r do
        for dx = -r, r do
            if dx * dx + dy * dy <= r * r then
                Gfx.fillRect(cx + dx, cy + dy, 1, 1, color)
            end
        end
    end
end

local function drawShutdownButton(landed)
    if not shutdown_rect then return end
    local r = shutdown_rect
    local cx = r.x + math.floor(r.w / 2)
    local cy = r.y + math.floor(r.h / 2)
    local rad = math.floor(r.d / 2) - 1
    local col = landed and C.power_on or C.power_off
    -- dark ring
    drawCircle(cx, cy, rad + 1, 15)
    drawCircle(cx, cy, rad, col)
    if landed then
        -- inner highlight
        drawCircle(cx, cy, math.max(1, rad - 3), 0)
        drawCircle(cx, cy, math.max(1, rad - 4), col)
    end
end

-- ============================================================
-- Splash / power screens
-- ============================================================

local function drawSplash(progress, booting)
    Gfx.clear(C.bg)
    local W, H = L.W, L.H

    -- thin frame
    Gfx.fillRect(0, 0, W, 2, C.border)
    Gfx.fillRect(0, H - 2, W, 2, C.border)
    Gfx.fillRect(0, 0, 2, H, C.border)
    Gfx.fillRect(W - 2, 0, 2, H, C.border)

    -- *ArtCorp* at 3x scale (bold double-strike)
    local title = "*ArtCorp*"
    local TITLE_SCALE = 3
    local tw = Font.textWidthScaled(title, TITLE_SCALE)
    local th = Font.height * TITLE_SCALE
    if tw > W - 16 then
        TITLE_SCALE = 2
        tw = Font.textWidthScaled(title, TITLE_SCALE)
        th = Font.height * TITLE_SCALE
    end
    local tx = math.floor((W - tw) / 2)
    local ty = math.floor(H * 0.22)
    -- drop shadow / bold
    Gfx.textScaled(tx + TITLE_SCALE, ty + TITLE_SCALE, title, C.accent, nil, TITLE_SCALE)
    Gfx.textScaled(tx, ty, title, C.title, nil, TITLE_SCALE)
    -- subtle accent edge
    Gfx.textScaled(tx - 1, ty - 1, title, C.accent, nil, TITLE_SCALE)

    -- subtitle: ship name when known (below the large title)
    local sub = ship_label or "FLIGHT OS"
    local sw = Font.textWidth(sub)
    Gfx.text(math.floor((W - sw) / 2), ty + th + 8, sub, C.dim)

    if boot_rect then
        local b = boot_rect
        local active = not booting
        Gfx.fillRect(b.x - 2, b.y - 2, b.w + 4, b.h + 4, C.border)
        Gfx.fillRect(b.x, b.y, b.w, b.h, active and C.boot_bg or C.panel)
        local lab = booting and "..." or "boot"
        local lw = Font.textWidth(lab)
        local lx = b.x + math.floor((b.w - lw) / 2)
        local ly = b.y + math.floor((b.h - Font.height) / 2)
        Gfx.text(lx, ly, lab, active and C.boot_fg or C.dim)
    end

    -- loading bar: | cubes |
    if booting then
        local segments = 12
        local seg = 7
        local gap = 1
        local bar_w = 2 + segments * (seg + gap) - gap + 2
        local bar_x = math.floor((W - bar_w) / 2)
        local bar_y = (boot_rect and (boot_rect.y + boot_rect.h + 16)) or math.floor(H * 0.7)
        local pipe_h = 14
        local pipe_y = bar_y - math.floor((pipe_h - seg) / 2)

        -- left pipe |
        Gfx.fillRect(bar_x, pipe_y, 2, pipe_h, C.dim)
        local filled = math.floor(clamp(progress or 0, 0, 1) * segments + 0.0001)
        local cx = bar_x + 4
        for i = 1, segments do
            if i <= filled then
                -- full cube (solid block)
                Gfx.fillRect(cx, pipe_y + math.floor((pipe_h - seg) / 2), seg, seg, C.accent)
                Gfx.fillRect(cx + 1, pipe_y + math.floor((pipe_h - seg) / 2) + 1, seg - 2, seg - 2, C.title)
            else
                Gfx.fillRect(cx, pipe_y + math.floor((pipe_h - seg) / 2), seg, seg, C.bar_bg)
            end
            cx = cx + seg + gap
        end
        -- right pipe |
        Gfx.fillRect(cx, pipe_y, 2, pipe_h, C.dim)
    end
end

-- ============================================================
-- Flight chrome + content
-- ============================================================

local function drawChrome()
    Gfx.clear(C.bg)
    Gfx.fillRect(0, 0, L.W, L.border, C.border)
    Gfx.fillRect(0, L.H - L.border, L.W, L.border, C.border)
    Gfx.fillRect(0, 0, L.border, L.H, C.border)
    Gfx.fillRect(L.W - L.border, 0, L.border, L.H, C.border)

    Gfx.fillRect(L.border, L.border, L.W - 2 * L.border, L.header_h, C.panel)
    Gfx.fillRect(L.border, L.border + L.header_h, L.W - 2 * L.border, 2, C.border)

    -- title starts after shutdown circle
    local title_x = L.border + 22
    Gfx.text(title_x, L.border + 6, "ARTCORPOS", C.title)
    Gfx.text(title_x + 60, L.border + 6, ship_label ~= "FLIGHT OS" and ship_label or "ATLAS", C.accent)

    Gfx.fillRect(L.strip_x - 3, L.body_y - 2, 3, L.body_h + 4, C.border)

    for i, tab in ipairs(TABS) do
        local x, y, w, h = tabRect(i)
        local on = tab.id == active_tab
        Gfx.fillRect(x, y, w, h, on and C.tab_on_bg or C.tab_off_bg)
        local label_txt = fit(tab.label, w - 4)
        local tw = Font.textWidth(label_txt)
        local tx = x + math.floor((w - tw) / 2)
        local ty = y + math.floor((h - Font.height) / 2)
        Gfx.text(tx, ty, label_txt, on and C.tab_on_fg or C.tab_off_fg)
    end
end

local function drawFlightStatic()
    local x = L.content_x
    local y = L.body_y + 2
    label(x, y, "ALTITUDE")
    label(x, y + 18, "SPEED")
    label(x, y + 36, "CLIMB")
    label(x, y + 54, "MODE")
    label(x, y + 72, "GEAR/PROX")
    label(x, y + 90, "THRUST")
    Gfx.fillRect(x, y + 102, L.content_w - 16, 6, C.bar_bg)
    label(x, y + 116, "PROP SPD")
    -- per-prop thrust (0..15) from drone mixer — not tilt
    label(x, y + 156, "REAR FW/BW")
    Gfx.fillRect(x, y + 168, L.content_w - 16, 5, C.bar_bg)
    Gfx.fillRect(x, y + 178, L.content_w - 16, 5, C.bar_bg)
    -- vertical altitude-target gauge track (right edge of content)
    local gx = x + L.content_w - 12
    Gfx.fillRect(gx, y, 12, 184, C.bar_bg)
    Gfx.fillRect(gx, y, 1, 184, C.border)
    Gfx.fillRect(gx + 11, y, 1, 184, C.border)
    Gfx.fillRect(gx, y, 12, 2, C.border)
    Gfx.fillRect(gx, y + 182, 12, 2, C.border)
end

local function drawEnginesStatic()
    local x = L.content_x
    local y = L.body_y + 2
    label(x, y, "PROPELLERS")
    Gfx.fillRect(x, y + 8, L.content_w, 2, C.panel)
    label(x, y + 16, "FL")
    label(x, y + 34, "FR")
    label(x, y + 52, "RL")
    label(x, y + 70, "RR")
    label(x, y + 90, "REAR")
    Gfx.fillRect(x, y + 100, L.content_w, 2, C.panel)
    label(x, y + 108, "FW")
    Gfx.fillRect(x, y + 120, L.content_w, 8, C.bar_bg)
    label(x, y + 136, "BW")
    Gfx.fillRect(x, y + 148, L.content_w, 8, C.bar_bg)
    label(x, y + 164, "TOTAL")
    Gfx.fillRect(x, y + 176, L.content_w, 8, C.bar_bg)
end

local function drawSystemsStatic()
    local x = L.content_x
    local y = L.body_y + 2
    label(x, y, "ATTITUDE")
    Gfx.fillRect(x, y + 10, L.content_w, 2, C.panel)
    label(x, y + 20, "PITCH")
    label(x, y + 40, "ROLL")
    label(x, y + 60, "YAW")
    label(x, y + 86, "PID GAINS")
    Gfx.fillRect(x, y + 96, L.content_w, 2, C.panel)
    label(x, y + 106, "ALT")
    label(x, y + 126, "PIT")
    label(x, y + 146, "ROL")
    label(x, y + 166, "YAW")
end

local function drawNavStatic()
    local x = L.content_x
    local y = L.body_y + 2
    label(x, y, "NAVIGATION")
    Gfx.fillRect(x, y + 10, L.content_w, 2, C.panel)
    label(x, y + 20, "HEADING")
    label(x, y + 40, "TARGET ALT")
    label(x, y + 60, "ALT ERROR")
    label(x, y + 86, "POSITION")
    Gfx.fillRect(x, y + 96, L.content_w, 2, C.panel)
    label(x, y + 106, "X")
    label(x, y + 126, "Y")
    label(x, y + 146, "Z")
end

local function drawAlarmsStatic()
    local x = L.content_x
    local y = L.body_y + 2
    label(x, y, "ALARMS")
    Gfx.fillRect(x, y + 10, L.content_w, 2, C.panel)
    for i = 0, 7 do
        Gfx.fillRect(x, y + 18 + i * 20, L.content_w, 16, C.panel)
    end
end

-- ACTIONS tab: touch buttons replacing M/L/G/X/R/T/N keys
local ACTION_BTNS = {
    { id = "mode",  label = "MODE",     feat = "cruise_mode" },
    { id = "land",  label = "AUTO-LAND", feat = "auto_land" },
    { id = "gear",  label = "GEAR",     feat = "gear" },
    { id = "estop", label = "E-STOP" },
    { id = "reset", label = "RESET" },
    { id = "tune",  label = "AUTO-TUNE", feat = "auto_tune" },
    { id = "next",  label = "NEXT TAB" },
}

local function actionBtnRect(i)
    local bw, bh, gap = 124, 30, 8
    local col = (i - 1) % 2
    local row = math.floor((i - 1) / 2)
    local x = L.content_x + 4 + col * (bw + gap)
    local y = L.body_y + 16 + row * (bh + gap)
    return x, y, bw, bh
end

local function drawActionsStatic()
    local x = L.content_x
    local y = L.body_y + 2
    label(x, y, "CONTROLS")
    Gfx.fillRect(x, y + 8, L.content_w, 2, C.panel)
end

local function drawActionsDynamic(s)
    local cfg = render_config
    local feats = (cfg and cfg.features) or {}
    for i, btn in ipairs(ACTION_BTNS) do
        local bx, by, bw, bh = actionBtnRect(i)
        local enabled = true
        if btn.feat and feats[btn.feat] == false then enabled = false end
        local bg = enabled and C.panel or C.bar_bg
        local fg = enabled and C.text or C.dim
        if btn.id == "estop" then
            bg = C.bad
            fg = 15
        elseif btn.id == "mode" and s.mode == "CRUISE" then
            bg = C.warn
            fg = 15
        elseif btn.id == "land" and s.auto_land then
            bg = C.warn
            fg = 15
        elseif btn.id == "gear" and s.gear_down then
            bg = C.good
            fg = 15
        end
        Gfx.fillRect(bx, by, bw, bh, bg)
        Gfx.fillRect(bx, by, bw, 1, C.border)
        Gfx.fillRect(bx, by + bh - 1, bw, 1, C.border)
        Gfx.fillRect(bx, by, 1, bh, C.border)
        Gfx.fillRect(bx + bw - 1, by, 1, bh, C.border)
        local txt = btn.label
        if btn.id == "estop" and s.estop then
            txt = "E-STOP (ON)"
        end
        local tw = Font.textWidth(txt)
        Gfx.text(bx + math.floor((bw - tw) / 2), by + math.floor((bh - Font.height) / 2), txt, fg)
    end
end

local function drawContentStatic()
    if active_tab == "flight" then
        drawFlightStatic()
    elseif active_tab == "engines" then
        drawEnginesStatic()
    elseif active_tab == "systems" then
        drawSystemsStatic()
    elseif active_tab == "nav" then
        drawNavStatic()
    elseif active_tab == "alarms" then
        drawAlarmsStatic()
    elseif active_tab == "actions" then
        drawActionsStatic()
    end
end

local function drawFlightDynamic(s)
    local x = L.content_x
    local y = L.body_y + 2
    local o = s.outputs or {}
    local vw = L.content_w - 20

    slotText(x + 70, y, vw - 70, string.format("%.1f", s.altitude or 0), C.accent, "right")
    slotText(x + 70, y + 18, vw - 70, string.format("%.1f", s.speed or 0) .. " MS", C.accent, "right")

    local clb = s.climb_rate or 0
    local cc = C.good
    if clb < -2 then cc = C.bad elseif clb < 0 then cc = C.warn end
    slotText(x + 70, y + 36, vw - 70, string.format("%+.1f", clb), cc, "right")

    local mode = s.mode or "???"
    slotText(x + 70, y + 54, vw - 70, mode, mode == "HOVER" and C.good or C.warn, "left")

    local gp = string.format("%s %d", s.gear_down and "DN" or "UP", s.proximity or 0)
    if s.auto_land then gp = "AL " .. (s.land_state or "") .. " " .. gp end
    if s.landed then gp = "GND " .. gp end
    slotText(x + 70, y + 72, vw - 70, gp, s.landed and C.good or C.text, "left")

    local thrust = (o.speed or 0) / 15
    drawBar(x, y + 102, L.content_w - 16, 6, thrust, C.good)
    slotText(x + L.content_w - 60, y + 90, 44,
        tostring(math.floor(thrust * 100 + 0.5)) .. "%", C.good, "right")

    local labels = { "FL", "FR", "RL", "RR" }
    for i, p in ipairs(labels) do
        local t = o[p .. "_speed"] or o.speed or 0
        local tc = C.good
        if t < 1 then tc = C.bad elseif t > 12 then tc = C.warn end
        slotText(x + 40, y + 128 + (i - 1) * 8, 70, string.format("%5.1f", t), tc, "right")
    end

    drawBar(x, y + 168, L.content_w - 16, 5, (o.rear_fw or 0) / 15, C.good)
    drawBar(x, y + 178, L.content_w - 16, 5, (o.rear_bw or 0) / 15, C.good)

    -- Vertical altitude target gauge (right edge)
    local gx = x + L.content_w - 12
    local gh = 184
    local max_alt = 320
    local function altY(alt)
        local a = clamp(alt or 0, 0, max_alt)
        return y + gh - 3 - math.floor((a / max_alt) * (gh - 8))
    end
    local cur = s.altitude or 0
    local tgt = s.target_altitude or 0
    local cy = altY(cur)
    local bottom = y + gh - 2
    if bottom > cy then
        Gfx.fillRect(gx + 2, cy, 8, bottom - cy, C.accent)
    end
    local ty = altY(tgt)
    Gfx.fillRect(gx, ty, 12, 2, C.warn)
    -- small target value chip above gauge
    slotText(x + L.content_w - 60, y - 0, 44, string.format("T%.0f", tgt), C.warn, "right")
end

local function drawEnginesDynamic(s)
    local x = L.content_x
    local y = L.body_y + 2
    local o = s.outputs or {}
    local labels = { "FL", "FR", "RL", "RR" }
    for i, p in ipairs(labels) do
        local spd = o[p .. "_speed"] or o.speed or 0
        local tc = C.good
        if spd < 1 then tc = C.bad elseif spd > 12 then tc = C.warn end
        slotText(x + 40, y + 16 + (i - 1) * 18, 80, string.format("%5.1f", spd), tc, "right")
    end
    drawBar(x, y + 120, L.content_w, 8, (o.rear_fw or 0) / 15, C.good)
    drawBar(x, y + 148, L.content_w, 8, (o.rear_bw or 0) / 15, C.good)
    drawBar(x, y + 176, L.content_w, 8, (o.speed or 0) / 15, C.good)
end

local function drawSystemsDynamic(s)
    local x = L.content_x
    local y = L.body_y + 2
    local vw = L.content_w - 70

    local pitch = s.pitch or 0
    local pc = C.good
    if math.abs(pitch) > 10 then pc = C.bad elseif math.abs(pitch) > 5 then pc = C.warn end
    slotText(x + 70, y + 20, vw, string.format("%+8.1f", pitch), pc, "right")

    local roll = s.roll or 0
    local rc = C.good
    if math.abs(roll) > 10 then rc = C.bad elseif math.abs(roll) > 5 then rc = C.warn end
    slotText(x + 70, y + 40, vw, string.format("%+8.1f", roll), rc, "right")

    slotText(x + 70, y + 60, vw, string.format("%+8.1f", s.yaw or 0), C.text, "right")

    local pid = {
        { y + 106, (s.pid_gains or {}).altitude },
        { y + 126, (s.pid_gains or {}).pitch },
        { y + 146, (s.pid_gains or {}).roll },
        { y + 166, (s.pid_gains or {}).yaw },
    }
    for _, row in ipairs(pid) do
        local g = row[2] or {}
        slotText(x + 50, row[1], L.content_w - 50,
            string.format("K%.1f I%.2f D%.1f", g.kp or 0, g.ki or 0, g.kd or 0),
            C.text, "left")
    end
end

local function drawNavDynamic(s)
    local x = L.content_x
    local y = L.body_y + 2
    local vw = L.content_w - 90

    slotText(x + 90, y + 20, vw, string.format("%.1f", s.yaw or 0), C.accent, "right")
    slotText(x + 90, y + 40, vw, string.format("%.1f", s.target_altitude or 0), C.accent, "right")
    local err = (s.altitude or 0) - (s.target_altitude or 0)
    local ec = C.good
    if math.abs(err) > 10 then ec = C.bad elseif math.abs(err) > 3 then ec = C.warn end
    slotText(x + 90, y + 60, vw, string.format("%+.1f", err), ec, "right")

    slotText(x + 50, y + 106, vw - 50, "N/A", C.dim, "left")
    slotText(x + 50, y + 126, vw - 50, string.format("%.1f", s.altitude or 0), C.text, "left")
    slotText(x + 50, y + 146, vw - 50, "N/A", C.dim, "left")
end

local function drawAlarmsDynamic(s, status_msg)
    local x = L.content_x
    local y = L.body_y + 2
    local msgs = {}
    if s.estop then
        table.insert(msgs, { "E-STOP LATCHED (RESET)", C.bad })
    end
    if status_msg and status_msg ~= "" then
        table.insert(msgs, { status_msg, C.accent })
    end
    local alt = s.altitude or 0
    if alt < 70 then
        table.insert(msgs, { "LOW ALTITUDE", C.bad })
    end
    if (s.climb_rate or 0) < -4 then
        table.insert(msgs, { "FAST DESCENT", C.warn })
    end
    if math.abs(s.pitch or 0) > 15 or math.abs(s.roll or 0) > 15 then
        table.insert(msgs, { "EXTREME ATTITUDE", C.bad })
    end
    if #msgs == 0 then
        table.insert(msgs, { "NO ACTIVE ALARMS", C.good })
    end
    for i = 1, 8 do
        local m = msgs[i]
        Gfx.fillRect(x + 2, y + 18 + (i - 1) * 20, L.content_w - 4, 16, C.panel)
        if m then
            Gfx.text(x + 6, y + 22 + (i - 1) * 20, fit(m[1], L.content_w - 12), m[2])
        end
    end
end

local function drawDynamic(s, status_msg)
    local x = L.content_x
    local y = L.border + 6

    drawShutdownButton(not not s.landed)

    local hdr = status_msg or ""
    if hdr == "" then hdr = s.mode or "" end
    local hdr_x = L.W - L.border - 140
    local hdr_w = 130
    -- keep clear of power button on left / not overlap title
    if hdr_x < L.border + 120 then
        hdr_x = L.border + 120
        hdr_w = L.W - L.border - hdr_x - 4
    end
    -- slotText fits to hdr_w itself (fit(hdr, 20) truncated to ~3 chars)
    slotText(hdr_x, y, hdr_w, hdr, C.accent, "right")

    local readout_x = L.border + 120
    slotText(readout_x, y, 56, string.format("A%.0f", s.altitude or 0), C.text, "right")
    slotText(readout_x + 60, y, 56, string.format("S%.0f", s.speed or 0), C.text, "right")
    if s.estop then
        slotText(readout_x + 120, y, 44, "STOP", C.bad, "right")
    elseif s.landed then
        slotText(readout_x + 120, y, 44, "GND", C.good, "right")
    elseif s.auto_land then
        slotText(readout_x + 120, y, 44, "LAND", C.warn, "right")
    end

    if active_tab == "flight" then
        drawFlightDynamic(s)
    elseif active_tab == "engines" then
        drawEnginesDynamic(s)
    elseif active_tab == "systems" then
        drawSystemsDynamic(s)
    elseif active_tab == "nav" then
        drawNavDynamic(s)
    elseif active_tab == "alarms" then
        drawAlarmsDynamic(s, status_msg)
    elseif active_tab == "actions" then
        drawActionsDynamic(s)
    end
end

-- ============================================================
-- Public API
-- ============================================================

function HUD.init(mon)
    local ok = Gfx.init(mon, SCALE)
    if not ok then
        error("CC:Graphics not available (need CC:Graphics mod + colour monitor)", 0)
    end
    applyLayout()
    initialized = true
    chrome_dirty = true
    content_dirty = true
    power_dirty = true
    return Gfx.W, Gfx.H
end

function HUD.setShipLabel(label)
    if label and label ~= "" then
        ship_label = tostring(label):upper()
    end
end

function HUD.markChromeDirty()
    chrome_dirty = true
    content_dirty = true
    power_dirty = true
end

function HUD.renderPower(mode, progress, status_msg)
    if not initialized then return end
    splash_active = true
    Gfx.begin()
    drawSplash(progress or 0, mode == "booting")
    Gfx.finish()
end

function HUD.render(mon, status, config, status_msg)
    if not initialized or not status then return end
    splash_active = false
    render_config = config
    status_msg = status_msg or ""
    Gfx.begin()
    if chrome_dirty then
        drawChrome()
        chrome_dirty = false
        content_dirty = true
    end
    if content_dirty then
        drawContentStatic()
        content_dirty = false
    end
    drawDynamic(status, status_msg)
    Gfx.finish()
end

function HUD.setTab(id)
    for _, tab in ipairs(TABS) do
        if tab.id == id then
            if active_tab ~= id then
                active_tab = id
                chrome_dirty = true
                content_dirty = true
            end
            return true
        end
    end
    return false
end

function HUD.getTab()
    return active_tab
end

function HUD.nextTab()
    for i, tab in ipairs(TABS) do
        if tab.id == active_tab then
            local nxt = TABS[(i % #TABS) + 1]
            HUD.setTab(nxt.id)
            return nxt.id
        end
    end
end

-- Returns: "boot" | "shutdown" | tab_id | "act:<id>" | nil
-- monitor_touch officially reports 1-based CHARACTER cells (tweaked.cc);
-- out-of-grid coordinates are treated as pixels (pixel-space events).
local last_touch_t, last_touch_x, last_touch_y = -1, -1, -1

local function hitTest(x, y)
    if splash_active and boot_rect
        and inRect(boot_rect.x - 6, boot_rect.y - 9, boot_rect.w + 12, boot_rect.h + 18, x, y) then
        return "boot"
    end

    if shutdown_rect and inRect(shutdown_rect.x, shutdown_rect.y, shutdown_rect.w, shutdown_rect.h, x, y) then
        return "shutdown"
    end

    if active_tab == "actions" then
        for i, btn in ipairs(ACTION_BTNS) do
            local bx, by, bw, bh = actionBtnRect(i)
            if inRect(bx, by, bw, bh, x, y) then
                return "act:" .. btn.id
            end
        end
    end

    for i, tab in ipairs(TABS) do
        local tx, ty, tw, th = tabRect(i)
        if x >= tx and x < tx + tw and y >= ty and y < ty + th then
            if active_tab ~= tab.id then
                HUD.setTab(tab.id)
            end
            return "tab:" .. tab.id
        end
    end
    return nil
end

-- Sample a character cell: corners + center, so a button partially covered
-- by the cell still hits (cell 6x9 px vs 12 px shutdown circle).
local function hitTestCell(cx, cy)
    local x0, y0 = (cx - 1) * 6, (cy - 1) * 9
    local x1, y1 = cx * 6 - 1, cy * 9 - 1
    local mx, my = math.floor((x0 + x1) / 2), math.floor((y0 + y1) / 2)
    local pts = { { x0, y0 }, { x1, y0 }, { x0, y1 }, { x1, y1 }, { mx, my } }
    for _, p in ipairs(pts) do
        local action = hitTest(p[1], p[2])
        if action then return action end
    end
    return nil
end

function HUD.handleTouch(rx, ry)
    if not initialized then return nil end
    if type(rx) ~= "number" or type(ry) ~= "number" then return nil end

    -- multi-block monitors can double-fire the same touch
    local t = os.clock()
    if rx == last_touch_x and ry == last_touch_y and t - last_touch_t < 0.05 then
        return nil
    end
    last_touch_t, last_touch_x, last_touch_y = t, rx, ry

    local cols = math.floor(Gfx.W / 6)
    local rows = math.floor(Gfx.H / 9)
    if rx >= 1 and ry >= 1 and rx <= cols and ry <= rows then
        -- official CC space: character cells (no raw-pixel reinterpretation,
        -- which made e.g. cell (7,7) fall through onto the shutdown circle)
        return hitTestCell(rx, ry)
    end
    -- out-of-grid: pixel-space event
    return hitTest(rx, ry)
end

function HUD.shutdown()
    if not initialized then return end
    Gfx.shutdown()
    initialized = false
    chrome_dirty = true
    content_dirty = true
    power_dirty = true
end

return HUD
