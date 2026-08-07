-- Generate subtitles for the playing file by running whisper.cpp locally.
-- Nothing is uploaded anywhere; the audio never leaves the machine.
--
-- The whisper.cpp binary and the ggml model are not shipped with mpv. When
-- subtitle generation is enabled and either is missing, the script offers to
-- download them into the mpv config directory.
--
-- See DOCS/man/transcribe.rst.

local msg = require 'mp.msg'
local options = require 'mp.options'
local utils = require 'mp.utils'

local o = {
    -- Generate subtitles automatically for files that have none.
    enabled = false,
    -- Language to transcribe as, or "auto" to detect it.
    language = "de",
    -- ggml model to use, without the "ggml-" prefix and ".bin" suffix.
    model = "base",
    -- Directory holding whisper-cli and the models. Empty means "~~/whisper".
    whisper_dir = "",
    -- whisper.cpp binary. Empty means whisper_dir/whisper-cli.
    whisper_path = "",
    -- Threads whisper may use. 0 lets whisper decide.
    threads = 0,
    -- mpv binary, used to decode formats whisper cannot read by itself.
    mpv_path = "mpv",
    -- Transcribe in chunks so subtitles appear while the file plays, instead
    -- of waiting for the whole file to be transcribed first.
    live = false,
    -- Length of a chunk in live mode, in seconds.
    chunk_seconds = 30,
    -- Write the subtitles here instead of next to the media file.
    output_dir = "",
}

-- Defined further down, but callbacks created before then have to see the
-- same locals, so the names are declared up here.
local update_menu
local transcribe

options.read_options(o, nil, function ()
    -- The menu shows the current settings, so it has to follow changes made
    -- through --script-opts at runtime.
    update_menu()
end)

local WHISPER_VERSION = "v1.9.2"
local WHISPER_URL = "https://github.com/ggml-org/whisper.cpp/releases/download/"
                    .. WHISPER_VERSION .. "/whisper-bin-x64.zip"
local MODEL_URL = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/"

-- Offered in the context menu. whisper itself accepts many more codes.
local LANGUAGES = {
    {code = "auto", name = "Detect automatically"},
    {code = "de", name = "German"},
    {code = "en", name = "English"},
    {code = "fr", name = "French"},
    {code = "it", name = "Italian"},
    {code = "es", name = "Spanish"},
    {code = "nl", name = "Dutch"},
    {code = "pl", name = "Polish"},
    {code = "tr", name = "Turkish"},
    {code = "ru", name = "Russian"},
    {code = "fa", name = "Persian"},
    {code = "ar", name = "Arabic"},
}

-- whisper.cpp decodes these by itself, anything else is converted first.
local DIRECT_FORMATS = {flac = true, mp3 = true, wav = true}

local MENU_TITLE = "Subtitle generation"

local script_name = mp.get_script_name()
local windows = mp.get_property("platform") == "windows"

local job = nil          -- handle of the running subprocess
local temp_files = {}    -- files to delete once the run is over
local live = nil         -- state of a chunked run
local asked_to_download = false

--- paths -------------------------------------------------------------------

local function config_path(rel)
    return mp.command_native({"expand-path", "~~/" .. rel})
end

local function exists(path)
    return path ~= nil and utils.file_info(path) ~= nil
end

local function whisper_dir()
    return o.whisper_dir ~= "" and o.whisper_dir or config_path("whisper")
end

local function whisper_bin()
    if o.whisper_path ~= "" then
        return o.whisper_path
    end
    return utils.join_path(whisper_dir(), windows and "whisper-cli.exe"
                                                   or "whisper-cli")
end

local function model_file()
    return utils.join_path(whisper_dir(), "ggml-" .. o.model .. ".bin")
end

local function mkdir(path)
    if exists(path) then
        return true
    end
    local args = windows and {"cmd", "/c", "md", (path:gsub("/", "\\"))}
                          or {"mkdir", "-p", path}
    local res = mp.command_native({name = "subprocess", args = args,
                                   playback_only = false, capture_stdout = true,
                                   capture_stderr = true})
    return res ~= nil and res.status == 0
end

--- settings ----------------------------------------------------------------

