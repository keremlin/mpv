# Fork reference: environment, build, implementation, testing

Everything needed to get this fork building, running and verified on a new
machine. `CLAUDE.md` is the short orientation; this is the detail behind it.

Upstream mpv's own documentation still applies for everything not listed here.


## 1. Environment

### 1.1 To build

| Requirement | Notes |
| --- | --- |
| **Docker Desktop** | The only hard requirement. The whole toolchain lives in a container image. |
| **git** | To clone. On Windows it will use `core.autocrlf=true`; that is expected and handled. |
| ~25 GB free disk | Container image, the `mpv-build` volume (sources, prefix, ccache) and the output folder. |
| ~8 GB RAM | ffmpeg and libplacebo are the peak. |

No compiler, MSYS2, Visual Studio, Windows SDK or Python is needed on the host
to build. Everything is cross-compiled from Ubuntu to `x86_64-w64-mingw32`.

### 1.2 To run the result

| Requirement | Notes |
| --- | --- |
| Windows 10 1607 or later | Same as upstream mpv. |
| The whole output folder | `mpv.exe` plus 24 DLLs. Moving `mpv.exe` alone will not work. |
| `curl` on PATH | Ships with Windows 10 1803+. Used by both the RSS reader and the whisper downloader. |
| Speech-to-text files | Only for subtitle generation, downloaded on demand. See section 4. |

### 1.3 To develop and test

Needed only for the verification harnesses in section 5:

```
pip install lupa docutils Pillow
```

- `lupa` — runs Lua code in-process for parser and syntax tests
- `docutils` — builds the man pages to validate RST
- `Pillow` — image conversion, used by `TOOLS/png2bgra.py`


## 2. Building

### 2.1 First time

```bash
git clone https://github.com/keremlin/mpv.git
cd mpv
docker build -t mpv-winbuild -f ci/docker/Dockerfile ci/docker
docker volume create mpv-build
```

The image is Ubuntu 24.04 plus: `g++-mingw-w64`, `gcc-multilib`, `ccache`,
`nasm`, `ninja-build`, `cmake`, `make`, `build-essential`, `autoconf`,
`automake`, `libtool`, `patch`, `gettext`, `pkgconf`, `git`, `wget`, `curl`,
`xz-utils`, `bzip2`, `unzip`, `rsync`, meson via pip, and rustup with the
`x86_64-pc-windows-gnu` target.

That package list is deliberately wider than CI's: CI installs only what the
GitHub runner lacks, so copying it leaves out `cmake` and others and the build
fails partway through.

### 2.2 Each build

PowerShell (this is the verified path on Windows):

```powershell
docker run --rm -v mpv-build:/build `
    -v "C:\path\to\mpv:/src:ro" `
    -v "C:\path\to\output:/out" `
    -v "C:\path\to\mpv\ci\docker\build-windows.sh:/build.sh:ro" `
    mpv-winbuild bash -c "tr -d '\r' < /build.sh > /tmp/b.sh && bash /tmp/b.sh"
```

Bash equivalent and full rationale: `DOCS/compile-windows.md`.

Running the same command from **Git Bash** fails with

```
stat C:/Program Files/Git/src/ci/docker/build-windows.sh: no such file
```

because MSYS rewrites container-side `/src/...` paths into host paths.
`MSYS_NO_PATHCONV=1` is the usual cure but has not been verified here; use
PowerShell.

### 2.3 What gets compiled

From source, in order, into `/build/mpv/mingw_prefix`:

`iconv`, `zlib-ng`, `shaderc`, `spirv-cross`, `amf-headers`, `nv-headers`,
`dav1d`, `lcms2`, `vulkan-headers`, `vulkan-loader`, `ffmpeg`, `libplacebo`,
`freetype`, `fribidi`, `harfbuzz`, `libass`, `luajit`, `curl` — then mpv.

**Timings.** First build 30-60 minutes. Later builds reuse the volume and take
about a minute, because `build_if_missing` records each finished dependency with
a marker file in the prefix and skips it next time. This also makes a failed
build resumable: fix the cause and re-run, and it continues at the failure.

