local M = {}
M.id        = "factory"
M.name      = "Factory"
M.icon      = "Fa"
M.iconBg    = colors.orange
M.iconFg    = colors.black
M.version   = 5
M.category  = "automation"
M.protocols = {"factory_dashboard"}

local function nowSeconds()
    if os.epoch then return math.floor(os.epoch("utc") / 1000) end
    return math.floor(os.clock())
end

function M.init(win, ctx)
    local Ui      = dofile("/os/lib/ui_framework/init.lua")
    local UiState = Ui.State

    -- Shared snapshot table — also closed-over by getCellValue hook
    local snapshot = {
        state = {}, uptime = {}, rsStock = {}, controllerStatus = {},
        locks = {}, history = {}, message = "Connecting...", time = 0,
    }

    local facCfg = {
        uiSettingsFile = "/data/factory_ui.db",
        scrollStep     = ctx.config.scrollStep or 3,
        groups         = {},
        computers      = {},
        uiColumns = {
            -- LOCK работает как кнопка: отправляет toggle_lock_<id> на мастер,
            -- который понимает префикс toggle_lock_ как remote_command/button.
            {id="lock",  title="LOCK",     width=7,  defaultVisible=true,
             kind="button", buttonPrefix="toggle_lock_",
             buttonFg=colors.black, buttonBg=colors.yellow},
            {id="ctrl",  title="CTRL",     width=6,  defaultVisible=false},
            {id="side",  title="SIDE",     width=7,  defaultVisible=false},
            {id="stock", title="RS STOCK", width=12},
            {id="rate",  title="ITEMS/H",  width=12},
            {id="state", title="STATE",    width=8,  required=true},
        },
        uiHooks = {
            getCellValue = function(device, colId)
                if colId == "lock" then
                    return snapshot.locks[device.id] and " LOCK " or " -- "
                end
                return nil
            end,
        },
    }

    local ui       = Ui.create(win, facCfg)
    local settings = UiState.loadUiSettings(facCfg, facCfg.uiColumns)

    ui.setThemeIndex(settings.themeIndex)
    ui.setViewIndex(settings.viewIndex)
    ui.setCompact(settings.compact)
    ui.setButtonStyle(settings.buttonStyle)
    ui.setShowTopControls(settings.showTopControls)
    ui.setColumns(settings.columns)
    ui.setSoundVolume(settings.soundVolume)
    ui.setCollapsedSections(settings.collapsedSections)

    local function save()
        UiState.saveUiSettings(facCfg, ui.getSettings())
    end

    local function sendCmd(kind, id, value)
        ctx.send(ctx.config.masterComputer, {
            type = "remote_command", kind = kind, id = id, value = value,
        }, ctx.config.dashboardProtocol)
    end

    local function reqSnapshot()
        ctx.send(ctx.config.masterComputer,
            {type = "request_snapshot"}, ctx.config.dashboardProtocol)
    end

    -- Store closures and state together so onEvent can reach them
    local st = {
        ui        = ui,
        UiState   = UiState,
        facCfg    = facCfg,
        snapshot  = snapshot,
        save      = save,
        sendCmd   = sendCmd,
        reqSnapshot = reqSnapshot,
        scrollStep  = ctx.config.scrollStep or 3,
        refreshTimer    = os.startTimer(ctx.config.refreshSeconds or 5),
        reconnectTimer  = os.startTimer((ctx.config.refreshSeconds or 5) * 3),
        refreshSeconds     = ctx.config.refreshSeconds or 5,
        controlProtocol    = ctx.config.controlProtocol,
        dashboardProtocol  = ctx.config.dashboardProtocol,
        masterComputer     = ctx.config.masterComputer,
    }

    reqSnapshot()
    ui.setMessage("Connecting...")
    return st
end

-- ── Drawing ───────────────────────────────────────────────────────────────────

function M.draw(st, win)
    local sn = st.snapshot
    st.ui.draw(sn.state, sn.uptime, sn.rsStock, sn.controllerStatus, sn.history)
end

-- ── Button handlers ───────────────────────────────────────────────────────────

local function applySnapshot(st, s)
    local sn = st.snapshot
    sn.state            = s.state            or {}
    sn.uptime           = s.uptime           or {}
    sn.rsStock          = s.rsStock          or {}
    sn.controllerStatus = s.controllerStatus or {}
    sn.locks            = s.locks            or {}
    sn.history          = s.history          or {}
    sn.time             = s.time             or nowSeconds()
    if type(s.message) == "string" then sn.message = s.message; st.ui.setMessage(s.message) end
    if type(s.groups)    == "table" then st.facCfg.groups    = s.groups    end
    if type(s.computers) == "table" then st.facCfg.computers = s.computers end
end

local function uiMsg(st, msg)
    st.ui.setMessage(msg)
    M.draw(st, nil)
end