-- Settings changed through the menu have to survive a restart, so they are
-- written back to the same config file options.read_options() reads.
local function save_options()
    local dir = config_path("script-opts")
    if not mkdir(dir) then
        msg.warn("could not create " .. dir .. ", settings are not persistent")
        return
    end
    local path = utils.join_path(dir, "transcribe.conf")
    local file, err = io.open(path, "w")
    if not file then
        msg.warn("could not write " .. path .. ": " .. tostring(err))
        return
    end
    file:write("# Written by mpv's transcribe script.\n")
    for _, key in ipairs({"enabled", "language", "model", "live",
                          "chunk_seconds", "threads", "whisper_dir",
                          "whisper_path", "mpv_path", "output_dir"}) do
        local value = o[key]
        if type(value) == "boolean" then
            value = value and "yes" or "no"
        end
        file:write(key .. "=" .. tostring(value) .. "\n")
    end
    file:close()
    msg.verbose("saved settings to " .. path)
end

--- subprocess handling -----------------------------------------------------

local function cleanup()
    job = nil
    live = nil
    for _, path in ipairs(temp_files) do
        os.remove(path)
    end
    temp_files = {}
end

local function finish(text, level)
    cleanup()
    if text then
        mp.osd_message(text, 4)
        msg[level or "info"](text)
    end
end

-- Runs args in the background and calls done(ok, res). playback_only is off so
-- that seeking or pausing does not kill a run that is under way.
local function run(args, done)
    msg.debug("running: " .. utils.to_string(args))
    job = mp.command_native_async({
        name = "subprocess",
        args = args,
        capture_stdout = true,
        capture_stderr = true,
        playback_only = false,
    }, function (success, res, err)
        job = nil
        if not success or not res then
            msg.error(err or "subprocess failed to start")
            finish("Subtitle generation failed, see the log", "error")
            return
        end
        if res.killed_by_us then
            cleanup()
            return
        end
        if res.stderr and res.stderr ~= "" then
            msg.debug(res.stderr)
        end
        done(res.status == 0, res)
    end)
end

local function fail(what, res)
    local detail = res and res.stderr ~= "" and res.stderr
                   or ("exit status " .. tostring(res and res.status))
    msg.error(what .. ": " .. detail)
    finish(what .. ", see the log", "error")
end

--- dependencies ------------------------------------------------------------

