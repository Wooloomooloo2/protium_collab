#!/bin/bash
#
# Run a Windows game that Mac Steam installed, under the macOS Proton build, the way Steam Play
# runs one through Proton on Linux.
#
#   macos/steamplay-run.sh <app id> [game arguments...]
#
# Mac Steam downloads a Windows build when its download platform is forced (in its console:
# @sSteamCmdForcePlatformType windows, then app_install <app id>), but it neither shows the
# Steam Play settings nor launches a compatibility tool on macOS. This script does the launch:
# it finds the game through Steam's library folders and the app's manifest, gives it a prefix
# in <library>/steamapps/compatdata/<app id>/pfx as Proton does, puts Valve's Windows client
# DLLs where steam_api looks for them, and starts the game through Proton's steam.exe, so
# that lsteamclient connects it to the running Mac Steam (login, ownership, stats and
# playtime; not the overlay, which Steam would have to inject into the game's process).
#
# Environment overrides:
#   WINE_INSTALL    the bundle (default: Protium.app's Contents/SharedSupport/runtime when this
#                   script is the app's copy, else ~/projects/proton-macos-build/install-aarch64)
#   PROTIUM_PYTHON  the Python that runs macos/steamplay (default: Protium.app's own when this
#                   script is the app's copy, else python3 from PATH)
#   STEAM_ROOT      Mac Steam's data folder (default ~/Library/Application Support/Steam)
#   WIN_STEAM_DLLS  a folder with Valve's Windows steamclient.dll and steamclient64.dll, which
#                   Mac Steam does not ship (Linux Steam has them in legacycompat/); copy them from
#                   the top folder of a Windows Steam install (default ~/Library/Application
#                   Support/SteamPlay/steamclient-windows)
#   GAME_EXE        the executable, relative to the install folder or as a full path, when the
#                   largest .exe in its top folder is not the game (macos/steamplay-launch gives
#                   the one Steam chose)
#   STEAMPLAY_LOG   where Wine's output goes (default <prefix>/../steamplay-run.log; the run
#                   before keeps its own as steamplay-run.prev.log)
#   WINEDEBUG       Wine's debug channels (default +loaddll,+msgbox)
#   PROTON_NO_FSYNC 1 to have every wait for, and change to, an event, semaphore or mutex go to
#                   the wineserver again. By default they are kept in shared memory
#                   (WINEFSYNC=1), as Proton does on Linux.
#   WINE_FSYNC_STATS  seconds between lines in the log that say how each process slept and
#                   what it woke; WINE_FSYNC_PARANOID=1 reports a wake-up that did not arrive
#   FEX_DISKCACHE   0 to have FEX translate a game's x86 code afresh at every start. By default
#                   (1) it keeps the translated code in the prefix and reads it back the next
#                   time, which shortens starts and loads after the first.
#   FEX_HARDWARE_TSO_OFF  for which calls into native code a thread gives up the processor's
#                   x86 memory ordering: "all" (the default), "syscall", "unix" or "none".
#                   Giving it up costs two kernel traps for each such call; keeping it makes
#                   the native code of that call slower where it mostly writes memory.
#                   macos/tests/cpu-bench.sh measures both.
#   MTL_HUD_ENABLED 1 to have macOS draw its Metal performance HUD over the game: frames per
#                   second and frame times, with lines DXMT adds. "macos/steamplay hud on" sets
#                   it for every game.
#
# For one game, these go in ~/Library/Application Support/SteamPlay/env.<app id> (under
# STEAMPLAY_HOME when that is set), one VAR=value a line, e.g.
#   WINEDEBUG=+loaddll,+msgbox,+system,+display
# It is read as shell and exported before anything of Wine's starts. Mac Steam does not take
# "VAR=value %command%" in a game's launch options for this tool: it fails to start the game
# with "OS Error 260".
#
# Steam's STEAM_COMPAT_CONFIG is read for nativevulkanloader. When a thread of the game waits a
# minute for a lock, samples of the game's processes are left as steamplay-run.hang.<pid>.txt.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# inside Protium.app this script is Contents/Resources/steamplay/steamplay-run.sh, next to the
# app's runtime and Python in Contents/SharedSupport
app_support="$SCRIPT_DIR/../../SharedSupport"
if [ -z "${WINE_INSTALL:-}" ] && [ -x "$app_support/runtime/bin/wine" ]; then
    WINE_INSTALL=$(cd "$app_support/runtime" && pwd)
