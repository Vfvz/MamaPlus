#!/bin/sh
# Builds the release zip for MamaPlus, or checks that the TOC and the folder agree.
#
#   sh tools/package.sh           check, then build <repo>/dist/MamaPlus-<version>.zip
#   sh tools/package.sh --check   check only (no zip); exit 1 if anything is wrong
#
# Works from any directory: it finds the addon folder from its own path
# (tools/.. is the addon folder, and its parent is the repo root that holds dist/).
#
# The zip has one top-level MamaPlus/ folder with MamaPlus.toc, every file the
# TOC lists (plus files that a listed .xml pulls in with <Script file> or
# <Include file>), Bindings.xml if present, README.md and TESTING.md. Nothing else.
#
# The check fails when:
#   - the TOC has no "## Interface:" line with 16001 (alone or in a comma list),
#   - the TOC has no "## Version:" or the version has characters unsafe in a file name,
#   - a TOC-listed file is missing, listed twice, or points outside the addon folder,
#   - Bindings.xml is listed in the TOC (the client loads it on its own),
#   - a *.lua or *.xml in the addon folder (outside tests/, tools/ and dot-folders)
#     is neither listed nor Bindings.xml, so it would silently not load or not ship,
#   - README.md or TESTING.md is missing.
#
# Uses "zip" when installed, else python3's zipfile. MP_ZIP_TOOL=zip|python3
# forces one (used to test the fallback).
set -eu

ADDON_NAME=MamaPlus

usage() {
    sed -n '2,5p' "$0" | sed 's/^# \{0,1\}//'
}

MODE=build
case "${1:-}" in
    "") ;;
    --check) MODE=check ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'package.sh: unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
esac
if [ "$#" -gt 1 ]; then
    printf 'package.sh: too many arguments\n' >&2; usage >&2; exit 2
fi

case "$0" in
    */*) SCRIPT_DIR=$(dirname "$0") ;;
    *) SCRIPT_DIR=. ;;
esac
ADDON_DIR=$(cd "$SCRIPT_DIR/.." && pwd -P)
REPO_ROOT=$(cd "$ADDON_DIR/.." && pwd -P)
DIST_DIR="$REPO_ROOT/dist"
TOC="$ADDON_DIR/$ADDON_NAME.toc"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/twpkg.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

PROBLEMS="$WORK/problems"
LISTED="$WORK/listed"
: > "$PROBLEMS"
: > "$LISTED"

problem() {
    printf '%s\n' "$*" >> "$PROBLEMS"
}

# Path cleanup shared by the TOC and XML parsers: backslashes to slashes, drop
# "." and empty segments, fold "..". A path that climbs out of the addon folder
# keeps a leading "../" so the caller can report it.
AWK_NORM='
function norm(p,    n, parts, out, outn, i, s) {
    gsub(/\\/, "/", p)
    n = split(p, parts, "/")
    outn = 0
    for (i = 1; i <= n; i++) {
        if (parts[i] == "" || parts[i] == ".") continue
        if (parts[i] == "..") {
            if (outn > 0) { outn--; continue }
            return "../" p
        }
        out[++outn] = parts[i]
    }
    s = ""
    for (i = 1; i <= outn; i++) s = s (i > 1 ? "/" : "") out[i]
    return s
}
'

# ---------------------------------------------------------------- TOC
if [ ! -f "$TOC" ]; then
    printf 'package.sh: %s not found\n' "$TOC" >&2
    exit 1
fi

# One clean copy of the TOC: no CR, no UTF-8 byte order mark.
BOM=$(printf '\357\273\277')
LC_ALL=C tr -d '\r' < "$TOC" | LC_ALL=C sed "1s/^$BOM//" > "$WORK/toc"

INTERFACES=$(sed -n 's/^##[[:space:]]*Interface[[:space:]]*:[[:space:]]*//p' "$WORK/toc")
if ! printf '%s\n' "$INTERFACES" | tr ',' '\n' | tr -d ' \t' | grep -qx '16001'; then
    if [ -n "$INTERFACES" ]; then
        problem "$ADDON_NAME.toc: '## Interface:' does not include 16001 (found: $(printf '%s' "$INTERFACES" | tr '\n' ' '))"
    else
        problem "$ADDON_NAME.toc: no '## Interface: 16001' line"
    fi
