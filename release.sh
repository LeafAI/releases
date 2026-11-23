#!/usr/bin/env bash
# Build, check and publish the macOS arm64 binaries of compere, whisper and speaker.
#
#   ./release.sh [compere|whisper|speaker|all] [--publish] [--version X.Y.Z]
#
# Without --publish nothing leaves this machine: it builds, checks and packs into ./dist and says what it
# would upload. With --publish it creates one GitHub release per component, tagged <name>-v<version>
# (compere-v0.4.0, whisper-v0.1.0, ...), so each component is released and versioned on its own.
#
# Every binary is built with the build machine's paths removed and is refused if one is still inside.
# A tag that already exists is never overwritten: bump the version instead.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OSS="${OSS_DIR:-$(cd "$HERE/.." && pwd)}"
REPO="${RELEASES_REPO:-LeafAI/releases}"
DIST="$HERE/dist"
# A local proxy is used when one is set up (direct access to api.github.com is unreliable on some networks).
[ -z "${RELEASE_PROXY:-}" ] || export HTTPS_PROXY="$RELEASE_PROXY" HTTP_PROXY="$RELEASE_PROXY"
export PATH="$HOME/.cargo/bin:$HOME/go/bin:/opt/homebrew/bin:/usr/local/go/bin:$PATH"

# component -> source directory (relative to $OSS) and branch the release must be built from
src_dir() { case "$1" in compere) echo compere ;; whisper) echo whisper ;; speaker) echo TTS ;; esac; }
src_branch() { case "$1" in compere) echo main ;; whisper) echo main ;; speaker) echo mistral.rs ;; esac; }

die() { echo "release: $*" >&2; exit 1; }
say() { echo "==> $*"; }

COMPONENTS=()
PUBLISH=0
VERSION_OVERRIDE=""
while [ $# -gt 0 ]; do
  case "$1" in
    compere | whisper | speaker) COMPONENTS+=("$1") ;;
    all) COMPONENTS=(compere whisper speaker) ;;
    --publish) PUBLISH=1 ;;
    --version) shift; VERSION_OVERRIDE="${1:-}"; [ -n "$VERSION_OVERRIDE" ] || die "--version needs a value" ;;
    -h | --help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
  shift
