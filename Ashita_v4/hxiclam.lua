--[[
* Goal of this addon is to calculate weight and cost of items obtained through clamming.
*
* Used SlowedHaste HGather as a base for this addon: https://github.com/SlowedHaste/HGather
--]] addon.name = 'hxiclam';
addon.author = 'jimmy58663';
addon.version = '1.2.5';
addon.desc = 'HorizonXI clamming tracker addon.';
addon.link = 'https://github.com/jimmy58663/HXIClam';
addon.commands = {'/hxiclam'};

require('common');
local chat = require('chat');
local d3d = require('d3d8');
local ffi = require('ffi');
local fonts = require('fonts');
local imgui = require('imgui');
local prims = require('primitives');
local scaling = require('scaling');
local settings = require('settings');
local data = require('constants');

local C = ffi.C;
local d3d8dev = d3d.get_device();

local logs = T {
    drop_log_dir = 'drops',
    turnin_log_dir = 'turnins',
    char_name = nil
};

-- Default Settings
local default_settings = T {
    visible = T {false},
    moon_display = T {false},
    display_timeout = T {600},
    opacity = T {1.0},
    padding = T {1.0},
    scale = T {1.0},
    item_index = data.ItemIndex,
    item_weight_index = data.ItemWeightIndex,
    font_scale = T {1.0},
    x = T {100},
    y = T {100},
    enable_logging = T {true},

    -- Clamming Display Settings
    clamming = T {bucket_cost = T {500}, bucket_subtract = T {true}},
    reset_on_load = T {false},
    first_attempt = 0,
    rewards = {},
    bucket_count = 0,
    item_count = 0,
    session_view = 1, -- 0 no session stats, 1 session summary, 2 session details

    bucket = {},
    bucket_weight = 0,
    bucket_capacity = 50,
    bucket_weight_warn_color = {1.0, 1.0, 0.0, 1.0}, -- yellow
    bucket_weight_warn_threshold = T {20},
    bucket_weight_crit_color = {1.0, 0.0, 0.0, 1.0}, -- red
    bucket_weight_crit_threshold = T {7},
    dig_timer_ready_color = {0.0, 1.0, 0.0, 1.0}, -- green
    bucket_weight_font_scale = T {1.0},

    last_dig = 0,
    dig_timer = 0,
    dig_timer_countdown = true,

    enable_tone = T {true},
    tone = 'clam.wav',
    tone_selected_idx = 1,
    available_tones = T {'clam.wav'},
    
    enable_turnin_tone = T {true},
    turnin_tone = 'clam.wav',
    turnin_tone_selected_idx = 1
};

-- HXIClam Variables
local hxiclam = T {
    settings = settings.load(default_settings),

    -- hxiclam movement variables..
    move = T {dragging = false, drag_x = 0, drag_y = 0, shift_down = false},

    -- Editor variables..
    editor = T {is_open = T {false}},

    last_attempt = ashita.time.clock()['ms'],
    pricing = T {},
    weights = T {},
    gil_per_hour = 0,

    play_tone = false,
    play_turnin_tone = false,
    turnin_sound_played = false,
    dig_ready_sound_played = false,
    has_bucket = false,
    bucket_broken = false
};

local MAX_HEIGHT_IN_LINES = 26;

----------------------------------------------------------------------------------------------------
-- Helper functions
----------------------------------------------------------------------------------------------------
local function split(inputstr, sep)
    if sep == nil then sep = '%s'; end
    local t = {};
    for str in string.gmatch(inputstr, '([^' .. sep .. ']+)') do
        table.insert(t, str);
    end
    return t;
end

local function clean_item_name(item_name)
    -- Remove "handful of" from the beginning of item names to make them more concise
    local cleaned = item_name:gsub("^handful of ", "");
    return cleaned;
end

----------------------------------------------------------------------------------------------------
-- Format numbers with commas
-- https://stackoverflow.com/questions/10989788/format-integer-in-lua
----------------------------------------------------------------------------------------------------
local function format_int(number)
    if (string.len(number) < 4) then return number end
    if (number ~= nil and number ~= '' and type(number) == 'number') then
        local i, j, minus, int, fraction =
            tostring(number):find('([-]?)(%d+)([.]?%d*)');

        -- we sometimes get a nil int from the above tostring, just return number in those cases
        if (int == nil) then return number end

        -- reverse the int-string and append a comma to all blocks of 3 digits
        int = int:reverse():gsub("(%d%d%d)", "%1,");

        -- reverse the int-string back remove an optional comma and put the
        -- optional minus and fractional part back
        return minus .. int:reverse():gsub("^,", "") .. fraction;
    else
        return 'NaN';
    end
end

function WriteLog(logtype, item)
    -- Current log types supported are drop and turnin
    local logdir = nil
    if logtype == 'drop' then
        logdir = logs.drop_log_dir;
    elseif logtype == 'turnin' then
        logdir = logs.turnin_log_dir;
    end

    local datetime = os.date('*t');
    local log_file_name = ('%s_%.4u.%.2u.%.2u.log'):fmt(logs.char_name,
                                                        datetime.year,
                                                        datetime.month,
                                                        datetime.day);
    local full_directory = ('%s/addons/hxiclam/logs/%s/'):fmt(
                               AshitaCore:GetInstallPath(), logdir);

    if (not ashita.fs.exists(full_directory)) then
        ashita.fs.create_dir(full_directory);
    end

    local file = io.open(('%s/%s'):fmt(full_directory, log_file_name), 'a');
    if (file ~= nil) then
        local filedata = ('%s, %s\n'):fmt(os.date('[%H:%M:%S]'), item);
        file:write(filedata);
        file:close();
    end
end

----------------------------------------------------------------------------------------------------
-- Helper functions borrowed from luashitacast
----------------------------------------------------------------------------------------------------
function GetTimestamp()
    local pVanaTime = ashita.memory.find('FFXiMain.dll', 0,
                                         'B0015EC390518B4C24088D4424005068', 0,
                                         0);
    local pointer = ashita.memory.read_uint32(pVanaTime + 0x34);
    local rawTime = ashita.memory.read_uint32(pointer + 0x0C) + 92514960;
    local timestamp = {};
    timestamp.day = math.floor(rawTime / 3456);
    timestamp.hour = math.floor(rawTime / 144) % 24;
    timestamp.minute = math.floor((rawTime % 144) / 2.4);
    return timestamp;
