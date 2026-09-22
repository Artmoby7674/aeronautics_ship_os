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
local hud_interval = 0.2
local alert_flash = false
local alert_flash_time = 0

function OS.start(cfg, hardware)
    config = cfg
    hw = hardware

    print("Initializing flight controller...")
    flight = Flight.new(config, hw)

    local state = hw.getShipState()
    flight.targets.altitude = state.altitude
    flight.targets.yaw = state.yaw

    running = true
    status_message = "Flight OS Ready"
    status_time = os.clock()

    print("Flight controller initialized.")
    print("Mode: " .. flight.mode)
    print("Altitude target: " .. string.format("%.1f", flight.targets.altitude))
    print("")
    print("Controls:")
    print("  W/S - Forward/Backward (hover)")
    print("  A/D - Left/Right strafe (hover) or Bank turn (cruise)")
    print("  Q/E - Altitude up/down (hover mode)")
    print("  M   - Toggle Hover/Cruise mode")
    print("  X   - Emergency stop")
    print("  T   - Auto-tune PIDs")
    print("  R   - Reset targets to current state")
    print("")
    print("Starting main loop...")
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
            OS.updateHUD()
            last_hud_update = now
        end
    end
end

function OS.controlTick()
    if not flight then return end

    local keys = hw.readInputs()
    flight:processInputs(keys)
    local outputs = flight:update()
end

function OS.handleKey(key, held)
    if held then return end
    local keys = require("keys")

    if key == keys.m then
        local result = {flight:toggleMode()}
        local changed = result[1]
        if changed then
            local old_mode = result[2]
            local new_mode = result[3]
            status_message = "Mode: " .. new_mode
            status_time = os.clock()
            OS.setColor(colors.yellow)
            print("[" .. string.format("%.0f", os.clock()) .. "] Mode: " .. old_mode .. " -> " .. new_mode)
            OS.resetColor()
        end

    elseif key == keys.x then
        flight:emergencyStop()
        status_message = "EMERGENCY STOP"
        status_time = os.clock()
        OS.setColor(colors.red)
        print("[" .. string.format("%.0f", os.clock()) .. "] EMERGENCY STOP")
        OS.resetColor()

    elseif key == keys.t then
        flight:requestAutoTune()
        status_message = "Auto-tuning PIDs..."
        status_time = os.clock()
        print("[" .. string.format("%.0f", os.clock()) .. "] Auto-tune requested")

    elseif key == keys.r then
        local state = hw.getShipState()
        flight.targets.altitude = state.altitude
        flight.targets.yaw = state.yaw
        flight.targets.move_forward = 0
        flight.targets.move_right = 0
        status_message = "Targets reset"
        status_time = os.clock()
        print("[" .. string.format("%.0f", os.clock()) .. "] Targets reset")

    elseif key == keys.q then
        if flight.mode == Flight.MODE_HOVER then
            flight.targets.altitude = flight.targets.altitude + 2
            status_message = "Alt+: " .. string.format("%.1f", flight.targets.altitude)
            status_time = os.clock()
        end

    elseif key == keys.e then
        if flight.mode == Flight.MODE_HOVER then
            flight.targets.altitude = flight.targets.altitude - 2
            status_message = "Alt-: " .. string.format("%.1f", flight.targets.altitude)
            status_time = os.clock()
        end

    elseif key == keys.n then
        local hud = require("lib.hud")
        hud.nextTab()
        status_message = "Tab: " .. hud.getTab():upper()
        status_time = os.clock()
    end
end

function OS.handlePeripheralConnect(name, peripheralType)
    print("[" .. string.format("%.0f", os.clock()) .. "] Connected: " .. name)
    status_message = "Connected: " .. name
    status_time = os.clock()
end

function OS.handlePeripheralDisconnect(name)
    print("[" .. string.format("%.0f", os.clock()) .. "] Disconnected: " .. name)
    status_message = "Disconnected: " .. name
    status_time = os.clock()
end

function OS.updateHUD()
    local mon = hw.getDevice("main_monitor")
    if not mon then return end

    local status = flight:getStatus()
    local hud = require("lib.hud")
    hud.render(mon, status, config, status_message)
end

function OS.displayStatus()
    if not flight then return end
    local status = flight:getStatus()
    local now = os.clock()

    OS.setColor(colors.lightBlue)
    print(string.format(
        "[%s] ALT:%.0f/%.0f | P:%.1f R:%.1f | Y:%.0f | SPD:%.1f | %s",
        string.format("%.0f", now),
        status.altitude, status.target_altitude,
        status.pitch, status.roll,
        status.yaw,
        status.speed,
        status.mode
    ))
    OS.resetColor()
end

function OS.setColor(color)
    if term.isColor() then term.setTextColor(color) end
end

function OS.resetColor()
    if term.isColor() then term.setTextColor(colors.white) end
end

function OS.shutdown()
    running = false
    if flight then flight:emergencyStop() end
    print("ArtCorpOS shutdown.")
end

os.atExit(function() OS.shutdown() end)

return OS