done
[ ${#COMPONENTS[@]} -gt 0 ] || COMPONENTS=(compere whisper speaker)
if [ -n "$VERSION_OVERRIDE" ] && [ ${#COMPONENTS[@]} -ne 1 ]; then die "--version applies to one component"; fi

[ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = arm64 ] || die "this script builds macOS arm64 binaries and must run on an Apple Silicon Mac"
for tool in git shasum tar gh; do command -v "$tool" >/dev/null || die "$tool is required"; done

# The version of a component: an explicit one, else Cargo.toml (Rust) or the newest v* tag (compere).
version_of() {
  local c="$1" dir="$2"
  if [ -n "$VERSION_OVERRIDE" ]; then echo "${VERSION_OVERRIDE#v}"; return; fi
  case "$c" in
    compere)
      local t; t="$(git -C "$dir" describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || true)"
      [ -n "$t" ] || die "compere has no v* tag; pass --version"
      # a commit after the tag is not that tag: the next patch is proposed, never silently reused
      if [ "$(git -C "$dir" rev-list --count "$t"..HEAD)" != 0 ]; then
        die "compere has commits after $t; pass --version X.Y.Z for what this release is called"
      fi
      echo "${t#v}" ;;
    *) sed -n 's/^version *= *"\(.*\)"/\1/p' "$dir/Cargo.toml" | head -1 ;;
  esac
}

# The source must be exactly what is on the remote, or the release is something nobody can reproduce.
check_source() {
  local c="$1" dir="$2" want; want="$(src_branch "$c")"
  [ -d "$dir/.git" ] || die "$c: $dir is not a git checkout"
  [ "$(git -C "$dir" branch --show-current)" = "$want" ] || die "$c: build from branch $want (now on $(git -C "$dir" branch --show-current))"
  [ -z "$(git -C "$dir" status --porcelain)" ] || die "$c: uncommitted changes in $dir"
  git -C "$dir" fetch -q origin "$want" || die "$c: cannot reach origin"
  [ "$(git -C "$dir" rev-parse HEAD)" = "$(git -C "$dir" rev-parse "origin/$want")" ] || die "$c: HEAD is not origin/$want (push or pull first)"
}

build() {
  local c="$1" dir="$2" version="$3" out="$4"
  case "$c" in
    compere)
      (cd "$dir" && CGO_ENABLED=0 go build -trimpath -buildvcs=false \
        -ldflags "-s -w -X github.com/LeafAI/compere/internal/cli.Version=v$version" -o "$out" .) ;;
    whisper | speaker)
      local target="$HERE/.build/$c" lib=""
      # sherpa-onnx's build script downloads its static libraries (about 100 MB) from GitHub, which can
      # stall for many minutes. A copy already on this machine from an earlier build is used instead.
      lib="${SHERPA_ONNX_LIB_DIR:-$(ls -d "$OSS"/*/target/sherpa-onnx-prebuilt/sherpa-onnx-v*-osx-arm64-static-lib/lib 2>/dev/null | head -1 || true)}"
      [ -z "$lib" ] || echo "    using the sherpa-onnx libraries in $lib"
      # Paths of this machine are rewritten to fixed names; the object-file prefix keeps them out of debug info.
      local envs=(RUSTFLAGS="--remap-path-prefix=$HOME/.cargo=/cargo --remap-path-prefix=$HOME/.rustup=/rustup --remap-path-prefix=$dir=/src -C link-arg=-Wl,-oso_prefix,/src" CARGO_TARGET_DIR="$target")
      [ -z "$lib" ] || envs+=(SHERPA_ONNX_LIB_DIR="$lib")
      (cd "$dir" && env "${envs[@]}" cargo build --release --locked)
      cp "$target/release/$c" "$out" ;;
  esac
}

# Refuse a binary that would leak where it was built, or that is not what the page promises.
verify() {
  local c="$1" bin="$2" version="$3" leaks
  [ "$(lipo -archs "$bin" 2>/dev/null)" = arm64 ] || die "$c: not an arm64-only binary"
  # What must not be inside is this machine: the user name and the home directory. A path from a
  # prebuilt third-party library (sherpa-onnx's own CI machine, /Users/runner/...) is not ours.
  leaks="$(strings -a "$bin" | grep -cF -e "$HOME" -e "/$(id -un)/" || true)"
  [ "$leaks" = 0 ] || { strings -a "$bin" | grep -F -e "$HOME" -e "/$(id -un)/" | head -5 >&2; die "$c: $leaks lines still name this machine"; }
  if otool -L "$bin" | tail -n +2 | awk '{print $1}' | grep -vE '^(/usr/lib/|/System/Library/)' | grep -q .; then
    otool -L "$bin" >&2; die "$c: links a library that is not part of macOS"
  fi
  case "$c" in
    compere) [ "$("$bin" --version)" = "compere v$version" ] || die "compere: --version says '$("$bin" --version)'" ;;
    whisper) "$bin" --version >/dev/null || die "whisper: does not run" ;;
    speaker) "$bin" --help >/dev/null || die "speaker: does not run" ;;
  esac
}

pack() {
  local c="$1" dir="$2" version="$3" bin="$4"
  local name="$c-$version-darwin-arm64" stage="$DIST/.stage/$c-$version-darwin-arm64"
  rm -rf "$stage"; mkdir -p "$stage"
  cp "$bin" "$stage/$c"; chmod 755 "$stage/$c"
  [ -f "$dir/LICENSE" ] && cp "$dir/LICENSE" "$stage/LICENSE"
  # a reproducible tarball: fixed owner and no extended attributes
  COPYFILE_DISABLE=1 tar --no-xattrs -C "$DIST/.stage" -czf "$DIST/$name.tar.gz" "$name" 2>/dev/null \
    || COPYFILE_DISABLE=1 tar -C "$DIST/.stage" -czf "$DIST/$name.tar.gz" "$name"
  (cd "$DIST" && shasum -a 256 "$name.tar.gz" > "$name.tar.gz.sha256")
  echo "$DIST/$name.tar.gz"
}