`docker volume rm mpv-build` to start completely clean.

### 2.4 Build traps

These each cost a full build cycle the first time.

1. **Commit before building.** `ci/docker/build-windows.sh` runs
   `git checkout -f -- .` inside the container to normalise line endings. That
   **reverts uncommitted changes to tracked files**. Untracked new files
   survive, so a new script can build while its integration points silently
   revert — producing a binary that looks fine and does nothing.

2. **Line endings.** A Windows checkout with `core.autocrlf=true` turns
   `#!/bin/bash -e` into `-e\r`, and every script in `ci/` dies with
   `/bin/bash: - : invalid option`. The build script re-checks the tree out with
   `core.autocrlf=false core.eol=lf` and asserts no CRLF remains.

3. **subrandr is disabled** via `SKIP_SUBRANDR=1`. Its Rust xtask cannot produce
   an import library when cross-compiling. It renders SRV3 and WebVTT subtitles
   only; ASS, SRT and everything the transcribe script generates go through
   libass and are unaffected. Pass `-e SKIP_SUBRANDR=0` once fixed upstream.
   A partial install from a failed attempt is deleted before each run, because
   meson would otherwise half-detect it.

4. **FFmpeg master deprecations.** FFmpeg is cloned from master, and mpv builds
   with `--werror`, so a field FFmpeg newly deprecates stops the build at the
   very last step, e.g. `demux_lavf.c: 'nb_streams' is deprecated
   [-Werror=deprecated-declarations]`. `ci/build-mingw64.sh` adds
   `-Wno-error=deprecated-declarations` to the mpv step's `CFLAGS`: the
   warnings still print, every other warning stays fatal. Dependencies are
   unaffected — they are already cached by then.

### 2.5 Output

`/out` is a self-contained portable folder: `mpv.exe` (~18.6 MB), `mpv.com`,
24 DLLs, and the register/unregister `.bat` files. Keep it together.


## 3. Implementation

### 3.1 What the fork adds

| Area | Files |
| --- | --- |
| Offline subtitles | `player/lua/transcribe.lua`, `DOCS/man/transcribe.rst` |
| Podcast reader | `player/lua/rss.lua`, `DOCS/man/rss.rst` |
| Icon | `etc/mpv-icon.ico`, `etc/mpv-icon-8bit-*.png`, `etc/mpv-symbolic.svg` |
| Idle logo bitmap | `player/lua/osc.lua`, `DOCS/man/osc.rst`, `TOOLS/png2bgra.py` |
| Container build | `ci/docker/Dockerfile`, `ci/docker/build-windows.sh` |

`etc/mpv.svg` was deliberately **not** replaced: the supplied file was a raster
image wrapped in an `<svg>` element. The Windows build never reads it.

### 3.2 Registering a builtin Lua script

A new script in `player/lua/` needs **six** edits. Missing the `lua.c` one
builds cleanly and fails at runtime with `module '@foo.lua' not found`:

| # | File | Edit |
| --- | --- | --- |
| 1 | `player/lua/meson.build` | add to `lua_files` (generates the `.inc`) |
| 2 | `player/lua.c` | add to `builtin_lua_scripts[]` with `#include` of the `.inc` **← easy to miss** |
| 3 | `player/scripting.c` | `load_builtin_script(mpctx, <slot>, opts->lua_load_<name>, "@<name>.lua")` |
| 4 | `player/core.h` | grow `builtin_script_ids[N]` to match the slot count |
| 5 | `options/options.h` | `bool lua_load_<name>;` |
| 6 | `options/options.c` | the `{"load-<name>", ...}` entry **and** `.lua_load_<name> = true` |

Current slots: 0 osc, 1 ytdl_hook, 2 stats, 3 console, 4 auto_profiles,
5 select, 6 positioning, 7 commands, 8 context_menu, 9 transcribe, 10 rss.
`builtin_script_ids[11]`.

Then document it: `DOCS/man/<name>.rst`, an `.. include::` in
`DOCS/man/mpv.rst`, and a `--load-<name>` entry in `DOCS/man/options.rst`.

