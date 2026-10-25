#!/bin/bash
set -euo pipefail

# Package a locally built stl2step CLI with its non-system dylib closure.
# The result matches the macOS engine layout used by SolidOut:
#
#   stl2step
#   Frameworks/*.dylib
#
# Every non-system load command is rewritten to the bundle. The staged binary
# is smoked in an empty environment before the archive is written. Set
# CODESIGN_IDENTITY to use a Developer ID; otherwise the bundle is ad-hoc signed.
#
# Usage:
#   .github/scripts/package-engine-macos.sh <tag> [build-dir] [out-dir]

usage() {
    echo "usage: $0 <tag> [build-dir] [out-dir]" >&2
    exit 2
}

die() {
    echo "package-engine-macos: $*" >&2
    exit 1
}

say() {
    echo "package-engine-macos: $*"
}

[[ $# -ge 1 && $# -le 3 ]] || usage

tag=$1
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$script_dir/../.." && pwd)
build_dir=${2:-"$root/build-release"}
out_dir=${3:-"$root/dist/engine"}

[[ "$(uname -s)" == Darwin ]] || die "macOS is required"

case "$(uname -m)" in
    arm64)  platform=arm64 ;;
    x86_64) platform=x64 ;;
    *)      die "unsupported macOS architecture: $(uname -m)" ;;
esac

binary="$build_dir/stl2step"
[[ -x "$binary" ]] || die "no executable at $binary (pass the build directory)"

binary_file=$(file "$binary")
case "$platform:$binary_file" in
    arm64:*arm64*)   ;;
    x64:*x86_64*)    ;;
    *) die "binary architecture does not match host: $binary_file" ;;
esac

work=$(mktemp -d "${TMPDIR:-/tmp}/stl2step-package.XXXXXX")
trap 'rm -rf "$work"' EXIT

stage="$work/stl2step-engine-$tag-macos-$platform"
frameworks="$stage/Frameworks"
mkdir -p "$frameworks"
cp -p "$binary" "$stage/stl2step"

queue_file="$work/queue"
seen_file="$work/seen"
: > "$queue_file"
: > "$seen_file"
printf '%s\n' "$binary" > "$queue_file"

# Walk each currently external dependency and copy it into Frameworks. Homebrew
# OCCT libraries use @rpath for their sibling libraries; resolving that against
# the declaring library's directory keeps the package independent of brew.
while IFS= read -r current; do
    [[ -n "$current" ]] || continue

    otool -L "$current" | tail -n +2 | awk '{print $1}' |
    while IFS= read -r dependency; do
        [[ -n "$dependency" ]] || continue
        case "$dependency" in
            /usr/lib/*|/System/Library/*)
                continue
                ;;
            @loader_path/*)
                candidate="$(dirname "$current")/${dependency#@loader_path/}"
                ;;
            @rpath/*)
                candidate="$(dirname "$current")/${dependency#@rpath/}"
                ;;
            @executable_path/*)
                candidate="$stage/${dependency#@executable_path/}"
                ;;
            /*)
                candidate="$dependency"
                ;;
            *)
                candidate="$(dirname "$current")/$dependency"
                ;;
        esac

        [[ -f "$candidate" ]] || die "unresolved dependency $dependency (from $current)"
        candidate_dir=$(cd "$(dirname "$candidate")" && pwd -P)
        candidate="$candidate_dir/$(basename "$candidate")"
        [[ -f "$candidate" ]] || die "unresolved dependency $dependency (from $current)"

        if grep -Fqx "$candidate" "$seen_file"; then
            continue
        fi
        printf '%s\n' "$candidate" >> "$seen_file"
        printf '%s\n' "$candidate" >> "$queue_file"

        destination="$frameworks/$(basename "$candidate")"
        if [[ -e "$destination" ]]; then
            cmp -s "$candidate" "$destination" ||
                die "two dependencies share the basename $(basename "$candidate")"
        else
            cp -Lp "$candidate" "$destination"
            chmod u+w "$destination"
        fi
    done
done < "$queue_file"

# Rewrite the executable and every bundled dylib. install_name_tool invalidates
# existing signatures, so sign only after all load commands are final.
while IFS= read -r current; do
    if [[ "$current" == "$binary" ]]; then
        target="$stage/stl2step"
        prefix='@executable_path/Frameworks'
    else
        target="$frameworks/$(basename "$current")"
        prefix='@loader_path'
    fi

    otool -L "$current" | tail -n +2 | awk '{print $1}' |
    while IFS= read -r dependency; do
        [[ -n "$dependency" ]] || continue
        case "$dependency" in
            /usr/lib/*|/System/Library/*)
                continue
                ;;
        esac
        install_name_tool -change "$dependency" "$prefix/$(basename "$dependency")" "$target"
    done

    if [[ "$current" != "$binary" ]]; then
        install_name_tool -id "@rpath/$(basename "$target")" "$target"
    fi
done < "$queue_file"

while IFS= read -r current; do
    if [[ "$current" == "$binary" ]]; then
        target="$stage/stl2step"
    else
        target="$frameworks/$(basename "$current")"
    fi
    if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
        codesign --force --sign "$CODESIGN_IDENTITY" --options runtime \
            --timestamp "$target" >/dev/null
    else
        codesign --force --sign - --timestamp=none "$target" >/dev/null
    fi
done < "$queue_file"

if otool -L "$stage/stl2step" |
    tail -n +2 |
    grep -E '(^|[[:space:]])(/usr/local/|/opt/homebrew/|@rpath/)' >/dev/null; then
    die "staged executable still has a non-relocatable dependency"
fi
for library in "$frameworks"/*.dylib; do
    if otool -L "$library" |
        tail -n +3 |
        grep -E '(^|[[:space:]])(/usr/local/|/opt/homebrew/|@rpath/)' >/dev/null; then
        die "staged library $library still has a non-relocatable dependency"
    fi
done

codesign --verify --deep --strict "$stage/stl2step" >/dev/null

version_line=$(env -i PATH=/usr/bin:/bin "$stage/stl2step" --version)
[[ "$version_line" =~ ^stl2step[[:space:]](.+)$ ]] ||
    die "could not parse version from '$version_line'"
engine_version=${BASH_REMATCH[1]}

env -i PATH=/usr/bin:/bin \
    "$stage/stl2step" "$root/tests/cube.stl" \
    -o "$work/cube.step" --quiet --no-verify >/dev/null
[[ -s "$work/cube.step" ]] || die "staged smoke conversion wrote no STEP file"

mkdir -p "$out_dir"
out_dir=$(cd "$out_dir" && pwd -P)
asset="stl2step-engine-$tag-macos-$platform.tar.gz"
archive="$out_dir/$asset"
(
    cd "$stage"
    COPYFILE_DISABLE=1 tar -czf "$archive" stl2step Frameworks
)

size=$(stat -f '%z' "$archive")
sha256=$(shasum -a 256 "$archive" | awk '{print $1}')
printf '%s  %s\n' "$sha256" "$asset" > "$out_dir/$asset.sha256"

say "platform $platform"
say "version $version_line"
say "dylibs $(find "$frameworks" -maxdepth 1 -name '*.dylib' | wc -l | tr -d ' ')"
say "wrote $archive"
say "size $size sha256 $sha256"