notes() {
  local c="$1" version="$2" dir="$3" sha="$4" asset="$5"
  cat <<EOF
$c $version for macOS (Apple Silicon, arm64).

Built from \`$(git -C "$dir" remote get-url origin | sed -E 's#^git@github.com:#https://github.com/#; s#\.git$##')\` at commit \`$sha\`, with the build machine's paths removed.

Install:

\`\`\`sh
curl -fsSL -O https://github.com/$REPO/releases/download/$c-v$version/$asset
curl -fsSL -O https://github.com/$REPO/releases/download/$c-v$version/$asset.sha256
shasum -a 256 -c $asset.sha256
tar -xzf $asset && install -m 755 ${asset%.tar.gz}/$c /usr/local/bin/$c
\`\`\`

The binary is not signed or notarized. A file fetched with \`curl\` is not quarantined, so macOS runs it; if you downloaded it in a browser, run \`xattr -d com.apple.quarantine $c\` first.
EOF
}

mkdir -p "$DIST" "$HERE/.build"
rm -rf "$DIST/.stage"
SUMMARY=()
for c in "${COMPONENTS[@]}"; do
  dir="$OSS/$(src_dir "$c")"
  say "$c: checking the source in $dir"
  check_source "$c" "$dir"
  version="$(version_of "$c" "$dir")"; [ -n "$version" ] || die "$c: cannot find a version"
  tag="$c-v$version"
  if [ "$PUBLISH" = 1 ]; then
    if out="$(gh release view "$tag" -R "$REPO" 2>&1)"; then
      die "$tag already exists in $REPO; bump the version, a published release is never replaced"
    elif ! printf '%s' "$out" | grep -qi "release not found"; then
      die "cannot tell whether $tag exists ($out); check the network and try again"
    fi
  fi
  say "$c: building $version"
  bin="$HERE/.build/$c.bin"; build "$c" "$dir" "$version" "$bin"
  say "$c: verifying"
  verify "$c" "$bin" "$version"
  asset_path="$(pack "$c" "$dir" "$version" "$bin")"
  asset="$(basename "$asset_path")"
  sha="$(git -C "$dir" rev-parse --short HEAD)"
  if [ "$PUBLISH" = 1 ]; then
    say "$c: publishing $tag"
    notes "$c" "$version" "$dir" "$sha" "$asset" > "$DIST/$tag.notes.md"
    # A network failure can happen after GitHub has already created the release, so every retry first
    # asks whether it exists: a release is created once, and a half-finished upload is completed, not redone.
    n=0
    until gh release view "$tag" -R "$REPO" >/dev/null 2>&1; do
      n=$((n + 1)); [ $n -le 4 ] || die "$tag: could not publish after 4 attempts (network?)"
      gh release create "$tag" "$asset_path" "$asset_path.sha256" -R "$REPO" \
        --title "$c $version (macOS arm64)" --notes-file "$DIST/$tag.notes.md" --target main || sleep $((n * 5))
    done
    have="$(gh release view "$tag" -R "$REPO" --json assets --jq '.assets[].name' | sort | tr '\n' ' ')"
    want="$(printf '%s\n' "$asset" "$asset.sha256" | sort | tr '\n' ' ')"
    [ "$have" = "$want" ] || die "$tag: the release has [$have], expected [$want]; upload the missing file with gh release upload"
    SUMMARY+=("published  $tag  $asset")
  else
    SUMMARY+=("built      $tag  $asset  (dry run: nothing uploaded; add --publish)")
  fi
done
rm -rf "$DIST/.stage"
echo; printf '%s\n' "${SUMMARY[@]}"