end

function GetWeather()
    local pWeather = ashita.memory.find('FFXiMain.dll', 0,
                                        '66A1????????663D????72', 0, 0);
    local pointer = ashita.memory.read_uint32(pWeather + 0x02);
    return ashita.memory.read_uint8(pointer + 0);
end

function GetMoon()
    local timestamp = GetTimestamp();
    local moon_index = ((timestamp.day + 26) % 84) + 1;
    local moon_table = {};
    moon_table.MoonPhase = data.MoonPhase[moon_index];
    moon_table.MoonPhasePercent = data.MoonPhasePercent[moon_index];
    return moon_table;
end

----------------------------------------------------------------------------------------------------
-- Core functions
----------------------------------------------------------------------------------------------------
--[[
* Prints the addon help information.
*
* @param {boolean} isError - Flag if this function was invoked due to an error.
--]]
local function print_help(isError)
    -- Print the help header..
    if (isError) then
        print(chat.header(addon.name):append(chat.error(
                                                 'Invalid command syntax for command: '))
                  :append(chat.success('/' .. addon.name)));
    else
        print(
            chat.header(addon.name):append(chat.message('Available commands:')));
    end

    local cmds = T {
        {'/hxiclam', 'Toggles the HXIClam editor.'},
        {'/hxiclam edit', 'Toggles the HXIClam editor.'},
        {'/hxiclam save', 'Saves the current settings to disk.'},
        {'/hxiclam reload', 'Reloads the current settings from disk.'},
        {'/hxiclam clear', 'Clears the HXIClam bucket and session stats.'},
        {'/hxiclam clear bucket', 'Clears the HXIClam bucket stats.'},
        {'/hxiclam clear session', 'Clears the HXIClam session stats.'},
        {'/hxiclam show', 'Shows the HXIClam information.'},
        {'/hxiclam show session', 'Shows the HXIClam session stats.'},
        {'/hxiclam hide', 'Hides the HXIClam information.'},
        {'/hxiclam hide session', 'Hides the HXIClam session stats.'},
        {'/hxiclam update', 'Updates the HXIClam item pricing and weight info.'},
        {'/hxiclam update pricing', 'Updates the HXIClam item pricing info.'},
        {'/hxiclam update weights', 'Updates the HXIClam item weight info.'}
    };

    -- Print the command list..
    cmds:ieach(function(v)
        print(chat.header(addon.name):append(chat.error('Usage: ')):append(
                  chat.message(v[1]):append(' - ')):append(chat.color1(6, v[2])));
    end);
end

local function update_pricing()
    local itemname;
    local itemvalue;
    for k, v in pairs(hxiclam.settings.item_index) do
        for k2, v2 in pairs(split(v, ':')) do
            if (k2 == 1) then itemname = v2; end
            if (k2 == 2) then itemvalue = tonumber(v2) or 0; end
        end

        hxiclam.pricing[itemname] = itemvalue;
    end
end

local function update_weights()
    local itemname;
    local itemvalue;
    for k, v in pairs(hxiclam.settings.item_weight_index) do
        for k2, v2 in pairs(split(v, ':')) do
            if (k2 == 1) then itemname = v2; end
            if (k2 == 2) then itemvalue = tonumber(v2) or 0; end
        end

        hxiclam.weights[itemname] = itemvalue;
    end

    hxiclam.settings.bucket_weight = 0;
    for k, v in pairs(hxiclam.settings.bucket) do
        if (hxiclam.weights[k] ~= nil) then
            hxiclam.settings.bucket_weight =
                hxiclam.settings.bucket_weight + (hxiclam.weights[k] * v);
        end
    end
end

local function update_tones()
    hxiclam.settings.available_tones = T {};
    local tone_path = ("%stones/"):format(addon.path);
    local cmd = 'dir "' .. tone_path .. '" /B';
    local idx = 1;
    for file in io.popen(cmd):lines() do
        hxiclam.settings.available_tones[idx] = file;
        idx = idx + 1;
    end
end

local function clear_rewards()
    hxiclam.last_attempt = ashita.time.clock()['ms'];
    hxiclam.settings.first_attempt = 0;
    hxiclam.settings.rewards = {};
    hxiclam.settings.item_count = 0;
    hxiclam.settings.bucket_count = 0;
end

local function clear_bucket()
    hxiclam.settings.bucket = {};
    hxiclam.settings.bucket_weight = 0;
    hxiclam.settings.bucket_capacity = 50;
    hxiclam.turnin_sound_played = false; -- Reset turnin sound flag
end

local function play_sound()
    if (hxiclam.settings.enable_tone[1] == true and hxiclam.play_tone == true) then
        ashita.misc.play_sound(("%stones/%s"):format(addon.path,
                                                     hxiclam.settings.tone));
        hxiclam.play_tone = false;
    end
    
    if (hxiclam.settings.enable_turnin_tone[1] == true and hxiclam.play_turnin_tone == true) then
        ashita.misc.play_sound(("%stones/%s"):format(addon.path,
                                                     hxiclam.settings.turnin_tone));
        hxiclam.play_turnin_tone = false;
    end
end

