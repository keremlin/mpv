TRANSCRIBE
==========

This script generates subtitles for the playing file by running whisper.cpp on
the local machine, and loads the result as an external subtitle track. The audio
is never sent anywhere. It can be disabled using the ``--load-transcribe=no``
option.

It requires a whisper.cpp CLI binary and a ggml model, neither of which is
shipped with mpv. Prebuilt binaries are available from
``https://github.com/ggml-org/whisper.cpp/releases`` and models from
``https://huggingface.co/ggerganov/whisper.cpp``. Nothing happens until
``model`` is configured.

Files whisper.cpp cannot decode by itself, which includes every video container,
are converted to wav by invoking mpv again, so ``mpv_path`` has to point at a
working mpv binary for those.

Script bindings
---------------

``transcribe``
    Transcribe the playing file and load the result. If a transcript for the
    file already exists, it is loaded instead of being generated again.

``cancel``
    Abort a transcription that is in progress.

Example for ``input.conf``::

    Ctrl+t script-binding transcribe/transcribe
    Ctrl+T script-binding transcribe/cancel

Configuration
-------------

This script can be customized through a config file
``script-opts/transcribe.conf`` placed in mpv's user directory and through the
``--script-opts`` command-line option.

``whisper_path=<path>``
    The whisper.cpp CLI binary (default: ``whisper-cli``). A name without path
    components is looked up in ``PATH``.

``model=<path>``
    The ggml model file to transcribe with (default: empty). The script does
    nothing while this is unset.

``language=<code>``
    Language to transcribe as, for example ``en`` or ``de`` (default: ``auto``,
    which lets whisper detect it).

``threads=<number>``
    Number of threads whisper may use (default: 0, which lets whisper decide).

``mpv_path=<path>``
    The mpv binary used to convert audio whisper cannot read (default: ``mpv``).

``save_next_to_file=<yes|no>``
    Write the transcript next to the media file as ``<name>.whisper.srt``
    instead of into a temporary directory (default: no). Either way an existing
    transcript is reused on the next playback.

``autostart=<yes|no>``
    Transcribe automatically whenever a file that has no subtitle tracks at all
    is loaded (default: no).
