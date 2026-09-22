-- ArtCorpOS - Monitor Painter
-- Draw on the cockpit monitor from the computer terminal
-- Run: paint

local SCALE = 0.5
local MON_W, MON_H = 48, 20

local colors_list = {
    { name = "black",      val = colors.black },
    { name = "blue",       val = colors.blue },
    { name = "lightBlue",  val = colors.lightBlue },
    { name = "cyan",       val = colors.cyan },
    { name = "green",      val = colors.green },
    { name = "lime",       val = colors.lime },
    { name = "yellow",     val = colors.yellow },
    { name = "orange",     val = colors.orange },
    { name = "red",        val = colors.red },
    { name = "magenta",    val = colors.magenta },
    { name = "purple",     val = colors.purple },
    { name = "pink",       val = colors.pink },
    { name = "white",      val = colors.white },
    { name = "gray",       val = colors.gray },
    { name = "lightGray",  val = colors.lightGray },
    { name = "brown",      val = colors.brown },
}

local cursor_x = 1
local cursor_y = 1
local brush = colors.cyan
local brush_idx = 4
local mon = nil
local pixels = {}
local show_controls = false
local last_cursor = { x = 0, y = 0 }

local function findMonitor()
    local m = peripheral.find("monitor", function(name, dev)
        local w, h = dev.getSize()
        return w >= MON_W and h >= MON_H
    end)
    if m then return m end
    return peripheral.find("monitor")
end

local function init()
    mon = findMonitor()
    if not mon then
        print("ERROR: No monitor found!")
        print("Connect a monitor via wired modem.")
        return false
    end
    pcall(function() mon.setTextScale(SCALE) end)
    MON_W, MON_H = mon.getSize()
    mon.setBackgroundColor(colors.black)
    mon.clear()

    if fs.exists("paint_data") then
        local f = fs.open("paint_data", "r")
        if f then
            local content = f.readAll()
            f.close()
            if content and content ~= "" then
                pixels = textutils.unserialise(content) or {}
            end
        end
    end
    return true
end

local function drawPixel(x, y, color)
    if x < 1 or x > MON_W or y < 1 or y > MON_H then return end
    mon.setBackgroundColor(color)
    mon.setCursorPos(x, y)
    mon.write(string.char(219))
    mon.setBackgroundColor(colors.black)
    pixels[x .. "," .. y] = color
end

local function clearPixel(x, y)
    if x < 1 or x > MON_W or y < 1 or y > MON_H then return end
    mon.setBackgroundColor(colors.black)
    mon.setCursorPos(x, y)
    mon.write(" ")
    pixels[x .. "," .. y] = nil
end

local function redrawAll()
    mon.setBackgroundColor(colors.black)
    mon.clear()
    for key, color in pairs(pixels) do
        local x, y = key:match("^(%-?%d+),(%-?%d+)$")
        x, y = tonumber(x), tonumber(y)
        if x and y then drawPixel(x, y, color) end
    end
end

local function drawMonitorCursor()
    mon.setBackgroundColor(colors.white)
    mon.setTextColor(colors.black)
    mon.setCursorPos(cursor_x, cursor_y)
    mon.write(string.char(219))
    mon.setBackgroundColor(colors.black)
    mon.setTextColor(colors.white)
end

