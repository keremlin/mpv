-- A podcast reader: subscribe to RSS feeds, browse their episodes and play
-- them, downloading the audio first if it is not on disk yet.
--
-- Feeds and the episode list are kept in ~~/rss/feeds.json, downloaded media
-- in ~~/rss/media. Nothing but the feed and the enclosure URLs is contacted.
--
-- See DOCS/man/rss.rst.

local msg = require 'mp.msg'
local input = require 'mp.input'
local options = require 'mp.options'
local utils = require 'mp.utils'

local o = {
    -- Refresh every feed when mpv starts.
    enabled = false,
    -- Download episodes before playing them. When off they are streamed.
    download = true,
    -- Where downloaded episodes go. Empty means "~~/rss/media".
    download_dir = "",
    -- Episodes to remember per feed. Older ones are forgotten.
    max_episodes = 200,
    -- Seconds to wait for a feed. Downloads are not limited by this.
    timeout = 30,
    -- HTTP client used for feeds and downloads.
    curl_path = "",
    -- Some podcast hosts refuse requests without a user agent.
    user_agent = "Mozilla/5.0 (compatible; mpv)",
}

-- Defined further down; callbacks made before then have to see the same
-- locals, so the names are declared here.
local update_menu
local browse_feeds
local browse_episodes

options.read_options(o, nil, function ()
    update_menu()
end)

local MENU_TITLE = "RSS"

local script_name = mp.get_script_name()
local windows = mp.get_property("platform") == "windows"

local feeds = {}      -- subscriptions, see load_feeds()
local job = nil       -- handle of the running curl
local busy = nil      -- description of what that curl is doing
local progress = nil  -- timer showing download progress

--- paths -------------------------------------------------------------------

local function config_path(rel)
    return mp.command_native({"expand-path", "~~/" .. rel})
end

local function exists(path)
    return path ~= nil and utils.file_info(path) ~= nil
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

local function rss_dir()
    return config_path("rss")
end

local function media_dir()
    return o.download_dir ~= "" and o.download_dir
                                 or utils.join_path(rss_dir(), "media")
end

local function feeds_file()
    return utils.join_path(rss_dir(), "feeds.json")
end

-- Feeds get a directory of their own, named after the URL so that renaming a
-- podcast does not orphan everything downloaded from it so far.
local function url_key(url)
    local h = 5381
    for i = 1, #url do
        h = (h * 33 + url:byte(i)) % 4294967296
    end
    local host = url:match("^%w+://([^/]+)") or "feed"
    host = host:gsub("^www%.", ""):gsub("[^%w%.%-]", "")
    return host:sub(1, 32) .. "-" .. string.format("%08x", h)
end

local function sanitize(name)
    name = name:gsub('[<>:"/\\|%?%*]', "_"):gsub("%c", "")
    name = name:gsub("^%s+", ""):gsub("[%s%.]+$", "")
    if #name > 80 then
        name = name:sub(1, 80)
    end
    return name ~= "" and name or "episode"
end

--- files -------------------------------------------------------------------

local function read_file(path)
    local file = io.open(path, "rb")
    if not file then
        return nil
    end
    local text = file:read("*a")
    file:close()
    return text
end

local function write_file(path, text)
    local file, err = io.open(path, "wb")
    if not file then
        msg.error("could not write " .. path .. ": " .. tostring(err))
        return false
    end
    file:write(text)
    file:close()
    return true
end

--- settings ----------------------------------------------------------------

