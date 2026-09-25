-- Resolve lib modules even if package.path is incomplete
local function loadLib(name)
    local ok, mod = pcall(require, name)
    if ok then return mod end
    local path = (name:gsub("%.", "/")) .. ".lua"
    local fn, err = loadfile(path)
    if fn then
        local ok2, res = pcall(fn)
        if ok2 then return res end
        error(res, 0)
    end
    error(mod, 0)
end

local Flight = loadLib("lib.flight")
local Hardware = loadLib("lib.hardware")

local OS = {}
local config = nil
local hw = nil
local flight = nil
local ship_info = nil

local running = false
local status_message = ""
local status_time = 0
local last_hud_update = 0
local hud_interval = 0.1

-- power: "off" = splash, "booting" = load bar + engine sequence, "on" = flight UI
local power_state = "off"
local boot_started = 0
local BOOT_DURATION = 5.0
local clutch_engaged = false

local function hasFeature(name)
    if hw and hw.hasFeature then return hw.hasFeature(name) end
    if config and config.features and config.features[name] ~= nil then
        return not not config.features[name]
    end
    return true
end

function OS.setShipInfo(info)
    ship_info = info
end

-- PID gain file for this ship (config/pid_<slot>.lua)
local function pidFilePath()
    local slot = (config and config.slot)
        or (ship_info and ship_info.profile)
        or "ship"
    return "config/pid_" .. slot .. ".lua"
end

local PID_NAMES = { "altitude", "pitch", "roll", "yaw", "speed" }

local function loadPidGains()
    local path = pidFilePath()
    if not fs.exists(path) then
        return false, path
    end
    local fn = loadfile(path)
    if not fn then return false, path end
    local ok, data = pcall(fn)
    if not ok or type(data) ~= "table" then return false, path end
    local any = false
    for _, name in ipairs(PID_NAMES) do
        local pid = flight.pid[name]
        local g = data[name]
        if pid and type(g) == "table" then
            pid:setGains(g.kp or pid.kp, g.ki or pid.ki, g.kd or pid.kd)
            any = true
        end
    end
    return any, path
end

function OS.savePidGains()
    if not flight then return false end
    local path = pidFilePath()
    local f = io.open(path, "w")
    if not f then
        print("  WARN: cannot write " .. path)
        return false
    end
    f:write("-- Auto-tuned PID gains (ArtCorpOS). Delete to re-run auto-tune.\nreturn {\n")
    for _, name in ipairs(PID_NAMES) do
        local g = flight.pid[name]:getGains()
        f:write(string.format("  %s = { kp = %.4f, ki = %.4f, kd = %.4f },\n",
            name, g.kp or 0, g.ki or 0, g.kd or 0))
    end
    f:write("}\n")
    f:close()
    print("  PID gains saved: " .. path)
    return true
end

