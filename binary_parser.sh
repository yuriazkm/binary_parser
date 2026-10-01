#!/bin/bash
# macOS / Xcode Command Line Tools; compatible with system Bash 3.2.
set -euo pipefail
export LC_ALL=C
fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }
[[ $# -eq 2 ]] || fail "Usage: $0 <ipa_path> <output_path>"
[[ -f "$1" ]] || fail "IPA not found: $1"
[[ -n "$2" ]] || fail 'Output directory must not be empty'
for tool in unzip find file strings sort awk otool nm shasum plutil mktemp; do
    command -v "$tool" >/dev/null || fail "Required tool missing: $tool (macOS with Xcode Command Line Tools required)"
done
[[ -x /usr/libexec/PlistBuddy ]] || fail 'PlistBuddy is required'
IPA_PATH="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
mkdir -p "$2"
OUTPUT_PATH=$(cd "$2" && pwd)
# Refuse stale results instead of mixing artifacts from different builds.
[[ -z "$(find "$OUTPUT_PATH" -mindepth 1 -maxdepth 1 -print -quit)" ]] || fail 'Output directory must be empty; use a new directory for each run'
TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/ipa-parser.XXXXXXXX")
trap 'rm -rf "$TEMP_DIR"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir "$TEMP_DIR/extract" "$TEMP_DIR/result"
RESULT="$TEMP_DIR/result"
unzip -q "$IPA_PATH" -d "$TEMP_DIR/extract" || fail 'Cannot extract IPA'
[[ -d "$TEMP_DIR/extract/Payload" ]] || fail 'Payload directory missing'
APP_PATH=''
for candidate in "$TEMP_DIR/extract/Payload/"*.app; do
    [[ -d "$candidate" ]] || continue
    [[ -z "$APP_PATH" ]] || fail 'Multiple top-level applications in IPA; ambiguous input'
    APP_PATH="$candidate"
done
[[ -n "$APP_PATH" ]] || fail 'No application in Payload'
# Do not follow archive links to files outside the extracted application.
[[ -z "$(find "$TEMP_DIR/extract" -type l -print -quit)" ]] || fail 'IPA contains symbolic links; supply a standard exported iOS IPA without symlinks'
cd "$APP_PATH"
[[ -f Info.plist ]] || fail 'Application Info.plist missing'
EXECUTABLE=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' Info.plist) || fail 'CFBundleExecutable missing'
[[ -n "$EXECUTABLE" && "$EXECUTABLE" != */* && "$EXECUTABLE" != '.' && "$EXECUTABLE" != '..' ]] || fail 'Invalid CFBundleExecutable'
MAIN_BINARY="./$EXECUTABLE"
is_macho() {
    local description
    description=$(file -b "$1") || return 1
    [[ "$description" == *Mach-O* ]]
}
[[ -f "$MAIN_BINARY" ]] && is_macho "$MAIN_BINARY" || fail "Application executable is missing or not Mach-O: $EXECUTABLE"
# Preserve the historical hash target for Flutter and Unity.
PRIMARY_BINARY="$MAIN_BINARY"
APP_TYPE='native / other iOS'
if [[ -f ./Frameworks/App.framework/App ]] && is_macho ./Frameworks/App.framework/App; then
    PRIMARY_BINARY='./Frameworks/App.framework/App'
    APP_TYPE='flutter'
elif [[ -f ./Frameworks/UnityFramework.framework/UnityFramework ]] && is_macho ./Frameworks/UnityFramework.framework/UnityFramework; then
    PRIMARY_BINARY='./Frameworks/UnityFramework.framework/UnityFramework'
    APP_TYPE='unity'
fi
printf 'Application: %s; type: %s; hash target: %s\n' "$EXECUTABLE" "$APP_TYPE" "$PRIMARY_BINARY"
# Find actual Mach-O files, regardless of filename or executable permission bits.
# Includes embedded frameworks, dylibs, extensions, and watch applications.
find . -type f -print0 > "$TEMP_DIR/files"
: > "$TEMP_DIR/strings"
while IFS= read -r -d '' binary; do
    if is_macho "$binary"; then
        strings "$binary" >> "$TEMP_DIR/strings" || fail "strings failed: $binary"
    fi
done < "$TEMP_DIR/files"
awk 'length>=1 && /[^ -~]/==0' "$TEMP_DIR/strings" | sort -u > "$RESULT/strings.txt"
# Keep the original server-facing meaning of these three reports.
WORKING_BINARY="$PRIMARY_BINARY"
[[ "$APP_TYPE" != flutter ]] || WORKING_BINARY="$MAIN_BINARY"
otool -L "$WORKING_BINARY" | sort > "$RESULT/frameworks.txt"
nm -u "$WORKING_BINARY" | sort > "$RESULT/external_symbols.txt"
otool -oV "$WORKING_BINARY" > "$RESULT/objc.txt"
shasum -a 256 "$PRIMARY_BINARY" | awk '{print $1}' > "$RESULT/binary_hash.txt"
plutil -p Info.plist > "$RESULT/info_plist.txt"
: > "$TEMP_DIR/assets"
while IFS= read -r -d '' asset; do
    case "$asset" in
        *.[pP][nN][gG]|*.[jJ][pP][gG]|*.[jJ][pP][eE][gG]|*.[gG][iI][fF]|*.[wW][eE][bB][pP]|*.[pP][dD][fF])
            shasum -a 256 "$asset" | awk '{print $1}' >> "$TEMP_DIR/assets" ;;
    esac
done < "$TEMP_DIR/files"
sort -u "$TEMP_DIR/assets" > "$RESULT/assets_hashes.txt"
# Publish only after every extraction command succeeds. Empty reports are valid
# for stripped binaries, applications without ObjC, or without loose images.
for artifact in "$RESULT/"*.txt; do
    cp "$artifact" "$OUTPUT_PATH/"
done
printf 'Extraction completed: %s\n' "$OUTPUT_PATH"
