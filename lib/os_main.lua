local Flight = require("lib.flight")
local Hardware = require("lib.hardware")

local OS = {}
local config = nil
local hw = nil
local flight = nil

local running = false
local status_message = ""
local status_time = 0
local last_hud_update = 0
local hud_interval = 0.1

-- power: "off" = splash, "booting" = load bar, "on" = flight UI
local power_state = "off"
local boot_started = 0
local BOOT_DURATION = 1.8

function OS.start(cfg, hardware)
    config = cfg
    hw = hardware

    print("Initializing flight controller...")
    flight = Flight.new(config, hw)

    local state = hw.getShipState()
    flight.targets.altitude = state.altitude
    flight:captureHeading()
    if state.sable_error then
        print("  WARNING ship state: " .. tostring(state.sable_error))
        print("  PID may be limited until CC:Sable pose is available.")
    end

    flight:setMode(Flight.MODE_HOVER)
    flight.proximity = hw.getProximity() or 0
    flight.landed = flight.proximity >= ((config.proximity and config.proximity.landed_threshold) or 15)
    flight:cutPropsSoft()
    if flight.landed then
        flight.gear_down = true
        hw.setGear(true)
        flight.land_state = Flight.LAND_DONE
    else
        flight.gear_down = false
        hw.setGear(false)
        flight.land_state = Flight.LAND_IDLE
    end
    hw.setAllSpeed(0)
    hw.cutAllOutputs()

    local mon = hw.getDevice("main_monitor")
    if mon then
        local hud = require("lib.hud")
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
    -- Start powered OFF on splash (fake power button flow)
    power_state = "off"
    status_message = ""
    status_time = 0

    print("Flight controller initialized.")
    print("Mode: " .. flight.mode .. "  props=0  prox=" .. tostring(flight.proximity) ..
        "  " .. (flight.landed and "LANDED" or "AIRBORNE"))
    print("Power: OFF (splash) — tap boot on monitor to start")
    print("")
    print("Controls (when ON):")
    print("  W/S - All props tilt forward/back")
    print("  A/D - Strafe left/right (bank)")
    print("  Q/E - Yaw left/right")
    print("  Space/Ctrl - Altitude target +/−")
    print("  Shift redstone - Hover <-> Cruise")
    print("  L auto-land  G gear  M mode  X e-stop  N tabs")
    print("  Red circle (top-left, when GND) - shutdown to splash")
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
                OS.controlTick()
                controlTimer = os.startTimer(0.05)
            end
        elseif event == "monitor_touch" then
            OS.handleMonitorTouch(param2, param3)
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

function OS.controlTick()
    if not flight then return end

    if power_state ~= "on" then
        -- Keep ship safe while splash/booting
        if power_state == "off" then
            hw.cutAllOutputs()
            flight:cutPropsSoft()
        end
        return
    end

    local keys = hw.readInputs()

    local shift = keys.SHIFT or 0
    if flight:pollShift(shift) then
        status_message = "Mode: " .. flight.mode
        status_time = os.clock()
        print("[" .. string.format("%.0f", os.clock()) .. "] Mode -> " .. flight.mode .. " (shift)")
    end

    flight:processInputs(keys)
    flight:update()
end

function OS.handleKey(key, held)
    if held then return end
    local keys = require("keys")

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

    if key == keys.m then
        local result = {flight:toggleMode()}
        if result[1] then
            status_message = "Mode: " .. result[3]
            status_time = os.clock()
            print("[" .. string.format("%.0f", os.clock()) .. "] Mode: " .. result[2] .. " -> " .. result[3])
        end

    elseif key == keys.x then
        flight:emergencyStop()
        status_message = "EMERGENCY STOP"
        status_time = os.clock()
        print("[" .. string.format("%.0f", os.clock()) .. "] EMERGENCY STOP")

    elseif key == keys.l then
        local ok, msg = flight:toggleAutoLand()
        status_message = msg or "AUTO-LAND"
        status_time = os.clock()
        print("[" .. string.format("%.0f", os.clock()) .. "] " .. tostring(msg))

    elseif key == keys.g then
        flight.gear_down = not flight.gear_down
        hw.setGear(flight.gear_down)
        status_message = flight.gear_down and "GEAR DOWN" or "GEAR UP"
        status_time = os.clock()

    elseif key == keys.t then
        flight:requestAutoTune()
        status_message = "Auto-tuning PIDs..."
        status_time = os.clock()

    elseif key == keys.r then
        local state = hw.getShipState()
        flight.targets.altitude = state.altitude
        flight:captureHeading()
        flight.targets.move_forward = 0
        flight.targets.move_right = 0
        flight.targets.yaw_cmd = 0
        status_message = "Targets reset"
        status_time = os.clock()

    elseif key == keys.space then
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

    elseif key == keys.n then
        local hud = require("lib.hud")
        local nxt = hud.nextTab()
        status_message = "Tab: " .. (nxt or hud.getTab()):upper()
        status_time = os.clock()
    end
end

function OS.beginBoot()
    if power_state ~= "off" then return end
    power_state = "booting"
    boot_started = os.clock()
    status_message = ""
    print("[" .. string.format("%.0f", os.clock()) .. "] Boot...")
end

function OS.powerOff()
    if power_state ~= "on" then return false, "NOT ON" end
    if not flight then return false, "NO FLIGHT" end
    if not flight.landed then
        return false, "MUST BE ON GROUND"
    end
    flight:emergencyStop()
    hw.cutAllOutputs()
    power_state = "off"
    local hud = require("lib.hud")
    hud.markChromeDirty()
    status_message = ""
    print("[" .. string.format("%.0f", os.clock()) .. "] Shutdown -> splash")
    return true, "OFF"
end

function OS.handleMonitorTouch(x, y)
    local hud = require("lib.hud")
    local action = hud.handleTouch(x, y)
    if not action then return end

    if power_state == "off" then
        if action == "boot" then
            OS.beginBoot()
        end
        return
    end

    if power_state == "booting" then
        return
    end

    -- power on
    if action == "shutdown" then
        local ok, msg = OS.powerOff()
        status_message = msg or (ok and "OFF" or "SHUTDOWN BLOCKED")
        status_time = os.clock()
        if not ok then
            print("[" .. string.format("%.0f", os.clock()) .. "] Shutdown blocked: " .. tostring(msg))
        end
        return
    end

    if action and action ~= "boot" then
        local tab = action
        if action:sub(1, 4) == "tab:" then
            tab = action:sub(5)
        end
        status_message = "Tab: " .. tostring(tab):upper()
        status_time = os.clock()
    end
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

    local hud = require("lib.hud")

    if power_state == "off" then
        pcall(hud.renderPower, "off", 0, status_message)
        return
    end

    if power_state == "booting" then
        local p = (os.clock() - boot_started) / BOOT_DURATION
        if p >= 1 then
            power_state = "on"
            hud.markChromeDirty()
            status_message = "READY"
            status_time = os.clock()
            print("[" .. string.format("%.0f", os.clock()) .. "] Boot complete")
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
        local hud = require("lib.hud")
        hud.shutdown()
    end)
    print("ArtCorpOS shutdown.")
end

return OS
