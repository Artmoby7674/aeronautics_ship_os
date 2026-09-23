local Hardware = {}
local config = nil
local devices = {}

function Hardware.init(cfg)
    config = cfg
end

function Hardware.scan()
    local found = {}

    local modem = peripheral.find("modem", function(name, m)
        return not m.isWireless()
    end)
    if modem then
        local names = modem.getNamesRemote()
        for _, name in ipairs(names) do
            local devType = modem.getTypeRemote(name)
            table.insert(found, { name = name, type = devType, via = "wired" })
        end
    end

    local wireless = peripheral.find("modem", function(name, m)
        return m.isWireless()
    end)
    if wireless then
        local types_to_find = { "monitor", "speaker" }
        for _, ptype in ipairs(types_to_find) do
            local dev = peripheral.find(ptype)
            if dev then
                local wname = peripheral.getName(dev)
                if wname then
                    local already = false
                    for _, d in ipairs(found) do
                        if d.name == wname then already = true break end
                    end
                    if not already then
                        table.insert(found, { name = wname, type = ptype, via = "wireless" })
                    end
                end
            end
        end
    end

    if #found == 0 then
        return nil, "No peripherals found (wired or wireless)"
    end
    return found
end

function Hardware.connect()
    local connected = {}
    local missing = {}

    for key, name in pairs(config.peripherals) do
        if name and name ~= "" then
            local wrapped = peripheral.wrap(name)
            if wrapped then
                connected[key] = wrapped
                print("  [OK] " .. key .. " -> " .. name)
            else
                table.insert(missing, key .. " (" .. tostring(name) .. ")")
                print("  [FAIL] " .. key .. " -> " .. tostring(name))
            end
        end
    end

    devices = connected
    return connected, missing
end

function Hardware.getDevice(key)
    return devices[key]
end

function Hardware.readInputs()
    local keys = {}
    for relayKey, sides in pairs(config.input_map or {}) do
        local relay = devices[relayKey]
        if relay then
            for key, side in pairs(sides) do
                local success, val = pcall(function()
                    return relay.getAnalogInput(side)
                end)
                keys[key] = success and val or 0
            end
        end
    end
    return keys
end

function Hardware.isKeyPressed(key)
    local keys = Hardware.readInputs()
    return (keys[key] or 0) > 0
end

function Hardware.getProximity()
    local prox = config.proximity
    if not prox then return 0 end
    local relay = devices[prox.input_key]
    if not relay then return 0 end
    local ok, val = pcall(function()
        return relay.getAnalogInput(prox.side)
    end)
    if not ok or type(val) ~= "number" then return 0 end
    return math.max(0, math.min(15, math.floor(val)))
end

function Hardware.setGear(deployed)
    local g = config.gear_output
    if not g then return false end
    local relay = devices[g.relay]
    if not relay then return false end
    local value = deployed and (g.deploy or 15) or (g.retract or 0)
    local ok = pcall(function()
        relay.setAnalogOutput(g.side, value)
    end)
    return ok
end

function Hardware.setPropellerOutput(prop, side, value)
    local mapping = (config.output_map or {})[prop]
    if not mapping then return false end

    local relay = devices[mapping.relay]
    if not relay then return false end

    local relaySide = mapping[side]
    if not relaySide then return false end

    value = math.max(0, math.min(15, math.floor(value + 0.5)))

    local success = pcall(function()
        relay.setAnalogOutput(relaySide, value)
    end)

    return success
end

function Hardware.setRearOutput(direction, value)
    local mapping = (config.output_map or {}).REAR
    if not mapping then return false end

    local relay = devices[mapping.relay]
    if not relay then return false end

    local relaySide = mapping[direction]
    if not relaySide then return false end

    value = math.max(0, math.min(15, math.floor(value + 0.5)))

    local success = pcall(function()
        relay.setAnalogOutput(relaySide, value)
    end)

    return success
end

function Hardware.cutAllOutputs()
    for prop, mapping in pairs(config.output_map or {}) do
        local relay = devices[mapping.relay]
        if relay then
            pcall(function()
                if mapping.tilt_fwd then relay.setAnalogOutput(mapping.tilt_fwd, 0) end
                if mapping.tilt_bwd then relay.setAnalogOutput(mapping.tilt_bwd, 0) end
                if mapping.speed    then relay.setAnalogOutput(mapping.speed, 0) end
                if mapping.fw       then relay.setAnalogOutput(mapping.fw, 0) end
                if mapping.bw       then relay.setAnalogOutput(mapping.bw, 0) end
            end)
        end
    end
end

function Hardware.setAllSpeed(value)
    for _, prop in ipairs({"FL", "FR", "RL", "RR"}) do
        Hardware.setPropellerOutput(prop, "speed", value)
    end
end

function Hardware.setAllTilt(value)
    for _, prop in ipairs({"FL", "FR", "RL", "RR"}) do
        if value >= 0 then
            Hardware.setPropellerOutput(prop, "tilt_fwd", value)
            Hardware.setPropellerOutput(prop, "tilt_bwd", 0)
        else
            Hardware.setPropellerOutput(prop, "tilt_fwd", 0)
            Hardware.setPropellerOutput(prop, "tilt_bwd", math.abs(value))
        end
    end
end

function Hardware.getShipState()
    local state = {
        position = { x = 0, y = 0, z = 0 },
        velocity = { x = 0, y = 0, z = 0 },
        angularVelocity = { x = 0, y = 0, z = 0 },
        pitch = 0,
        roll = 0,
        yaw = 0,
        mass = 0,
        altitude = 0,
        speed = 0,
        climb_rate = 0,
    }

    local ok, err = pcall(function()
        local pose = sublevel.getLogicalPose()
        if pose and pose.position then
            state.position = { x = pose.position.x, y = pose.position.y, z = pose.position.z }
            state.altitude = pose.position.y
        end

        if pose and pose.orientation then
            local q = pose.orientation
            state.pitch = math.deg(math.atan2(2 * (q.w * q.x + q.y * q.z),
                1 - 2 * (q.x * q.x + q.y * q.y)))
            state.roll = math.deg(math.asin(math.max(-1, math.min(1,
                2 * (q.w * q.y - q.z * q.x)))))
            state.yaw = math.deg(math.atan2(2 * (q.w * q.z + q.x * q.y),
                1 - 2 * (q.y * q.y + q.z * q.z)))
        end

        local vel = sublevel.getLinearVelocity()
        if vel then
            state.velocity = { x = vel.x, y = vel.y, z = vel.z }
            state.speed = math.sqrt(vel.x * vel.x + vel.z * vel.z)
            state.climb_rate = vel.y
        end

        local angVel = sublevel.getAngularVelocity()
        if angVel then
            state.angularVelocity = { x = angVel.x, y = angVel.y, z = angVel.z }
        end

        state.mass = sublevel.getMass() or 0
    end)

    if not ok then
        state.sable_error = err
    end

    return state
end

function Hardware.hasSable()
    return type(sublevel) == "table" and type(sublevel.getLogicalPose) == "function"
end

function Hardware.playNote(instrument, volume, pitch)
    local spk = devices.speaker
    if spk then
        pcall(function()
            spk.playNote(instrument, volume or 1, pitch or 1)
        end)
    end
end

return Hardware