fi

VERSION=$(sed -n 's/^##[[:space:]]*Version[[:space:]]*:[[:space:]]*//p' "$WORK/toc" | sed -n '1s/[[:space:]]*$//p')
if [ -z "$VERSION" ]; then
    problem "$ADDON_NAME.toc: no '## Version:' line (or it is empty)"
else
    case "$VERSION" in
        *[!A-Za-z0-9._+-]*)
            problem "$ADDON_NAME.toc: version '$VERSION' has characters that are unsafe in a file name (use letters, digits, . _ + -)" ;;
    esac
fi

# File lines: not "#"-comments or "##" directives, trimmed, with any trailing
# "[AllowLoadGameType ...]"-style gate removed, path normalised.
LC_ALL=C awk "$AWK_NORM"'
    /^[ \t]*#/ { next }
    {
        line = $0
        sub(/^[ \t]+/, "", line)
        sub(/[ \t]+\[.*$/, "", line)
        sub(/[ \t]+$/, "", line)
        if (line == "") next
        print norm(line)
    }
' "$WORK/toc" > "$WORK/toc_files"

while IFS= read -r f; do
    case "$f" in
        ../*|"")
            problem "$ADDON_NAME.toc lists a path outside the addon folder: $f"
            continue ;;
    esac
    if grep -Fxq -- "$f" "$LISTED"; then
        problem "$ADDON_NAME.toc lists $f twice"
        continue
    fi
    if [ "$f" = "Bindings.xml" ]; then
        problem "$ADDON_NAME.toc lists Bindings.xml: the client loads it on its own, remove it from the TOC"
        continue
    fi
    printf '%s\n' "$f" >> "$LISTED"
done < "$WORK/toc_files"

# ---------------------------------------------------------------- XML includes
# A listed .xml may load more files with <Script file="..."/> or
# <Include file="..."/>, relative to the .xml's own folder. Those files load and
# must ship too. $LISTED grows while it is walked, so nested includes resolve.
i=1
while :; do
    f=$(sed -n "${i}p" "$LISTED")
    [ -n "$f" ] || break
    i=$((i + 1))
    case "$f" in
        *.xml|*.XML) ;;
        *) continue ;;
    esac
    [ -f "$ADDON_DIR/$f" ] || continue
    case "$f" in
        */*) base=${f%/*}/ ;;
        *) base= ;;
    esac
    LC_ALL=C awk -v base="$base" "$AWK_NORM"'
        { sub(/\r$/, ""); buf = buf $0 " " }
        END {
            rest = buf; buf = ""
            while ((s = index(rest, "<!--")) > 0) {
                buf = buf substr(rest, 1, s - 1)
                rest = substr(rest, s + 4)
                e = index(rest, "-->")
                if (e == 0) { rest = ""; break }
                rest = substr(rest, e + 3)
            }
            buf = buf rest
            while (match(buf, /<(Script|Include)[ \t]([^>]*[ \t])?file[ \t]*=[ \t]*"[^"]*"/)) {
                tag = substr(buf, RSTART, RLENGTH)
                buf = substr(buf, RSTART + RLENGTH)
                sub(/^.*[ \t]file[ \t]*=[ \t]*"/, "", tag)
                sub(/"$/, "", tag)
                print norm(base tag)
            }
        }
    ' "$ADDON_DIR/$f" > "$WORK/refs"
    while IFS= read -r ref; do
        case "$ref" in
            ../*|"")
                problem "$f loads a path outside the addon folder: $ref"
                continue ;;
        esac
        grep -Fxq -- "$ref" "$LISTED" || printf '%s\n' "$ref" >> "$LISTED"
    done < "$WORK/refs"
done

# ---------------------------------------------------------------- existence
while IFS= read -r f; do
    [ -f "$ADDON_DIR/$f" ] || problem "listed file is missing: $f"
done < "$LISTED"

for f in README.md TESTING.md; do
    [ -f "$ADDON_DIR/$f" ] || problem "$f is missing (it ships in the zip)"
done

# ---------------------------------------------------------------- unlisted
# Every .lua/.xml outside tests/, tools/ and dot-folders must load, or it is
# either dead code or a file someone forgot to add to the TOC.
(
    cd "$ADDON_DIR"
    find . \( -path ./tests -o -path ./tools -o \( -name '.?*' -type d \) \) -prune \
        -o -type f \( -name '*.lua' -o -name '*.xml' \) -print
) | sed 's|^\./||' | LC_ALL=C sort > "$WORK/found"

while IFS= read -r f; do
    [ "$f" = "Bindings.xml" ] && continue
    grep -Fxq -- "$f" "$LISTED" || problem "$f is not listed in $ADDON_NAME.toc (add it, or move it out of the addon folder)"
done < "$WORK/found"

# ---------------------------------------------------------------- report
NPROB=$(wc -l < "$PROBLEMS" | tr -d ' ')
if [ "$NPROB" -gt 0 ]; then
    printf 'package.sh: %s problem(s) in %s:\n' "$NPROB" "$ADDON_DIR" >&2
    sed 's/^/  - /' "$PROBLEMS" >&2
    exit 1
fi

NLISTED=$(wc -l < "$LISTED" | tr -d ' ')
if [ "$MODE" = check ]; then
    printf 'package.sh: OK, %s %s, %s file(s) load from the TOC\n' "$ADDON_NAME" "$VERSION" "$NLISTED"
    exit 0
fi

# ---------------------------------------------------------------- build
STAGE="$WORK/stage"
mkdir -p "$STAGE/$ADDON_NAME"

ship() {
    case "$1" in
        */*) mkdir -p "$STAGE/$ADDON_NAME/${1%/*}" ;;
    esac
    cp "$ADDON_DIR/$1" "$STAGE/$ADDON_NAME/$1"
}

