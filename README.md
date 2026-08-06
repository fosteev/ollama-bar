# ollama-bar

A macOS menu bar app that shows what your local Ollama server is actually doing — which models are loaded, what they cost in memory, how fast they are generating, and what they are producing right now.

Status: the headless core and its CLI are working (M1). The menu bar app is next.

## Try it

```bash
swift build
swift run ollama-bar-cli          # live view, refreshes every 2s
swift run ollama-bar-cli --once   # one snapshot
```

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

`Sources/Core` holds the domain and the monitor, `Sources/Infrastructure` the HTTP client and the
`server.log` tailer, `Sources/CLI` the terminal front end. Parsers are tested against samples
recorded from a live server in `Fixtures/`.

See [docs/PLAN.md](docs/PLAN.md) for the architecture and roadmap.
