# releases

Prebuilt macOS (Apple Silicon, arm64) binaries of LeafAI command-line tools. Each tool has its own releases,
tagged `<tool>-v<version>`, so they are versioned and published on their own.

| tool | what it is | latest tag |
|---|---|---|
| `compere` | hosts a code review, a talk or a podcast in the browser | see [releases](https://github.com/LeafAI/releases/releases?q=compere-v) |
| `whisper` | offline speech-to-text for the command line | see [releases](https://github.com/LeafAI/releases/releases?q=whisper-v) |
| `speaker` | text-to-speech MCP server and player | see [releases](https://github.com/LeafAI/releases/releases?q=speaker-v) |

## Install

```sh
TOOL=compere VERSION=0.4.1          # a tool and a version from the releases page
ASSET=$TOOL-$VERSION-darwin-arm64.tar.gz
BASE=https://github.com/LeafAI/releases/releases/download/$TOOL-v$VERSION
curl -fsSL -O $BASE/$ASSET -O $BASE/$ASSET.sha256
shasum -a 256 -c $ASSET.sha256
tar -xzf $ASSET && install -m 755 ${ASSET%.tar.gz}/$TOOL /usr/local/bin/$TOOL
```

The binaries are not signed or notarized. A file downloaded with `curl` is not quarantined, so macOS runs it.
If you downloaded one in a browser, run `xattr -d com.apple.quarantine <tool>` once.

Only macOS arm64 is built. Every binary is built with the build machine's paths removed and links nothing but
macOS's own libraries.

## Publish (maintainers)

`release.sh` builds, checks and publishes. It needs an Apple Silicon Mac with Go, Rust, `git` and an
authenticated `gh`. The three source checkouts are expected next to this one (`../compere`, `../whisper`,
`../TTS` for speaker); set `OSS_DIR` to change where.

```sh
./release.sh                       # dry run for all three: build, check, pack into dist/; uploads nothing
./release.sh compere --publish     # publish one tool as compere-v<version>
./release.sh all --publish         # publish all three
./release.sh compere --version 0.3.2 --publish   # name a version that is not the newest tag
```

It refuses to publish when the checkout is dirty, is not the remote's tip of its release branch (compere and
whisper `main`, speaker `mistral.rs`), when a binary still names this machine, links a non-macOS library or
is not arm64-only, or when the tag already exists: a published release is never replaced, bump the version.
The version comes from `Cargo.toml` (whisper, speaker) or the newest `v*` tag (compere, which must have no
commits after it unless `--version` is given).

If GitHub is unreachable or slow from your network, set a proxy for the run: `RELEASE_PROXY=http://127.0.0.1:1080 ./release.sh all --publish`.
A failed upload is safe to run again: an existing release is detected and a missing asset is reported, never silently replaced.