local function handleButton(st, id)
    local ui   = st.ui
    local save = st.save

    local function sendBtn(bid) st.sendCmd("button", bid) end
    local function msg(m)  uiMsg(st, m) end

    -- theme_select_N
    local tp = "theme_select_"
    if string.sub(id, 1, #tp) == tp then
        local name = ui.setThemeByIndex(tonumber(string.sub(id, #tp + 1)))
        ui.playSound("settings"); save(); msg("Theme: " .. (name or "?")); return
    end
    -- toggle_column_X
    local cp = "toggle_column_"
    if string.sub(id, 1, #cp) == cp then
        local cid = string.sub(id, #cp + 1)
        local vis = ui.toggleColumn(cid)
        ui.playSound("settings"); save(); msg("Col " .. cid .. ": " .. (vis and "ON" or "OFF")); return
    end
    -- reboot_computer_N
    local rp = "reboot_computer_"
    if string.sub(id, 1, #rp) == rp then
        local cid = tonumber(string.sub(id, #rp + 1))
        if cid then ui.openRebootConfirm(cid); msg("Confirm reboot " .. cid) end; return
    end
    -- confirm_reboot_N
    local crp = "confirm_reboot_"
    if string.sub(id, 1, #crp) == crp then
        local cid = tonumber(string.sub(id, #crp + 1))
        ui.closeModal()
        if cid == os.getComputerID() then
            os.reboot()
        elseif cid then
            pcall(rednet.send, cid, {type = "reboot"}, st.controlProtocol)
            msg("Reboot sent to " .. cid)
        end
        return
    end

    if id == "confirm_stop" then
        ui.closeModal(); sendBtn("confirm_stop"); msg("Emergency stop sent"); return
    end

    -- Local button table
    local local_btns = {
        settings = function() ui.playSound("settings"); ui.openSettingsMenu(); msg("Settings") end,
        theme    = function() ui.playSound("menu");     ui.openThemeMenu();    msg("Select theme") end,
        modal_close = function() ui.playSound("menu"); ui.closeModal(); M.draw(st) end,
        view  = function() ui.playSound("settings"); local v=ui.nextView(); save(); msg("View: "..v) end,
        compact = function()
            ui.playSound("settings")
            local c = ui.toggleCompact(); save()
            msg(c and "Dense: ON" or "Dense: OFF")
        end,
        toggle_button_style = function()
            ui.playSound("settings")
            local s = ui.toggleButtonStyle(); save(); msg("Buttons: " .. s)
        end,
        toggle_top_controls = function()
            ui.playSound("settings")
            local s = ui.toggleTopControls(); save()
            msg(s and "Controls: ON" or "Controls: OFF")
        end,
        scroll_up   = function() ui.scroll(-st.scrollStep); M.draw(st) end,
        scroll_down = function() ui.scroll(st.scrollStep);  M.draw(st) end,
        page_prev   = function() ui.page(-1); M.draw(st) end,
        page_next   = function() ui.page(1);  M.draw(st) end,
        settings_scroll_up   = function() ui.scrollSettings(-3); M.draw(st) end,
        settings_scroll_down = function() ui.scrollSettings(3);  M.draw(st) end,
        computers      = function() ui.openComputersMenu(); msg("Computers") end,
        emergency_stop = function() ui.openStopConfirm();   msg("Confirm stop") end,
        cancel_stop    = function() ui.closeModal(); msg("Stop cancelled") end,
        cancel_reboot  = function() ui.openComputersMenu(); msg("Reboot cancelled") end,
        reboot_self    = function() ui.openRebootConfirm(os.getComputerID()); msg("Confirm reboot") end,
        sound_volume_up = function()
            local v = ui.changeSoundVolume(0.1); save()
            msg("Volume: " .. tostring(math.floor(v * 100 + 0.5)) .. "%")
        end,
        sound_volume_down = function()
            local v = ui.changeSoundVolume(-0.1); save()
            msg("Volume: " .. tostring(math.floor(v * 100 + 0.5)) .. "%")
        end,
    }

    local h = local_btns[id]
    if h then h(); return end

    -- Remote button
    st.sendCmd("button", id)
    msg("Sent: " .. id)
end

local function handleMeter(st, id, value)
    if id == "sound_volume" then
        local v = st.ui.setSoundVolume(value); st.save()
        uiMsg(st, "Volume: " .. tostring(math.floor(v * 100 + 0.5)) .. "%")
    end
end

-- ── Event handler ─────────────────────────────────────────────────────────────

function M.onEvent(st, event, p1, p2, p3, p4)
    local ui  = st.ui
    local cfg = st.facCfg

    if event == "mouse_click" or event == "monitor_touch" then
        -- Scrollbar имеет приоритет — если клик попал в него, остальное
        -- (hitTest по кнопкам/устройствам) пропускаем.
        if ui.handleScrollbarClick and ui.handleScrollbarClick(p2, p3) then
            M.draw(st); return st, true
        end
        local kind, id, value = ui.hitTest(p2, p3)
        if kind == "device" then
            st.sendCmd("device", id)
            ui.playSound("toggle_on")
            uiMsg(st, "Toggle: " .. tostring(id))
            return st, true
        elseif kind == "button" then
            handleButton(st, id)
            return st, true
        elseif kind == "meter" then
            handleMeter(st, id, value)
            return st, true
        elseif kind == "section" then
            local col = ui.toggleSectionCollapse(id)
            ui.playSound("menu"); st.save()
            uiMsg(st, col and "Collapsed: " .. id or "Expanded: " .. id)
            return st, true
        end

    elseif event == "mouse_drag" then
        if ui.handleScrollbarDrag and ui.handleScrollbarDrag(p2, p3) then
            M.draw(st); return st, true
        end

    elseif event == "mouse_scroll" then
        local dir = p1; local shift = p4
        if shift then ui.page(dir) else ui.scroll(dir * st.scrollStep) end
        return st, true

    elseif event == "rednet_message" then
        local proto = p3
        if proto == st.dashboardProtocol
            and type(p2) == "table" and p2.type == "snapshot"
        then
            applySnapshot(st, p2)
            return st, true
        end

    elseif event == "timer" then
        if p1 == st.refreshTimer then
            st.refreshTimer = os.startTimer(st.refreshSeconds)
            return st, true
        end
        if p1 == st.reconnectTimer then
            if nowSeconds() - (st.snapshot.time or 0) > st.refreshSeconds * 2 then
                st.reqSnapshot()
            end
            st.reconnectTimer = os.startTimer(st.refreshSeconds * 3)
        end
    end

    return st, false
end

return M
