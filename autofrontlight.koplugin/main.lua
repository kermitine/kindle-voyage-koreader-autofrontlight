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
local DEFAULT_DARKNESS_BRIGHTNESS = 12
local DEFAULT_DAYLIGHT_BRIGHTNESS = 0
local DEFAULT_BRIGHT_LIGHT_READING = 10000

local AutoFrontlight = WidgetContainer:extend {
    name = "autofrontlight",
    is_doc_only = false,
    enabled = false,
    interval_seconds = DEFAULT_INTERVAL_SECONDS,
    brightness_levels = nil,
    darkness_brightness = DEFAULT_DARKNESS_BRIGHTNESS,
    daylight_brightness = DEFAULT_DAYLIGHT_BRIGHTNESS,
    bright_light_reading = DEFAULT_BRIGHT_LIGHT_READING,
    last_target_brightness = nil,
    scheduled = false,
}

function AutoFrontlight:_save()
    self.settings:saveSetting("enabled", self.enabled)
    self.settings:saveSetting("interval_seconds", self.interval_seconds)
    self.settings:saveSetting("brightness_levels", self.brightness_levels)
    self.settings:saveSetting("darkness_brightness", self.darkness_brightness)
    self.settings:saveSetting("daylight_brightness", self.daylight_brightness)
    self.settings:saveSetting("bright_light_reading", self.bright_light_reading)
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

function AutoFrontlight:_loadAdaptiveSettings()
    local max_brightness = Device:getPowerDevice().fl_max or 24
    self.darkness_brightness = math.max(1, math.min(max_brightness,
        tonumber(self.settings:readSetting("darkness_brightness")) or DEFAULT_DARKNESS_BRIGHTNESS))
    self.daylight_brightness = math.max(0, math.min(self.darkness_brightness,
        tonumber(self.settings:readSetting("daylight_brightness")) or DEFAULT_DAYLIGHT_BRIGHTNESS))
    self.bright_light_reading = math.max(100,
        tonumber(self.settings:readSetting("bright_light_reading")) or DEFAULT_BRIGHT_LIGHT_READING)
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

function AutoFrontlight:_readRawAmbientLight()
    local has_lipc, lipc = pcall(require, "liblipclua")
    if not has_lipc or lipc == nil then
        logger.warn("AutoFrontlight: liblipclua is unavailable")
        return nil
    end

    local handle = lipc.init("com.github.koreader.autofrontlight")
    if not handle then
        logger.warn("AutoFrontlight: could not open a LIPC handle")
        return nil
    end

    local ok, value = pcall(handle.get_int_property, handle, "com.lab126.powerd", "alsLux")
    pcall(handle.close, handle)
    if not ok or type(value) ~= "number" then
        logger.warn("AutoFrontlight: failed to read raw ambient light", value)
        return nil
    end
    return math.max(0, value)
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

function AutoFrontlight:_calculateTargetBrightness(raw_light)
    if raw_light >= self.bright_light_reading then
        return self.daylight_brightness
    end

    -- Human perception is approximately logarithmic. Mapping log(raw + 1)
    -- gives useful separation in dark rooms without wasting most of the range
    -- on the very large values produced in daylight.
    local position = math.log(raw_light + 1) / math.log(self.bright_light_reading + 1)
    local target = self.darkness_brightness
        + (self.daylight_brightness - self.darkness_brightness) * position
    return math.floor(target + 0.5)
end

function AutoFrontlight:_applyBrightness(target, source)
    -- Preserve a manual override until the calculated target changes.
    if target == self.last_target_brightness then
        return
    end

    local powerd = Device:getPowerDevice()
    if target <= 0 then
        logger.dbg("AutoFrontlight:", source, "turning frontlight off")
        powerd:turnOffFrontlight()
    else
        logger.dbg("AutoFrontlight:", source, "setting brightness", target)
        powerd:setIntensity(target)
        -- On Kindle this is normally already reflected by setIntensityHW, but
        -- explicitly turn the light on for compatibility with future changes.
        powerd:turnOnFrontlight()
    end
    self.last_target_brightness = target
end

