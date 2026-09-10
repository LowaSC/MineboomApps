local M = {}
M.id        = "storage"
M.name      = "RS Store"
M.icon      = "RS"
M.iconBg    = colors.lightBlue
M.iconFg    = colors.black
M.version   = 4
M.category  = "automation"
M.protocols = {"factory_rs_dashboard"}

local function nowSeconds()
    if os.epoch then return math.floor(os.epoch("utc") / 1000) end
    return math.floor(os.clock())
end

local function clamp(v, lo, hi)
    return math.max(lo, math.min(hi, v))
end

local function formatCount(n)
    n = tonumber(n) or 0
    if n >= 1e9 then return string.format("%.1fB", n/1e9) end
    if n >= 1e6 then return string.format("%.1fM", n/1e6) end
    if n >= 1e3 then return string.format("%.1fk", n/1e3) end
    return tostring(math.floor(n))
end

local function formatPercent(v)
    if type(v) ~= "number" then return "--" end
    return tostring(math.floor(v*100+0.5)) .. "%"
end

local function storageBarColor(r)
    if type(r) ~= "number" then return colors.lime end
    if r >= 0.9 then return colors.red end
    if r >= 0.7 then return colors.yellow end
    return colors.lime
end

local function writeClipped(mon, x, y, text, maxW, fg, bg)
    local s = tostring(text or "")
    if maxW <= 0 then return end
    if #s > maxW then s = string.sub(s, 1, maxW) end
    mon.setCursorPos(x, y); mon.setTextColor(fg); mon.setBackgroundColor(bg); mon.write(s)
end

local function fillRect(mon, x, y, w, h, bg)
    for row = 0, h-1 do
        mon.setCursorPos(x, y+row); mon.setBackgroundColor(bg); mon.write(string.rep(" ", w))
    end
end