### 3.3 Context menu mechanics

Both scripts add a submenu by read-modify-writing the `menu-data` property.
Two things make that harder than it looks:

- **`select.lua` rebuilds `menu-data` from scratch** when the window is created,
  dropping anything else in it. Both scripts therefore register an
  `observe_property` that re-adds their submenu whenever it goes missing. The
  presence check is what stops it looping, and what lets two scripts doing this
  converge rather than clobber each other.
- **An empty Lua table is ambiguous** between array and map, and `menu-data`
  wants an array. Item `state` must be `nil` when unset, never `{}`. Beware the
  Lua `cond and nil or X` pitfall: write `not running and {"disabled"} or nil`.

On Windows the native menu in `video/out/w32_common.c` renders this same
property, which is why `--load-context-menu` defaults to `no` there.

### 3.4 transcribe.lua

`script-opts/transcribe.conf`:

| Option | Default | Meaning |
| --- | --- | --- |
| `enabled` | `no` | Auto-transcribe loaded files that have no subtitles |
| `language` | `de` | Language code, or `auto` to detect |
| `model` | `base` | ggml model, without `ggml-` prefix / `.bin` suffix |
| `whisper_dir` | *(empty)* | Holds whisper-cli and models; empty means `~~/whisper` |
| `whisper_path` | *(empty)* | Explicit binary path |
| `threads` | `0` | 0 lets whisper decide |
| `mpv_path` | *(empty)* | mpv binary for decoding formats whisper cannot read |
| `live` | `no` | Transcribe in chunks while playing |
| `chunk_seconds` | `30` | Chunk length in live mode |
| `output_dir` | *(empty)* | Write `.srt` here instead of beside the media |

Bindings `transcribe/toggle`, `transcribe/transcribe`, `transcribe/cancel`.
Script messages: `toggle`, `toggle-live`, `set-language`, `start`, `cancel`,
`install`.

`mpv_path` defaults by looking for `mpv.exe` next to the config directory (the
portable layout), then falling back to PATH — mpv does not tell scripts where
its own binary is.

### 3.5 rss.lua

`script-opts/rss.conf`:

| Option | Default | Meaning |
| --- | --- | --- |
| `enabled` | `no` | Refresh every feed ~1s after startup |
| `download` | `yes` | Download before playing; `no` streams instead |
| `download_dir` | *(empty)* | Empty means `~~/rss/media` |
| `max_episodes` | `200` | Remembered per feed; downloaded ones are never pruned |
| `timeout` | `30` | Seconds for a feed fetch; downloads are not capped |
| `curl_path` | *(empty)* | Empty means whatever is on PATH |
| `user_agent` | `Mozilla/5.0 (compatible; mpv)` | Some hosts refuse requests without one |

Bindings `rss/browse`, `rss/update`, `rss/add`, `rss/toggle`.
Script messages: `browse`, `update`, `add` (optional URL argument), `remove`
(feed key), `toggle`, `toggle-download`.

**Storage.** `~~/rss/feeds.json` holds subscriptions and episode lists;
`~~/rss/media/<host>-<hash>/` holds downloads named `<date> <title>.<ext>`.
Writes go to a temp file and are renamed into place.

**Feed parsing.** RSS 2.0 `<enclosure>`, Atom `<link rel="enclosure">` and Media
RSS `<media:content>`. CDATA unwrapped, entities decoded (including numeric and
hex, encoded back to UTF-8 by hand since LuaJIT has no `utf8.char`), RFC 822 and
ISO 8601 dates. Dates are converted with a civil-calendar algorithm rather than
`os.time()`, because `os.time()` interprets its argument in the local zone and
would make the same feed sort differently on different machines.

**Downloads** go to `<name>.part` and are renamed on success, so an interrupted
download is never mistaken for a playable episode.

The episode browser is `mp.input.select()` — mpv's built-in searchable overlay,
the same one `select.lua` uses. mpv cannot open a second OS window.


## 4. Speech-to-text requirements