--[[
* Renders the HXIClam settings editor.
--]]
local function render_general_config(settings)
    imgui.Text('General Settings');
    imgui.BeginChild('settings_general', {
        0, imgui.GetTextLineHeightWithSpacing() * MAX_HEIGHT_IN_LINES / 2
    }, true, ImGuiWindowFlags_AlwaysAutoResize);
    if (imgui.Checkbox('Visible', hxiclam.settings.visible)) then
        -- if the checkbox is interacted with, reset the last_attempt
        -- to force the window back open
        hxiclam.last_attempt = ashita.time.clock()['ms'];
    end
    imgui.ShowHelp('Toggles if HXIClam is visible or not.');
    imgui.Checkbox('Enable sound', hxiclam.settings.enable_tone);
    imgui.ShowHelp(
        'Enable/Disable a tone to be played when the dig timer is ready.');
    imgui.SameLine();
    if (imgui.BeginCombo('', hxiclam.settings.tone)) then
        for k, v in pairs(hxiclam.settings.available_tones) do
            local is_selected = k == hxiclam.settings.tone_selected_idx;
            if (imgui.Selectable(v, is_selected)) then
                hxiclam.settings.tone_selected_idx = k;
                hxiclam.settings.tone = v;
            end
            if (is_selected) then imgui.SetItemDefaultFocus(); end
        end
        imgui.EndCombo();
    end
    imgui.SameLine();
    if (imgui.ArrowButton("Tone_Test", ImGuiDir_Right)) then
        ashita.misc.play_sound(("%stones/%s"):format(addon.path,
                                                     hxiclam.settings.tone));
    end
    
    imgui.Checkbox('Enable turnin sound', hxiclam.settings.enable_turnin_tone);
    imgui.ShowHelp(
        'Enable/Disable a tone to be played when the bucket is nearly full and ready to turn in.');
    imgui.SameLine();
    if (imgui.BeginCombo('##turnin', hxiclam.settings.turnin_tone)) then
        for k, v in pairs(hxiclam.settings.available_tones) do
            local is_selected = k == hxiclam.settings.turnin_tone_selected_idx;
            if (imgui.Selectable(v, is_selected)) then
                hxiclam.settings.turnin_tone_selected_idx = k;
                hxiclam.settings.turnin_tone = v;
            end
            if (is_selected) then imgui.SetItemDefaultFocus(); end
        end
        imgui.EndCombo();
    end
    imgui.SameLine();
    if (imgui.ArrowButton("Turnin_Tone_Test", ImGuiDir_Right)) then
        ashita.misc.play_sound(("%stones/%s"):format(addon.path,
                                                     hxiclam.settings.turnin_tone));
    end
    imgui.SliderFloat('Opacity', hxiclam.settings.opacity, 0.125, 1.0, '%.3f');
    imgui.ShowHelp('The opacity of the HXIClam window.');
    imgui.SliderFloat('Font Scale', hxiclam.settings.font_scale, 0.1, 2.0,
                      '%.3f');
    imgui.ShowHelp('The scaling of the font size.');
    imgui.InputInt('Display Timeout', hxiclam.settings.display_timeout);
    imgui.ShowHelp(
        'How long should the display window stay open after the last dig.');

    local pos = {hxiclam.settings.x[1], hxiclam.settings.y[1]};
    if (imgui.InputInt2('Position', pos)) then
        hxiclam.settings.x[1] = pos[1];
        hxiclam.settings.y[1] = pos[2];
    end
    imgui.ShowHelp('The position of HXIClam on screen.');

    imgui.Checkbox('Moon Display', hxiclam.settings.moon_display);
    imgui.ShowHelp('Toggles if moon phase / percent is shown.');
    imgui.Checkbox('Reset Rewards On Load', hxiclam.settings.reset_on_load);
    imgui.ShowHelp(
        'Toggles whether we reset rewards each time the addon is loaded.');
    imgui.Checkbox('Enable Logging', hxiclam.settings.enable_logging);
    imgui.ShowHelp(
        'Toggles whether drops and bucket turnins are logged in a text file.');
    imgui.SameLine();
    imgui.EndChild();
    imgui.Text('Clamming Display Settings');
    imgui.BeginChild('clam_general', {
        0, imgui.GetTextLineHeightWithSpacing() * MAX_HEIGHT_IN_LINES / 2
    }, true, ImGuiWindowFlags_AlwaysAutoResize);
    if (imgui.RadioButton('Hide Session Stats',
                          hxiclam.settings.session_view == 0)) then
        hxiclam.settings.session_view = 0;
    end
    imgui.ShowHelp('Hides the session stats.');
    imgui.SameLine();
    if (imgui.RadioButton('Session Summary', hxiclam.settings.session_view == 1)) then
        hxiclam.settings.session_view = 1;
    end
    imgui.ShowHelp('Shows only session stats as a summary.');
    imgui.SameLine();
    if (imgui.RadioButton('Session Details', hxiclam.settings.session_view == 2)) then
        hxiclam.settings.session_view = 2;
    end
    imgui.ShowHelp('Shows full session details.');
    -- Commented out since we now use a progress bar instead of counting
    --if (imgui.RadioButton('Dig Timer Count Up',
    --                      hxiclam.settings.dig_timer_countdown == false)) then
    --    hxiclam.settings.dig_timer_countdown = false;
    --end
    --imgui.ShowHelp('Dig timer will count up to 9 and then display Dig Ready.');
    --imgui.SameLine();
    --if (imgui.RadioButton('Dig Timer Count Down',
    --                      hxiclam.settings.dig_timer_countdown == true)) then
    --    hxiclam.settings.dig_timer_countdown = true;
    --end
    --imgui.ShowHelp(
    --    'Dig timer will count down from 10 and then display Dig Ready.');
    imgui.Checkbox('Subtract Bucket Cost',
                   hxiclam.settings.clamming.bucket_subtract);
    imgui.ShowHelp(
        'Toggles if bucket costs are automatically subtracted from gil earned.');
    imgui.InputInt('Warning Weight Limit',
                   hxiclam.settings.bucket_weight_warn_threshold);
    imgui.ShowHelp(
        'How much weight left in your bucket will turn the bucket weight to the warning bucket color.');
    imgui.ColorEdit4('Warning Bucket Color',
                     hxiclam.settings.bucket_weight_warn_color);
    imgui.ShowHelp(
        'The color bucket weight will turn when it reached the warning weight limit.');
    imgui.InputInt('Critical Weight Limit',
                   hxiclam.settings.bucket_weight_crit_threshold);
    imgui.ShowHelp(
        'How much weight left in your bucket will turn the bucket weight to the critical bucket color.');
    imgui.ColorEdit4('Critical Bucket Color',
                     hxiclam.settings.bucket_weight_crit_color);
    imgui.ShowHelp(
        'The color bucket weight will turn when it reached the critical weight limit.');
    imgui.ColorEdit4('Dig Timer Ready Color',
                     hxiclam.settings.dig_timer_ready_color);
    imgui.ShowHelp('The color dig timer will turn when it reaches Dig Ready.');
    imgui.SliderFloat('Weight Font Scale',
                      hxiclam.settings.bucket_weight_font_scale, 0.1, 2.0,
                      '%.3f');
    imgui.ShowHelp('The scaling of the font size for bucket weight.');
    imgui.EndChild();
end