fi
if [ -z "${PROTIUM_PYTHON:-}" ] && [ -x "$app_support/python/bin/python3" ]; then
    PROTIUM_PYTHON=$(cd "$app_support/python/bin" && pwd)/python3
fi
WINE_INSTALL=${WINE_INSTALL:-$HOME/projects/proton-macos-build/install-aarch64}
PROTIUM_PYTHON=${PROTIUM_PYTHON:-python3}
# the app's Python must not write compiled files into the app, which would break its signature
export PYTHONDONTWRITEBYTECODE=1
STEAM_ROOT=${STEAM_ROOT:-$HOME/Library/Application Support/Steam}
WIN_STEAM_DLLS=${WIN_STEAM_DLLS:-$HOME/Library/Application Support/SteamPlay/steamclient-windows}

die() { echo "steamplay-run.sh: error: $*" >&2; exit 1; }
log() { echo ":: $*" >&2; }

[ $# -ge 1 ] || die "usage: steamplay-run.sh <app id> [game arguments...]"
appid=$1; shift
[[ $appid =~ ^[0-9]+$ ]] || die "'$appid' is not an app id"
[ -x "$WINE_INSTALL/bin/wine" ] || die "no Wine in $WINE_INSTALL"
CLIENT_DIR="$STEAM_ROOT/Steam.AppBundle/Steam/Contents/MacOS"
[ -f "$CLIENT_DIR/steamclient.dylib" ] || die "no steamclient.dylib in $CLIENT_DIR"
pgrep -f steam_osx >/dev/null || die "Mac Steam is not running; start it and sign in first"

# The library that holds the app: the one whose steamapps has its manifest
library=
while IFS= read -r path; do
    [ -f "$path/steamapps/appmanifest_$appid.acf" ] && { library=$path; break; }
done < <(sed -n 's/^[[:space:]]*"path"[[:space:]]*"\(.*\)"$/\1/p' "$STEAM_ROOT/steamapps/libraryfolders.vdf")
[ -n "$library" ] || die "app $appid is not installed in any Steam library"
manifest="$library/steamapps/appmanifest_$appid.acf"
installdir=$(sed -n 's/^[[:space:]]*"installdir"[[:space:]]*"\(.*\)"$/\1/p' "$manifest")
game_dir="$library/steamapps/common/$installdir"
[ -d "$game_dir" ] || die "no install folder $game_dir"

if [ -n "${GAME_EXE:-}" ]; then
    case $GAME_EXE in /*) exe=$GAME_EXE ;; *) exe="$game_dir/$GAME_EXE" ;; esac
else
    exe=$(find "$game_dir" -maxdepth 1 -iname '*.exe' ! -iname 'UnityCrashHandler*' ! -iname '*setup*' \
          ! -iname 'unins*' -exec stat -f '%z %N' {} + | sort -rn | head -1 | cut -d' ' -f2-)
fi
[ -f "$exe" ] || die "no game executable in $game_dir (set GAME_EXE)"

# Steam Play names the game's compatibility data folder itself; it is the same one
compat=${STEAM_COMPAT_DATA_PATH:-"$library/steamapps/compatdata/$appid"}
prefix="$compat/pfx"
mkdir -p "$prefix"
export WINEPREFIX="$prefix"
export STEAM_COMPAT_DATA_PATH="$compat"
export STEAM_COMPAT_CLIENT_INSTALL_PATH="$CLIENT_DIR"
export STEAM_COMPAT_INSTALL_PATH="$game_dir"
export STEAM_COMPAT_LIBRARY_PATHS="$library/steamapps"
export SteamAppId=$appid SteamGameId=$appid SteamOverlayGameId=$appid
export WINEDLLOVERRIDES="${WINEDLLOVERRIDES:-mscoree,mshtml=}"
# macOS's Metal performance HUD, for every game while "macos/steamplay hud on" has left its file
if [ -z "${MTL_HUD_ENABLED:-}" ] && [ -e "${STEAMPLAY_HOME:-$HOME/Library/Application Support/SteamPlay}/hud" ]; then
    export MTL_HUD_ENABLED=1
fi
# GLib in lib/external would load GIO modules from Homebrew's folder, which on a player's Mac
# holds modules for whatever GLib Homebrew has; it gets a folder of the bundle's own instead
export GIO_MODULE_DIR=${GIO_MODULE_DIR:-$WINE_INSTALL/lib/external/gio/modules}
# One game's own settings, from env.<app id> next to that file (see the head of this file)
game_env="${STEAMPLAY_HOME:-$HOME/Library/Application Support/SteamPlay}/env.$appid"
if [ -f "$game_env" ]; then
    set -a
    . "$game_env"
    set +a
fi
# fsync: the wineserver decides as it starts and the game's processes follow it, so this is set
# before anything of Wine's runs here. A server that an earlier run left in the prefix keeps
# what it started with.
if [ "${PROTON_NO_FSYNC:-0}" = 1 ]; then
    export WINEFSYNC=0
else
    export WINEFSYNC="${WINEFSYNC:-1}"
fi
# FEX's cache of translated code. Without the second setting a 32-bit and a 64-bit process of
# one game delete each other's files, as each takes the other's for stale.
export FEX_DISKCACHE="${FEX_DISKCACHE:-1}"
export FEX_DISKCACHEPRUNESTALEENTRIES="${FEX_DISKCACHEPRUNESTALEENTRIES:-0}"
unset VK_DRIVER_FILES VK_ICD_FILENAMES VK_ADD_DRIVER_FILES PROTON_DISABLE_LSTEAMCLIENT

if [ ! -f "$prefix/system.reg" ]; then
    log "creating the prefix in $prefix"
    "$WINE_INSTALL/bin/wine" wineboot -u >/dev/null 2>&1 || die "wineboot failed in $prefix"
fi
# Steam puts a game's cloud saves for its Documents folder in users/steamuser/My Documents, while
# Wine and the game call that folder Documents; with two folders the game found none of its saves.
# "My Documents" is made a link to Documents, so that both names are the one folder. Steam syncs
# before the game starts, often before the prefix is made, so a real folder of that name may be
# there already: its files go into Documents, and where Documents has a different file of the same
# name, the newer one stays there. The older copies are kept in "My Documents (older copies)".
link_my_documents() {
    local user_dir=$1 old new rel f kept
    old="$user_dir/My Documents"
    new="$user_dir/Documents"
    [ -L "$old" ] && return 0
    mkdir -p "$new"
    if [ -d "$old" ]; then
        while IFS= read -r -d '' f; do
            rel=${f#"$old"/}
            mkdir -p "$(dirname "$new/$rel")"
            if [ ! -e "$new/$rel" ] && [ ! -L "$new/$rel" ]; then
                mv "$f" "$new/$rel"
            elif cmp -s "$f" "$new/$rel"; then
                rm -f "$f"
            elif [ "$f" -nt "$new/$rel" ]; then
                # swap them: the newer into Documents, the older left behind with the old folder
                mv "$new/$rel" "$f.protium-swap"
                mv "$f" "$new/$rel"
                mv "$f.protium-swap" "$f"
            fi
        done < <(find "$old" \( -type f -o -type l \) -print0)
        if [ -z "$(find "$old" \( -type f -o -type l \) -print -quit)" ]; then
            rm -rf "$old"
        else
            kept="$user_dir/My Documents (older copies)"
            [ -e "$kept" ] && kept="$kept $(date +%Y%m%d-%H%M%S)"
            mv "$old" "$kept"
            log "older copies of files in My Documents are kept in $kept"
        fi
    fi
    ln -s Documents "$old"
}
link_my_documents "$prefix/drive_c/users/steamuser"
# Proton's wine.inf registers its fonts by file name (arial.ttf, tahoma.ttf, ...), and Proton's
# script links the files into the prefix's Fonts folder. DirectWrite lists what it finds there
# and nothing else: with the folder empty it had no Tahoma, and the browser of the Rockstar Games
# Launcher asked for one in circles until its stack was gone. Wine's own fonts go in as Proton
# puts them; where Proton has fonts of its own making under Microsoft's names, the Mac's own
# copies of Microsoft's fonts stand in. (The East Asian and Indic ones have no such stand-in.)
fonts_dir="$prefix/drive_c/windows/Fonts"
mkdir -p "$fonts_dir"
for font in "$WINE_INSTALL"/share/wine/fonts/*.tt[fc]; do
    [ -e "$font" ] && ln -sfn "$font" "$fonts_dir/$(basename "$font")"
done
while IFS='|' read -r font mac_font; do
    [ -f "/System/Library/Fonts/Supplemental/$mac_font" ] \
        && ln -sfn "/System/Library/Fonts/Supplemental/$mac_font" "$fonts_dir/$font"
done <<'FONTS'
arial.ttf|Arial.ttf
arialbd.ttf|Arial Bold.ttf
cour.ttf|Courier New.ttf
courbd.ttf|Courier New Bold.ttf
micross.ttf|Microsoft Sans Serif.ttf
tahoma.ttf|Tahoma.ttf
tahomabd.ttf|Tahoma Bold.ttf
times.ttf|Times New Roman.ttf
wingdings.ttf|Wingdings.ttf
FONTS
# What the game's install scripts ask for, once per prefix: Steam for Windows and for Linux run
# them before a game's first start, Mac Steam does not (see "installscript" in macos/steamplay).
# Red Dead Redemption 2's installs the Vulkan runtime that the option below is about.
STEAMPLAY_WINE="$WINE_INSTALL/bin/wine" WINEDEBUG=-all "$PROTIUM_PYTHON" "$SCRIPT_DIR/steamplay" installscript "$appid" \
    || log "app $appid: an install script step did not finish (macos/steamplay installscript $appid --again repeats them)"
# Steam's own compatibility options for the game, which Proton's script takes the same way.
# nativevulkanloader: the game is to load Khronos's vulkan-1.dll, which its own installer puts
# into the prefix (Red Dead Redemption 2; wine.inf says the same for RDR2.exe): only that loader
# takes the layer Rockstar's overlay comes in, and without the overlay the game never finished
# loading a story. Where a prefix has only Wine's loader all the same, that one has to do.
case ",${STEAM_COMPAT_CONFIG:-}," in
    *,nativevulkanloader,*)
        vulkan_dll="$prefix/drive_c/windows/system32/vulkan-1.dll"
        if [ -f "$vulkan_dll" ] && ! head -c 128 "$vulkan_dll" | grep -qa -e 'Wine builtin DLL' -e 'Wine placeholder DLL'; then
            WINEDLLOVERRIDES="$WINEDLLOVERRIDES;vulkan-1=n"
        else
            WINEDLLOVERRIDES="$WINEDLLOVERRIDES;vulkan-1=b"
        fi ;;
esac
# steam_api loads Valve's Windows client DLLs from Steam's folder in the prefix, and ntdll
# points their exports at lsteamclient
steam_in_pfx="$prefix/drive_c/Program Files (x86)/Steam"
mkdir -p "$steam_in_pfx"
for dll in steamclient.dll steamclient64.dll; do
    [ -f "$steam_in_pfx/$dll" ] && continue
    [ -f "$WIN_STEAM_DLLS/$dll" ] || die "no $dll in $WIN_STEAM_DLLS: copy Valve's Windows steamclient.dll and" \
        "steamclient64.dll there from the top folder of a Windows Steam install, or set WIN_STEAM_DLLS"
    cp "$WIN_STEAM_DLLS/$dll" "$steam_in_pfx/$dll"
done
# and Valve's overlay DLLs, which steam_api loads from there as well. The overlay itself does not
# draw (ntdll points these at lsteamclient too), but a game may look for the module: Call of Duty:
# Modern Warfare Remastered ends itself, without a word, when it is not in the process
for dll in GameOverlayRenderer.dll GameOverlayRenderer64.dll; do
    [ -f "$steam_in_pfx/$dll" ] && continue
    if [ -f "$WIN_STEAM_DLLS/$dll" ]; then
        cp "$WIN_STEAM_DLLS/$dll" "$steam_in_pfx/$dll"
    else
        echo "steamplay-run: no $dll in $WIN_STEAM_DLLS (\"steamplay steamclient --again\" fetches it); some games need it" >&2
    fi
done

logfile=${STEAMPLAY_LOG:-$compat/steamplay-run.log}
# the run before this one keeps its log, since the next start is often how a crash gets looked at
[ -f "$logfile" ] && mv -f "$logfile" "${logfile%.log}.prev.log"
# where each module is loaded, so that the PE addresses of a crash can be given their DLLs, and
# what a message box says, which is often all a game tells of what it could not do
export WINEDEBUG="${WINEDEBUG:-+loaddll,+msgbox}"
# and where ntdll leaves the stack of a thread that ran out of it (wine-stack.<pid>.<tid>.bin)
export WINE_STACK_DUMP_DIR="${WINE_STACK_DUMP_DIR:-$compat}"
log "app $appid: $exe (log: $logfile)"
# A game that hangs says nothing of where. Wine does say when a thread has waited a minute for a
# lock that another one holds: at that, where every thread of the game's processes is gets
# saved next to the log (macOS's sample), once per run. The watcher goes when this process,
# which becomes Wine's, does.
hang=${logfile%.log}.hang
rm -f "$hang".*.txt
(
    game_dir_win="Z:${game_dir//\//\\}\\"
    while sleep 2 && kill -0 $$ 2>/dev/null; do
        grep -qa 'RtlpWaitForCriticalSection.*wait timed out' "$logfile" 2>/dev/null || continue
        for pid in $(ps -axo pid=,command= | grep -F -- "$game_dir_win" | grep -v ' grep ' | awk '{print $1}'); do
            /usr/bin/sample "$pid" 3 -file "$hang.$pid.txt" &
        done
        wait
        exit 0
    done
) </dev/null >/dev/null 2>&1 &
# When the session has ended, how long it ran and how it ended goes into SteamPlay's results,
# which "macos/steamplay discover" judges games by. Like the watcher above, this waits for this
# process, which becomes Wine's.
started=$(date +%s)
# One notice when a newer Protium is out, once per version; the game does not wait for it
("$PROTIUM_PYTHON" "$SCRIPT_DIR/steamplay" version --notify) </dev/null >/dev/null 2>&1 &
(
    while kill -0 $$ 2>/dev/null; do sleep 2; done
    "$PROTIUM_PYTHON" "$SCRIPT_DIR/steamplay" record "$appid" "$started" "$logfile"
) </dev/null >/dev/null 2>&1 &
cd "$(dirname "$exe")"
# steam.exe starts the game by its full Windows path (Wine's Z: drive is the host's /). It is
# named by its own full path too, as Proton does: by its bare name Wine has start.exe look for
# it and wait for it, and steam.exe, which ends when no other program is left, waits for
# start.exe in turn. Nothing of the session then ever ends, and Steam goes on showing the game
# as running after it was quit.
exec "$WINE_INSTALL/bin/wine" 'c:\windows\system32\steam.exe' "Z:${exe//\//\\}" "$@" >"$logfile" 2>&1 </dev/null