Nothing here ships with mpv and nothing is downloaded until asked for. When
subtitle generation is switched on and something is missing, mpv says what and
offers to fetch it; the context menu can also trigger it.

### 4.1 The two downloads

| What | Source | Size |
| --- | --- | --- |
| `ggml-<model>.bin` | `huggingface.co/ggerganov/whisper.cpp` | see table below |
| `whisper-cli.exe` + ggml DLLs | whisper.cpp release `v1.9.2`, `whisper-bin-x64.zip` | ~20 MB unpacked |

Both land in `whisper/` inside mpv's config directory —
`portable_config\whisper\` for a portable install, `%APPDATA%\mpv\whisper\`
otherwise, or wherever `whisper_dir` points.

The archive layout differs between whisper.cpp releases, so the script searches
up to three levels deep for the binary and records where it actually landed. In
`v1.9.2` it is `whisper/Release/whisper-cli.exe`, alongside per-CPU
`ggml-cpu-*.dll` variants (sandybridge, haswell, skylakex, icelake, alderlake,
...) picked at runtime.

### 4.2 Model sizes

Measured from Hugging Face:

| Model | Size | Notes |
| --- | --- | --- |
| `tiny` | 74 MB | fastest, noticeably worse |
| `base` | 141 MB | **default** |
| `small` | 465 MB | good accuracy/speed balance |
| `medium` | 1463 MB | |
| `large-v3` | 2952 MB | best, slow on CPU |

Models ending in `.en` are English-only; `base` is multilingual.

### 4.3 Automatic download is Windows-only

On Linux and macOS, install whisper.cpp yourself, point `whisper_path` at the
binary and drop a `ggml-*.bin` into `whisper_dir`.

### 4.4 Audio handling

whisper.cpp decodes **wav, mp3 and flac** natively, via miniaudio. Anything
else — including every video container and the m4a/aac common in podcasts — is
converted first by invoking mpv again:

```
mpv <file> --no-config --no-terminal --vid=no --sid=no \
    --audio-channels=mono --audio-samplerate=16000 \
    --of=wav --oac=pcm_s16le --o=<temp>.wav