ship "$ADDON_NAME.toc"
while IFS= read -r f; do
    ship "$f"
done < "$LISTED"
[ -f "$ADDON_DIR/Bindings.xml" ] && ship Bindings.xml
ship README.md
ship TESTING.md

ZIP_NAME="$ADDON_NAME-$VERSION.zip"
ZIP_TMP="$WORK/$ZIP_NAME"

TOOL=${MP_ZIP_TOOL:-}
if [ -z "$TOOL" ]; then
    if command -v zip >/dev/null 2>&1; then
        TOOL=zip
    elif command -v python3 >/dev/null 2>&1; then
        TOOL=python3
    else
        printf 'package.sh: neither zip nor python3 is installed\n' >&2
        exit 2
    fi
fi

case "$TOOL" in
    zip)
        # Sorted names (directories included) give the same entry order every run.
        ( cd "$STAGE" && find "$ADDON_NAME" -print | LC_ALL=C sort | zip -X -q -@ "$ZIP_TMP" )
        ;;
    python3)
        python3 - "$ZIP_TMP" "$STAGE" "$ADDON_NAME" <<'PY'
import os
import sys
import zipfile

out, root, top = sys.argv[1:4]
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as zf:
    for dirpath, dirnames, filenames in os.walk(os.path.join(root, top)):
        dirnames.sort()
        rel = os.path.relpath(dirpath, root).replace(os.sep, "/")
        zf.write(dirpath, rel + "/")
        for name in sorted(filenames):
            zf.write(os.path.join(dirpath, name), rel + "/" + name)
PY
        ;;
    *)
        printf 'package.sh: MP_ZIP_TOOL must be zip or python3, not %s\n' "$TOOL" >&2
        exit 2
        ;;
esac

mkdir -p "$DIST_DIR"
rm -f "$DIST_DIR/$ZIP_NAME"
mv "$ZIP_TMP" "$DIST_DIR/$ZIP_NAME"
NFILES=$(cd "$STAGE" && find "$ADDON_NAME" -type f | wc -l | tr -d ' ')
printf 'package.sh: built %s (%s files, %s)\n' "$DIST_DIR/$ZIP_NAME" "$NFILES" "$TOOL"
