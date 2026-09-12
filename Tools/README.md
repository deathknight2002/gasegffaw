# Tools

Host-side tooling for Bornless Ritual. Everything here runs on Linux or macOS without
Xcode unless a section says otherwise.

| Tool | Purpose | Status |
|---|---|---|
| `gen_xcodeproj.rb` / `gen_xcodeproj.sh` | Regenerates `BornlessRitual.xcodeproj` from the source tree | ready |
| `truth/` | Swiss Ephemeris reference vectors for the RitualCore astrology tests | ready |
| `metal-lint/` | Type-checks `.metal` sources on Linux with clang and stub MSL headers | being built |
| `capture/` | Host scripts that drive the on-device capture harness | to be added |

## gen_xcodeproj

`BornlessRitual.xcodeproj` is a generated, committed artifact. Never edit it by hand or
add files through Xcode's UI: run the generator and commit the result.

```sh
ruby Tools/gen_xcodeproj.rb          # generate + validate (from any directory)
Tools/gen_xcodeproj.sh               # same, installs the xcodeproj gem first if missing
ruby Tools/gen_xcodeproj.rb --check  # CI: fail if the committed project is stale (writes nothing)
ruby Tools/gen_xcodeproj.rb --force-scaffold  # rewrite Info.plist, bridging header, asset stubs
```

Requirements: Ruby 3.x and the [`xcodeproj`](https://github.com/CocoaPods/Xcodeproj) gem
(1.28.1 verified). `python3` is used for the plist validation step only; when it is
absent the check degrades to an XML well-formedness test.

### What it produces

* `BornlessRitual.xcodeproj/project.pbxproj` (objectVersion 60, "Xcode 15.0"
  compatibility, opens in Xcode 15 and 16 with no upgrade prompt).
* `BornlessRitual.xcodeproj/xcshareddata/xcschemes/BornlessRitual.xcscheme` — shared
  scheme, Run builds Debug, carries a disabled example launch line
  `-stage 7 -camera threequarter -renderPath rt -seed 1 -capture stills` and
  `MTL_DEBUG_LAYER=0`.
* `project.xcworkspace/contents.xcworkspacedata` and `IDEWorkspaceChecks.plist`, so
  Xcode does not need to write into the project on first open.

Scaffold files, written only when missing (hand edits survive re-runs):

* `BornlessRitual/Info.plist` — full plist, `GENERATE_INFOPLIST_FILE = NO`.
* `BornlessRitual/BornlessRitual-Bridging-Header.h` — `#include "Shaders/ShaderTypes.h"`.
* `BornlessRitual/Resources/Assets.xcassets` — `AppIcon` (single 1024×1024 slot with a
  generated dark-red placeholder PNG) and `AccentColor` (sRGB 0.95, 0.60, 0.15).
* The `App/ Render/ Shaders/ Interaction/ Capture/ Resources/` directories.

### How files are picked up

| On disk (under `BornlessRitual/`) | In the project |
|---|---|
| `**/*.swift` | Compile Sources |
| `Shaders/*.metal` | Compile Sources (Metal) |
| `Shaders/*.h` | Referenced in the navigator only; found via `HEADER_SEARCH_PATHS` / `MTL_HEADER_SEARCH_PATHS = $(SRCROOT)/BornlessRitual/Shaders` and the bridging header |
| `Resources/**` — `.xcassets`/`.bundle`/`.scnassets`/`.xcstrings` folders, and `.json .txt .plist .strings .png .jpg .heic .wav .caf .m4a .mp3 .mov .mp4 .ttf .otf .md` files | Copy Bundle Resources (folder bundles as one reference each) |
| `Info.plist`, the bridging header | Referenced, in no build phase |
| `Packages/RitualCore` | Local Swift package (`XCLocalSwiftPackageReference`), product `RitualCore` linked into the app |

Unrecognised files under `Resources/` are reported and skipped, never silently bundled.
Hidden files and directories are ignored. Groups mirror the directory layout; children
are sorted (groups first, then files, case-insensitive) so the navigator is stable.

Frameworks phase: `RitualCore` (package product) plus explicit `CoreHaptics`, `Metal`,
`MetalFX`, `MetalKit` (`SDKROOT`-relative). MetalPerformanceShaders, AVFoundation,
ImageIO and UniformTypeIdentifiers are linked implicitly through Swift `import`.

### Target facts

iOS 17.0, iPhone only (`TARGETED_DEVICE_FAMILY = 1`), bundle id `com.bornless.ritual`,
Swift 5.0 with `SWIFT_STRICT_CONCURRENCY = minimal`, `CODE_SIGN_STYLE = Automatic` with
an empty `DEVELOPMENT_TEAM` (set yours in Xcode's Signing tab — that edit is local to
your checkout, or pass it on the `xcodebuild` command line), `ENABLE_PREVIEWS = YES`,
`MTL_LANGUAGE_REVISION = Metal31`, `MTL_FAST_MATH = YES`, `MTL_ENABLE_DEBUG_INFO =
INCLUDE_SOURCE` (Debug) / `NO` (Release), `ENABLE_USER_SCRIPT_SANDBOXING = NO`,
`DEAD_CODE_STRIPPING = YES`, `-Onone` / `-O` + whole-module in Release. The full tables
live at the top of `gen_xcodeproj.rb`; change them there, regenerate, commit.

### Determinism

The project is rebuilt from scratch on every run and then all object UUIDs are
replaced with MD5 digests of each object's path in the object graph
(`Xcodeproj::Project#predictabilize_uuids`). Inputs are sorted before they are added,
so two runs over the same tree produce byte-identical `project.pbxproj` and scheme
files, and `git diff` after a regeneration shows only real changes (a new file adds its
own objects; nothing else moves). `--check` regenerates into a temporary directory and
compares against the committed files.

### Validation

After writing, the generator re-opens the project with `Xcodeproj::Project.open`,
asserts the target, the package product link, the four framework links, that
`Info.plist`/the bridging header/`.h` files are in no build phase, the key target
settings, prints counts and a navigator tree, validates `Info.plist` with Python's
`plistlib` (required keys, empty `UILaunchScreen` dict, `UIApplicationSupportsMultipleScenes
= false`, `APPL`), and parses the scheme back to check the launch action.

### Verifying on macOS

```sh
xcodebuild -project BornlessRitual.xcodeproj -scheme BornlessRitual \
  -destination 'generic/platform=iOS' -configuration Debug \
  CODE_SIGNING_ALLOWED=NO build
```

## truth

`truth/gen_vectors.py` produces the Swiss Ephemeris (Moshier) reference vectors that
pin RitualCore's astrology code (`NatalChart`, prenatal syzygy, Placidus ASC/MC,
obliquity/nutation):

