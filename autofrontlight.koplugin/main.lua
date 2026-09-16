-- Standalone port of KOReader's former Auto frontlight plugin.
-- It uses UIManager's scheduler instead of the removed BackgroundRunner plugin.

local Device = require("device")

-- Do not hide the menu based on hasLightSensor(): some Kindle builds report
-- that capability incorrectly even though ambientBrightnessLevel() works.
if not Device:isKindle() then
    return { disabled = true }
end

local DataStorage = require("datastorage")
local InfoMessage = require("ui/widget/infomessage")
local LuaSettings = require("luasettings")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local DEFAULT_INTERVAL_SECONDS = 60
local INTERVALS = { 15, 30, 60, 120 }
local DEFAULT_BRIGHTNESS_LEVELS = { 10, 7, 4, 2, 0 }
local AMBIENT_LEVEL_NAMES = {
    _("0 · Darkest"),
    _("1 · Dim"),
    _("2 · Indoor light"),
    _("3 · Bright"),
    _("4 · Very bright"),
}

local AutoFrontlight = WidgetContainer:extend {
    name = "autofrontlight",
    is_doc_only = false,
    enabled = false,
    interval_seconds = DEFAULT_INTERVAL_SECONDS,
    brightness_levels = nil,
    last_brightness = -1,
    scheduled = false,
}

function AutoFrontlight:_save()
    self.settings:saveSetting("enabled", self.enabled)
    self.settings:saveSetting("interval_seconds", self.interval_seconds)
    self.settings:saveSetting("brightness_levels", self.brightness_levels)
    self.settings:flush()
end

function AutoFrontlight:_loadBrightnessLevels()
    local saved = self.settings:readSetting("brightness_levels")
    local max_brightness = Device:getPowerDevice().fl_max or 24
    self.brightness_levels = {}
    for index = 1, 5 do
        local value = type(saved) == "table" and tonumber(saved[index])
            or DEFAULT_BRIGHTNESS_LEVELS[index]
        value = math.floor(value or DEFAULT_BRIGHTNESS_LEVELS[index])
        self.brightness_levels[index] = math.max(0, math.min(max_brightness, value))
    end
end

function AutoFrontlight:_unschedule()
    if self.task then
        UIManager:unschedule(self.task)
    end
    self.scheduled = false
end

function AutoFrontlight:_schedule(delay_seconds)
    self:_unschedule()
    if not self.enabled then
        return
    end

    UIManager:scheduleIn(delay_seconds or self.interval_seconds, self.task)
    self.scheduled = true
end

function AutoFrontlight:_readAmbientLevel()
    if type(Device.ambientBrightnessLevel) ~= "function" then
        logger.warn("AutoFrontlight: ambientBrightnessLevel is unavailable")
        return nil
    end
    local ok, value = pcall(function()
        return Device:ambientBrightnessLevel()
    end)
    if not ok or type(value) ~= "number" then
        logger.warn("AutoFrontlight: failed to read the ambient-light sensor", value)
        return nil
    end
    return value
end

function AutoFrontlight:_applyAmbientLevel(level)
    -- KOReader maps the Voyage's raw ALS reading to five buckets, 0 through 4.
    -- Preserve a manual frontlight override until the ambient bucket changes.
    if level == self.last_brightness then
        return
    end

    local powerd = Device:getPowerDevice()
    local target = self.brightness_levels[level + 1]
    if target == nil then
        logger.warn("AutoFrontlight: invalid ambient level", level)
        return
    elseif target <= 0 then
        logger.dbg("AutoFrontlight: ambient level", level, "turning frontlight off")
        powerd:turnOffFrontlight()
    else
        logger.dbg("AutoFrontlight: ambient level", level, "setting brightness", target)
        powerd:setIntensity(target)
        -- On Kindle this is normally already reflected by setIntensityHW, but
        -- explicitly turn the light on for compatibility with future changes.
        powerd:turnOnFrontlight()
    end
    self.last_brightness = level
end

function AutoFrontlight:_poll()
    local level = self:_readAmbientLevel()
    if level ~= nil then
        logger.dbg("AutoFrontlight: ambient level", level)
        self:_applyAmbientLevel(level)
    end
    return level
end

function AutoFrontlight:_runTask()
    self.scheduled = false
    if not self.enabled then
        return
    end
    self:_poll()
    self:_schedule()
end

function AutoFrontlight:_setEnabled(enabled)
    self.enabled = enabled
    self.last_brightness = -1
    self:_save()

    if enabled then
        -- Give the menu time to close before changing the light.
        self:_schedule(0.5)
    else
        self:_unschedule()
    end
end