```

so `mpv_path` must resolve for those formats. Temp files are deleted after the
run. Live mode adds `--start=` and `--length=` to carve out one chunk.

### 4.5 Language

Defaults to German (`de`). Setting it deliberately rather than leaving `auto` is
worth it: detection reads the first few seconds, costs time, and gets it wrong
on short files, on music, and on recordings that open with silence or a greeting
in another language.

### 4.6 Live mode

Transcribes one `chunk_seconds` chunk at a time and appends to the `.srt`,
reloading the subtitle track as it grows, so subtitles appear while the file
plays. Each chunk is transcribed as a standalone file, so its timestamps start
at zero and are shifted to the chunk offset, with cue numbering carried across.

### 4.7 Known limitation

whisper hallucinates text over silence. This is inherent to whisper.cpp, not
something this fork introduces.


## 5. Testing and verification

Several bugs here appeared **only in the built binary** — the missing `lua.c`
registration, and the context menu entry vanishing once `select.lua` ran. Review
alone does not catch those. These are the harnesses that do.

### 5.1 Lua logic, in-process

`lupa` runs the script under stubbed `mp`, `mp.msg`, `mp.utils`, `mp.input` and
`mp.options` modules. To reach file-local functions, slice the source at a
section comment and append a `return {...}`:

```python
src = open("player/lua/rss.lua", encoding="utf-8").read()
slice_ = src[:src.index("--- fetching ---")] + "\nreturn {parse_feed=parse_feed}\n"
M = lua.execute(slice_)
```

Loading the **whole** file under stubs is also worth doing on its own — it is a
syntax check that costs nothing.

Note `lupa` here is Lua 5.5 while mpv uses LuaJIT (5.1). Keep test code to plain
constructs, and avoid 5.1-absent library calls in the scripts themselves.

### 5.2 Real feeds, real data

Synthetic XML does not exercise what real podcast feeds do. Fetch a few and
parse them:

```
https://proxyfeed.svmaudio.com/feeds/easygerman/feed.xml
https://feeds.simplecast.com/54nAGcIl        (The Daily, 18 MB, 2943 items)
https://feeds.megaphone.fm/GLT1412515089     (JRE, 2733 items)
```

Assert on missing dates/URLs/GUIDs, duplicate GUIDs and sort order rather than
on exact values, which change.

### 5.3 Driving the real UI over IPC

Launch the built binary with a named pipe and speak JSON to it:

```
mpv.exe --idle=yes --force-window=yes --input-ipc-server=\\.\pipe\mpv-test
```

`{"command": ["keypress", "ENTER"]}` drives the `input.select` overlay, which is
how the full subscribe → browse → download → play path gets tested without a
human.

**Launch and connect must happen inside a single tool call.** A backgrounded
child process is killed when the call ends, and the pipe goes with it.

### 5.4 When IPC will not cooperate

More robust, and no pipe involved — load a throwaway script that dumps what you
need and quits:

```lua
mp.observe_property("vo-configured", "bool", function (_, ok)
    if not ok then return end
    mp.add_timeout(2.5, function ()
        local f = io.open(os.getenv("MENU_DUMP"), "w")
        f:write(require('mp.utils').format_json(
                    mp.get_property_native("menu-data", {})))
        f:close()
        mp.commandv("quit")
    end)
end)
```

Run with `--script=dump.lua`. Waiting for `vo-configured` matters: it is only
after the window exists that `select.lua` has rebuilt `menu-data` and any race
between scripts has settled.

### 5.5 Documentation

```
python -m docutils --writer=manpage DOCS/man/mpv.rst /dev/null
```

Silence means the RST is valid and every reference resolves. This catches a
missing `.. include::` or a broken ``SECTION``\_ link.

### 5.6 What has been verified

| Area | Result |
| --- | --- |
| RSS parser unit tests | 45 assertions: dates, time zones, entities, UTF-8, CDATA, extensions, malformed input |
| RSS merge/prune | download flags survive refresh; downloaded episodes kept past the limit; trimmed feeds do not lose them |
| Real feeds | 6388 episodes across 3 feeds, zero missing dates/URLs/GUIDs; 18 MB parsed in 0.38s |
| RSS end-to-end | subscribe, browse, download 31 MB, play, replay without re-downloading |
| Menu coexistence | RSS and Subtitle generation submenus both survive `select.lua`'s rebuild |
| Transcription | German TTS clip transcribed correctly; AAC conversion path and temp cleanup; live mode chunk offsets and cue numbering |
| Icon | extracted back out of the built `mpv.exe` and compared |
| Man pages | build clean with `rst2man` |


## 6. Running the built player

A `portable_config/` directory next to `mpv.exe` overrides every config path, so
everything stays inside the folder:

```
portable_config/
  input.conf                  key bindings for both features
  mpv-logo.<w>x<h>.bgra       idle-screen logo, premultiplied-alpha BGRA
  script-opts/transcribe.conf
  script-opts/rss.conf
  whisper/ggml-base.bin       141 MB, downloaded on demand
  whisper/Release/whisper-cli.exe
  rss/feeds.json              subscriptions
  rss/media/<feed>/           downloaded episodes
```

`whisper/` and `rss/` are created on first use; neither is in the repo.

The idle logo is a raw BGRA blob because `overlay-add` accepts only `bgra` with
premultiplied alpha. `TOOLS/png2bgra.py` converts a PNG, with `--alpha-from-luma`
for art on a black background and `--feather` to hide a glow clipped at the
frame edge. When a bitmap is present, `osc.lua` draws it instead of the vector
logo — not on top of it.


## 7. Known limitations

- whisper hallucinates over silence (inherent to whisper.cpp)
- the 16x16 icon is a downscale and is hard to read at that size
- the idle logo bitmap is fixed-resolution and lives in `portable_config`
  rather than being compiled into the binary
- SRV3 and WebVTT subtitles cannot be rendered (subrandr disabled, section 2.4)
- RSS feeds behind authentication are not supported
