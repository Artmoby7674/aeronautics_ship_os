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

function Hardware.hasFeature(name)
    if not config or not config.features then return true end
    local v = config.features[name]
    if v == nil then return true end
    return not not v
end

local function engineCfg()
    return config and config.engine or nil
end

function Hardware.setEngineStarter(active)
    local e = engineCfg()
    if not e or not Hardware.hasFeature("engine_auto_start") then return false end
    local relay = devices[e.relay_key or "engine_relay"]
    if not relay then return false end
    local value = active and (e.active or 15) or (e.inactive or 0)
    return pcall(function()
        relay.setAnalogOutput(e.start_side or "left", value)
    end)
end

function Hardware.setClutch(engaged)
    local e = engineCfg()
    if not e or not Hardware.hasFeature("clutch") then return false end
    local relay = devices[e.relay_key or "engine_relay"]
    if not relay then return false end
    local value = engaged and (e.active or 15) or (e.inactive or 0)
    return pcall(function()
        relay.setAnalogOutput(e.clutch_side or "right", value)
    end)
end

function Hardware.engineOutputsOff()
    Hardware.setEngineStarter(false)
    Hardware.setClutch(false)
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

    -- Slow-downer: engine is always ~256 RPM; higher redstone = more braking.
    -- Flight layer uses thrust 0..15 (0 = stopped). Invert at the wire.
    if side == "speed" then
        value = 15 - value
    end

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
                -- Speed is inverted slow-down: 15 = fully braked / props stopped
                if mapping.speed    then relay.setAnalogOutput(mapping.speed, 15) end
                if mapping.fw       then relay.setAnalogOutput(mapping.fw, 0) end
                if mapping.bw       then relay.setAnalogOutput(mapping.bw, 0) end
            end)
        end
    end
    -- Propulsion safety: never leave starter high from a cut
    Hardware.setEngineStarter(false)
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

-- Body frame (Create/Sable): +X east, +Y up, +Z south.
-- Pitch about X, roll about Z, yaw about Y (YXZ / Advanced-Math toEuler).
-- toEuler returns (roll, yaw, pitch) — not (pitch, yaw, roll).
-- Output convention: pitch + = nose down, roll + = right down (MC-style).
local function quatAttitude(q)
    if type(q) ~= "table" then
        return 0, 0, 0
    end

    if type(q.toEuler) == "function" then
        local ok, r, y, p = pcall(q.toEuler, q)
        if ok and type(p) == "number" and type(y) == "number" and type(r) == "number" then
            local norm = math.sqrt(p * p + y * y + r * r)
            if norm ~= norm or norm == math.huge then
                return 0, 0, 0
            end
            return -math.deg(p), -math.deg(r), math.deg(y)
        end
    end

    local x, y, z, w
    if type(q.v) == "table" and q.a ~= nil then
        x, y, z, w = q.v.x, q.v.y, q.v.z, q.a
    else
        x, y, z, w = q.x, q.y, q.z, q.w
    end
    if type(x) ~= "number" or type(y) ~= "number"
        or type(z) ~= "number" or type(w) ~= "number" then
        return 0, 0, 0
    end

    local singularity = 2 * (y * z - x * w)
    local pitch, yaw, roll
    if singularity > 0.9999 then
        pitch = -math.pi / 2
        yaw = math.atan2(-2 * (x * y - z * w), 2 * (w * w + x * x) - 1)
        roll = 0
    elseif singularity < -0.9999 then
        pitch = math.pi / 2
        yaw = -math.atan2(-2 * (x * y - z * w), 2 * (w * w + x * x) - 1)
        roll = 0
    else
        pitch = math.asin(-singularity)
        yaw = math.atan2(2 * (x * z + y * w), 2 * (w * w + z * z) - 1)
        roll = math.atan2(2 * (x * y + z * w), 2 * (w * w + y * y) - 1)
    end
    return math.deg(pitch), math.deg(roll), math.deg(yaw)
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
            local pitch, roll, yaw = quatAttitude(pose.orientation)
            state.pitch = pitch
            state.roll = roll
            state.yaw = yaw
        end

        local vel = sublevel.getLinearVelocity()
        if vel then
            state.velocity = { x = vel.x, y = vel.y, z = vel.z }
            state.speed = math.sqrt(vel.x * vel.x + vel.z * vel.z)
            state.climb_rate = vel.y
        end

        local angVel = sublevel.getAngularVelocity()
        if angVel then
            state.angularVelocity = { x = angVel.x or 0, y = angVel.y or 0, z = angVel.z or 0 }
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