-- Settings changed through the menu have to survive a restart, so they are
-- written back to the file options.read_options() reads.
local function save_options()
    local dir = config_path("script-opts")
    if not mkdir(dir) then
        msg.warn("could not create " .. dir .. ", settings are not persistent")
        return
    end
    local lines = {"# Written by mpv's rss script.\n"}
    for _, key in ipairs({"enabled", "download", "download_dir", "max_episodes",
                          "timeout", "curl_path", "user_agent"}) do
        local value = o[key]
        if type(value) == "boolean" then
            value = value and "yes" or "no"
        end
        lines[#lines + 1] = key .. "=" .. tostring(value) .. "\n"
    end
    write_file(utils.join_path(dir, "rss.conf"), table.concat(lines))
end

--- the subscription list ---------------------------------------------------

local function load_feeds()
    local text = read_file(feeds_file())
    if not text then
        return
    end
    local data = utils.parse_json(text)
    if type(data) ~= "table" or type(data.feeds) ~= "table" then
        msg.warn(feeds_file() .. " is not readable, starting with no feeds")
        return
    end
    for _, feed in ipairs(data.feeds) do
        if type(feed) == "table" and type(feed.url) == "string" then
            feed.key = feed.key or url_key(feed.url)
            feed.episodes = type(feed.episodes) == "table" and feed.episodes or {}
            feeds[#feeds + 1] = feed
        end
    end
end

local function save_feeds()
    if not mkdir(rss_dir()) then
        msg.error("could not create " .. rss_dir())
        return
    end
    local text = utils.format_json({feeds = feeds})
    if not text then
        msg.error("could not serialise the feed list")
        return
    end
    -- Write beside the real file and move it into place, so that a crash
    -- halfway through cannot leave a truncated subscription list behind.
    local tmp = feeds_file() .. ".tmp"
    if write_file(tmp, text) then
        os.remove(feeds_file())
        os.rename(tmp, feeds_file())
    end
end

local function find_feed(key)
    for i, feed in ipairs(feeds) do
        if feed.key == key then
            return feed, i
        end
    end
    return nil
end

--- XML ---------------------------------------------------------------------

local ENTITIES = {amp = "&", lt = "<", gt = ">", quot = '"', apos = "'",
                  nbsp = " "}

local function utf8_char(cp)
    local floor = math.floor
    if cp < 0x80 then
        return string.char(cp)
    elseif cp < 0x800 then
        return string.char(0xC0 + floor(cp / 0x40), 0x80 + cp % 0x40)
    elseif cp < 0x10000 then
        return string.char(0xE0 + floor(cp / 0x1000),
                           0x80 + floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
    elseif cp < 0x110000 then
        return string.char(0xF0 + floor(cp / 0x40000),
                           0x80 + floor(cp / 0x1000) % 0x40,
                           0x80 + floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
    end
    return "?"
end

local function unescape(text)
    if not text or not text:find("&", 1, true) then
        return text
    end
    text = text:gsub("&#[xX](%x+);", function (hex)
        return utf8_char(tonumber(hex, 16))
    end)
    text = text:gsub("&#(%d+);", function (dec)
        return utf8_char(tonumber(dec))
    end)
    return (text:gsub("&(%a+);", function (name)
        return ENTITIES[name:lower()] or ("&" .. name .. ";")
    end))
end

-- Iterates over the contents of every <name ...>...</name> in xml. Elements
-- that can contain another element of the same name are not handled, which
-- none of the ones read here can.
local function blocks(xml, name)
    local open, close = "<" .. name, "</" .. name .. ">"
    local pos = 1
    return function ()
        while true do
            local start = xml:find(open, pos, true)
            if not start then
                return nil
            end
            local after = xml:sub(start + #open, start + #open)
            local gt = xml:find(">", start, true)
            -- Guard against <item> also matching <itemStuff>.
            if gt and after:match("^[%s/>]") then
                local stop = xml:find(close, gt, true)
                if not stop then
                    return nil
                end
                pos = stop + #close
                return xml:sub(gt + 1, stop - 1)
            end
            pos = start + #open
        end
    end
end

local function tag_body(xml, name)
    return xml:match("<" .. name .. ">(.-)</" .. name .. ">")
           or xml:match("<" .. name .. "%s[^>]*>(.-)</" .. name .. ">")
end

-- Plain text of an element: CDATA unwrapped, markup dropped, entities decoded.
local function text_of(xml, name)
    local body = tag_body(xml, name)
    if not body then
        return nil
    end
    local cdata = body:match("<!%[CDATA%[(.-)%]%]>")
    if cdata then
        body = cdata
    else
        body = body:gsub("<[^>]*>", "")
    end
    body = unescape(body):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
    return body ~= "" and body or nil
end

local function attr(tag, name)
    local value = tag:match(name .. '%s*=%s*"([^"]*)"')
                  or tag:match(name .. "%s*=%s*'([^']*)'")
    return unescape(value)
end

--- dates -------------------------------------------------------------------

local MONTHS = {jan = 1, feb = 2, mar = 3, apr = 4, may = 5, jun = 6, jul = 7,
                aug = 8, sep = 9, oct = 10, nov = 11, dec = 12}

-- Days between 1970-01-01 and y-m-d, by Howard Hinnant's civil calendar
-- algorithm. os.time() is not used because it interprets its argument in the
-- local time zone, which would make the same feed sort differently elsewhere.
local function days_from_civil(y, m, d)
    y = m <= 2 and y - 1 or y
    local era = math.floor(y / 400)
    local yoe = y - era * 400
    local doy = math.floor((153 * (m + (m > 2 and -3 or 9)) + 2) / 5) + d - 1
    local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
    return era * 146097 + doe - 719468
end

-- Understands RFC 822 (RSS) and ISO 8601 (Atom). Returns seconds since the
-- epoch and a plain date for display, or nil if the format is unknown.
local function parse_date(text)
    if not text then
        return nil
    end
    local zone
    local d, mon, y, h, mi, s =
        text:match("(%d%d?)%s+(%a+)%s+(%d%d%d%d)%s+(%d%d):(%d%d):?(%d?%d?)")
    local month = mon and MONTHS[mon:sub(1, 3):lower()]
    if month then
        zone = text:match("([%+%-]%d%d:?%d%d)%s*$")
    else
        y, month, d, h, mi, s =
            text:match("(%d%d%d%d)%-(%d%d)%-(%d%d)[T ](%d%d):(%d%d):?(%d?%d?)")
        if not y then
            return nil
        end
        zone = text:match("([%+%-]%d%d:?%d%d)%s*$")
    end

    y, month, d = tonumber(y), tonumber(month), tonumber(d)
    if not y or not month or not d or month < 1 or month > 12 then
        return nil
    end
    local epoch = days_from_civil(y, month, d) * 86400 + tonumber(h) * 3600
                  + tonumber(mi) * 60 + (tonumber(s) or 0)
    local sign, zh, zm = (zone or ""):match("([%+%-])(%d%d):?(%d%d)")
    if sign then
        local offset = tonumber(zh) * 3600 + tonumber(zm) * 60
        epoch = epoch + (sign == "-" and offset or -offset)
    end
    return epoch, string.format("%04d-%02d-%02d", y, month, d)
end

--- feed parsing ------------------------------------------------------------

local MIME_EXT = {
    ["audio/mpeg"] = "mp3", ["audio/mp3"] = "mp3", ["audio/aac"] = "aac",
    ["audio/mp4"] = "m4a", ["audio/x-m4a"] = "m4a", ["audio/ogg"] = "ogg",
    ["audio/opus"] = "opus", ["audio/flac"] = "flac", ["audio/x-flac"] = "flac",
    ["audio/wav"] = "wav", ["audio/x-wav"] = "wav",
    ["video/mp4"] = "mp4", ["video/x-m4v"] = "m4v",
    ["video/quicktime"] = "mov", ["video/webm"] = "webm",
}

local function media_extension(url, mime)
    local ext = url:gsub("[?#].*$", ""):match("%.(%a%w?%w?%w?)$")
    if ext then
        return ext:lower()
    end
    return mime and MIME_EXT[mime:lower():gsub("%s*;.*$", "")] or "mp3"
end

-- Podcasts use <enclosure>; Atom and Media RSS feeds are also seen in the wild.
local function find_media(item)
    for tag in item:gmatch("<enclosure[^>]*>") do
        local url = attr(tag, "url")
        if url then
            return url, attr(tag, "type"), tonumber(attr(tag, "length"))
        end
    end
    for tag in item:gmatch("<media:content[^>]*>") do
        local url = attr(tag, "url")
        if url and (attr(tag, "medium") == "audio"
                    or (attr(tag, "type") or ""):match("^audio")) then
            return url, attr(tag, "type"), tonumber(attr(tag, "fileSize"))
        end
    end
    for tag in item:gmatch("<link[^>]*>") do
        if attr(tag, "rel") == "enclosure" and attr(tag, "href") then
            return attr(tag, "href"), attr(tag, "type"),
                   tonumber(attr(tag, "length"))
        end
    end
    return nil
end

local function parse_item(item)
    local url, mime, size = find_media(item)
    if not url then
        return nil
    end
    local date, date_text = parse_date(text_of(item, "pubDate")
                                       or text_of(item, "published")
                                       or text_of(item, "updated")
                                       or text_of(item, "dc:date"))
    return {
        title = text_of(item, "title") or "Untitled",
        url = url,
        guid = text_of(item, "guid") or text_of(item, "id") or url,
        date = date,
        date_text = date_text,
        duration = text_of(item, "itunes:duration"),
        size = size,
        ext = media_extension(url, mime),
    }
end

local function parse_feed(xml)
    -- Channel metadata sits before the first item; looking at the whole
    -- document would pick up an episode title instead.
    xml = xml:gsub("<!%-%-.-%-%->", "")
    local head = xml:match("^(.-)<item[%s>]") or xml:match("^(.-)<entry[%s>]")
                 or xml
    local parsed = {title = text_of(head, "title"), episodes = {}}

    for item in blocks(xml, "item") do
        local episode = parse_item(item)
        if episode then
            parsed.episodes[#parsed.episodes + 1] = episode
        end
    end
    if #parsed.episodes == 0 then
        for entry in blocks(xml, "entry") do
            local episode = parse_item(entry)
            if episode then
                parsed.episodes[#parsed.episodes + 1] = episode
            end
        end
    end
    return parsed
end

--- fetching ----------------------------------------------------------------

local function curl_bin()
    return o.curl_path ~= "" and o.curl_path or "curl"
end

local function stop_progress()
    if progress then
        progress:kill()
        progress = nil
    end
end

local function idle()
    job = nil
    busy = nil
    stop_progress()
    update_menu()
end

-- Runs curl in the background. playback_only is off so that a download is not
-- killed when playback stops.
local function fetch(url, dest, what, done)
    local args = {curl_bin(), "-L", "--fail", "--silent", "--show-error",
                  "--connect-timeout", "30", "-A", o.user_agent, "-o", dest}
    if what == "feed" then
        -- Episodes are large and slow links are normal, so only feeds get an
        -- overall deadline.
        args[#args + 1] = "--max-time"
        args[#args + 1] = tostring(o.timeout)
    end
    args[#args + 1] = url

    msg.debug("fetching " .. url)
    job = mp.command_native_async({
        name = "subprocess",
        args = args,
        capture_stdout = true,
        capture_stderr = true,
        playback_only = false,
    }, function (success, res, err)
        job = nil
        if not success or not res then
            idle()
            done(false, err or "could not run " .. curl_bin())
            return
        end
        if res.killed_by_us then
            os.remove(dest)
            idle()
            return
        end
        if res.status ~= 0 then
            os.remove(dest)
            local detail = res.stderr ~= "" and res.stderr
                           or ("curl exited with " .. tostring(res.status))
            idle()
            done(false, detail)
            return
        end
        done(true)
    end)
    update_menu()
end

--- updating ----------------------------------------------------------------

local function sort_episodes(episodes)
    table.sort(episodes, function (a, b)
        if (a.date or 0) ~= (b.date or 0) then
            return (a.date or 0) > (b.date or 0)
        end
        return (a.title or "") < (b.title or "")
    end)
end

-- Keeps what is already known about an episode, most importantly whether it
-- has been downloaded, and adds whatever the feed now lists.
local function merge_episodes(feed, fresh)
    local known = {}
    for _, episode in ipairs(feed.episodes) do
        known[episode.guid or episode.url] = episode
    end

    local merged, listed = {}, {}
    for _, episode in ipairs(fresh) do
        local id = episode.guid or episode.url
        local old = known[id]
        if old then
            episode.file = old.file
        end
        listed[id] = true
        merged[#merged + 1] = episode
    end
    -- Episodes the feed no longer lists are kept if their audio is on disk,
    -- so that a podcast trimming its backlog does not hide what was already
    -- downloaded.
    for _, episode in ipairs(feed.episodes) do
        if episode.file and not listed[episode.guid or episode.url] then
            merged[#merged + 1] = episode
        end
    end

    sort_episodes(merged)
    -- Long-running podcasts list thousands of episodes; remember only the
    -- newest, plus anything already downloaded whatever its age.
    local kept = {}
    for _, episode in ipairs(merged) do
        if #kept < o.max_episodes or episode.file then
            kept[#kept + 1] = episode
        end
    end
    feed.episodes = kept
end

local function update_feed(feed, done)
    if not mkdir(rss_dir()) then
        done(false, "could not create " .. rss_dir())
        return
    end
    local tmp = utils.join_path(rss_dir(), feed.key .. ".xml")
    busy = "Updating " .. (feed.title or feed.url)
    fetch(feed.url, tmp, "feed", function (ok, err)
        if not ok then
            feed.error = err
            msg.error("could not fetch " .. feed.url .. ": " .. tostring(err))
            done(false, err)
            return
        end
        local xml = read_file(tmp)
        os.remove(tmp)
        if not xml or xml == "" then
            done(false, "the feed is empty")
            return
        end
        local parsed = parse_feed(xml)
        if #parsed.episodes == 0 and not parsed.title then
            done(false, "this does not look like an RSS feed")
            return
        end
        feed.title = parsed.title or feed.title or feed.url
        feed.error = nil
        merge_episodes(feed, parsed.episodes)
        msg.verbose(feed.title .. ": " .. #feed.episodes .. " episodes")
        done(true)
    end)
end

-- Feeds are refreshed one after another rather than all at once, so that a
-- long subscription list does not open dozens of connections.
local function update_all(quiet, done)
    if job then
        if not quiet then
            mp.osd_message(busy or "Busy")
        end
        return
    end
    if #feeds == 0 then
        if not quiet then
            mp.osd_message("No RSS feeds yet. Add one from the RSS menu.")
        end
        return
    end

    local failed = 0
    local function step(i)
        if i > #feeds then
            save_feeds()
            idle()
            if not quiet then
                mp.osd_message(failed == 0
                               and ("Updated " .. #feeds .. " feed" ..
                                    (#feeds == 1 and "" or "s"))
                               or (failed .. " of " .. #feeds ..
                                   " feeds failed, see the log"), 4)
            end
            if done then
                done()
            end
            return
        end
        if not quiet then
            mp.osd_message("Updating feeds (" .. i .. "/" .. #feeds .. ")...", 30)
        end
        update_feed(feeds[i], function (ok)
            if not ok then
                failed = failed + 1
            end
            step(i + 1)
        end)
    end
    step(1)
end

--- subscriptions -----------------------------------------------------------

local function add_feed(url)
    url = (url or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if url == "" then
        return
    end
    -- Podcast directories hand out feed:// links, which curl cannot fetch.
    url = url:gsub("^feed://", "http://"):gsub("^itpc://", "http://")
    if not url:match("^https?://") then
        mp.osd_message("Not an http(s) address: " .. url, 4)
        return
    end
    local key = url_key(url)
    if find_feed(key) then
        mp.osd_message("That feed is already in the list")
        return
    end

    local feed = {url = url, key = key, title = url, episodes = {}}
    feeds[#feeds + 1] = feed
    mp.osd_message("Fetching the feed...", 30)
    update_feed(feed, function (ok, err)
        idle()
        if not ok then
            -- Do not keep a subscription that never worked in the first place.
            local _, index = find_feed(key)
            if index then
                table.remove(feeds, index)
            end
            update_menu()
            mp.osd_message("Could not add the feed: " .. tostring(err), 5)
            return
        end
        save_feeds()
        update_menu()
        mp.osd_message("Added " .. feed.title .. " (" .. #feed.episodes ..
                       " episodes)", 4)
    end)
end

local function remove_feed(key)
    local feed, index = find_feed(key)
    if not feed then
        return
    end
    table.remove(feeds, index)
    save_feeds()
    update_menu()
    -- Downloaded episodes are left alone; deleting them silently would be a
    -- surprising amount of destruction for a menu click.
    mp.osd_message("Removed " .. feed.title ..
                   "\nDownloads stay in " .. media_dir(), 5)
end

local function prompt_for_feed()
    input.get({
        prompt = "RSS feed URL:",
        submit = function (text)
            input.terminate()
            add_feed(text)
        end,
    })
end

--- playing -----------------------------------------------------------------

local function episode_dir(feed)
    return utils.join_path(media_dir(), feed.key)
end

local function episode_path(feed, episode)
    return episode.file and utils.join_path(episode_dir(feed), episode.file)
end

local function downloaded(feed, episode)
    local path = episode_path(feed, episode)
    return path ~= nil and exists(path)
end

local function play(url, episode)
    mp.command_native({name = "loadfile", url = url, flags = "replace",
                       options = {["force-media-title"] = episode.title}})
end

local function human_size(bytes)
    if bytes >= 1048576 then
        return string.format("%.1f MB", bytes / 1048576)
    end
    return string.format("%.0f kB", bytes / 1024)
end

-- curl is run silently, so progress comes from watching the file grow.
local function show_progress(path, episode)
    stop_progress()
    progress = mp.add_periodic_timer(1, function ()
        local info = utils.file_info(path)
        if not info then
            return
        end
        local text = "Downloading " .. episode.title .. "\n"
        if episode.size and episode.size > 0 then
            text = text .. string.format("%d%%  (%s of %s)",
                                         math.floor(info.size / episode.size * 100),
                                         human_size(info.size),
                                         human_size(episode.size))
        else
            text = text .. human_size(info.size)
        end
        mp.osd_message(text, 2)
    end)
end

local function download_episode(feed, episode, done)
    local dir = episode_dir(feed)
    if not mkdir(media_dir()) or not mkdir(dir) then
        mp.osd_message("Could not create " .. dir, 5)
        return
    end

    local name = sanitize((episode.date_text and episode.date_text .. " " or "")
                          .. episode.title) .. "." .. (episode.ext or "mp3")
    local path = utils.join_path(dir, name)
    -- Download beside the real name so that an interrupted download is never
    -- mistaken for a complete episode.
    local part = path .. ".part"

    busy = "Downloading " .. episode.title
    mp.osd_message("Downloading " .. episode.title .. "...", 30)
    show_progress(part, episode)
    fetch(episode.url, part, "media", function (ok, err)
        stop_progress()
        if not ok then
            idle()
            mp.osd_message("Download failed: " .. tostring(err), 5)
            return
        end
        os.remove(path)
        local moved, move_err = os.rename(part, path)
        if not moved then
            os.remove(part)
            idle()
            mp.osd_message("Could not store the episode: " ..
                           tostring(move_err), 5)
            return
        end
        episode.file = name
        save_feeds()
        idle()
        done(path)
    end)
end

local function play_episode(feed, episode)
    if not episode.url then
        mp.osd_message("This episode has no audio attached")
        return
    end
    local path = episode_path(feed, episode)
    if path and exists(path) then
        play(path, episode)
        return
    end
    if not o.download then
        play(episode.url, episode)
        return
    end
    if job then
        mp.osd_message(busy or "Busy")
        return
    end
    download_episode(feed, episode, function (file)
        play(file, episode)
    end)
end

--- browsing ----------------------------------------------------------------

local BACK = "[ Back to feeds ]"

function browse_episodes(feed)
    if #feed.episodes == 0 then
        mp.osd_message((feed.error and ("This feed failed to load: " ..
                                        feed.error)
                                    or "This feed has no episodes yet"), 5)
        return
    end

    local items = {BACK}
    for _, episode in ipairs(feed.episodes) do
        local line = (episode.date_text or "??????????") .. "  " .. episode.title
        if episode.duration then
            line = line .. "  (" .. episode.duration .. ")"
        end
        if downloaded(feed, episode) then
            line = line .. "  [downloaded]"
        end
        items[#items + 1] = line
    end

    input.select({
        prompt = feed.title .. ":",
        items = items,
        -- Skip the back entry, so Enter on an untouched list plays the newest
        -- episode.
        default_item = 2,
        keep_open = true,
        submit = function (index)
            if index == 1 then
                browse_feeds()
                return
            end
            input.terminate()
            play_episode(feed, feed.episodes[index - 1])
        end,
    })
end

function browse_feeds()
    if #feeds == 0 then
        mp.osd_message("No RSS feeds yet. Add one from the RSS menu.", 4)
        return
    end

    local items = {}
    for _, feed in ipairs(feeds) do
        local line = feed.title or feed.url
        if feed.error then
            line = line .. "  [unreachable]"
        else
            line = line .. "  (" .. #feed.episodes .. " episodes)"
        end
        items[#items + 1] = line
    end

    input.select({
        prompt = "Select a feed:",
        items = items,
        keep_open = true,
        submit = function (index)
            browse_episodes(feeds[index])
        end,
    })
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

local function has_our_submenu(menu)
    for _, item in ipairs(menu or {}) do
        if item.title == MENU_TITLE then
            return true
        end
    end
    return false
end

function update_menu()
    local menu = mp.get_property_native("menu-data", {})
    for i = #menu, 1, -1 do
        if menu[i].title == MENU_TITLE then
            table.remove(menu, i)
        end
    end

    local items = {
        {title = "Update feeds on startup", cmd = menu_command("toggle"),
         state = checked(o.enabled)},
        {title = "Download before playing", cmd = menu_command("toggle-download"),
         state = checked(o.download)},
        {type = "separator"},
        {title = "Show episodes", cmd = menu_command("browse"),
         state = #feeds == 0 and {"disabled"} or nil},
        {title = busy and (busy .. "...") or "Update feeds now",
         cmd = menu_command("update"),
         state = (job ~= nil or #feeds == 0) and {"disabled"} or nil},
        {type = "separator"},
        {title = "Add feed...", cmd = menu_command("add")},
    }

    if #feeds > 0 then
        local removable = {}
        for _, feed in ipairs(feeds) do
            removable[#removable + 1] = {
                title = feed.title or feed.url,
                cmd = menu_command("remove " .. feed.key),
            }
        end
        items[#items + 1] = {type = "submenu", title = "Remove feed",
                             submenu = removable}
    else
        items[#items + 1] = {title = "Remove feed", state = {"disabled"}}
    end

    menu[#menu + 1] = {type = "submenu", title = MENU_TITLE, submenu = items}
    mp.set_property_native("menu-data", menu)
end

--- bindings and events -----------------------------------------------------

local function toggle()
    o.enabled = not o.enabled
    save_options()
    update_menu()
    mp.osd_message("RSS feeds are " ..
                   (o.enabled and "updated on startup" or "not updated automatically"))
    if o.enabled then
        update_all(false)
    end
end

mp.add_key_binding(nil, "browse", browse_feeds)
mp.add_key_binding(nil, "update", function () update_all(false) end)
mp.add_key_binding(nil, "add", prompt_for_feed)
mp.add_key_binding(nil, "toggle", toggle)

mp.register_script_message("browse", browse_feeds)
mp.register_script_message("update", function () update_all(false) end)
mp.register_script_message("add", prompt_for_feed)
mp.register_script_message("remove", remove_feed)
mp.register_script_message("toggle", toggle)
mp.register_script_message("toggle-download", function ()
    o.download = not o.download
    save_options()
    update_menu()
end)

-- select.lua rebuilds menu-data from scratch once the window is created, which
-- drops whatever else was in there, so put our submenu back whenever it goes
-- missing. This also does the initial build, because observing a property
-- reports its current value straight away.
mp.observe_property("menu-data", "native", function (_, menu)
    if not has_our_submenu(menu) then
        update_menu()
    end
end)

load_feeds()
update_menu()

if o.enabled and #feeds > 0 then
    -- Not during startup itself: the first file should begin playing without
    -- waiting for the network.
    mp.add_timeout(1, function ()
        update_all(true, update_menu)
    end)
end