function AutoFrontlight:init()
    self.settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/autofrontlight.lua")
    if self.settings:has("enabled") then
        self.enabled = self.settings:isTrue("enabled")
    elseif self.settings:has("enable") then
        -- Migrate the setting used by KOReader's removed built-in plugin.
        self.enabled = self.settings:isTrue("enable")
        self.settings:saveSetting("enabled", self.enabled)
        self.settings:delSetting("enable")
        self.settings:flush()
    else
        self.enabled = false
    end
    self.interval_seconds = self.settings:readSetting("interval_seconds", DEFAULT_INTERVAL_SECONDS)
    self:_loadBrightnessLevels()
    self.task = function()
        self:_runTask()
    end

    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end
    if self.enabled then
        self:_schedule(1)
    end
end

function AutoFrontlight:onSuspend()
    self:_unschedule()
end

function AutoFrontlight:onResume()
    if self.enabled then
        -- Force a fresh decision because the ambient light may have changed
        -- while the Kindle was asleep.
        self.last_brightness = -1
        self:_schedule(1)
    end
end

function AutoFrontlight:onCloseWidget()
    self:_unschedule()
    self.settings:flush()
end

function AutoFrontlight:onFlushSettings()
    self.settings:flush()
end

function AutoFrontlight:addToMainMenu(menu_items)
    local interval_items = {}
    for interval_index = 1, #INTERVALS do
        local interval = INTERVALS[interval_index]
        table.insert(interval_items, {
            text = T(_("%1 seconds"), interval),
            radio = true,
            checked_func = function()
                return self.interval_seconds == interval
            end,
            callback = function(touchmenu_instance)
                self.interval_seconds = interval
                self:_save()
                if self.enabled then
                    self:_schedule()
                end
                touchmenu_instance:updateItems()
            end,
        })
    end

    local brightness_items = {}
    for ambient_level = 0, 4 do
        local level = ambient_level
        table.insert(brightness_items, {
            text_func = function()
                return T(_("%1: brightness %2"),
                    AMBIENT_LEVEL_NAMES[level + 1], self.brightness_levels[level + 1])
            end,
            callback = function(touchmenu_instance)
                local SpinWidget = require("ui/widget/spinwidget")
                UIManager:show(SpinWidget:new {
                    title_text = AMBIENT_LEVEL_NAMES[level + 1],
                    info_text = _("Choose the frontlight brightness for this ambient-light level. Set it to 0 to turn the frontlight off."),
                    value = self.brightness_levels[level + 1],
                    value_min = 0,
                    value_max = Device:getPowerDevice().fl_max or 24,
                    value_step = 1,
                    value_hold_step = 5,
                    ok_text = _("Set brightness"),
                    callback = function(spin)
                        self.brightness_levels[level + 1] = spin.value
                        self.last_brightness = -1
                        self:_save()
                        if self.enabled then
                            self:_schedule(0.5)
                        end
                        touchmenu_instance:updateItems()
                    end,
                })
            end,
        })
    end
    table.insert(brightness_items, {
        text = _("Restore recommended levels"),
        callback = function(touchmenu_instance)
            for index = 1, 5 do
                self.brightness_levels[index] = DEFAULT_BRIGHTNESS_LEVELS[index]
            end
            self.last_brightness = -1
            self:_save()
            if self.enabled then
                self:_schedule(0.5)
            end
            touchmenu_instance:updateItems()
        end,
    })

    menu_items.auto_frontlight = {
        text = _("Auto frontlight"),
        sorting_hint = "device",
        sub_item_table = {
            {
                text = _("Enable ambient-light control"),
                checked_func = function()
                    return self.enabled
                end,
                check_callback_updates_menu = true,
                callback = function(touchmenu_instance)
                    self:_setEnabled(not self.enabled)
                    touchmenu_instance:updateItems()
                end,
            },
            {
                text = _("Check interval"),
                sub_item_table = interval_items,
            },
            {
                text = _("Brightness by ambient level"),
                sub_item_table = brightness_items,
            },
            {
                text = _("Test sensor now"),
                callback = function()
                    local level = self:_poll()
                    UIManager:show(InfoMessage:new {
                        text = level and T(_("Ambient-light level: %1; selected brightness: %2"),
                            level, self.brightness_levels[level + 1])
                            or _("Could not read the ambient-light sensor."),
                        timeout = 4,
                    })
                end,
            },
            {
                text = _("Compatibility information"),
                callback = function()
                    local level = self:_readAmbientLevel()
                    local sensor_flag = Device:hasLightSensor() and _("yes") or _("no")
                    UIManager:show(InfoMessage:new {
                        text = T(_("Device: %1\nKOReader sensor flag: %2\nAmbient level: %3"),
                            Device.model or _("Kindle"), sensor_flag,
                            level ~= nil and tostring(level) or _("unavailable")),
                    })
                end,
            },
        },
    }
end

return AutoFrontlight
