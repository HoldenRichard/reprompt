# Reprompt

A macOS menubar utility that rewrites the prompt you have selected, in place, with one hotkey.
Select text in any app, press ⌘⇧R, and an overlay shows an optimized version to accept,
edit, or dismiss. Quick mode rewrites immediately; Clarify mode asks two or three questions
first.

The optimizer system prompt is the product. It is developed against real prompts with the
harness before the app is trusted with it.

## Layout

- `Sources/RepromptCore` — shared library: raw-HTTPS Claude client with SSE streaming, the
  request builder with per-model capability flags, the optimizer, prompt resources
  (compiled in), Keychain storage.
- `Sources/RepromptHarness` — `reprompt-harness` CLI: `harvest`, `optimize`, `run`, `judge`, `axprobe`.
- `Sources/Reprompt` — the menubar app (SwiftUI + AppKit).
- `scripts/bundle.sh` — assembles and signs `dist/Reprompt.app`.
- `prompts/` and `runs/` — local only, gitignored (they contain your real prompts).

## Harness

```bash
export ANTHROPIC_API_KEY=...            # never committed; the app uses Keychain instead
swift run reprompt-harness harvest      # ~/.claude/projects -> prompts/raw (read-only over transcripts)
# copy 8-10 prompts into prompts/curated/ (see prompts/CANDIDATES.md)
swift run reprompt-harness optimize "make the login screen less janky"
swift run reprompt-harness run --judge --both-orders            # prompts/curated x {opus-5, sonnet-5}
swift run reprompt-harness run --prompts prompts/raw --sample 40 --judge --both-orders --prompts-dir my-prompts/
swift run reprompt-harness judge --run runs/<timestamp>          # re-judge without re-generating
swift run reprompt-harness axprobe                              # what AX sees in the frontmost app
```

`--prompts-dir` points at a directory containing edited copies of the prompt files
(`optimizer_system.md` etc.) so the prompt can be iterated without rebuilding. Every run
freezes the prompts it used and their SHA-256 under `runs/<timestamp>/`.

## App

```bash
scripts/bundle.sh && open dist/Reprompt.app
```

Grant Accessibility when prompted (needed to read the selection and to paste back). Paste
the API key once in Settings; it is stored in Keychain. The app is signed with a stable
identity so the grant survives rebuilds.

Tests: `swift test`.
