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

## Bring your own key

Reprompt talks to [Groq](https://console.groq.com/keys) by default. Its free tier does not
train on your prompts, does not retain them by default, and answers in a few hundred
milliseconds. Nothing you select leaves your machine except the text sent to that one
request. Sign up, create a key, and store it once:

```bash
security add-generic-password -a groq-api-key -s com.holdenrichard.reprompt -A -w
```

The command prompts for the key so it never touches your shell history. `-A` lets any app
on your Mac read the item without a password prompt; drop it for a stricter keychain entry,
at the cost of a prompt after each rebuild. Anthropic and Gemini clients exist behind the
same interface (`GEMINI_API_KEY` / `ANTHROPIC_API_KEY`, or their own keychain accounts) if
you would rather pay for a different model.

## Harness

```bash
swift run reprompt-harness models     # what the provider offers your account, checked against the catalog
swift run reprompt-harness harvest    # ~/.claude/projects -> prompts/raw, read-only over the transcripts
# copy 8-10 prompts into prompts/curated/ (see prompts/CANDIDATES.md)
swift run reprompt-harness optimize "make the login screen less janky"
swift run reprompt-harness run --judge --both-orders            # prompts/curated, blind pairwise judge
swift run reprompt-harness run --prompts prompts/raw --sample 40 --judge --both-orders --prompts-dir my-prompts/
swift run reprompt-harness judge --run runs/<timestamp>          # re-judge without re-generating
swift run reprompt-harness axprobe                              # what Accessibility sees in the frontmost app
```

`--prompts-dir` points at a directory containing edited copies of the prompt files
(`optimizer_system.md` etc.) so the prompt can be iterated without rebuilding. Every run
freezes the prompts it used and their SHA-256 under `runs/<timestamp>/`. `prompts/` and
`runs/` are gitignored: they hold your real prompts.

## App

```bash
scripts/bundle.sh && open dist/Reprompt.app
```

Grant Accessibility when prompted; it is needed to read your selection and to paste the
rewrite back. `bundle.sh` signs with the first Apple Development identity in your keychain,
so the grant survives rebuilds; without one it falls back to ad-hoc signing and warns you.

Press ⌘⇧R with text selected, or with the cursor simply sitting in a text field, in which
case the whole field is used. Accept replaces the text in place. Clarify mode, from the
menubar, asks two or three questions first. The default model is GPT-OSS 120B; Qwen 3.8
is the faster choice.

## Tests

```bash
swift test
```

239 tests across three targets. They run offline in under a second: `MockURLProtocol`
serves canned HTTP and Server-Sent Events, so the real client, streaming, error and
cancellation paths are exercised without a network or an API key.

What is covered, and what is not:

- **Covered end to end**: request shaping per model, SSE parsing, refusals, fallbacks,
  truncation, cancellation, the optimizer and judge call paths, the session state machine,
  Keychain round-trips, real Carbon hotkey registration, pasteboard snapshot and restore,
  and every pure function in the harness.
- **Not covered**: anything needing the Accessibility grant or a real target application,
  namely reading a selection out of another app, posting the synthetic Cmd+C and Cmd+V,
  and the Accessibility write-back. Those are verified by hand with
  `swift run reprompt-harness axprobe` across the app matrix.

The suite is checked against itself: each fixed defect was reintroduced and confirmed to
make a named test fail, so the tests demonstrably catch the bugs they describe.
