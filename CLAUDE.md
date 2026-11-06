# CLAUDE.md

Orientation for this repository. **`DOCS/fork-reference.md` is the full
reference** — environment, build, implementation, speech-to-text and testing.
Read it before building, changing a builtin script, or setting up a new machine.

Upstream mpv's own docs apply for everything this fork does not touch.

## What this is

A fork of [mpv](https://github.com/mpv-player/mpv) (`keremlin/mpv`) adding two
offline-first features, both as **builtin Lua scripts**, both driven from the
context menu (right-click the window):

| Feature | Script | Manual |
| --- | --- | --- |
| Offline subtitles via whisper.cpp | `player/lua/transcribe.lua` | `DOCS/man/transcribe.rst` |
| Podcast / RSS reader | `player/lua/rss.lua` | `DOCS/man/rss.rst` |

Plus a replaced application icon and a bitmap idle logo (`player/lua/osc.lua`).
Both scripts persist settings to `script-opts/<name>.conf`.

## Branches

- `master` — `transcribe` is merged into it
- `changelogo` — icon and idle-logo work, sits on `master`
- `rss` — podcast reader, **stacked on `changelogo`**, so its diff against
  `master` also contains the logo commits

> `master` tracks the **`upstream`** remote (mpv-player/mpv), not `origin`.
> A bare `git push` from `master` aims at the real mpv project. Always push by
> name: `git push origin <branch>`.

## Build in one minute

Only Docker Desktop and git are required — no compiler or SDK on the host.

```bash
docker build -t mpv-winbuild -f ci/docker/Dockerfile ci/docker
docker volume create mpv-build
```

```powershell
docker run --rm -v mpv-build:/build `
    -v "C:\path\to\mpv:/src:ro" `
    -v "C:\path\to\output:/out" `
    -v "C:\path\to\mpv\ci\docker\build-windows.sh:/build.sh:ro" `
    mpv-winbuild bash -c "tr -d '\r' < /build.sh > /tmp/b.sh && bash /tmp/b.sh"
```

First build 30-60 minutes, later builds about a minute. Use PowerShell, not Git
Bash — MSYS rewrites the container-side `/src/...` paths. Details and the bash
form: `DOCS/compile-windows.md` and section 2 of the fork reference.

## The three things that waste a build cycle

1. **Commit before you build.** The build script runs `git checkout -f -- .`
   inside the container, which reverts uncommitted changes to *tracked* files.
   Untracked new files survive — so a new script can build while its
   integration points silently revert.
2. **A new builtin Lua script needs six edits**, and the one in `player/lua.c`
   is the easy one to miss: it builds clean and fails at runtime with
   `module '@foo.lua' not found`. Full list in fork reference §3.2.
3. **Verify in the built binary, not in review.** Two real bugs here were
   invisible until the exe ran. Harnesses in fork reference §5.

## Known limitations

whisper hallucinates over silence; the 16x16 icon is an illegible downscale; the
idle logo is fixed-resolution and lives in `portable_config`; SRV3/WebVTT
subtitles cannot be rendered because subrandr is disabled for cross-compiling.
