return {
    name = "Atlas",
    version = "1.0",

    -- Offset of computer from center of mass (in blocks)
    -- Positive X = right, Positive Y = up, Positive Z = forward
    computer_offset = { x = 0, y = 6, z = 56 },

    -- Wired network device names
    -- These are the names assigned to each relay during boot scan
    peripherals = {
        -- Input relays (typewriter receiver links on each side)
        input_1 = "relay_1",  -- WASD: W=front, S=back, A=left, D=right
        input_2 = "relay_2",  -- Q/E: Q=front, E=back

        -- Output relays (propeller transmitter links on each side)
        output_FL = "relay_3",  -- Front-left: tiltFwd=front, tiltBwd=back, speed=right
        output_FR = "relay_4",  -- Front-right: tiltFwd=front, tiltBwd=back, speed=right
        output_RL = "relay_5",  -- Rear-left: tiltFwd=front, tiltBwd=back, speed=right
        output_RR = "relay_6",  -- Rear-right: tiltFwd=front, tiltBwd=back, speed=right
        output_REAR = "relay_7", -- Rear thrusters: fw=front, bw=back

        -- Monitors
        -- main_monitor = "monitor_0",

        -- Speaker
        -- speaker = "speaker_0",
    },

    -- Which side of each input relay has which key's link
    input_map = {
        input_1 = {
            W = "front",
            S = "back",
            A = "left",
            D = "right",
        },
        input_2 = {
            Q = "front",
            E = "back",
        },
    },

    -- Which side of each output relay has which propeller function
    output_map = {
        FL   = { relay = "output_FL", tilt_fwd = "front", tilt_bwd = "back", speed = "right" },
        FR   = { relay = "output_FR", tilt_fwd = "front", tilt_bwd = "back", speed = "right" },
        RL   = { relay = "output_RL", tilt_fwd = "front", tilt_bwd = "back", speed = "right" },
        RR   = { relay = "output_RR", tilt_fwd = "front", tilt_bwd = "back", speed = "right" },
        REAR = { relay = "output_REAR", fw = "front", bw = "back" },
    },

    -- Propeller positions relative to center of mass (in blocks)
    propellers = {
        FL = { x = -3, y = 0, z = 3 },
        FR = { x = 3,  y = 0, z = 3 },
        RL = { x = -3, y = 0, z = -3 },
        RR = { x = 3,  y = 0, z = -3 },
    },

    -- Physics limits
    limits = {
        max_speed = 80,         -- m/s
        max_altitude = 320,     -- blocks above world origin
        min_altitude = 65,      -- minimum safe altitude
        max_tilt = 15,          -- degrees
        max_climb_rate = 10,    -- blocks/s
        max_descent_rate = 5,   -- blocks/s
        hover_speed = 2,        -- blocks/s for WASD movement in hover
    },

    -- Fuel system
    fuel = {
        type = "charcoal",
        smelt_time = 80,            -- seconds per item
        items_per_smelt = 8,        -- items smelted per fuel item
        tank_capacity = 12960,      -- total seconds of fuel (6x9 burners)
    },

    -- PID controller defaults (auto-tuned at runtime)
    pid = {
        altitude = { kp = 1.0, ki = 0.1, kd = 0.5, integral_limit = 10 },
        pitch    = { kp = 2.0, ki = 0.0, kd = 1.0, integral_limit = 5 },
        roll     = { kp = 2.0, ki = 0.0, kd = 1.0, integral_limit = 5 },
        yaw      = { kp = 1.5, ki = 0.0, kd = 0.8, integral_limit = 5 },
    },

    -- Redstone signal range
    signal = {
        max = 15,
        min = 0,
        -- Speed signal: 15 = full speed, 0 = stopped
        -- Tilt signals: 15 = full tilt, 0 = no tilt
        -- The analog clutch linearly reduces speed from 15 (no reduction) to 0 (full reduction)
    },
}
