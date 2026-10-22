# ChronoForge

[![CI](https://github.com/grabbiel/chrono/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/grabbiel/chrono/actions/workflows/ci.yml)

A Chrono Trigger (USA 1.0) reverse-engineering toolkit and ChronoForge Studio, a
native macOS game-authoring app built with Swift, SwiftUI, AppKit and Metal.

**This repository contains no game data.** You need your own legally obtained
Chrono Trigger (USA) ROM; tools that read it check its SHA-256
(`06d1c2b06b716052c5596aaa0c2e5632a027fee1a9a28439e509f813c30829a9`).

## Status

Work in progress. Implemented: the original LZSS packer and codecs, asset
previews, scene authoring, the dialogue codec, event bytecode (read, edit,
assemble, lower from scenes), SPC700 song sequences (read, edit, assemble), an
`.sfc` builder for event packs, dialogue and songs, a native SPC700 CPU,
S-SMP bus and S-DSP, the game's sound driver booted (directly or through a
user-supplied IPL image) and sent songs and samples as the game sends them, WAV
rendering, and live playback of ROM songs, edited songs and samples in the
Studio and the CLI. Not yet implemented: a playable runtime, standalone game
export and most asset editors.

## Build

Apple silicon Mac, macOS 15 or later, Xcode with Swift 6.

```sh
sh re_workspace/tools/libctcodec/build.sh
swift build --package-path macos_studio
swift test --package-path macos_studio
bash macos_studio/tools/bundle_app.sh
open macos_studio/build/ChronoForgeStudio.app
```

In Studio, press Command-O to open a `.ctproj` directory. A small sample project
is at `macos_studio/Tests/ChronoForgeCoreTests/Resources/MyGame.ctproj`; copy it
before editing.

## Documentation

- [Scene Director guide and CLI](macos_studio/docs/scene_director.md)
- [Event bytecode](macos_studio/docs/event_bytecode.md), [text codec](macos_studio/docs/text_codec.md),
  [song sequences](macos_studio/docs/music_sequences.md), [ROM builder](macos_studio/docs/rom_builder.md)
- [Project bundle schema](macos_studio/docs/ctproj_schema.md)
- [SPC700 CPU, S-SMP bus and IPL upload](macos_studio/docs/spc700.md)
- [Contributing](CONTRIBUTING.md) and [GitHub workflow](docs/github-workflow.md)

## Verification

Public CI builds and tests everything that does not need the ROM. ROM-dependent
verification (codec corpora, text/event/song round trips, ROM builds, the sound
driver and real-IPL upload) runs only in the maintainer's local gate,
`re_workspace/tools/verify_all.sh`. See [docs/github-workflow.md](docs/github-workflow.md).

## License

Apache License 2.0 (see [LICENSE](LICENSE)). Third-party notices are in
[macos_studio/ThirdParty](macos_studio/ThirdParty/README.md).