local function drawTerminal()
    term.setBackgroundColor(colors.black)
    term.clear()
    term.setCursorPos(1, 1)

    term.setTextColor(colors.cyan)
    print("=== MONITOR PAINTER ===")
    print("")

    term.setTextColor(colors.white)
    term.write("Monitor: ")
    term.setTextColor(colors.lightBlue)
    print(MON_W .. "x" .. MON_H)

    term.setTextColor(colors.white)
    term.write("Cursor:  ")
    term.setTextColor(colors.lightBlue)
    print(cursor_x .. "," .. cursor_y)

    term.setTextColor(colors.white)
    term.write("Brush:   ")
    term.setTextColor(brush)
    local cidx = colors_list[brush_idx]
    print(cidx and cidx.name or "?")

    term.setTextColor(colors.white)
    term.write("Pixels:  ")
    term.setTextColor(colors.lightBlue)
    local count = 0
    for _ in pairs(pixels) do count = count + 1 end
    print(count)

    print("")
    term.setTextColor(colors.gray)
    print("Arrows/WASD Move  Space Paint")
    print("Backspace    Erase X     Help")

    if show_controls then
        print("")
        term.setTextColor(colors.cyan)
        print("--- CONTROLS ---")
        term.setTextColor(colors.white)
        print("  Arrows/WASD  Move cursor")
        print("  Space        Paint pixel")
        print("  Backspace    Erase pixel")
        print("  1-9,0        Select color")
        print("  [ / ]        Cycle colors")
        print("  L            Fill line right")
        print("  R            Fill rect to cursor")
        print("  C            Clear all")
        print("  S            Save")
        print("  Q            Quit")
        print("")
        term.setTextColor(colors.cyan)
        print("--- COLORS ---")
        for i, c in ipairs(colors_list) do
            local key = i <= 9 and tostring(i) or "0"
            term.setTextColor(c.val)
            term.write(key .. ":" .. c.name .. "  ")
            if i % 3 == 0 then print("") end
        end
        term.setTextColor(colors.white)
    end
end

local function saveData()
    local f = fs.open("paint_data", "w")
    if f then
        f.write(textutils.serialise(pixels))
        f.close()
    end
end

local function clearAll()
    pixels = {}
    mon.setBackgroundColor(colors.black)
    mon.clear()
end

-- ============================================================
-- Main
-- ============================================================

if not init() then return end
redrawAll()
drawTerminal()

while true do
    local event, key = os.pullEvent("key")

    if key == keys.q then
        mon.setBackgroundColor(colors.black)
        mon.clear()
        term.clear()
        term.setCursorPos(1, 1)
        print("Painter closed.")
        return

    elseif key == keys.x then
        show_controls = not show_controls

    elseif key == keys.left or key == keys.a then
        cursor_x = math.max(1, cursor_x - 1)
    elseif key == keys.right or key == keys.d then
        cursor_x = math.min(MON_W, cursor_x + 1)
    elseif key == keys.up or key == keys.w then
        cursor_y = math.max(1, cursor_y - 1)
    elseif key == keys.down or key == keys.s then
        cursor_y = math.min(MON_H, cursor_y + 1)

    elseif key == keys.space then
        drawPixel(cursor_x, cursor_y, brush)
    elseif key == keys.backspace then
        clearPixel(cursor_x, cursor_y)

    elseif key == keys.l then
        for x = cursor_x, MON_W do
            drawPixel(x, cursor_y, brush)
        end
    elseif key == keys.r then
        local x1, y1 = 1, 1
        local x2, y2 = cursor_x, cursor_y
        if x1 > x2 then x1, x2 = x2, x1 end
        if y1 > y2 then y1, y2 = y2, y1 end
        for y = y1, y2 do
            for x = x1, x2 do
                drawPixel(x, y, brush)
            end
        end

    elseif key == keys.c then
        clearAll()
    elseif key == keys.s then
        saveData()

    elseif key == keys.leftBracket then
        brush_idx = brush_idx - 1
        if brush_idx < 1 then brush_idx = #colors_list end
        brush = colors_list[brush_idx].val
    elseif key == keys.rightBracket then
        brush_idx = brush_idx + 1
        if brush_idx > #colors_list then brush_idx = 1 end
        brush = colors_list[brush_idx].val
    else
        for i = 1, 9 do
            if key == keys[i] then
                brush_idx = i
                brush = colors_list[i].val
                break
            end
        end
        if key == keys["0"] then
            brush_idx = 10
            brush = colors_list[10].val
        end
    end

    drawTerminal()
    drawMonitorCursor()
end
