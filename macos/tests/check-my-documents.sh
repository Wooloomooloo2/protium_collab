#!/bin/bash
#
# Checks how macos/steamplay-run.sh joins a prefix's "My Documents", where Steam puts cloud saves,
# to its Documents, where the game looks for them (link_my_documents).
#
#   macos/tests/check-my-documents.sh
#
# Each case builds a user folder in a temporary folder and runs the function on it:
#   fresh     no My Documents: it becomes a link to Documents
#   linked    My Documents is a link already: nothing is changed
#   merge     a real My Documents with saves: they move into Documents (a file that is the same in
#             both is not kept twice), and the link is made
#   newer     a file in both: the newer copy is in Documents, the older one in "(older copies)"
#   again     a second run changes nothing
# It needs no Wine and no Steam. Exit status 1 when one failed.

set -u
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
FAILED=0
pass() { echo "PASS  $1: $2"; }
fail() { echo "FAIL  $1: $2"; FAILED=1; }
log() { :; }
eval "$(sed -n '/^link_my_documents() {$/,/^}$/p' "$SCRIPT_DIR/../steamplay-run.sh")"
declare -F link_my_documents >/dev/null || { echo "check-my-documents.sh: no link_my_documents in steamplay-run.sh" >&2; exit 2; }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

u=$T/fresh; mkdir -p "$u/Documents"
link_my_documents "$u"
[ "$(readlink "$u/My Documents")" = Documents ] && pass fresh "My Documents is a link to Documents" \
    || fail fresh "My Documents is not a link to Documents"

u=$T/linked; mkdir -p "$u/Elsewhere"; ln -s Elsewhere "$u/My Documents"
link_my_documents "$u"
[ "$(readlink "$u/My Documents")" = Elsewhere ] && pass linked "an existing link is left as it was" \
    || fail linked "an existing link was changed"

u=$T/merge; mkdir -p "$u/Documents/Game" "$u/My Documents/Game/123"
echo save > "$u/My Documents/Game/123/save0.dat"
echo same > "$u/My Documents/Game/123/save1.dat"; mkdir -p "$u/Documents/Game/123"
echo same > "$u/Documents/Game/123/save1.dat"
echo log > "$u/Documents/Game/game.log"
link_my_documents "$u"
if [ "$(cat "$u/Documents/Game/123/save0.dat" 2>/dev/null)" = save ] && [ -f "$u/Documents/Game/game.log" ] \
    && [ -L "$u/My Documents" ] && [ ! -e "$u/My Documents (older copies)" ]; then
    pass merge "the saves are in Documents, My Documents is a link, nothing left over"
else
    fail merge "$(cd "$u" && find . | sort | tr '\n' ' ')"
fi

u=$T/newer; mkdir -p "$u/Documents/Game" "$u/My Documents/Game"
echo cloud-new > "$u/My Documents/Game/a.dat"; touch -t 202611240900 "$u/My Documents/Game/a.dat"
echo local-old > "$u/Documents/Game/a.dat";    touch -t 202611230900 "$u/Documents/Game/a.dat"
echo cloud-old > "$u/My Documents/Game/b.dat"; touch -t 202611230900 "$u/My Documents/Game/b.dat"
echo local-new > "$u/Documents/Game/b.dat";    touch -t 202611240900 "$u/Documents/Game/b.dat"
link_my_documents "$u"
k="$u/My Documents (older copies)"
if [ "$(cat "$u/Documents/Game/a.dat")" = cloud-new ] && [ "$(cat "$u/Documents/Game/b.dat")" = local-new ] \
    && [ "$(cat "$k/Game/a.dat" 2>/dev/null)" = local-old ] && [ "$(cat "$k/Game/b.dat" 2>/dev/null)" = cloud-old ] \
    && [ -L "$u/My Documents" ]; then
    pass newer "the newer copies are in Documents, the older ones in (older copies)"
else
    fail newer "$(cd "$u" && find . -type f | sort | while read -r f; do printf '%s=%s ' "$f" "$(cat "$f")"; done)"
fi

before=$(cd "$u" && find . | sort)
link_my_documents "$u"
[ "$(cd "$u" && find . | sort)" = "$before" ] && pass again "a second run changes nothing" \
    || fail again "a second run changed the folder"

exit $FAILED