local function deps_missing()
    local missing = {}
    if not exists(whisper_bin()) then
        missing[#missing + 1] = "speech recognition program"
    end
    if not exists(model_file()) then
        missing[#missing + 1] = "language model"
    end
    return missing
end

-- The archive layout differs between whisper.cpp releases, so rather than
-- assuming one, look for the binary wherever it ended up.
local function find_binary(dir, depth)
    local name = windows and "whisper-cli.exe" or "whisper-cli"
    local files = utils.readdir(dir, "files") or {}
    for _, file in ipairs(files) do
        if file == name then
            return utils.join_path(dir, file)
        end
    end
    if depth <= 0 then
        return nil
    end
    for _, sub in ipairs(utils.readdir(dir, "dirs") or {}) do
        local found = find_binary(utils.join_path(dir, sub), depth - 1)
        if found then
            return found
        end
    end
    return nil
end

local function download_model(done)
    if exists(model_file()) then
        done()
        return
    end
    local url = MODEL_URL .. "ggml-" .. o.model .. ".bin"
    mp.osd_message("Downloading the " .. o.model .. " language model...", 60)
    run({"curl", "-L", "--fail", "-o", model_file(), url}, function (ok, res)
        if not ok then
            os.remove(model_file())
            fail("Could not download the language model", res)
            return
        end
        done()
    end)
end

local function download_whisper(done)
    if exists(whisper_bin()) then
        done()
        return
    end
    if not windows then
        finish("Install whisper.cpp and set whisper_path in transcribe.conf",
               "error")
        return
    end
    local zip = utils.join_path(whisper_dir(), "whisper.zip")
    mp.osd_message("Downloading the speech recognition program...", 60)
    run({"curl", "-L", "--fail", "-o", zip, WHISPER_URL}, function (ok, res)
        if not ok then
            os.remove(zip)
            fail("Could not download whisper.cpp", res)
            return
        end
        -- tar handles zip files on Windows 10 and later.
        run({"tar", "-xf", zip, "-C", whisper_dir()}, function (ok2, res2)
            os.remove(zip)
            if not ok2 then
                fail("Could not unpack whisper.cpp", res2)
                return
            end
            local found = find_binary(whisper_dir(), 3)
            if not found then
                finish("whisper-cli was not found in the archive", "error")
                return
            end
            if found ~= whisper_bin() then
                o.whisper_path = found
                save_options()
            end
            done()
        end)
    end)
end

local function install_dependencies(done)
    if not mkdir(whisper_dir()) then
        finish("Could not create " .. whisper_dir(), "error")
        return
    end
    download_whisper(function ()
        download_model(function ()
            mp.osd_message("Subtitle generation is ready")
            if done then
                done()
            end
        end)
    end)
end

-- Offers the download once, and remembers the answer for the session.
local function prompt_for_dependencies()
    local missing = deps_missing()
    if #missing == 0 or asked_to_download or job then
        return #missing == 0
    end
    asked_to_download = true
    mp.osd_message("Subtitle generation needs the " ..
                   table.concat(missing, " and the ") ..
                   " (about 200 MB).\nPress y to download, n to skip.", 15)
    mp.add_forced_key_binding("y", "transcribe-download-yes", function ()
        mp.remove_key_binding("transcribe-download-yes")
        mp.remove_key_binding("transcribe-download-no")
        -- Carry on with what the user asked for in the first place.
        install_dependencies(transcribe)
    end)
    mp.add_forced_key_binding("n", "transcribe-download-no", function ()
        mp.remove_key_binding("transcribe-download-yes")
        mp.remove_key_binding("transcribe-download-no")
        mp.osd_message("Skipped. Use the context menu to download later.")
    end)
    return false
end

--- srt handling ------------------------------------------------------------

local function ts_to_ms(text)
    local h, m, s, ms = text:match("(%d+):(%d+):(%d+),(%d+)")
    if not h then
        return nil
    end
    return ((tonumber(h) * 60 + tonumber(m)) * 60 + tonumber(s)) * 1000
           + tonumber(ms)
end

local function ms_to_ts(total)
    local ms = total % 1000
    local s = math.floor(total / 1000) % 60
    local m = math.floor(total / 60000) % 60
    local h = math.floor(total / 3600000)
    return string.format("%02d:%02d:%02d,%03d", h, m, s, ms)
end

-- Chunks are transcribed as standalone files, so their timestamps start at
-- zero and have to be moved to where the chunk actually sits.
local function shift_srt(text, offset_ms, first_index)
    local out = {}
    local index = first_index
    for block in (text .. "\n\n"):gmatch("(.-)\n\n") do
        local from, to, body =
            block:match("^%s*%d+%s*\n%s*([%d:,]+)%s*%-%->%s*([%d:,]+)%s*\n(.*)$")
        local from_ms = from and ts_to_ms(from)
        local to_ms = to and ts_to_ms(to)
        if from_ms and to_ms and body:match("%S") then
            out[#out + 1] = string.format("%d\n%s --> %s\n%s\n", index,
                                          ms_to_ts(from_ms + offset_ms),
                                          ms_to_ts(to_ms + offset_ms), body)
            index = index + 1
        end
    end
    return table.concat(out, "\n"), index
end

local function read_file(path)
    local file = io.open(path, "r")
    if not file then
        return nil
    end
    local text = file:read("*a")
    file:close()
    return text
end

local function append_file(path, text)
    local file = io.open(path, "a")
    if not file then
        msg.error("could not write " .. path)
        return false
    end
    file:write(text)
    file:close()
    return true
end

--- transcription -----------------------------------------------------------

local function subtitle_path()
    local path = mp.get_property("path")
    if not path or mp.get_property_native("demuxer-via-network", false) then
        return nil
    end
    local dir, name = utils.split_path(path)
    name = name:gsub("%.[^.]*$", "")
    return utils.join_path(o.output_dir ~= "" and o.output_dir or dir,
                           name .. ".srt")
end

local function whisper_args(input, prefix)
    local args = {whisper_bin(), "-m", model_file(), "-osrt", "-of", prefix,
                  "-np"}
    if o.language ~= "" then
        args[#args + 1] = "-l"
        args[#args + 1] = o.language
    end
    if o.threads > 0 then
        args[#args + 1] = "-t"
        args[#args + 1] = tostring(o.threads)
    end
    args[#args + 1] = input
    return args
end

local function extract_args(path, wav, start, length)
    local args = {o.mpv_path, path, "--no-config", "--no-terminal", "--vid=no",
                  "--sid=no", "--audio-channels=mono",
                  "--audio-samplerate=16000", "--of=wav", "--oac=pcm_s16le",
                  "--o=" .. wav}
    if start then
        args[#args + 1] = "--start=" .. tostring(start)
        args[#args + 1] = "--length=" .. tostring(length)
    end
    return args
end

local function show_subtitles(srt, reload)
    if reload and live and live.loaded then
        mp.commandv("sub-reload")
        return
    end
    if o.language == "auto" or o.language == "" then
        mp.commandv("sub-add", srt, "select", "Transcript")
    else
        mp.commandv("sub-add", srt, "select", "Transcript", o.language)
    end
    if live then
        live.loaded = true
    end
end

-- Whole-file mode: one pass over the file, subtitles appear when it is done.
local function transcribe_whole(path, srt)
    local prefix = srt:gsub("%.srt$", "")
    local function whisper(input)
        mp.osd_message("Generating subtitles, this can take a while...", 30)
        run(whisper_args(input, prefix), function (ok, res)
            if not ok then
                fail("Subtitle generation failed", res)
                return
            end
            if not exists(srt) then
                finish("Subtitle generation produced nothing", "error")
                return
            end
            show_subtitles(srt, false)
            finish("Subtitles ready")
        end)
    end

    local ext = path:lower():match("%.([%w]+)$")
    if ext and DIRECT_FORMATS[ext] then
        whisper(path)
    else
        local wav = prefix .. ".transcribe.wav"
        temp_files[#temp_files + 1] = wav
        mp.osd_message("Extracting audio...", 30)
        run(extract_args(path, wav), function (ok, res)
            if not ok then
                fail("Could not extract audio, check mpv_path", res)
                return
            end
            whisper(wav)
        end)
    end
end

-- Live mode: transcribe one chunk at a time and grow the subtitle file as we
-- go, so subtitles show up while the file is still playing.
local function transcribe_next_chunk()
    if not live then
        return
    end
    local start = live.chunk * o.chunk_seconds
    if start >= live.duration then
        show_subtitles(live.srt, true)
        finish("Subtitles complete")
        return
    end

    local wav = live.prefix .. ".transcribe.wav"
    local chunk_srt = live.prefix .. ".transcribe.srt"
    temp_files = {wav, chunk_srt}

    run(extract_args(live.path, wav, start, o.chunk_seconds), function (ok, res)
        if not ok then
            fail("Could not extract audio, check mpv_path", res)
            return
        end
        run(whisper_args(wav, live.prefix .. ".transcribe"), function (ok2, res2)
            if not ok2 then
                fail("Subtitle generation failed", res2)
                return
            end
            local text = read_file(chunk_srt)
            os.remove(wav)
            os.remove(chunk_srt)
            if text then
                local shifted, next_index =
                    shift_srt(text, start * 1000, live.index)
                if shifted ~= "" and append_file(live.srt, shifted) then
                    live.index = next_index
                    show_subtitles(live.srt, true)
                end
            end
            live.chunk = live.chunk + 1
            transcribe_next_chunk()
        end)
    end)
end

local function transcribe_live(path, srt)
    local duration = mp.get_property_number("duration")
    if not duration then
        msg.warn("unknown duration, falling back to whole-file mode")
        transcribe_whole(path, srt)
        return
    end
    -- Start from an empty file so a previous partial run cannot leak in.
    local file = io.open(srt, "w")
    if not file then
        finish("Could not write " .. srt, "error")
        return
    end
    file:close()

    live = {
        path = path,
        srt = srt,
        prefix = srt:gsub("%.srt$", ""),
        duration = duration,
        chunk = 0,
        index = 1,
        loaded = false,
    }
    mp.osd_message("Generating subtitles while playing...", 5)
    transcribe_next_chunk()
end

function transcribe()
    if job or live then
        mp.osd_message("Subtitle generation is already running")
        return
    end
    local path = mp.get_property("path")
    if not path then
        return
    end
    local srt = subtitle_path()
    if not srt then
        mp.osd_message("Can only generate subtitles for local files")
        return
    end
    if exists(srt) then
        show_subtitles(srt, false)
        mp.osd_message("Loaded the existing subtitles")
        return
    end
    if not prompt_for_dependencies() then
        return
    end
    if o.live then
        transcribe_live(path, srt)
    else
        transcribe_whole(path, srt)
    end
end

local function cancel()
    if not job and not live then
        return
    end
    local handle = job
    live = nil
    if handle then
        mp.abort_async_command(handle)
    end
    finish("Subtitle generation cancelled")
end

--- menu --------------------------------------------------------------------

local function menu_command(rest)
    return "script-message-to " .. script_name .. " " .. rest
end

-- Returns nil rather than an empty table for the unset case: an empty Lua
-- table is ambiguous between an array and a map, and menu-data wants an array.
local function checked(condition)
    return condition and {"checked"} or nil
end

function update_menu()
    local running = job ~= nil or live ~= nil
    local menu = mp.get_property_native("menu-data", {})
    for i = #menu, 1, -1 do
        if menu[i].title == MENU_TITLE then
            table.remove(menu, i)
        end
    end

    local langs = {}
    for _, lang in ipairs(LANGUAGES) do
        langs[#langs + 1] = {
            title = lang.name,
            cmd = menu_command("set-language " .. lang.code),
            state = checked(o.language == lang.code),
        }
    end

    local items = {
        {title = "Generate subtitles automatically",
         cmd = menu_command("toggle"), state = checked(o.enabled)},
        {title = "Show subtitles while transcribing",
         cmd = menu_command("toggle-live"), state = checked(o.live)},
        {type = "separator"},
        {type = "submenu", title = "Language", submenu = langs},
        {type = "separator"},
        {title = "Generate for this file now", cmd = menu_command("start"),
         state = running and {"disabled"} or nil},
        {title = "Cancel", cmd = menu_command("cancel"),
         state = not running and {"disabled"} or nil},
    }
    if #deps_missing() > 0 then
        items[#items + 1] = {type = "separator"}
        items[#items + 1] = {title = "Download speech recognition files",
                             cmd = menu_command("install")}
    end

    menu[#menu + 1] = {type = "submenu", title = MENU_TITLE, submenu = items}
    mp.set_property_native("menu-data", menu)
end

--- bindings and events -----------------------------------------------------

local function toggle()
    o.enabled = not o.enabled
    save_options()
    update_menu()
    mp.osd_message("Subtitle generation " .. (o.enabled and "on" or "off"))
    if o.enabled then
        prompt_for_dependencies()
    end
end

mp.add_key_binding(nil, "transcribe", transcribe)
mp.add_key_binding(nil, "cancel", cancel)
mp.add_key_binding(nil, "toggle", toggle)

mp.register_script_message("toggle", toggle)
mp.register_script_message("toggle-live", function ()
    o.live = not o.live
    save_options()
    update_menu()
end)
mp.register_script_message("set-language", function (code)
    o.language = code
    save_options()
    update_menu()
end)
mp.register_script_message("start", transcribe)
mp.register_script_message("cancel", cancel)
mp.register_script_message("install", function ()
    install_dependencies(update_menu)
end)

mp.register_event("end-file", function ()
    if job or live then
        local handle = job
        live = nil
        if handle then
            mp.abort_async_command(handle)
        end
        cleanup()
    end
end)

mp.register_event("file-loaded", function ()
    if not o.enabled or job or live then
        return
    end
    -- Files that already have subtitles are left alone.
    for _, track in ipairs(mp.get_property_native("track-list", {})) do
        if track.type == "sub" then
            return
        end
    end
    transcribe()
end)

update_menu()
