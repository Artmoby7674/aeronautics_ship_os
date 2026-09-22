-- ArtCorpOS - Monitor Painter
-- Design your HUD layout on the monitor
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
local show_help = false

-- Grid character for drawing
local GRID_CHAR = string.char(219)

local function findMonitor()
    -- Try wired first
    local m = peripheral.find("monitor", function(name, dev)
        local w, h = dev.getSize()
        return w >= MON_W and h >= MON_H
    end)
    if m then return m end

    -- Try any monitor
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

    -- Load existing pixels if any
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
    mon.write(GRID_CHAR)
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
        if x and y then
            drawPixel(x, y, color)
        end
    end
end

local function drawCursor()
    -- Flash cursor
    local current = pixels[cursor_x .. "," .. cursor_y]
    local c = current or colors.black
    -- Invert for visibility
    mon.setTextColor(colors.white)
    mon.setBackgroundColor(colors.black)
    mon.setCursorPos(cursor_x, cursor_y)
    mon.write("+")
end

local function drawHUD()
    -- Info bar at top of terminal
    term.setBackgroundColor(colors.black)
    term.clear()
    term.setCursorPos(1, 1)

    term.setTextColor(colors.cyan)
    print("=== MONITOR PAINTER ===")
    print("")
    term.setTextColor(colors.white)
    print("Monitor: " .. MON_W .. "x" .. MON_H .. " chars")
    print("Cursor: " .. cursor_x .. "," .. cursor_y)

    local cidx = colors_list[brush_idx]
    term.setTextColor(brush)
    print("Brush: " .. (cidx and cidx.name or "?"))
    term.setTextColor(colors.white)
    print("Pixels: " .. #pixels)

    print("")
    term.setTextColor(colors.lightBlue)
    print("CONTROLS:")
    print("  Arrows/WASD - Move cursor")
    print("  Space       - Paint pixel")
    print("  Backspace   - Erase pixel")
    print("  1-9,0       - Select color")
    print("  [/]         - Prev/Next color")
    print("  L           - Fill line (hold)")
    print("  R           - Fill rect (hold)")
    print("  C           - Clear all")
    print("  S           - Save")
    print("  H           - Toggle help")
    print("  Q           - Quit")

    if show_help then
        print("")
        term.setTextColor(colors.yellow)
        print("COLORS:")
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
        print("Saved!")
    end
end

local function clearAll()
    pixels = {}
    mon.setBackgroundColor(colors.black)
    mon.clear()
    print("Cleared!")
end

-- ============================================================
-- Main
-- ============================================================

if not init() then return end

redrawAll()
drawCursor()
drawHUD()

local fill_start = nil

while true do
    local event, key = os.pullEvent("key")

    if key == keys.q then
        mon.setBackgroundColor(colors.black)
        mon.clear()
        term.clear()
        term.setCursorPos(1, 1)
        print("Painter closed.")
        return

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
        -- Fill horizontal line from cursor to edge
        for x = cursor_x, MON_W do
            drawPixel(x, cursor_y, brush)
        end

    elseif key == keys.r then
        -- Fill rectangle from 1,1 to cursor
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

    elseif key == keys.h then
        show_help = not show_help

    elseif key == keys.leftBracket then
        brush_idx = brush_idx - 1
        if brush_idx < 1 then brush_idx = #colors_list end
        brush = colors_list[brush_idx].val

    elseif key == keys.rightBracket then
        brush_idx = brush_idx + 1
        if brush_idx > #colors_list then brush_idx = 1 end
        brush = colors_list[brush_idx].val

    else
        -- Number keys 1-9
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

    redrawAll()
    drawCursor()
    drawHUD()
end
