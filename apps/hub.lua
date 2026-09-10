local Scrollbar = dofile("/os/lib/scrollbar.lua")

local M = {}
M.id        = "hub"
M.name      = "Hub"
M.icon      = "Hb"
M.iconBg    = colors.cyan
M.iconFg    = colors.black
M.version   = 4
M.category  = "network"
M.protocols = {"factory_hub"}

local function nowSeconds()
    if os.epoch then return math.floor(os.epoch("utc") / 1000) end
    return math.floor(os.clock())
end

local function padRight(s, n)
    s = tostring(s or "")
    if #s >= n then return string.sub(s, 1, n) end
    return s .. string.rep(" ", n - #s)
end

local HEADER_ROWS = 2

local function buildSorted(computers)
    local list = {}
    for id, info in pairs(computers or {}) do
        table.insert(list, {id = tonumber(id) or 0, info = info})
    end
    table.sort(list, function(a, b) return a.id < b.id end)
    return list
end

local function iterateRows(sorted, scroll, winH, confirmReboot, fn)
    local reserveBottom = confirmReboot and 3 or 0
    local maxY    = winH - reserveBottom
    local contentY = HEADER_ROWS + 1
    for i = scroll + 1, #sorted do
        if contentY > maxY then break end
        fn(sorted[i], contentY)
        contentY = contentY + 1
    end
end

function M.init(win, ctx)
    local st = {
        win           = win,
        computers     = {},
        time          = 0,
        scroll        = 0,
        confirmReboot = nil,
        hubComputer   = ctx.config.hubComputer,
        hubProtocol   = ctx.config.hubProtocol,
        controlProtocol = ctx.config.controlProtocol,
        ctx           = ctx,
        sb            = Scrollbar.create({
            thumbBg = colors.cyan,
            thumbFg = colors.black,
        }),
    }
    return st
end

function M.draw(st, win)
    local W, H = win.getSize()
    win.setBackgroundColor(colors.black)
    win.clear()

    -- Row 1: hub status
    local age   = nowSeconds() - (st.time or 0)
    local hubOk = age < 15
    win.setCursorPos(1, 1)
    win.setTextColor(hubOk and colors.lime or colors.red)
    win.write(padRight(hubOk and ("HUB OK " .. age .. "s") or ("HUB OFFLINE " .. age .. "s"), W - 3))
    win.setTextColor(colors.gray)
    win.write(" /-")

    -- Row 2: column header. Резервируем последнюю колонку под scrollbar.
    local idW   = 4
    local stW   = 8
    local nameW = W - idW - stW - 1
    win.setCursorPos(1, 2)
    win.setBackgroundColor(colors.gray)
    win.setTextColor(colors.white)
    win.write(padRight("ID",   idW))
    win.write(padRight("NAME", nameW))
    win.write(padRight("STATUS", stW))

    -- Computer rows
    local sorted = buildSorted(st.computers)
    iterateRows(sorted, st.scroll, H, st.confirmReboot, function(entry, contentY)
        local info  = entry.info or {}
        local ago   = info.lastSeen and (nowSeconds() - info.lastSeen) or nil
        local old   = ago and ago > 25
        local online = info.online
        local sFg   = online and (old and colors.yellow or colors.lime) or colors.red
        local sStr  = online and (old and " OLD    " or " ONLINE ") or " OFFLINE"
        local lineBg = (contentY % 2 == 0) and colors.gray or colors.black

        win.setCursorPos(1, contentY)
        win.setBackgroundColor(lineBg)
        win.setTextColor(colors.lightGray)
        win.write(padRight(tostring(entry.id), idW))
        win.setTextColor(colors.white)
        win.write(padRight(info.label or ("PC-" .. entry.id), nameW))
        win.setTextColor(sFg)
        win.write(padRight(sStr, stW))
    end)

    -- Scrollbar справа.
    local reserveBottom = st.confirmReboot and 3 or 0
    local sbTop = HEADER_ROWS + 1
    local sbBottom = H - reserveBottom
    if sbBottom >= sbTop then
        local visRows = sbBottom - sbTop + 1
        st.sb:setBounds(W, sbTop, sbBottom)
        st.sb:setContent(visRows, #sorted)
        st.sb:setScroll(st.scroll)
        st.sb:draw(win)
    end

    -- Reboot confirmation dialog
    if st.confirmReboot then
        local id   = st.confirmReboot
        local info = st.computers[tostring(id)] or {}
        win.setCursorPos(1, H - 2)
        win.setBackgroundColor(colors.orange)
        win.setTextColor(colors.black)
        win.write(padRight("  REBOOT PC-" .. tostring(id) .. " " .. (info.label or "") .. " ?", W))
        win.setCursorPos(1, H - 1)
        local halfW = math.floor(W / 2)
        win.setBackgroundColor(colors.red)
        win.setTextColor(colors.white)
        win.write(padRight("  YES", halfW))
        win.setBackgroundColor(colors.gray)
        win.write(padRight("  NO", W - halfW))
    end
end

function M.onEvent(st, event, p1, p2, p3, p4)
    if event == "mouse_click" or event == "monitor_touch" then
        local btn, x, y = p1, p2, p3

        local W, H = st.win.getSize()

        -- Confirmation dialog
        if st.confirmReboot then
            local yYes = H - 1
            if y == yYes then
                if x <= math.floor(W / 2) then
                    st.ctx.send(st.hubComputer, {
                        type     = "hub_command",
                        action   = "reboot",
                        targetId = st.confirmReboot,
                    }, st.hubProtocol)
                end
                st.confirmReboot = nil
                return st, true
            end
            return st, false
        end

        -- Scrollbar справа.
        if st.sb:onClick(x, y) then
            st.scroll = st.sb.scroll
            return st, true
        end

        -- Tap on a row to confirm reboot
        local sorted = buildSorted(st.computers)
        iterateRows(sorted, st.scroll, H, nil, function(entry, contentY)
            if y == contentY then
                st.confirmReboot = entry.id
            end
        end)
        return st, true

    elseif event == "mouse_drag" then
        if st.sb:onDrag(p2, p3) then
            st.scroll = st.sb.scroll
            return st, true
        end
        return st, false

    elseif event == "mouse_scroll" then
        st.sb:scrollBy(p1)
        st.scroll = st.sb.scroll
        return st, true

    elseif event == "rednet_message" then
        local senderId, msg, proto = p1, p2, p3
        if proto == st.hubProtocol
            and senderId == st.hubComputer
            and type(msg) == "table" and msg.type == "hub_snapshot"
        then
            st.computers = msg.computers or {}
            st.time      = nowSeconds()
            return st, true
        end

    elseif event == "timer" then
        return st, true
    end

    return st, false
end

return M
