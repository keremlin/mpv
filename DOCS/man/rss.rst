RSS
===

This script turns mpv into a podcast client. It keeps a list of RSS feeds,
reads the episodes each one lists, and plays them, downloading the audio first
if it is not on disk yet. It can be disabled entirely with the ``--load-rss=no``
option.

Everything is driven from the ``RSS`` submenu of the context menu, which is
opened by right-clicking the window (see `CONTEXT MENU`_). Nothing is contacted
until a feed is added.

Adding and removing feeds
-------------------------

``RSS`` -> ``Add feed...`` asks for a feed address and fetches it straight away.
The feed is only kept if it turns out to be readable, so a typo does not leave a
broken entry behind. ``feed://`` and ``itpc://`` links, which podcast
directories like to hand out, are rewritten to ``http://``.

A feed address is the ``.xml`` link a podcast publishes, for example::

    https://proxyfeed.svmaudio.com/feeds/easygerman/feed.xml

``RSS`` -> ``Remove feed`` lists the subscriptions and drops the one that is
picked. Episodes already downloaded from it are **not** deleted; they stay in
the download directory and have to be removed by hand.

The subscription list lives in ``rss/feeds.json`` inside mpv's user directory,
which is ``%APPDATA%\mpv\rss\`` on Windows, ``portable_config\rss\`` next to
``mpv.exe`` for a portable install, and ``~/.config/mpv/rss/`` elsewhere. It is
plain JSON and can be edited while mpv is not running, which is the easiest way
to import a longer list of feeds.

Browsing and playing
--------------------

``RSS`` -> ``Show episodes`` opens the selector: first the list of feeds, then
the episodes of whichever one is chosen. The episode list is sorted by
publication date, newest first, and marks the episodes that are already on
disk. Typing filters the list, and the first entry goes back to the feed list.

Choosing an episode plays it. If its audio has not been downloaded yet it is
fetched first, with progress shown on screen, and playback starts when the
download finishes. Downloads are written to a ``.part`` file and only renamed
into place once complete, so an interrupted download is never mistaken for a
playable episode.

Downloaded episodes go to ``rss/media/<feed>/`` inside mpv's user directory,
one directory per feed, named ``<date> <episode title>.<ext>``. ``download_dir``
moves them elsewhere. They are never deleted automatically.

Turning ``Download before playing`` off makes the script stream episodes
directly from their URL instead. That saves disk space and starts playback
sooner, at the cost of needing a connection for the whole episode and of not
being able to seek reliably on servers that do not support range requests.

Updating
--------

``RSS`` -> ``Update feeds now`` refetches every feed. Feeds are fetched one after
another rather than all at once, so a long subscription list does not open
dozens of connections.

``RSS`` -> ``Update feeds on startup`` does the same automatically about a second
after mpv starts. This is off by default and is what the ``enabled`` option
controls. It is deliberately the only thing that switch governs: browsing,
playing and updating by hand keep working with it off, so that the feeds already
fetched stay usable without a connection.

An update keeps what is already known about an episode, most importantly whether
its audio has been downloaded. Only the newest ``max_episodes`` entries of a
feed are remembered, except that episodes already downloaded are kept however
old they are, so a podcast trimming its own backlog cannot hide them.

Feeds are read with ``curl``, which is part of Windows 10 and later and of most
Unix systems. If it is not on ``PATH``, set ``curl_path``.

RSS 2.0 with ``<enclosure>`` elements is what podcasts use and is what this is
built for. Atom feeds with ``<link rel="enclosure">`` and Media RSS
``<media:content>`` are also read. Items without an attached media file are
skipped, since there is nothing to play.

Script bindings
---------------

``browse``
    Open the feed and episode selector.

``update``
    Refetch every feed now.

``add``
    Ask for a feed address and subscribe to it.

    Subscribing to a known feed without being asked is also possible by sending
    the address along, which is what a binding or the IPC interface would do::

        script-message-to rss add https://example.com/feed.xml

``toggle``
    Switch updating on startup on or off.

Example for ``input.conf``::

    Ctrl+r script-binding rss/browse
    Ctrl+Shift+r script-binding rss/update

Configuration
-------------

This script can be customized through a config file ``script-opts/rss.conf``
placed in mpv's user directory and through the ``--script-opts`` command-line
option. Settings changed through the menu are written back to that same file, so
they survive a restart.

Configurable options
~~~~~~~~~~~~~~~~~~~~

``enabled``
    Default: no

    Refetch every feed when mpv starts.

``download``
    Default: yes

    Download an episode before playing it. When set to ``no``, episodes are
    streamed from their URL instead.

``download_dir``
    Default: empty

    Where downloaded episodes go. Empty means ``rss/media`` inside mpv's user
    directory.

``max_episodes``
    Default: 200

    How many episodes to remember per feed. Older ones are forgotten unless
    their audio has been downloaded.

``timeout``
    Default: 30

    Seconds to wait for a feed. Episode downloads are not limited by this, only
    by a 30 second connection timeout.

``curl_path``
    Default: empty

    The ``curl`` binary to use. Empty means whatever is on ``PATH``.

``user_agent``
    Default: ``Mozilla/5.0 (compatible; mpv)``

    Sent with every request. Some podcast hosts refuse requests that do not
    carry a user agent.