local function render_item_price_config(settings)
    imgui.Text('Item Prices');
    imgui.BeginChild('settings_general', {
        0, imgui.GetTextLineHeightWithSpacing() * MAX_HEIGHT_IN_LINES
    }, true, ImGuiWindowFlags_AlwaysAutoResize);

    imgui.InputInt('Bucket Cost', hxiclam.settings.clamming.bucket_cost);
    imgui.ShowHelp('Cost of a single bucket.');

    imgui.Separator();

    local temp_strings = T {};
    temp_strings[1] = table.concat(hxiclam.settings.item_index, '\n');
    if (imgui.InputTextMultiline('\nItem Prices', temp_strings, 8192, {
        0, imgui.GetTextLineHeightWithSpacing() * (MAX_HEIGHT_IN_LINES - 3)
    })) then
        hxiclam.settings.item_index = split(temp_strings[1], '\n');
        table.sort(hxiclam.settings.item_index);
    end
    imgui.ShowHelp(
        'Individual items, lowercase, separated by : with price on right side.');
    imgui.EndChild();
end

local function render_item_weight_config(settings)
    imgui.Text('Item Weights');
    imgui.BeginChild('settings_general', {
        0, imgui.GetTextLineHeightWithSpacing() * MAX_HEIGHT_IN_LINES
    }, true, ImGuiWindowFlags_AlwaysAutoResize);

    local temp_strings = T {};
    temp_strings[1] = table.concat(hxiclam.settings.item_weight_index, '\n');
    if (imgui.InputTextMultiline('\nItem Weights', temp_strings, 8192, {
        0, imgui.GetTextLineHeightWithSpacing() * (MAX_HEIGHT_IN_LINES - 3)
    })) then
        hxiclam.settings.item_weight_index = split(temp_strings[1], '\n');
        table.sort(hxiclam.settings.item_weight_index);
    end
    imgui.ShowHelp(
        'Individual items, lowercase, separated by : with weight on right side.');
    imgui.EndChild();
end

local function render_editor()
    if (not hxiclam.editor.is_open[1]) then return; end

    imgui.SetNextWindowSize({0, 0}, ImGuiCond_Always);
    if (imgui.Begin('HXIClam##Config', hxiclam.editor.is_open,
                    ImGuiWindowFlags_AlwaysAutoResize)) then

        -- imgui.SameLine();
        if (imgui.Button('Save Settings')) then
            settings.save();
            print(
                chat.header(addon.name):append(chat.message('Settings saved.')));
        end
        imgui.SameLine();
        if (imgui.Button('Reload Settings')) then
            settings.reload();
            print(chat.header(addon.name):append(chat.message(
                                                     'Settings reloaded.')));
        end
        imgui.SameLine();
        if (imgui.Button('Reset Settings')) then
            settings.reset();
            print(chat.header(addon.name):append(chat.message(
                                                     'Settings reset to defaults.')));
        end
        imgui.SameLine();
        if (imgui.Button('Update Pricing')) then
            update_pricing();
            print(chat.header(addon.name):append(
                      chat.message('Pricing updated.')));
        end
        imgui.SameLine();
        if (imgui.Button('Update Weights')) then
            update_weights();
            print(chat.header(addon.name):append(
                      chat.message('Weights updated.')));
        end
        if (imgui.Button('Clear Session')) then
            clear_rewards();
            print(chat.header(addon.name):append(
                      chat.message('Cleared session.')));
        end
        imgui.SameLine();
        if (imgui.Button('Clear Bucket')) then
            clear_bucket();
            print(
                chat.header(addon.name):append(chat.message('Cleared bucket.')));
        end
        imgui.SameLine();
        if (imgui.Button('Clear All')) then
            clear_rewards();
            clear_bucket();
            print(chat.header(addon.name):append(chat.message(
                                                     'Cleared session and bucket.')));
        end

        imgui.Separator();

        if (imgui.BeginTabBar('##hxiclam_tabbar',
                              ImGuiTabBarFlags_NoCloseWithMiddleMouseButton)) then
            if (imgui.BeginTabItem('General', nil)) then
                render_general_config(settings);
                imgui.EndTabItem();
            end
            if (imgui.BeginTabItem('Item Price', nil)) then
                render_item_price_config(settings);
                imgui.EndTabItem();
            end
            if (imgui.BeginTabItem('Item Weight', nil)) then
                render_item_weight_config(settings);
                imgui.EndTabItem();
            end
            imgui.EndTabBar();
        end

    end
    imgui.End();
end

--[[
* Registers a callback for the settings to monitor for character switches.
--]]
settings.register('settings', 'settings_update', function(s)
    if (s ~= nil) then hxiclam.settings = s; end

    -- Save the current settings..
    settings.save();
    update_pricing();
    update_weights();
end);

--[[
* event: load
* desc : Event called when the addon is being loaded.
--]]
ashita.events.register('load', 'load_cb', function()
    update_pricing();
    update_weights();
    update_tones();
    if (hxiclam.settings.reset_on_load[1]) then
        print('Reset bucket and session on reload.');
        clear_rewards();
        clear_bucket();
    end

    local name = AshitaCore:GetMemoryManager():GetParty():GetMemberName(0);
    if (name ~= nil and name:len() > 0) then logs.char_name = name; end
end);

--[[
* event: unload
* desc : Event called when the addon is being unloaded.
--]]
ashita.events.register('unload', 'unload_cb', function()
    -- Save the current settings..
    settings.save();
end);

