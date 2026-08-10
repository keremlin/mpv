![mpv logo](https://raw.githubusercontent.com/mpv-player/mpv.io/master/source/images/mpv-logo-128.png)

# mpv


> A fork of [mpv](https://github.com/mpv-player/mpv) that generates subtitles
> from speech on your own machine, with no cloud service involved. See
> [Offline subtitle generation](#offline-subtitle-generation). Everything else
> is upstream mpv and is documented below.


* [External links](#external-links)
* [Overview](#overview)
* [Offline subtitle generation](#offline-subtitle-generation)
* [System requirements](#system-requirements)
* [Downloads](#downloads)
* [Changelog](#changelog)
* [Compilation](#compilation)
* [Release cycle](#release-cycle)
* [Bug reports](#bug-reports)
* [Contributing](#contributing)
* [License](#license)
* [Contact](#contact)


## External links


* [Wiki](https://github.com/mpv-player/mpv/wiki)
* [User Scripts](https://github.com/mpv-player/mpv/wiki/User-Scripts)
* [FAQ][FAQ]
* [Manual](https://mpv.io/manual/master/)


## Overview


**mpv** is a free (as in freedom) media player for the command line. It supports
a wide variety of media file formats, audio and video codecs, and subtitle types.

There is a [FAQ][FAQ].

Releases can be found on the [release list][releases].

## Offline subtitle generation


This fork adds a built-in `transcribe` script that generates subtitles for
whatever is playing by running [whisper.cpp](https://github.com/ggml-org/whisper.cpp)
on your own machine. The audio never leaves the computer: there is no account,
no API key and no network traffic beyond the one-time model download described
below.

The full option reference is in the
[manual](https://mpv.io/manual/master/#transcribe) and in
[DOCS/man/transcribe.rst](DOCS/man/transcribe.rst).

### Turning it on and off

Subtitle generation is **off by default**. Enable it either way:

* Right-click the video window and pick **Subtitle generation → Generate
  subtitles automatically**, or
* bind a key in `input.conf`:

      Ctrl+t       script-binding transcribe/toggle
      Ctrl+g       script-binding transcribe/transcribe
      Ctrl+Shift+g script-binding transcribe/cancel

Whichever you use, the change is written to `script-opts/transcribe.conf` in
mpv's user directory, so it survives a restart. Setting `enabled=no` there, or
passing `--load-transcribe=no`, turns the feature off again; the latter also
stops the script from loading at all.

### How automatic transcription works

When it is enabled, every file you open that has **no subtitle track of its
own** is transcribed:

1. If a subtitle file for it already exists, that one is loaded and nothing is
   generated. Work is never repeated.
2. Otherwise the audio is handed to whisper.cpp. `wav`, `mp3` and `flac` are
   read directly; everything else, including every video container, is first
   converted to 16 kHz mono by invoking mpv again.
3. The result is written **next to the media file** as `<name>.srt` and loaded
   as the active subtitle track.

Because `<name>.srt` is exactly the name mpv looks for on its own, playing the
file again simply loads it. An `.srt` that is already there is never
overwritten.

Files that already carry subtitles are skipped, so enabling this does not
interfere with normal playback of media that is already subtitled.

By default the subtitles appear when the whole file has been processed. Set
`live=yes` (**Subtitle generation → Show subtitles while transcribing**) to
transcribe in chunks instead, extending the subtitle file as playback goes on,
so the first subtitles show up after a few seconds rather than at the end.
Whether that keeps up with playback depends on the model and the machine; if it
falls behind, the subtitles lag, not the video.

### Choosing the language

The language is set under **Subtitle generation → Language**, or with
`language=` in `transcribe.conf`. It defaults to **German** (`de`).

It is worth setting this deliberately rather than leaving it on `auto`. Whisper
detects the language from the first few seconds of audio, which costs extra time
and gets it wrong on short files, on music, and on recordings that open with
silence or a greeting in another language. Naming the language skips detection
entirely and improves accuracy. Use `auto` only when you genuinely do not know
what you are about to play.

Note that models whose name ends in `.en` understand English only; the default
`base` model is multilingual.

### The speech recognition files

whisper.cpp and its language model are **not shipped with mpv** and are not
downloaded until you ask for them. The first time you enable subtitle
generation, mpv reports what is missing and offers to fetch it:

> Subtitle generation needs the speech recognition program and the language
> model (about 200 MB). Press y to download, n to skip.

Pressing `y` downloads, into a `whisper` directory inside mpv's user directory:

| File | Source | Size |
| --- | --- | --- |
| `ggml-<model>.bin` | [huggingface.co/ggerganov/whisper.cpp](https://huggingface.co/ggerganov/whisper.cpp) | ~141 MB for `base` |
| `whisper-cli` and its libraries | [whisper.cpp releases](https://github.com/ggml-org/whisper.cpp/releases) | ~60 MB unpacked |

On Windows that directory is `%APPDATA%\mpv\whisper\`, or
`portable_config\whisper\` next to `mpv.exe` for a portable install. On Linux
and macOS it is `~/.config/mpv/whisper/`. Use `whisper_dir=` to put them
somewhere else, such as a shared drive.

The automatic download is implemented for Windows only. On other platforms,
install whisper.cpp yourself, point `whisper_path=` at the binary and drop a
`ggml-*.bin` model into `whisper_dir`.

A larger model gives noticeably better results for accented speech and noisy
recordings, at the cost of speed. Change it with `model=` — `small`, `medium` or
`large-v3` — and mpv will offer to download the new one the same way.

## System requirements

- A not too ancient Linux (usually, only the latest releases of distributions
  are actively supported), Windows 10 1607 or later, or macOS 10.15 or later.
- A somewhat capable CPU. Hardware decoding might help if the CPU is too slow to
  decode video in realtime, but must be explicitly enabled with the `--hwdec`
  option.
- A not too crappy GPU. mpv's focus is not on power-efficient playback on
  embedded or integrated GPUs (for example, hardware decoding is not even
  enabled by default). Low power GPUs may cause issues like tearing, stutter,
  etc. On such GPUs, it's recommended to use `--profile=fast` for smooth playback.
  The main video output uses shaders for video rendering and scaling,
  rather than GPU fixed function hardware. On Windows, you might want to make
  sure the graphics drivers are current. In some cases, ancient fallback video
  output methods can help (such as `--vo=xv` on Linux), but this use is not
  recommended or supported.

mpv does not go out of its way to break on older hardware or old, unsupported
operating systems, but development is not done with them in mind. Keeping
compatibility with such setups is not guaranteed. If things work, consider it
a happy accident.

## Downloads


For semi-official builds and third-party packages please see
[mpv.io/installation](https://mpv.io/installation/).

## Changelog


There is no complete changelog; however, changes to the player core interface
are listed in the [interface changelog][interface-changes].

Changes to the C API are documented in the [client API changelog][api-changes].

The [release list][releases] has a summary of most of the important changes
on every release.

Changes to the default key bindings are indicated in
[restore-old-bindings.conf][restore-old-bindings].

Changes to the default OSC bindings are indicated in
[restore-osc-bindings.conf][restore-osc-bindings].

## Compilation


Compiling with full features requires development files for several
external libraries. Mpv requires [meson](https://mesonbuild.com/index.html)
to build. Meson can be obtained from your distro or PyPI.

After creating your build directory (e.g. `meson setup build`), you can view a list
of all the build options via `meson configure build`. You could also just simply
look at the `meson_options.txt` file. Logs are stored in `meson-logs` within
your build directory.

Example:

    meson setup build
    meson compile -C build
    meson install -C build

For libplacebo, meson can use a git check out as a subproject for a convenient
way to compile mpv if a sufficient libplacebo version is not easily available
in the build environment. It will be statically linked with mpv. Example:

    mkdir -p subprojects
    git clone https://code.videolan.org/videolan/libplacebo.git --depth=1 --recursive subprojects/libplacebo

Essential dependencies (incomplete list):

- gcc or clang
- X development headers (xlib, xrandr, xext, xscrnsaver, xpresent, libvdpau,
  libGL, GLX, EGL, xv, ...)
- Audio output development headers (libasound/ALSA, pulseaudio)
- FFmpeg libraries (libavutil libavcodec libavformat libswscale libavfilter
  and either libswresample or libavresample)
- libplacebo
- zlib
- iconv (normally provided by the system libc)
- libass (OSD, OSC, text subtitles)
- Lua (optional, required for the OSC pseudo-GUI and youtube-dl integration)
- libjpeg (optional, used for screenshots only)
- uchardet (optional, for subtitle charset detection)
- nvdec and vaapi libraries for hardware decoding on Linux (optional)

Libass dependencies (when building libass):

- gcc or clang, nasm on x86 and x86_64
- fribidi, freetype, fontconfig development headers (for libass)
- harfbuzz (required for correct rendering of combining characters, particularly
  for correct rendering of non-English text on macOS, and Arabic/Indic scripts on
  any platform)

FFmpeg dependencies (when building FFmpeg):

- gcc or clang, nasm on x86 and x86_64
- OpenSSL or GnuTLS (have to be explicitly enabled when compiling FFmpeg)
- libx264/libmp3lame/libfdk-aac if you want to use encoding (have to be
  explicitly enabled when compiling FFmpeg)
- For native DASH playback, FFmpeg needs to be built with --enable-libxml2
  (although there are security implications, and DASH support has lots of bugs).
- AV1 decoding support requires dav1d.
- For good nvidia support on Linux, make sure nv-codec-headers is installed
  and can be found by configure.

Most of the above libraries are available in suitable versions on normal
Linux distributions. For ease of compiling the latest git master of everything,
you may wish to use the separately available build wrapper ([mpv-build][mpv-build])
which first compiles FFmpeg libraries and libass, and then compiles the player
statically linked against those.

If you want to build a Windows binary, see [Windows compilation][windows_compilation].


## Release cycle

Once or twice a year, a release is cut off from the current development state
and is assigned a 0.X.0 version number. No further maintenance is done, except
in the event of security issues.

The goal of releases is to make Linux distributions happy. Linux distributions
are also expected to apply their own patches in case of bugs.

Releases other than the latest release are unsupported and unmaintained.

See the [release policy document][release-policy] for more information.

## Bug reports


Please use the [issue tracker][issue-tracker] provided by GitHub to send us bug
reports or feature requests. Follow the template's instructions or the issue
will likely be ignored or closed as invalid.

Questions can be asked in the [discussions][discussions] or on IRC (see
[Contact](#Contact) below).

## Contributing


Please read [contribute.md][contribute.md].

For small changes you can just send us pull requests through GitHub. For bigger
changes come and talk to us on IRC before you start working on them. It will
make code review easier for both parties later on.

You can check [the wiki](https://github.com/mpv-player/mpv/wiki/Stuff-to-do)
or the [issue tracker](https://github.com/mpv-player/mpv/issues?q=is%3Aopen+is%3Aissue+label%3Ameta%3Afeature-request)
for ideas on what you could contribute with.

## License

GPLv2 "or later" by default, LGPLv2.1 "or later" with `-Dgpl=false`.
See [details.](https://github.com/mpv-player/mpv/blob/master/Copyright)

## History

This software is based on the MPlayer project. Before mpv existed as a project,
the code base was briefly developed under the mplayer2 project. For details,
see the [FAQ][FAQ].

## Contact


Most activity happens on the IRC channel and the GitHub issue tracker.

- **GitHub issue tracker**: [issue tracker][issue-tracker] (report bugs here)
- **Discussions**: [discussions][discussions]
- **User IRC Channel**: `#mpv` on `irc.libera.chat`
- **Developer IRC Channel**: `#mpv-devel` on `irc.libera.chat`

[FAQ]: https://github.com/mpv-player/mpv/wiki/FAQ
[releases]: https://github.com/mpv-player/mpv/releases
[mpv-build]: https://github.com/mpv-player/mpv-build
[issue-tracker]:  https://github.com/mpv-player/mpv/issues
[discussions]: https://github.com/mpv-player/mpv/discussions
[release-policy]: https://github.com/mpv-player/mpv/blob/master/DOCS/release-policy.md
[windows_compilation]: https://github.com/mpv-player/mpv/blob/master/DOCS/compile-windows.md
[interface-changes]: https://github.com/mpv-player/mpv/blob/master/DOCS/interface-changes.rst
[api-changes]: https://github.com/mpv-player/mpv/blob/master/DOCS/client-api-changes.rst
[restore-old-bindings]: https://github.com/mpv-player/mpv/blob/master/etc/restore-old-bindings.conf
[restore-osc-bindings]: https://github.com/mpv-player/mpv/blob/master/etc/restore-osc-bindings.conf
[contribute.md]: https://github.com/mpv-player/mpv/blob/master/DOCS/contribute.md