function OS.start(cfg, hardware)
    config = cfg
    hw = hardware

    local eng = config.engine or {}
    BOOT_DURATION = eng.boot_seconds or 5.0

    print("Initializing flight controller...")
    flight = Flight.new(config, hw)
    flight.onTuneComplete = function(ok)
        if ok then OS.savePidGains() end
    end
    flight.onGearAutoDeploy = function(prox)
        status_message = "PROX " .. tostring(prox) .. " - GEAR DOWN"
        status_time = os.clock()
        print("[" .. string.format("%.0f", os.clock()) .. "] gear auto-deploy (prox=" .. tostring(prox) .. ")")
    end

    -- Load saved PID gains, or arm auto-tune if the file is missing
    -- (first boot, or someone deleted config/pid_<slot>.lua).
    -- Armed AFTER landed/gear init below so requestAutoTune sees real state.
    local pid_loaded, pid_path = false, nil
    if hasFeature("auto_tune") then
        pid_loaded, pid_path = loadPidGains()
    end

    local state = hw.getShipState()
    flight.targets.altitude = state.altitude
    flight:captureHeading()
    if state.sable_error then
        print("  WARNING ship state: " .. tostring(state.sable_error))
        print("  PID may be limited until CC:Sable pose is available.")
    end

    flight:setMode(Flight.MODE_HOVER)
    if not hasFeature("cruise_mode") then
        flight:setMode(Flight.MODE_HOVER)
    end
    flight.proximity = hw.getProximity() or 0
    flight.landed = flight.proximity >= ((config.proximity and config.proximity.landed_threshold) or 15)
    flight:cutPropsSoft()
    if flight.landed or flight.proximity > 0 then
        flight.gear_down = true
        hw.setGear(true)
        -- settle time like a normal deploy (boot-with-prox transient can
        -- otherwise read as landed on the very first update tick)
        flight.gear_settle = (config.proximity and config.proximity.gear_settle_ticks) or 20
        if flight.landed then
            flight.land_state = Flight.LAND_DONE
        else
            flight.land_state = Flight.LAND_IDLE
        end
    else
        flight.gear_down = false
        hw.setGear(false)
        flight.land_state = Flight.LAND_IDLE
    end

    -- Arm auto-tune only now that landed/mode are known
    if hasFeature("auto_tune") then
        if pid_loaded then
            print("  PID gains loaded: " .. tostring(pid_path))
        else
            print("  PID file missing (" .. tostring(pid_path) .. ") - auto-tune armed")
            flight:requestAutoTune()
        end
    end

    hw.setAllSpeed(0)
    hw.cutAllOutputs()
    hw.engineOutputsOff()
    clutch_engaged = false

    local mon = hw.getDevice("main_monitor")
    if mon then
        local hud = loadLib("lib.hud")
        local ship_label = (ship_info and ship_info.name) or config.name
        if ship_label then hud.setShipLabel(ship_label) end
        local ok, w, h = pcall(hud.init, mon)
        if ok then
            print("HUD ready: " .. tostring(w) .. "x" .. tostring(h) .. " px (mode 2)")
        else
            print("HUD ERROR: " .. tostring(w))
            print("Monitor HUD disabled.")
        end
    else
        print("No monitor found - HUD disabled.")
    end

    running = true
    power_state = "off"
    status_message = ""
    status_time = 0

    local ship_label = (ship_info and ship_info.name) or config.name or "SHIP"
    local feats = config.features or {}
    print("Flight controller initialized.")
    print("Ship: " .. ship_label .. "  config v" .. tostring(config.version))
    print("Mode: " .. flight.mode .. "  props=0  prox=" .. tostring(flight.proximity) ..
        "  " .. (flight.landed and "LANDED" or "AIRBORNE"))
    print("Features:" ..
        (feats.engine_auto_start and " engine-start" or "") ..
        (feats.clutch and " clutch" or "") ..
        (feats.auto_land and " auto-land" or "") ..
        (feats.cruise_mode and " cruise" or "") ..
        (feats.auto_tune and " auto-tune" or "") ..
        (feats.fuel_level and " fuel" or ""))
    print("Power: OFF (splash) — tap boot to start sequence")
    print("")
    print("Controls (when ON):")
    print("  W/S - Tilt collective (translation)")
    print("  A/D - Strafe via bank tilt")
    print("  Q/E - Yaw left/right")
    print("  Space/Ctrl - Altitude target +/−")
    if hasFeature("cruise_mode") then
        print("  Shift redstone - Hover <-> Cruise")
        print("  Cruise: W/S speed goal, Space/Ctrl altitude (slight pitch)")
    end
    local ctrl = "  Actions (monitor ACTIONS tab):"
    if hasFeature("auto_land") then ctrl = ctrl .. " land" end
    if hasFeature("gear") then ctrl = ctrl .. " gear" end
    if hasFeature("auto_tune") then ctrl = ctrl .. " tune" end
    ctrl = ctrl .. " mode  e-stop  reset  tabs"
    print(ctrl)
    print("  Red circle (top-left) - shutdown (decouples clutch)")
    print("")

    local controlTimer = os.startTimer(0.05)
    OS.mainLoop(controlTimer)
end

function OS.mainLoop(controlTimer)
    while running do
        local event, param1, param2, param3 = os.pullEvent()
        local now = os.clock()

        if event == "key" then
            OS.handleKey(param1, param2)
        elseif event == "timer" then
            if param1 == controlTimer then
                -- Always re-arm so a control error cannot kill the 20 Hz loop;
                -- log each distinct error (once) instead of swallowing it
                local ok, err = pcall(OS.controlTick)
                if not ok and err ~= OS._last_tick_error then
                    OS._last_tick_error = err
                    print("[CONTROL ERROR] " .. tostring(err))
                elseif ok then
                    OS._last_tick_error = nil
                end
                controlTimer = os.startTimer(0.05)
            end
        elseif event == "monitor_touch" then
            pcall(OS.handleMonitorTouch, param2, param3)
        elseif event == "peripheral" then
            OS.handlePeripheralConnect(param1, param2)
        elseif event == "peripheral_detach" then
            OS.handlePeripheralDisconnect(param1)
        elseif event == "terminate" then
            OS.shutdown()
            return
        end

        if status_time > 0 and now - status_time > 3 then
            status_message = ""
            status_time = 0
        end

        if now - last_hud_update >= hud_interval then
            OS.updateDisplay()
            last_hud_update = now
        end
    end
