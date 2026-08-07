-- Generate subtitles for the playing file by running whisper.cpp locally.
-- Nothing is uploaded anywhere; the audio never leaves the machine.
--
-- Needs a whisper.cpp CLI binary and a ggml model, configured through
-- script-opts/transcribe.conf. See DOCS/man/transcribe.rst.

local msg = require 'mp.msg'
local options = require 'mp.options'
local utils = require 'mp.utils'

local o = {
    -- whisper.cpp CLI binary. A bare name is looked up in PATH.
    whisper_path = "whisper-cli",
    -- ggml model file. Transcription refuses to run while this is unset.
    model = "",
    -- Language code to transcribe as, or "auto" to detect it.
    language = "auto",
    -- Threads whisper may use. 0 lets whisper decide.
    threads = 0,
    -- mpv binary, used to decode formats whisper cannot read by itself.
    mpv_path = "mpv",
    -- Write the result next to the media file as "<name>.whisper.srt" and
    -- reuse it later, instead of keeping it in a temporary directory.
    save_next_to_file = false,
    -- Start transcribing on its own whenever a file has no subtitles at all.
    autostart = false,
}

options.read_options(o)

-- whisper.cpp decodes these by itself, so they can be passed straight in.
-- Everything else is converted to wav first.
local direct_formats = {flac = true, mp3 = true, wav = true}

local job = nil
local temp_wav = nil

local function tempdir()
    return os.getenv("TMPDIR") or os.getenv("TEMP") or os.getenv("TMP") or "/tmp"
end

local function finish(text, level)
    job = nil
    if temp_wav then
        os.remove(temp_wav)
        temp_wav = nil
    end
    if text then
        mp.osd_message(text, 4)
        msg[level or "info"](text)
    end
end

-- Runs args in the background and calls done(ok, res). playback_only is off so
-- that seeking or pausing does not kill a transcription that is under way.
local function run(args, done)
    msg.debug("running: " .. utils.to_string(args))
    job = mp.command_native_async({
        name = "subprocess",
        args = args,
        capture_stdout = true,
        capture_stderr = true,
        playback_only = false,
    }, function (success, res, err)
        if not success or not res then
            msg.error(err or "subprocess failed to start")
            finish("Transcription failed, see the log", "error")
            return
        end
        if res.killed_by_us then
            finish()
            return
        end
        if res.stderr and res.stderr ~= "" then
            msg.debug(res.stderr)
        end
        done(res.status == 0, res)
    end)
end

local function load_subtitle(srt)
    if not utils.file_info(srt) then
        finish("Transcription produced no subtitles", "error")
        return
    end
    if o.language == "auto" or o.language == "" then
        mp.commandv("sub-add", srt, "select", "Transcript")
    else
        mp.commandv("sub-add", srt, "select", "Transcript", o.language)
    end
    finish("Transcript loaded")
end

local function run_whisper(input, prefix)
    local args = {o.whisper_path, "-m", o.model, "-osrt", "-of", prefix, "-np"}
    if o.language ~= "" then
        args[#args + 1] = "-l"
        args[#args + 1] = o.language
    end
    if o.threads > 0 then
        args[#args + 1] = "-t"
        args[#args + 1] = tostring(o.threads)
    end
    args[#args + 1] = input

    mp.osd_message("Transcribing, this can take a while...", 30)
    run(args, function (ok, res)
        if not ok then
            msg.error(res.stderr ~= "" and res.stderr or "whisper exited with "
                      .. tostring(res.status))
            finish("Transcription failed, see the log", "error")
            return
        end
        load_subtitle(prefix .. ".srt")
    end)
end

local function extract_audio(path, prefix, done)
    temp_wav = prefix .. ".wav"
    mp.osd_message("Extracting audio...", 30)
    run({o.mpv_path, path, "--no-config", "--no-terminal", "--vid=no", "--sid=no",
         "--audio-channels=mono", "--audio-samplerate=16000",
         "--of=wav", "--oac=pcm_s16le", "--o=" .. temp_wav}, function (ok, res)
        if not ok then
            msg.error(res.stderr ~= "" and res.stderr or "mpv exited with "
                      .. tostring(res.status))
            finish("Could not extract audio, check mpv_path", "error")
            return
        end
        done(temp_wav)
    end)
end

local function transcribe()
    if job then
        mp.osd_message("Already transcribing")
        return
    end
    if o.model == "" then
        finish("transcribe: no model configured, see transcribe.conf", "error")
        return
    end

    local path = mp.get_property("path")
    if not path then
        return
    end
    local is_url = mp.get_property_native("demuxer-via-network", false)

    local prefix
    if o.save_next_to_file and not is_url then
        prefix = path:gsub("%.[^.\\/]*$", "") .. ".whisper"
    else
        local name = (mp.get_property("filename/no-ext") or "audio")
                     :gsub("[^%w%-_.]", "_")
        prefix = utils.join_path(tempdir(), "mpv-transcribe-" .. name)
    end

    -- A previous run of the same file can just be loaded again.
    if utils.file_info(prefix .. ".srt") then
        load_subtitle(prefix .. ".srt")
        return
    end

    local ext = path:lower():match("%.([%w]+)$")
    if not is_url and ext and direct_formats[ext] then
        run_whisper(path, prefix)
    else
        extract_audio(path, prefix, function (wav)
            run_whisper(wav, prefix)
        end)
    end
end

local function cancel()
    if not job then
        return
    end
    mp.abort_async_command(job)
    finish("Transcription cancelled")
end

mp.add_key_binding(nil, "transcribe", transcribe)
mp.add_key_binding(nil, "cancel", cancel)

mp.register_event("end-file", function ()
    -- Do not leave a stray whisper process behind when playback moves on.
    if job then
        mp.abort_async_command(job)
        finish()
    end
end)

mp.register_event("file-loaded", function ()
    if not o.autostart or o.model == "" then
        return
    end
    for _, track in ipairs(mp.get_property_native("track-list", {})) do
        if track.type == "sub" then
            return
        end
    end
    transcribe()
end)
