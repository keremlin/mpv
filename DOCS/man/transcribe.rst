TRANSCRIBE
==========

This script generates subtitles for the playing file by running whisper.cpp on
the local machine, and loads the result as an external subtitle track. The audio
is never sent anywhere. The script can be disabled entirely with the
``--load-transcribe=no`` option.

Subtitle generation is off until it is switched on, either from the
``Subtitle generation`` submenu of the context menu or in the configuration file
described below. Settings changed through the menu are written back to
``script-opts/transcribe.conf`` in mpv's user directory, so they survive a
restart.

Once it is on, every file that is loaded and has no subtitle track of its own is
transcribed, and the result is written next to the media file as ``<name>.srt``.
Because mpv loads such a file on its own, playing the same file again reuses the
subtitles instead of generating them a second time. A file that already has an
``<name>.srt`` next to it is never overwritten.

Requirements
------------

The whisper.cpp binary and the ggml language model are not part of mpv. When
subtitle generation is switched on and either is missing, the script says so and
offers to download both into ``whisper`` in mpv's user directory, which takes
roughly 200 MB for the default model. This can also be triggered from the
context menu. The automatic download is only implemented for Windows;
on other platforms install whisper.cpp yourself and point ``whisper_path`` at
it.

whisper.cpp reads ``wav``, ``mp3`` and ``flac`` by itself. Any other format,
which includes every video container, is converted first by invoking mpv again,
so ``mpv_path`` has to point at a working mpv binary for those.

Script bindings
---------------

``toggle``
    Switch subtitle generation on or off.

``transcribe``
    Generate subtitles for the playing file now, whether or not automatic
    generation is on.

``cancel``
    Abort a run that is in progress.

Example for ``input.conf``::

    Ctrl+t script-binding transcribe/toggle
    Ctrl+g script-binding transcribe/transcribe

Configuration
-------------

This script can be customized through a config file
``script-opts/transcribe.conf`` placed in mpv's user directory and through the
``--script-opts`` command-line option.

``enabled=<yes|no>``
    Generate subtitles automatically for files that have none (default: no).

``language=<code>``
    Language to transcribe as, for example ``de`` or ``en`` (default: ``de``).
    ``auto`` lets whisper detect the language, which is slower and less
    reliable than naming it.

``model=<name>``
    The ggml model to use, without the ``ggml-`` prefix and ``.bin`` suffix
    (default: ``base``). Larger models such as ``medium`` or ``large-v3`` are
    considerably more accurate and considerably slower. Models ending in
    ``.en`` only understand English.

``live=<yes|no>``
    Transcribe the file in chunks and extend the subtitle file as playback goes
    on, so subtitles start appearing after the first chunk instead of after the
    whole file (default: no). Whether this keeps up with playback depends on the
    model and the machine; if it falls behind, the subtitles lag rather than
    playback.

``chunk_seconds=<seconds>``
    Length of one chunk in live mode (default: 30). Shorter chunks show the
    first subtitles sooner but transcribe less accurately, because whisper has
    less context to work with.

``whisper_dir=<path>``
    Directory holding the whisper.cpp binary and the models (default: ``whisper``
    in mpv's user directory).

``whisper_path=<path>``
    The whisper.cpp binary, if it is not in ``whisper_dir`` (default: empty).

``threads=<number>``
    Number of threads whisper may use (default: 0, which lets whisper decide).

``mpv_path=<path>``
    The mpv binary used to convert audio whisper cannot read (default: ``mpv``).

``output_dir=<path>``
    Write the subtitles here instead of next to the media file (default:
    empty).