function AutoFrontlight:_poll()
    local raw_light = self:_readRawAmbientLight()
    if raw_light ~= nil then
        local target = self:_calculateTargetBrightness(raw_light)
        logger.dbg("AutoFrontlight: raw ambient light", raw_light, "target", target)
        self:_applyBrightness(target, "raw light " .. raw_light)
        return raw_light, nil, target
    end

    -- Fallback for unusual Kindle builds where direct LIPC access fails.
    local level = self:_readAmbientLevel()
    if level ~= nil then
        local target = self.brightness_levels[level + 1]
        logger.dbg("AutoFrontlight: fallback ambient level", level, "target", target)
        self:_applyBrightness(target, "fallback level " .. level)
        return nil, level, target
    end
    return nil, nil, nil
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
    self.last_target_brightness = nil
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
    self:_loadAdaptiveSettings()
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
        self.last_target_brightness = nil
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

    local curve_items = {
        {
            text_func = function()
                return T(_("Brightness in darkness: %1"), self.darkness_brightness)
            end,
            callback = function(touchmenu_instance)
                local SpinWidget = require("ui/widget/spinwidget")
                UIManager:show(SpinWidget:new {
                    title_text = _("Brightness in darkness"),
                    info_text = _("Frontlight level used when the sensor reads complete darkness."),
                    value = self.darkness_brightness,
                    value_min = 1,
                    value_max = Device:getPowerDevice().fl_max or 24,
                    value_step = 1,
                    value_hold_step = 5,
                    ok_text = _("Set brightness"),
                    callback = function(spin)
                        self.darkness_brightness = spin.value
                        self.daylight_brightness = math.min(self.daylight_brightness, spin.value)
                        self.last_target_brightness = nil
                        self:_save()
                        if self.enabled then
                            self:_schedule(0.5)
                        end
                        touchmenu_instance:updateItems()
                    end,
                })
            end,
        },
        {
            text_func = function()
                return T(_("Brightness in daylight: %1"), self.daylight_brightness)
            end,
            callback = function(touchmenu_instance)
                local SpinWidget = require("ui/widget/spinwidget")
                UIManager:show(SpinWidget:new {
                    title_text = _("Brightness in daylight"),
                    info_text = _("Frontlight level used at or above the bright-light threshold. Set it to 0 to turn the frontlight off."),
                    value = self.daylight_brightness,
                    value_min = 0,
                    value_max = self.darkness_brightness,
                    value_step = 1,
                    value_hold_step = 5,
                    ok_text = _("Set brightness"),
                    callback = function(spin)
                        self.daylight_brightness = spin.value
                        self.last_target_brightness = nil
                        self:_save()
                        if self.enabled then
                            self:_schedule(0.5)
                        end
                        touchmenu_instance:updateItems()
                    end,
                })
            end,
        },
        {
            text_func = function()
                return T(_("Bright-light threshold: %1"), self.bright_light_reading)
            end,
            callback = function(touchmenu_instance)
                local SpinWidget = require("ui/widget/spinwidget")
                UIManager:show(SpinWidget:new {
                    title_text = _("Bright-light threshold"),
                    info_text = _("Raw sensor reading at which the daylight brightness is reached. A higher value keeps the frontlight brighter in well-lit rooms."),
                    value = self.bright_light_reading,
                    value_min = 500,
                    value_max = 32768,
                    value_step = 500,
                    value_hold_step = 2000,
                    ok_text = _("Set threshold"),
                    callback = function(spin)
                        self.bright_light_reading = spin.value
                        self.last_target_brightness = nil
                        self:_save()
                        if self.enabled then
                            self:_schedule(0.5)
                        end
                        touchmenu_instance:updateItems()
                    end,
                })
            end,
        },
        {
            text = _("Restore recommended curve"),
            callback = function(touchmenu_instance)
                self.darkness_brightness = DEFAULT_DARKNESS_BRIGHTNESS
                self.daylight_brightness = DEFAULT_DAYLIGHT_BRIGHTNESS
                self.bright_light_reading = DEFAULT_BRIGHT_LIGHT_READING
                self.last_target_brightness = nil
                self:_save()
                if self.enabled then
                    self:_schedule(0.5)
                end
                touchmenu_instance:updateItems()
            end,
        },
    }

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
                text = _("Adaptive brightness curve"),
                sub_item_table = curve_items,
            },
            {
                text = _("Test sensor now"),
                callback = function()
                    local raw_light, level, target = self:_poll()
                    local status_text
                    if raw_light ~= nil then
                        status_text = T(_("Raw light reading: %1\nSelected brightness: %2"),
                            raw_light, target)
                    elseif level ~= nil then
                        status_text = T(_("Raw reading unavailable\nFallback level: %1\nSelected brightness: %2"),
                            level, target)
                    else
                        status_text = _("Could not read the ambient-light sensor.")
                    end
                    UIManager:show(InfoMessage:new {
                        text = status_text,
                        timeout = 4,
                    })
                end,
            },
            {
                text = _("Compatibility information"),
                callback = function()
                    local raw_light = self:_readRawAmbientLight()
                    local level = self:_readAmbientLevel()
                    local sensor_flag = Device:hasLightSensor() and _("yes") or _("no")
                    UIManager:show(InfoMessage:new {
                        text = T(_("Device: %1\nKOReader sensor flag: %2\nRaw light: %3\nFallback level: %4"),
                            Device.model or _("Kindle"), sensor_flag,
                            raw_light ~= nil and tostring(raw_light) or _("unavailable"),
                            level ~= nil and tostring(level) or _("unavailable")),
                    })
                end,
            },
        },
    }
end

return AutoFrontlight
