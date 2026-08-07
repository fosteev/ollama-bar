# ollama-bar

A macOS menu bar app that shows what your local Ollama server is actually doing — which models are loaded, what they cost in memory, how fast they are generating, and what they are producing right now.

Status: menu bar app, headless CLI and request interception all work (M1–M3).

## The app

```bash
brew install tuist
tuist generate
open OllamaBar.xcworkspace   # then Cmd+R
```

It appears in the menu bar with no Dock icon. The label stays quiet — an icon, plus a dot when a
model is resident — and only shows a number while something is generating.

## The CLI

Same core, no Xcode required:

```bash
swift run ollama-bar-cli                # live view, refreshes every 2s
swift run ollama-bar-cli --once         # one snapshot
swift run ollama-bar-cli --proxy 11435  # and watch what passes through
```

## Seeing output

Ollama offers no way to watch another client's stream, and its log carries metadata only. To see
what a model is actually producing, turn on interception (Settings, or `--proxy` on the CLI) and
point your client at that port instead of Ollama's.

The proxy is a byte-for-byte TCP relay: it never parses or re-encodes what it forwards. HTTP is
reconstructed from a copy of the stream purely for display, so a bug there costs you visibility and
nothing else. Transparency is checked by tests that compare a proxied response against the same
request made directly.

```
ollama-bar  http://127.0.0.1:11434

qwen3.5-27b-32k:latest
  27.8B Q4_K_M  17.0 GiB  GPU  ctx 32K  evicts in 4:12

total resident: 17.0 GiB
generating: 5.9 t/s (slot 0)
```

Needs a local Ollama; nothing has to be reconfigured on the client side.

## Development

```bash
swift test
```

`Sources/Core` holds the domain and the monitor, `Sources/Infrastructure` the HTTP client, the
`server.log` tailer and settings storage, `Sources/App` the SwiftUI menu bar app, `Sources/CLI` the
terminal front end. Parsers are tested against samples recorded from a live server in `Fixtures/`.

The logic builds as a plain SPM package, so `swift test` runs without generating an Xcode project;
Tuist exists only for the `.app` bundle. Both read the same source directories.

See [docs/PLAN.md](docs/PLAN.md) for the architecture and roadmap, and
[docs/TODO.md](docs/TODO.md) for what is still missing.