local function drawBar(ctx, x, y, w, value, label, fillBg, emptyBg, fg)
    local ratio   = clamp(value or 0, 0, 1)
    local fillW   = math.floor(w * ratio + 0.5)
    ctx.monitor.setCursorPos(x, y); ctx.monitor.setBackgroundColor(emptyBg)
    ctx.monitor.write(string.rep(" ", w))
    if fillW > 0 then
        ctx.monitor.setCursorPos(x, y); ctx.monitor.setBackgroundColor(fillBg)
        ctx.monitor.write(string.rep(" ", fillW))
    end
    local text = tostring(label or "")
    local tx   = x + math.floor((w - #text) / 2)
    if tx < x then tx = x end
    for i = 1, #text do
        local cx = tx + i - 1
        if cx >= x and cx < x + w then
            local ibg = (cx < x + fillW) and fillBg or emptyBg
            writeClipped(ctx.monitor, cx, y, string.sub(text, i, i), 1, fg, ibg)
        end
    end
end

local function drawCard(ctx, x, y, w, title, value, bg, fg)
    local titleFg = (ctx.theme and ctx.theme.mutedFg) or colors.lightGray
    fillRect(ctx.monitor, x, y, w, 3, bg)
    writeClipped(ctx.monitor, x+1, y,   title, w-2, titleFg, bg)
    writeClipped(ctx.monitor, x+1, y+1, value, w-2, fg,      bg)
end

local function normalizeSnapshot(msg)
    if type(msg) ~= "table" then return nil end
    if msg.type == "rs_snapshot" and type(msg.snapshot) == "table" then return msg.snapshot end
    if msg.type == "rs_snapshot" then return msg end
    if msg.isConnected ~= nil or msg.totalItems ~= nil then return msg end
    return nil
end

function M.init(win, ctx)
    local Ui      = dofile("/os/lib/ui_framework/init.lua")
    local UiState = Ui.State

    -- Mutable state shared with drawView hook via upvalues
    local snapshot   = {ok=false, items={}, message="Connecting...", time=0}
    local lastSeen   = nil
    local itemTrend  = {}
    local prevCounts = {}
    local totalHist  = {}

    local function updateTrends(items)
        local cur = {}
        for _, it in ipairs(items or {}) do cur[it.name] = tonumber(it.count) or 0 end
        local next_trend = {}
        for name, count in pairs(cur) do
            local prev = prevCounts[name]
            if     prev == nil         then next_trend[name] = "new"
            elseif count > prev        then next_trend[name] = "up"
            elseif count < prev        then next_trend[name] = "down"
            else                            next_trend[name] = "flat"
            end
        end
        itemTrend = next_trend; prevCounts = cur
    end

    local function pushHistory(total, ts)
        if type(total) ~= "number" then return end
        table.insert(totalHist, {time=ts, count=total})
        while #totalHist > 30 do table.remove(totalHist, 1) end
    end

    local function computeThroughput()
        if #totalHist < 2 then return nil, nil end
        local first, last = totalHist[1], totalHist[#totalHist]
        local elapsed = last.time - first.time
        if elapsed <= 0 then return 0, 0 end
        return (last.count - first.count) / elapsed * 60, elapsed
    end

    local stoCfg = {
        title           = "RS STORAGE",
        uiSettingsFile  = "/data/storage_ui.db",
        scrollStep      = ctx.config.scrollStep or 3,
        topLimit        = ctx.config.topLimit    or 20,
        staleSeconds    = ctx.config.staleSeconds or 15,
        enableCompact   = false,
        computers       = {{id=10, label="RS Bridge"}},
        uiViews = {
            {id="dashboard", label="DASH", type="dashboard"},
            {id="disk",      label="DISK", type="disk"},
            {id="net",       label="NET",  type="net"},
        },
        uiColumns = {
            {id="name",  title="ITEM",  width=22},
            {id="count", title="COUNT", width=10},
            {id="share", title="SHARE", width=7},
        },
        actionButtons = {
            full  = {
                {id="request_refresh", x=2,  width=10, label=" REFRESH ", fg=colors.black,  bg=colors.lightBlue},
                {id="scroll_up",       x=13, width=5,  label=" UP ",      fg=colors.white,  bg=colors.gray},
                {id="scroll_down",     x=19, width=5,  label=" DN ",      fg=colors.white,  bg=colors.gray},
            },
            short = {
                {id="request_refresh", x=2, width=4, label=" R ",  fg=colors.black,  bg=colors.lightBlue},
                {id="scroll_up",       x=7, width=3, label="^",    fg=colors.white,  bg=colors.gray},
                {id="scroll_down",     x=11,width=3, label="v",    fg=colors.white,  bg=colors.gray},
            },
        },
        uiHooks = {
            drawView = function(dctx, viewType)
                if viewType ~= "dashboard" and viewType ~= "disk" and viewType ~= "net" then
                    return false
                end
                local theme   = dctx.theme
                local pageBg  = theme.pageBg
                local secBg   = theme.sectionBg
                local secFg   = theme.sectionFg
                local colBg   = theme.columnBg
                local colFg   = theme.columnFg
                local mutedFg = theme.mutedFg
                local rowA    = theme.rowA
                local rowFg   = theme.rowFg
                local data    = snapshot
                local width   = dctx.width
                local y       = dctx.contentTop

                if not data.ok then
                    dctx.drawEmptyState(data.message or "Connecting...", string.char(15), colors.orange)
                    return true
                end

                if viewType == "disk" then
                    dctx.drawCell(dctx.monitor, 2, y, width-4, " ITEM STORAGE (DISK) ", secFg, secBg); y=y+2
                    if data.usedItemStorage and data.maxItemStorage then
                        local pct = data.itemStoragePercent or (data.usedItemStorage/data.maxItemStorage)
                        local barL = formatCount(data.usedItemStorage).."/"..formatCount(data.maxItemStorage)
                            .."  "..formatPercent(pct)
                        drawBar(dctx,2,y,width-4,pct,barL,storageBarColor(pct),colors.gray,colors.black); y=y+2
                        local free = data.freeItemStorage or (data.maxItemStorage-data.usedItemStorage)
                        writeClipped(dctx.monitor,3,y,"Free: "..formatCount(free).." slots",width-5,mutedFg,pageBg)
                        y=y+2
                    else
                        writeClipped(dctx.monitor,3,y,"Disk data unavailable",width-5,colors.orange,pageBg); y=y+2
                    end
                    if data.usedFluidStorage and data.maxFluidStorage then
                        dctx.drawCell(dctx.monitor,2,y,width-4," FLUID STORAGE (DISK) ",secFg,secBg); y=y+2
                        local pct = data.fluidStoragePercent or (data.usedFluidStorage/data.maxFluidStorage)
                        drawBar(dctx,2,y,width-4,pct,formatPercent(pct),colors.blue,colors.gray,colors.white); y=y+2
                    end
                    return true

                elseif viewType == "net" then
                    dctx.drawCell(dctx.monitor,2,y,width-4," RS NETWORK ",secFg,secBg); y=y+2
                    if data.energyStorage and data.maxEnergyStorage and data.maxEnergyStorage>0 then
                        local er = data.energyStorage/data.maxEnergyStorage
                        drawBar(dctx,2,y,width-4,er,"Energy "..formatCount(data.energyStorage)
                            .."/"..formatCount(data.maxEnergyStorage).."  "..formatPercent(er),
                            colors.red,colors.gray,colors.white); y=y+2
                    end
                    if data.energyUsage then
                        writeClipped(dctx.monitor,3,y,"Usage: "..formatCount(data.energyUsage).." FE/t",
                            width-5,mutedFg,pageBg); y=y+1
                    end
                    dctx.drawCell(dctx.monitor,2,y,width-4," NETWORK STATUS ",secFg,secBg); y=y+2
                    local clab = data.isConnected==true and "CONNECTED" or (data.isConnected==false and "DISCONNECTED" or "UNKNOWN")
                    local ccol = data.isConnected==true and colors.lime or (data.isConnected==false and colors.red or colors.orange)
                    writeClipped(dctx.monitor,3,y,"Network: ",9,mutedFg,pageBg)
                    writeClipped(dctx.monitor,12,y,clab,width-14,ccol,pageBg); y=y+1
                    return true

                elseif viewType == "dashboard" then
                    local age    = lastSeen and (nowSeconds()-lastSeen) or nil
                    local fresh  = age and age<=(ctx.config.staleSeconds or 15)
                    local sLabel = (data.ok and fresh) and "ONLINE" or (data.ok and "STALE" or "OFFLINE")
                    local sBg    = (data.ok and fresh) and colors.green or (data.ok and colors.orange or colors.red)

                    -- 4 карточки в строку. На узком экране ширина carda
                    -- зажимается, но карточки не наезжают (each x+=cw+1).
                    local cw = math.max(5, math.floor((width - 2 - 3) / 4))

                    local perMin, span = computeThroughput()
                    local flowL = "--"; local flowBg = colBg; local flowFg = colFg
                    if perMin and span and span >= 5 then
                        local mag = math.abs(math.floor(perMin))
                        if     perMin>0 then flowL=string.char(30)..formatCount(mag).."/m"; flowBg=colors.green;  flowFg=colors.black
                        elseif perMin<0 then flowL=string.char(31)..formatCount(mag).."/m"; flowBg=colors.red;    flowFg=colors.white
                        else                 flowL=string.char(250).."0/m"
                        end
                    end

                    local x = 2
                    drawCard(dctx,x,y,cw,"LINK",sLabel..(age and (" "..age.."s") or ""),sBg,colors.black)
                    x=x+cw+1; drawCard(dctx,x,y,cw,"TYPES",formatCount(data.itemTypes),colBg,colFg)
                    x=x+cw+1; drawCard(dctx,x,y,cw,"ITEMS",formatCount(data.totalItems),colBg,colFg)
                    x=x+cw+1; drawCard(dctx,x,y,cw,"FLOW",flowL,flowBg,flowFg)
                    y=y+4

                    local sL = "Storage "
                    if data.usedItemStorage and data.maxItemStorage then
                        sL=sL..formatCount(data.usedItemStorage).."/"..formatCount(data.maxItemStorage)
                    else sL=sL..formatCount(data.totalItems) end
                    sL=sL.."  "..formatPercent(data.itemStoragePercent)
                    drawBar(dctx,2,y,width-4,data.itemStoragePercent or 0,sL,
                        storageBarColor(data.itemStoragePercent),colors.gray,colors.black); y=y+2

                    if data.energyUsage then
                        writeClipped(dctx.monitor,2,y,"Energy: "..formatCount(data.energyUsage).." FE/t",
                            width-4,mutedFg,pageBg); y=y+1
                    end

                    dctx.drawCell(dctx.monitor,2,y,width-4," TOP "..tostring(ctx.config.topLimit or 20).." ITEMS ",
                        secFg,secBg); y=y+1

                    local items     = data.items or {}
                    local limit     = math.min(ctx.config.topLimit or 20, #items)
                    local visRows   = dctx.contentBottom - y + 1
                    local maxScroll = math.max(0, limit - visRows)
                    dctx.ui.scrollOffset = clamp(dctx.ui.scrollOffset or 0, 0, maxScroll)
                    local startIdx  = dctx.ui.scrollOffset + 1
                    local topCount  = (items[1] and tonumber(items[1].count) and tonumber(items[1].count)>0)
                                      and tonumber(items[1].count) or 1
                    local cols = (dctx.ui and dctx.ui.columns) or {}

                    for idx = startIdx, math.min(limit, startIdx+visRows-1) do
                        if y > dctx.contentBottom then break end
                        local it  = items[idx]
                        local rbg = (idx%2==0) and theme.rowB or rowA
                        local cnt = tonumber(it.count) or 0
                        local share = (data.totalItems and data.totalItems>0) and (cnt/data.totalItems) or 0

                        local idxW=4; local countW=9; local shareW=6
                        local avail = width-4
                        local nameW = avail - idxW - countW - shareW
                        if nameW < 10 then nameW = 10 end

                        fillRect(dctx.monitor,2,y,width-4,1,rbg)
                        writeClipped(dctx.monitor,3,y,tostring(idx)..".",idxW,mutedFg,rbg)

                        local trend = itemTrend[it.name] or "flat"
                        local ac = string.char(250); local afc = mutedFg
                        if trend=="up"   then ac=string.char(30);  afc=colors.lime
                        elseif trend=="down" then ac=string.char(31);  afc=colors.red
                        elseif trend=="new"  then ac="+";              afc=colors.lightBlue
                        end

                        writeClipped(dctx.monitor,3+idxW,y,it.label or it.name or "?",nameW,rowFg,rbg)
                        writeClipped(dctx.monitor,3+idxW+nameW,y,ac,1,afc,rbg)
                        writeClipped(dctx.monitor,3+idxW+nameW+2,y,formatCount(cnt),countW-2,rowFg,rbg)
                        writeClipped(dctx.monitor,3+idxW+nameW+countW,y,formatPercent(share),shareW,mutedFg,rbg)
                        drawBar(dctx,2+idxW+nameW+countW+shareW,y,width-4-idxW-nameW-countW-shareW,
                            cnt/topCount,"",colors.lightBlue,colors.gray,colors.black)
                        y=y+1
                    end
                    return true
                end
                return false
            end,
        },
    }

    local ui       = Ui.create(win, stoCfg)
    local settings = UiState.loadUiSettings(stoCfg, stoCfg.uiColumns)

    ui.setThemeIndex(settings.themeIndex)
    ui.setViewIndex(settings.viewIndex)
    ui.setCompact(settings.compact)
    ui.setButtonStyle(settings.buttonStyle)
    ui.setShowTopControls(settings.showTopControls)
    ui.setColumns(settings.columns)
    ui.setSoundVolume(settings.soundVolume)

    local function save()
        UiState.saveUiSettings(stoCfg, ui.getSettings())
    end

    local function reqRefresh()
        ctx.send(ctx.config.rsComputer, {type="request_refresh"}, ctx.config.rsProtocol)
    end

    -- handleSnapshot updates the upvalue `snapshot` directly
    local function handleSnapshot(msg)
        local sn = normalizeSnapshot(msg)
        if not sn then return false end
        snapshot  = sn
        lastSeen  = nowSeconds()
        if sn.ok then
            updateTrends(sn.items)
            pushHistory(sn.totalItems, lastSeen)
        end
        return true
    end

    local st = {
        ui         = ui,
        UiState    = UiState,
        stoCfg     = stoCfg,
        save       = save,
        reqRefresh = reqRefresh,
        handleSnapshot = handleSnapshot,
        scrollStep     = ctx.config.scrollStep or 3,
        refreshTimer   = os.startTimer(ctx.config.refreshSeconds or 5),
        refreshSeconds = ctx.config.refreshSeconds or 5,
        rsComputer     = ctx.config.rsComputer,
        rsProtocol     = ctx.config.rsProtocol,
    }

    reqRefresh()
    return st
end

-- ── Drawing ───────────────────────────────────────────────────────────────────

function M.draw(st, win)
    st.ui.draw({sections={}, snapshot={}, message=""})
end

-- ── Button handlers ───────────────────────────────────────────────────────────

local function handleButton(st, id)
    local ui   = st.ui
    local save = st.save

    local btns = {
        settings = function() ui.playSound("settings"); ui.openSettingsMenu(); ui.draw({sections={}}) end,
        theme    = function() ui.playSound("menu"); ui.openThemeMenu(); ui.draw({sections={}}) end,
        modal_close = function() ui.playSound("menu"); ui.closeModal(); M.draw(st) end,
        view  = function() ui.playSound("settings"); ui.nextView(); save(); M.draw(st) end,
        compact = function()
            ui.playSound("settings"); ui.toggleCompact(); save(); M.draw(st)
        end,
        toggle_button_style = function()
            ui.playSound("settings"); ui.toggleButtonStyle(); save(); M.draw(st)
        end,
        toggle_top_controls = function()
            ui.playSound("settings"); ui.toggleTopControls(); save(); M.draw(st)
        end,
        scroll_up   = function() ui.scroll(-st.scrollStep); M.draw(st) end,
        scroll_down = function() ui.scroll(st.scrollStep);  M.draw(st) end,
        settings_scroll_up   = function() ui.scrollSettings(-3); M.draw(st) end,
        settings_scroll_down = function() ui.scrollSettings(3);  M.draw(st) end,
        request_refresh = function()
            ui.playSound("menu"); st.reqRefresh(); M.draw(st)
        end,
        computers = function() ui.openComputersMenu(); M.draw(st) end,
        reboot_self = function() ui.openRebootConfirm(os.getComputerID()); M.draw(st) end,
        cancel_reboot = function() ui.openSettingsMenu(); M.draw(st) end,
        sound_volume_up   = function() ui.changeSoundVolume(0.1); save(); M.draw(st) end,
        sound_volume_down = function() ui.changeSoundVolume(-0.1); save(); M.draw(st) end,
    }

    local tp = "theme_select_"
    if string.sub(id, 1, #tp) == tp then
        ui.setThemeByIndex(tonumber(string.sub(id, #tp+1))); save(); M.draw(st); return
    end
    local cp = "toggle_column_"
    if string.sub(id, 1, #cp) == cp then
        ui.toggleColumn(string.sub(id, #cp+1)); save(); M.draw(st); return
    end
    local crp = "confirm_reboot_"
    if string.sub(id, 1, #crp) == crp then
        local cid = tonumber(string.sub(id, #crp+1))
        ui.closeModal()
        if cid == os.getComputerID() then os.reboot()
        elseif cid then pcall(rednet.send, cid, {type="reboot"}) end
        return
    end

    local h = btns[id]
    if h then h() end
end

-- ── Event handler ─────────────────────────────────────────────────────────────

function M.onEvent(st, event, p1, p2, p3, p4)
    if event == "mouse_click" or event == "monitor_touch" then
        if st.ui.handleScrollbarClick and st.ui.handleScrollbarClick(p2, p3) then
            M.draw(st); return st, true
        end
        local kind, id, value = st.ui.hitTest(p2, p3)
        if kind == "button" then
            handleButton(st, id); return st, true
        elseif kind == "meter" then
            if id == "sound_volume" then
                st.ui.setSoundVolume(value); st.save(); M.draw(st)
            end
            return st, true
        end

    elseif event == "mouse_drag" then
        if st.ui.handleScrollbarDrag and st.ui.handleScrollbarDrag(p2, p3) then
            M.draw(st); return st, true
        end

    elseif event == "mouse_scroll" then
        local dir = p1; local shift = p4
        if shift then st.ui.page(dir) else st.ui.scroll(dir * st.scrollStep) end
        return st, true

    elseif event == "rednet_message" then
        local proto = p3
        if proto == st.rsProtocol then
            if st.handleSnapshot(p2) then return st, true end
        end

    elseif event == "timer" then
        if p1 == st.refreshTimer then
            st.refreshTimer = os.startTimer(st.refreshSeconds)
            return st, true
        end
    end

    return st, false
end

return M