--[[
* event: command
* desc : Event called when the addon is processing a command.
--]]
ashita.events.register('command', 'command_cb', function(e)
    -- Parse the command arguments..
    local args = e.command:args();
    if (#args == 0 or not args[1]:any('/hxiclam')) then return; end

    -- Block all related commands..
    e.blocked = true;

    -- Handle: /hxiclam - Toggles the hxiclam editor.
    -- Handle: /hxiclam edit - Toggles the hxiclam editor.
    if (#args == 1 or (#args >= 2 and args[2]:any('edit'))) then
        hxiclam.editor.is_open[1] = not hxiclam.editor.is_open[1];
        return;
    end

    -- Handle: /hxiclam save - Saves the current settings.
    if (#args >= 2 and args[2]:any('save')) then
        update_pricing();
        update_weights();
        settings.save();
        print(chat.header(addon.name):append(chat.message('Settings saved.')));
        return;
    end

    -- Handle: /hxiclam reload - Reloads the current settings from disk.
    if (#args >= 2 and args[2]:any('reload')) then
        settings.reload();
        update_tones();
        print(chat.header(addon.name):append(chat.message('Settings reloaded.')));
        return;
    end

    -- Handle: /hxiclam clear - Clears the current session and bucket info.
    -- Handle: /hxiclam clear bucket - Clears the current bucket info.
    -- Handle: /hxiclam clear session - Clears the current session info.
    if (#args >= 2 and args[2]:any('clear')) then
        if (#args == 3 and args[3]:any('bucket')) then
            clear_bucket();
            print(chat.header(addon.name):append(chat.message(
                                                     'Cleared hxiclam bucket.')));
        elseif (#args == 3 and args[3]:any('session')) then
            clear_rewards();
            print(chat.header(addon.name):append(chat.message(
                                                     'Cleared hxiclam session.')));
        else
            clear_rewards();
            clear_bucket();
            print(chat.header(addon.name):append(chat.message(
                                                     'Cleared hxiclam bucket and session.')));
        end
        return;
    end

    -- Handle: /hxiclam show - Shows the hxiclam object.
    if (#args >= 2 and args[2]:any('show')) then
        if (#args == 3 and args[3]:any('session')) then
            hxiclam.settings.session_view = 2;
        elseif (#args == 3 and args[3]:any('summary')) then
            hxiclam.settings.session_view = 1;
        else
            -- reset last dig on show command to reset timeout counter
            hxiclam.last_attempt = ashita.time.clock()['ms'];
            hxiclam.settings.visible[1] = true;
        end
        return;
    end

    -- Handle: /hxiclam hide - Hides the hxiclam object.
    if (#args >= 2 and args[2]:any('hide')) then
        if (#args == 3 and args[3]:any('session')) then
            hxiclam.settings.session_view = 0;
        else
            hxiclam.settings.visible[1] = false;
        end
        return;
    end

    -- Handle: /hxiclam update - Updates the current pricing and weight info for items.
    -- Handle: /hxiclam update pricing - Updates the current pricing info for items.
    -- Handle: /hxiclam update weights - Updates the current weight info for items.
    if (#args >= 2 and args[2]:any('update')) then
        if (#args == 3 and args[3]:any('pricing')) then
            update_pricing();
            print(chat.header(addon.name):append(
                      chat.message('Pricing updated.')));
        elseif (#args == 3 and args[3]:any('weights')) then
            update_weights();
            print(chat.header(addon.name):append(
                      chat.message('Weights updated.')));
        else
            update_pricing();
            update_weights();
            print(chat.header(addon.name):append(chat.message(
                                                     'Pricing and weights updated.')));
        end
        return;
    end

    -- Unhandled: Print help information..
    print_help(true);
end);

----------------------------------------------------------------------------------------------------
-- Parse Digging Items + Main Logic
----------------------------------------------------------------------------------------------------
ashita.events.register('text_in', 'text_in_cb', function(e)
    local last_attempt_secs =
        (ashita.time.clock()['ms'] - hxiclam.last_attempt) / 1000.0;
    local message = e.message;
    message = string.lower(message);
    message = string.strip_colors(message);

    local bucket = string.match(message, "obtained key item: clamming kit");
    local item = string.match(message,
                              "you find a[n]? (.*) and toss it into your bucket.*");
    local bucket_upgrade = string.match(message,
                                        "your clamming capacity has increased to (%d+) ponzes!");
    local bucket_turnin = string.match(message, "you return the clamming kit");
    local overweight = string.match(message,
                                    ".*for the bucket and its bottom breaks.*");
    local incident =
        string.match(message, ".*somthing jumps into your bucket.*"); -- need an example text of this

    -- Update last attempt timestamp if any clamming action occurs
    -- show hxiclam once a clamming action occurs
    if (bucket or item or bucket_turnin or overweight or incident) then
        hxiclam.last_attempt = ashita.time.clock()['ms']
        if (hxiclam.settings.first_attempt == 0) then
            hxiclam.settings.first_attempt = ashita.time.clock()['ms'];
        end
        if (hxiclam.settings.visible[1] == false) then
            hxiclam.settings.visible[1] = true;
        end
    end

    -- Clear bucket and add to bucket count when a bucket is obtained.
    if (bucket) then
        clear_bucket();
        hxiclam.has_bucket = true; -- Player now has a bucket
        hxiclam.bucket_broken = false; -- Reset broken state
        hxiclam.settings.bucket_count = hxiclam.settings.bucket_count + 1;
        
        -- Set last_dig to current time so timer doesn't think it's ready immediately
        hxiclam.settings.last_dig = ashita.time.clock()['ms'];
        
        -- Reset dig ready sound flag so it doesn't play immediately
        hxiclam.dig_ready_sound_played = false;
    elseif (item) then
        -- If we're digging items, we must have a bucket
        hxiclam.has_bucket = true;
        hxiclam.bucket_broken = false;
        
        -- Update last dig time and reset dig_timer
        hxiclam.settings.last_dig = ashita.time.clock()['ms'];
        
        -- Reset dig ready sound flag for new dig cycle
        hxiclam.dig_ready_sound_played = false;

        if (hxiclam.settings.dig_timer_countdown) then
            hxiclam.settings.dig_timer = 10;
        else
            hxiclam.settings.dig_timer = 0;
        end

        -- Update bucket item list
        if (hxiclam.settings.bucket[item] == nil) then
            hxiclam.settings.bucket[item] = 1;
        elseif (hxiclam.settings.bucket[item] ~= nil) then
            hxiclam.settings.bucket[item] = hxiclam.settings.bucket[item] + 1;
        end

        -- Log the item
        if (hxiclam.settings.enable_logging[1]) then
            WriteLog('drop', item);
        end

        -- Update bucket weight
        if (hxiclam.weights[item] ~= nil) then
            hxiclam.settings.bucket_weight =
                hxiclam.settings.bucket_weight + hxiclam.weights[item];
        end
    elseif (bucket_upgrade) then
        hxiclam.settings.bucket_capacity = bucket_upgrade;
        elseif (bucket_turnin) then
        if (hxiclam.settings.bucket ~= nil and hxiclam.settings.bucket ~= {}) then
            -- Only add to rewards if bucket wasn't broken (lost items shouldn't count toward session stats)
            if (not hxiclam.bucket_broken) then
            for k, v in pairs(hxiclam.settings.bucket) do
                hxiclam.settings.item_count = hxiclam.settings.item_count + v;
                if (hxiclam.settings.rewards[k] == nil) then
                    hxiclam.settings.rewards[k] = v;
                elseif (hxiclam.settings.rewards[k] ~= nil) then
                    hxiclam.settings.rewards[k] =
                        hxiclam.settings.rewards[k] + v
                end

                -- Log the items turned in
                if (hxiclam.settings.enable_logging[1]) then
                    for i = 1, v do WriteLog('turnin', k); end
                    end
                end
            end
            clear_bucket();
        end
        hxiclam.has_bucket = false; -- No longer has bucket after turning it in
        hxiclam.bucket_broken = false; -- Reset broken state after turnin
        hxiclam.turnin_sound_played = false; -- Reset turnin sound flag
    end

    if (overweight or incident) then 
        hxiclam.has_bucket = false; -- No longer has bucket (broken), but keep contents visible
        hxiclam.bucket_broken = true; -- Mark as broken to show "Broken Bucket"
        hxiclam.turnin_sound_played = false; -- Reset turnin sound flag
    end
end);

--[[
* event: packet_in
* desc : Event called when a packet is received from the server.
--]]
ashita.events.register('packet_in', 'zonename_packet_in', function(event)
    if event.id == 0x0A then  -- Check if it's a zone change packet
        -- Hide the HXIClam window when zoning
        hxiclam.settings.visible[1] = false;
    end
end);

--[[
* event: d3d_beginscene
* desc : Event called when the Direct3D device is beginning a scene.
--]]
ashita.events.register('d3d_beginscene', 'beginscene_cb',
                       function(isRenderingBackBuffer) end);

--[[
* event: d3d_present
* desc : Event called when the Direct3D device is presenting a scene.
--]]
ashita.events.register('d3d_present', 'present_cb', function()
    local last_attempt_secs =
        (ashita.time.clock()['ms'] - hxiclam.last_attempt) / 1000.0;
    render_editor();

    if (last_attempt_secs > hxiclam.settings.display_timeout[1]) then
        hxiclam.settings.visible[1] = false;
    end

    -- Hide the hxiclam object if not visible..
    if (not hxiclam.settings.visible[1]) then return; end

    -- Hide the hxiclam object if Ashita is currently hiding font objects..
    if (not AshitaCore:GetFontManager():GetVisible()) then return; end

    imgui.SetNextWindowBgAlpha(hxiclam.settings.opacity[1]);
    imgui.SetNextWindowSize({-1, -1}, ImGuiCond_Always);
    
    -- Set rounded corners for prettier appearance
    imgui.PushStyleVar(ImGuiStyleVar_WindowRounding, 8.0);
    imgui.PushStyleVar(ImGuiStyleVar_ChildRounding, 4.0);
    
    if (imgui.Begin('HXIClam##Display', hxiclam.settings.visible[1],
                    bit.bor(ImGuiWindowFlags_NoDecoration,
                            ImGuiWindowFlags_AlwaysAutoResize,
                            ImGuiWindowFlags_NoFocusOnAppearing,
                            ImGuiWindowFlags_NoNav))) then
        local elapsed_time = ashita.time.clock()['s'] -
                                 math.floor(
                                     hxiclam.settings.first_attempt / 1000.0);
        local timer_display = hxiclam.settings.dig_timer;

        if (hxiclam.settings.dig_timer_countdown) then
            local dig_diff = (math.floor(hxiclam.settings.last_dig / 1000.0) +
                                 10) - ashita.time.clock()['s'];
            if (dig_diff < hxiclam.settings.dig_timer) then
                hxiclam.settings.dig_timer = dig_diff;
            end

            timer_display = hxiclam.settings.dig_timer;
            if (timer_display <= 0) then timer_display = "Dig Ready" end
        else
            local dig_diff = ashita.time.clock()['s'] -
                                 math.floor(hxiclam.settings.last_dig / 1000.0);
            if (dig_diff > hxiclam.settings.dig_timer) then
                hxiclam.settings.dig_timer = dig_diff
            end

            timer_display = hxiclam.settings.dig_timer;
            if (timer_display >= 10) then timer_display = "Dig Ready" end
        end

        local total_worth = 0;
        local bucket_total = 0;
        local moon_table = GetMoon();
        local moon_phase = moon_table.MoonPhase;
        local moon_percent = moon_table.MoonPhasePercent;

        imgui.SetWindowFontScale(hxiclam.settings.bucket_weight_font_scale[1]);
        
        -- Calculate bucket total first
        local bucket_total = 0;
        for k, v in pairs(hxiclam.settings.bucket) do
            if (hxiclam.pricing[k] ~= nil) then
                bucket_total = bucket_total + hxiclam.pricing[k] * v;
            end
        end
        
        -- Calculate text widths to prevent overlap
        local weight_text = 'Weight: ' .. tostring(hxiclam.settings.bucket_weight) .. ' / ' .. hxiclam.settings.bucket_capacity .. 'pz';
        local profit_text = 'Value: ' .. format_int(bucket_total) .. 'g';
        local weight_width = imgui.CalcTextSize(weight_text);
        local profit_width = imgui.CalcTextSize(profit_text);
        local min_spacing = 20; -- minimum pixels between weight and profit
        local window_width = imgui.GetWindowSize();
        
        -- Ensure minimum window width to prevent overlap
        local min_window_width = weight_width + profit_width + min_spacing + 20; -- 20 for padding
        if (window_width < min_window_width) then
            imgui.SetNextWindowSize({min_window_width, -1}, ImGuiCond_Always);
            window_width = min_window_width;
        end
        
        -- Left side: Weight
        if ((hxiclam.settings.bucket_capacity - hxiclam.settings.bucket_weight) <=
            hxiclam.settings.bucket_weight_crit_threshold[1]) then
            imgui.TextColored(hxiclam.settings.bucket_weight_crit_color,
                              'Weight: ' .. tostring(hxiclam.settings.bucket_weight) .. ' / ' ..
                                  hxiclam.settings.bucket_capacity .. 'pz');
        elseif ((hxiclam.settings.bucket_capacity -
            hxiclam.settings.bucket_weight) <=
            hxiclam.settings.bucket_weight_warn_threshold[1]) then
            imgui.TextColored(hxiclam.settings.bucket_weight_warn_color,
                              'Weight: ' .. tostring(hxiclam.settings.bucket_weight) .. ' / ' ..
                                  hxiclam.settings.bucket_capacity .. 'pz');
        else
            imgui.Text('Weight: ' .. tostring(hxiclam.settings.bucket_weight) .. ' / ' ..
                           hxiclam.settings.bucket_capacity .. 'pz');
        end
        
        -- Right side: Profit with safe positioning
        imgui.SameLine();
        local safe_profit_x = math.max(weight_width + min_spacing, window_width - profit_width - 10);
        imgui.SetCursorPosX(safe_profit_x);
        imgui.Text(profit_text);
        
        imgui.SetWindowFontScale(hxiclam.settings.font_scale[1]);

        -- Dig Timer Progress Bar - smooth calculation using real time
        local dig_progress, dig_ready, show_text, bar_text, bar_color;
        
        -- Check if bucket is nearly full (5 ponzes or less remaining)
        local bucket_space_remaining = hxiclam.settings.bucket_capacity - hxiclam.settings.bucket_weight;
        local bucket_nearly_full = hxiclam.has_bucket and bucket_space_remaining <= 5;
        
        if (hxiclam.bucket_broken) then
            -- Broken bucket - show full red bar with "Broken Bucket"
            dig_progress = 1.0;
            dig_ready = false;
            show_text = true;
            bar_text = 'Broken Bucket';
            bar_color = {1.0, 0.0, 0.0, 1.0}; -- red
        elseif (not hxiclam.has_bucket) then
            -- No bucket - show full blue bar with "No Bucket"
            dig_progress = 1.0;
            dig_ready = false;
            show_text = true;
            bar_text = 'No Bucket';
            bar_color = {0.2, 0.6, 1.0, 1.0}; -- blue
        elseif (bucket_nearly_full) then
            -- Bucket nearly full - show rainbow blinking "Turn In Bucket"
            dig_progress = 1.0;
            dig_ready = false;
            show_text = true;
            bar_text = 'Turn In Bucket';
            
            -- Clear sound flag when in turn-in mode (don't play dig ready sound)
            hxiclam.play_tone = false;
            
            -- Mark dig ready sound as played so it doesn't play when transitioning back
            hxiclam.dig_ready_sound_played = true;
            
            -- Play turnin sound only once when bucket first becomes nearly full
            if (not hxiclam.turnin_sound_played) then
                hxiclam.play_turnin_tone = true;
                hxiclam.turnin_sound_played = true;
            end
            
            -- Rainbow color cycle using time-based hue rotation
            local time = ashita.time.clock()['ms'] / 500.0; -- Speed of color change
            local hue = (time % 6.0); -- 6 color segments in rainbow
            
            if (hue < 1.0) then
                bar_color = {1.0, hue, 0.0, 1.0}; -- Red to Yellow
            elseif (hue < 2.0) then
                bar_color = {2.0 - hue, 1.0, 0.0, 1.0}; -- Yellow to Green
            elseif (hue < 3.0) then
                bar_color = {0.0, 1.0, hue - 2.0, 1.0}; -- Green to Cyan
            elseif (hue < 4.0) then
                bar_color = {0.0, 4.0 - hue, 1.0, 1.0}; -- Cyan to Blue
            elseif (hue < 5.0) then
                bar_color = {hue - 4.0, 0.0, 1.0, 1.0}; -- Blue to Magenta
            else
                bar_color = {1.0, 0.0, 6.0 - hue, 1.0}; -- Magenta to Red
            end
                else
            -- Normal dig timer logic
            local current_time = ashita.time.clock()['ms'];
            local time_since_dig = (current_time - hxiclam.settings.last_dig) / 1000.0; -- convert to seconds
            dig_progress = math.min(time_since_dig / 10.0, 1.0); -- clamp to 1.0 max
            dig_ready = dig_progress >= 1.0;
            show_text = dig_ready;
            bar_text = 'Dig Ready';
            
            -- Reset turnin sound flag when bucket is no longer nearly full
            hxiclam.turnin_sound_played = false;
            
            -- Only reset dig ready sound flag if the timer is not ready yet
            if (not dig_ready) then
                hxiclam.dig_ready_sound_played = false;
            end
            
            if (dig_ready) then
                bar_color = {0.0, 0.7, 0.0, 1.0}; -- darker green for better text visibility
                -- Only play dig ready sound once when it becomes ready
                if (not hxiclam.dig_ready_sound_played) then
                    hxiclam.play_tone = true;
                    hxiclam.dig_ready_sound_played = true;
                end
            else
                bar_color = {1.0, 0.6, 0.0, 1.0}; -- orange
            end
        end

        -- Set progress bar color
        imgui.PushStyleColor(ImGuiCol_PlotHistogram, bar_color);
        
        -- Calculate scaled progress bar height based on weight font scale
        local base_bar_height = 20;
        local scaled_bar_height = base_bar_height * hxiclam.settings.bucket_weight_font_scale[1];
        
        -- Draw progress bar
        imgui.ProgressBar(dig_progress, {-1, scaled_bar_height}, '');
        
        -- Draw text overlay with better visibility
        if (show_text) then
            -- Set font scale back to weight font scale for text calculations
            imgui.SetWindowFontScale(hxiclam.settings.bucket_weight_font_scale[1]);
            
            local bar_pos_x, bar_pos_y = imgui.GetItemRectMin();
            local bar_size_x, bar_size_y = imgui.GetItemRectSize();
            local text_size_x, text_size_y = imgui.CalcTextSize(bar_text);
            local text_x = bar_pos_x + (bar_size_x - text_size_x) * 0.5; -- center horizontally
            local text_y = bar_pos_y + (bar_size_y - text_size_y) * 0.5; -- center vertically
            
            -- Draw text with dark outline for better visibility
            local draw_list = imgui.GetWindowDrawList();
            draw_list:AddText({text_x + 1, text_y + 1}, 0xFF000000, bar_text); -- black outline
            draw_list:AddText({text_x, text_y}, 0xFFFFFFFF, bar_text); -- white text
            
            -- Reset to general font scale after drawing
            imgui.SetWindowFontScale(hxiclam.settings.font_scale[1]);
        end
        
        imgui.PopStyleColor();
        
        -- Play any pending sounds
        play_sound();

        local bucket_contents = '';
        for k, v in pairs(hxiclam.settings.bucket) do
            local itemTotal = 0;
            if (hxiclam.pricing[k] ~= nil) then
                itemTotal = v * hxiclam.pricing[k];
            end
            
            local display_name = clean_item_name(k);

            if (bucket_contents == '') then
                bucket_contents = display_name .. ': ' .. 'x' .. format_int(v) .. ' (' ..
                                      format_int(itemTotal) .. 'g)';
            else
                bucket_contents = bucket_contents .. '\n' .. display_name .. ': ' .. 'x' ..
                                      format_int(v) .. ' (' ..
                                      format_int(itemTotal) .. 'g)';
            end
        end

        if (bucket_contents ~= '') then
            imgui.Separator();
            imgui.Text(bucket_contents);
        end

        if (hxiclam.settings.session_view > 0) then
            imgui.Separator();
            imgui.Separator();
            imgui.SetWindowFontScale(hxiclam.settings.font_scale[1] + 0.1);
            imgui.Text('Session Stats:');
            imgui.SetWindowFontScale(hxiclam.settings.font_scale[1]);
            imgui.Text('Buckets Cost: ' ..
                           format_int(hxiclam.settings.bucket_count *
                                          hxiclam.settings.clamming.bucket_cost[1]));
            imgui.Text('Items Dug: ' .. tostring(hxiclam.settings.item_count));
            if (hxiclam.settings.moon_display[1]) then
                imgui.Text('Moon: ' .. moon_phase .. ' (' ..
                               tostring(moon_percent) .. '%%)');
            end
            imgui.Separator();

            for k, v in pairs(hxiclam.settings.rewards) do
                local itemTotal = 0;
                if (hxiclam.pricing[k] ~= nil) then
                    total_worth = total_worth + hxiclam.pricing[k] * v;
                    itemTotal = v * hxiclam.pricing[k];
                end

                if (hxiclam.settings.session_view > 1) then
                    local display_name = clean_item_name(k);
                    imgui.Text(display_name .. ': ' .. 'x' .. format_int(v) .. ' (' ..
                                   format_int(itemTotal) .. 'g)');
                end
            end
            if (hxiclam.settings.session_view > 1) then
                imgui.Separator();
            end

            -- Calculate profit for gil per hour (always subtract bucket costs)
            local total_profit = total_worth - (hxiclam.settings.bucket_count * hxiclam.settings.clamming.bucket_cost[1]);
            
            -- only update gil_per_hour every 3 seconds (always based on profit)
            if ((ashita.time.clock()['s'] % 3) == 0) then
                hxiclam.gil_per_hour = math.floor((total_profit / elapsed_time) * 3600);
            end
            
            if (hxiclam.settings.clamming.bucket_subtract[1]) then
                imgui.Text('Total Profit: ' .. format_int(total_profit) .. 'g' ..
                               ' (' .. format_int(hxiclam.gil_per_hour) ..
                               ' gph)');
            else
                imgui.Text('Total Revenue: ' .. format_int(total_worth) .. 'g' .. ' (' ..
                        format_int(hxiclam.gil_per_hour) .. ' gph)');
            end
        end
    end
    imgui.End();
    
    -- Restore original styling
    imgui.PopStyleVar(2); -- Pop both WindowRounding and ChildRounding

end);

--[[
* event: key
* desc : Event called when the addon is processing keyboard input. (WNDPROC)
--]]
ashita.events.register('key', 'key_callback', function(e)
    -- Key: VK_SHIFT
    if (e.wparam == 0x10) then
        hxiclam.move.shift_down = not (bit.band(e.lparam,
                                                bit.lshift(0x8000, 0x10)) ==
                                      bit.lshift(0x8000, 0x10));
        return;
    end
end);

--[[
* event: mouse
* desc : Event called when the addon is processing mouse input. (WNDPROC)
--]]
ashita.events.register('mouse', 'mouse_cb', function(e)
    -- Tests if the given coords are within the equipmon area.
    local function hit_test(x, y)
        local e_x = hxiclam.settings.x[1];
        local e_y = hxiclam.settings.y[1];
        local e_w = ((32 * hxiclam.settings.scale[1]) * 4) +
                        hxiclam.settings.padding[1] * 3;
        local e_h = ((32 * hxiclam.settings.scale[1]) * 4) +
                        hxiclam.settings.padding[1] * 3;

        return ((e_x <= x) and (e_x + e_w) >= x) and
                   ((e_y <= y) and (e_y + e_h) >= y);
    end

    -- Returns if the equipmon object is being dragged.
    local function is_dragging() return hxiclam.move.dragging; end

    -- Handle the various mouse messages..
    switch(e.message, {
        -- Event: Mouse Move
        [512] = (function()
            hxiclam.settings.x[1] = e.x - hxiclam.move.drag_x;
            hxiclam.settings.y[1] = e.y - hxiclam.move.drag_y;

            e.blocked = true;
        end):cond(is_dragging),

        -- Event: Mouse Left Button Down
        [513] = (function()
            if (hxiclam.move.shift_down) then
                hxiclam.move.dragging = true;
                hxiclam.move.drag_x = e.x - hxiclam.settings.x[1];
                hxiclam.move.drag_y = e.y - hxiclam.settings.y[1];

                e.blocked = true;
            end
        end):cond(hit_test:bindn(e.x, e.y)),

        -- Event: Mouse Left Button Up
        [514] = (function()
            if (hxiclam.move.dragging) then
                hxiclam.move.dragging = false;

                e.blocked = true;
            end
        end):cond(is_dragging),

        -- Event: Mouse Wheel Scroll
        [522] = (function()
            if (e.delta < 0) then
                hxiclam.settings.opacity[1] =
                    hxiclam.settings.opacity[1] - 0.125;
            else
                hxiclam.settings.opacity[1] =
                    hxiclam.settings.opacity[1] + 0.125;
            end
            hxiclam.settings.opacity[1] =
                hxiclam.settings.opacity[1]:clamp(0.125, 1);

            e.blocked = true;
        end):cond(hit_test:bindn(e.x, e.y))
    });
end);