end

function OS.bootTick()
    if not hw then return end
    if not hasFeature("engine_auto_start") then return end

    local eng = config.engine or {}
    local t = os.clock() - boot_started
    local start_s = eng.start_seconds or 3
    local clutch_at = start_s + (eng.clutch_delay or 1)
    local active = eng.active or 15
    local _ = active

    if t < start_s then
        if not OS._starter_on then
            OS._starter_on = true
            print("[" .. string.format("%.0f", os.clock()) .. "] Engine starter ON (" .. start_s .. "s)")
        end
        hw.setEngineStarter(true)
        hw.setClutch(false)
        clutch_engaged = false
    else
        if OS._starter_on then
            OS._starter_on = false
            hw.setEngineStarter(false)
            print("[" .. string.format("%.0f", os.clock()) .. "] Engine starter OFF")
        end
        hw.setEngineStarter(false)
    end

    if t >= clutch_at then
        if not clutch_engaged and hasFeature("clutch") then
            hw.setClutch(true)
            clutch_engaged = true
            print("[" .. string.format("%.0f", os.clock()) .. "] Clutch COUPLED")
            status_message = "CLUTCH ON"
            status_time = os.clock()
        elseif hasFeature("clutch") then
            hw.setClutch(true)
        end
    end
end

function OS.controlTick()
    if not flight then return end

    if power_state == "booting" then
        OS.bootTick()
        return
    end

    if power_state ~= "on" then
        -- Keep ship safe while splash
        if power_state == "off" then
            hw.cutAllOutputs()
            flight:cutPropsSoft()
            if not clutch_engaged then
                hw.engineOutputsOff()
            end
        end
        return
    end

    local keys = hw.readInputs()

    local shift = keys.SHIFT or 0
    if hasFeature("cruise_mode") and flight:pollShift(shift) then
        status_message = "Mode: " .. flight.mode
        status_time = os.clock()
        print("[" .. string.format("%.0f", os.clock()) .. "] Mode -> " .. flight.mode .. " (shift)")
    elseif not hasFeature("cruise_mode") then
        -- ignore shift when cruise feature disabled
    end

    -- Redstone Space/Ctrl altitude steps (rising edge + hold repeat @ 20Hz)
    local step = (config.limits and config.limits.alt_step) or 2
    local sp = (keys.SPACE or 0) > 0
    local ct = (keys.CTRL or 0) > 0
    OS._alt_ticks = OS._alt_ticks or { space = 0, ctrl = 0 }
    local function altHold(name, down, delta)
        local t = OS._alt_ticks
        if not down then
            t[name] = 0
            return
        end
        t[name] = (t[name] or 0) + 1
        -- first tick, then every 0.2s while held
        if t[name] == 1 or t[name] % 4 == 0 then
            if flight:adjustAltitude(delta) then
                status_message = (delta > 0 and "Alt+: " or "Alt-: ") ..
                    string.format("%.1f", flight.targets.altitude)
                status_time = os.clock()
            end
        end
    end
    altHold("space", sp, step)
    altHold("ctrl", ct, -step)

    flight:processInputs(keys)
    flight:update()

    if flight.tune_status and flight.tune_status ~= "" then
        local ts = flight.tune_status
        if ts == "queued" or ts == "running" or ts == "waiting for air" then
            status_message = "Tune: " .. ts
            status_time = os.clock()
        else
            status_message = "Tune: " .. ts
            status_time = os.clock()
            print("[" .. string.format("%.0f", os.clock()) .. "] Auto-tune " .. ts)
            flight.tune_status = nil
        end
    end
end