```sh
pip install pyswisseph
python3 Tools/truth/gen_vectors.py > Packages/RitualCore/Tests/RitualCoreTests/Fixtures/ephemeris_vectors.json
```

The fixture is committed (41 vectors: the owner's chart plus 40 seeded random
date/place pairs, tolerance 0.1°). Regenerate only when the vector set changes; the
tests compare against the committed JSON, not against a live Swiss Ephemeris.

## metal-lint

Being built by another agent. Goal: syntax- and type-check every `.metal` file under
`BornlessRitual/Shaders` on Linux, where no Metal compiler exists, using `clang++
-fsyntax-only` with stub MSL headers (`metal-lint/include/__msl/`): vector types as
clang `ext_vector_type` typedefs, function-style constructors via macros, `half` as
`_Float16`, address-space keywords, ray-tracing intrinsics. `docs/RENDER_CONTRACT.md`
requires all shaders to pass it. Entry point: `Tools/metal-lint/lint.sh`; see that
directory's README when it lands. It is a lint, not a compiler: a clean run does not
prove the shader compiles with Apple's `metal` tool, only that it is well-formed
against the stubbed subset.

## capture

Placeholder — host capture scripts to be added. Planned contents (see
`docs/ARCHITECTURE.md` §7 and `docs/CRITIC.md`):

* `capture/critic_capture.sh <device-id>` — launches the app on a connected iPhone with
  the harness launch arguments (`-stage`, `-camera`, `-renderPath`, `-seed`,
  `-capture stills|clip|perf`) for the 24 stills × 2 render paths plus the two clips,
  then pulls `Documents/Captures/<runName>/` from the app's container (visible thanks to
  `UIFileSharingEnabled` / `LSSupportsOpeningDocumentsInPlace` in `Info.plist`).
* `capture/assemble.sh` — assembles clip frame sequences into MP4 with ffmpeg.

Until these exist, use the Run scheme's launch arguments in Xcode (the example line is
present but disabled) and copy captures out with Finder or `devicectl`.