-- Shared by keyboard (M/L/G/X/R/T/N) and ACTIONS tab buttons
function OS.doAction(name)
    if power_state ~= "on" or not flight then return end

    if name == "mode" then
        if not hasFeature("cruise_mode") then
            status_message = "No cruise mode on this ship"
            status_time = os.clock()
        else
            local result = {flight:toggleMode()}
            if result[1] then
                status_message = "Mode: " .. result[3]
                status_time = os.clock()
                print("[" .. string.format("%.0f", os.clock()) .. "] Mode: " .. result[2] .. " -> " .. result[3])
            end
        end

    elseif name == "estop" then
        flight:emergencyStop()
        status_message = "EMERGENCY STOP"
        status_time = os.clock()
        print("[" .. string.format("%.0f", os.clock()) .. "] EMERGENCY STOP")

    elseif name == "land" then
        if not hasFeature("auto_land") then
            status_message = "No auto-land on this ship"
            status_time = os.clock()
        else
            local ok, msg = flight:toggleAutoLand()
            status_message = msg or "AUTO-LAND"
            status_time = os.clock()
            print("[" .. string.format("%.0f", os.clock()) .. "] " .. tostring(msg))
        end

    elseif name == "gear" then
        if not hasFeature("gear") then
            status_message = "No gear on this ship"
            status_time = os.clock()
        elseif not flight.gear_down then
            flight.gear_down = true
            hw.setGear(true)
            flight.gear_settle = (config.proximity and config.proximity.gear_settle_ticks) or 20
            status_message = "GEAR DOWN"
            status_time = os.clock()
        elseif (flight.proximity or 0) > 0 then
            status_message = "PROX ACTIVE - GEAR LOCKED"
            status_time = os.clock()
        else
            flight.gear_down = false
            hw.setGear(false)
            status_message = "GEAR UP"
            status_time = os.clock()
        end

    elseif name == "tune" then
        if not hasFeature("auto_tune") then
            status_message = "No auto-tune on this ship"
            status_time = os.clock()
        else
            local ok, msg = flight:requestAutoTune()
            status_message = ok and "Auto-tuning altitude PID..." or ("Auto-tune: " .. tostring(msg))
            status_time = os.clock()
        end

    elseif name == "reset" then
        local state = hw.getShipState()
        flight.estop = false
        flight.targets.altitude = state.altitude
        flight:captureHeading()
        flight.targets.move_forward = 0
        flight.targets.move_right = 0
        flight.targets.yaw_cmd = 0
        status_message = "Targets reset"
        status_time = os.clock()

    elseif name == "next" then
        local hud = loadLib("lib.hud")
        local nxt = hud.nextTab()
        status_message = "Tab: " .. (nxt or hud.getTab()):upper()
        status_time = os.clock()
    end
end

function OS.handleKey(key, held)
    if held then return end
    local keys = _G.keys
    if not keys then
        local ok, mod = pcall(require, "keys")
        if ok then keys = mod end
    end
    if not keys then return end

    -- Power keys only meaningful when on (except allow nothing on splash)
    if power_state == "off" then
        if key == keys.space or key == keys.enter then
            OS.beginBoot()
        end
        return
    end
    if power_state == "booting" then
        return
    end

    -- Actions (mode/land/gear/estop/…) are monitor-only (ACTIONS tab).
    if key == keys.space then
        local step = (config.limits and config.limits.alt_step) or 2
        if flight:adjustAltitude(step) then
            status_message = "Alt+: " .. string.format("%.1f", flight.targets.altitude)
            status_time = os.clock()
        end
    elseif key == keys.leftCtrl or key == keys.rightCtrl then
        local step = (config.limits and config.limits.alt_step) or 2
        if flight:adjustAltitude(-step) then
            status_message = "Alt-: " .. string.format("%.1f", flight.targets.altitude)
            status_time = os.clock()
        end
    end
end

function OS.beginBoot()
    if power_state ~= "off" then return end
    power_state = "booting"
    boot_started = os.clock()
    OS._starter_on = false
    clutch_engaged = false
    -- A fresh boot must not inherit the previous run's e-stop latch
    -- (powerOff->emergencyStop leaves it set; HUD would show READY otherwise).
    -- Tune flags: Flight:update() gates them on landed+HOVER+estop, but
    -- powerOff's emergencyStop cleared the armed-pending tune — re-arm it
    -- if the PID file is still missing.
    if flight then
        flight.estop = false
        if hasFeature("auto_tune") and not fs.exists(pidFilePath()) then
            flight.tune_pending = true
            flight.tune_status = nil
        end
    end
    status_message = ""
    print("[" .. string.format("%.0f", os.clock()) .. "] Boot sequence (" .. tostring(BOOT_DURATION) .. "s)...")
end

function OS.powerOff()
    if power_state ~= "on" then return false, "NOT ON" end
    if not flight then return false, "NO FLIGHT" end
    -- allowed in the air too (pilot may need an emergency power-down);
    -- emergencyStop cuts all outputs, so the ship will drop
    flight:emergencyStop()
    hw.cutAllOutputs()
    -- Decouple clutch on deliberate shutdown only (grounded power button)
    if hasFeature("clutch") then
        hw.setClutch(false)
        clutch_engaged = false
        print("[" .. string.format("%.0f", os.clock()) .. "] Clutch DECOUPLED")
    end
    hw.setEngineStarter(false)
    OS._starter_on = false
    power_state = "off"
    local hud = loadLib("lib.hud")
    hud.markChromeDirty()
    status_message = ""
    print("[" .. string.format("%.0f", os.clock()) .. "] Shutdown -> splash")
    return true, "OFF"
end

function OS.handleMonitorTouch(x, y)
    local hud = loadLib("lib.hud")
    local action = hud.handleTouch(x, y)
    if not action then return end

    if power_state == "off" then
        if action == "boot" then
            OS.beginBoot()
        end
    elseif power_state == "booting" then
        -- ignore
    elseif action == "shutdown" then
        local ok, msg = OS.powerOff()
        status_message = msg or (ok and "OFF" or "SHUTDOWN BLOCKED")
        status_time = os.clock()
        if not ok then
            print("[" .. string.format("%.0f", os.clock()) .. "] Shutdown blocked: " .. tostring(msg))
        end
    elseif action:sub(1, 4) == "act:" then
        OS.doAction(action:sub(5))
    elseif action ~= "boot" then
        local tab = action
        if action:sub(1, 4) == "tab:" then
            tab = action:sub(5)
        end
        status_message = "Tab: " .. tostring(tab):upper()
        status_time = os.clock()
    end

    -- redraw now so the first tap is visible without waiting for the HUD timer
    OS.updateDisplay()
    last_hud_update = os.clock()
end

function OS.handlePeripheralConnect(name, peripheralType)
    print("[" .. string.format("%.0f", os.clock()) .. "] Connected: " .. name)
    status_message = "Connected: " .. name
    status_time = os.clock()
    for key, assigned in pairs(config.peripherals or {}) do
        if assigned == name then
            pcall(Hardware.connect)
        end
    end
end

function OS.handlePeripheralDisconnect(name)
    print("[" .. string.format("%.0f", os.clock()) .. "] Disconnected: " .. name)
    status_message = "Disconnected: " .. name
    status_time = os.clock()
end

function OS.updateDisplay()
    local mon = hw.getDevice("main_monitor")
    if not mon then return end

    local hud = loadLib("lib.hud")

    if power_state == "off" then
        pcall(hud.renderPower, "off", 0, status_message)
        return
    end

    if power_state == "booting" then
        local p = (os.clock() - boot_started) / BOOT_DURATION
        if p >= 1 then
            power_state = "on"
            hud.markChromeDirty()
            status_message = clutch_engaged and "READY + CLUTCH" or "READY"
            status_time = os.clock()
            print("[" .. string.format("%.0f", os.clock()) .. "] Boot complete" ..
                (clutch_engaged and " (clutch coupled)" or ""))
            p = 1
        end
        pcall(hud.renderPower, "booting", p, status_message)
        return
    end

    if not flight then return end
    local ok, err = pcall(function()
        local status = flight:getStatus()
        hud.render(mon, status, config, status_message)
    end)
    if not ok then
        if not OS._hud_error_once then
            OS._hud_error_once = true
            print("[HUD ERROR] " .. tostring(err))
        end
    end
end

function OS.shutdown()
    running = false
    if flight then flight:emergencyStop() end
    pcall(function()
        if hw then
            hw.setEngineStarter(false)
            if hasFeature("clutch") then
                hw.setClutch(false)
                clutch_engaged = false
            end
        end
    end)
    pcall(function()
        local hud = loadLib("lib.hud")
        hud.shutdown()
    end)
    print("ArtCorpOS shutdown.")
end

return OS
