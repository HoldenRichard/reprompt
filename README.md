<p align="center"><img src="assets/preview-appicon.png" width="128" alt="Reprompt icon"></p>

# Reprompt

[![CI](https://github.com/HoldenRichard/reprompt/actions/workflows/ci.yml/badge.svg)](https://github.com/HoldenRichard/reprompt/actions/workflows/ci.yml)

Rewrite the prompt you're about to send, in place, with one hotkey.

Select text in any app, or just leave the cursor in a text field, and press **⌘⇧R**. A
small overlay streams back a sharper version of what you wrote: structured where yours was
loose, explicit about the output you want, stripped of padding, and still in your voice.
Accept replaces the original where it sits. It runs on Groq's free tier, so it costs
nothing and answers in a few hundred milliseconds.

**Quick** mode rewrites immediately. **Clarify** mode asks two or three questions first,
for prompts where the answer would genuinely change the result.

## Platforms

| | App | Library and harness |
|---|---|---|
| macOS 26 | yes | yes |
| Linux | no | yes, built and tested in CI |
| Windows | no | yes, built and tested in CI |

The menubar app is macOS by nature: the global hotkey, the Accessibility API that reads
your selection, the overlay panel and the Keychain are all Apple APIs. The core library and
the prompt-tuning harness have no such ties and build anywhere Swift 6.2 does. On Linux and
Windows there is no keychain, so set `GROQ_API_KEY` in the environment instead; streaming
responses arrive whole rather than token by token there, because Foundation on those
platforms has no streaming request API.

A Windows and Linux app is the obvious next step and would be a separate, small
implementation reusing the same prompt files and the same Groq API — the prompts are the
product, and they are plain text. Contributions welcome.

## Requirements

- macOS 26 or later, on Apple silicon or Intel
- Xcode 26 with the Swift 6.3 toolchain, to build from source
- A free [Groq](https://console.groq.com/keys) account, no card required
- The Accessibility permission, granted on first launch

Building from source is the supported way to run it. There is no notarized download: the
bundle is signed with whatever Apple Development identity is in your keychain, which is
enough for your own Mac.

## Install

```bash
git clone https://github.com/HoldenRichard/reprompt.git
cd reprompt
security add-generic-password -a groq-api-key -s com.holdenrichard.reprompt -A -w
scripts/bundle.sh && open dist/Reprompt.app
```

The `security` line prompts for your Groq key twice and never echoes it, so it stays out
of your shell history. `-A` lets any app on your Mac read the item without a password
prompt; leave it off for a stricter entry, at the cost of a prompt after each rebuild.

macOS will ask for Accessibility permission the first time. Reprompt needs it to read your
selection and to paste the rewrite back; it never needs Input Monitoring, because it
listens to nothing.

## Use

| | |
|---|---|
| ⌘⇧R | Rewrite the selection, or the whole field if nothing is selected |
| ⌘↩ | Accept, replacing the original text in place |
| ⌘E | Edit the rewrite before accepting |
| ⇧⌘C | Copy the rewrite instead of pasting it |
| ⎋ | Dismiss |

The menubar icon switches between Quick and Clarify and picks the model. GPT-OSS 120B is
the default; Qwen 3.8 27B answers in about 200 ms if you would rather have speed. Settings
has the hotkey, the model, dark mode, and the whole-field behaviour.

## Privacy

The text you select is sent to Groq over HTTPS, once per rewrite, and nothing else leaves
your Mac. Groq's stated policy is that it does not train on inputs on any tier and does not
retain them by default; read [their data page](https://console.groq.com/docs/your-data)
and decide for yourself. Your API key lives in the macOS Keychain, never in a file.
Clipboard-based reads and writes snapshot your clipboard and put it back afterwards.

Anthropic and Gemini clients exist behind the same interface if you would rather pay for
a different model: set `ANTHROPIC_API_KEY` or `GEMINI_API_KEY`, or store a key under the
matching keychain account. `GROQ_API_KEY` works the same way and is the only path on
Linux and Windows. Gemini's free tier trains on inputs, which is why it is not the
default.

## How it works

Three targets in one Swift package, no Xcode project.

- **RepromptCore** — a provider-neutral request type with Anthropic, Gemini and Groq
  clients behind one protocol; streaming over raw HTTPS; the optimizer prompts compiled
  into the binary; Keychain storage.
- **Reprompt** — the menubar app. A Carbon global hotkey, which needs no permission. The
  selection is read through the Accessibility API when the app allows it, otherwise
  through a simulated Cmd+C with the clipboard restored. The overlay is a non-activating
  panel, so the app you were in stays frontmost. Accept writes back through Accessibility
  or pastes.
- **reprompt-harness** — a CLI for tuning the optimizer prompt against your own real
  prompts, with a blind pairwise judge. See below.

## Tuning the prompt

The system prompt is the product, and the harness is how it gets better. It pulls prompts
you have actually written out of your Claude Code transcripts, rewrites each one, has the
same model answer both versions, and asks a blind judge which answer served the original
request better.

```bash
swift run reprompt-harness models     # what your account offers, checked against the catalog
swift run reprompt-harness harvest    # ~/.claude/projects -> prompts/raw, read-only
# copy 8-10 prompts into prompts/curated/
swift run reprompt-harness optimize "make the login screen less janky"
swift run reprompt-harness run --judge --both-orders
swift run reprompt-harness run --prompts prompts/raw --sample 40 --judge --both-orders --prompts-dir my-prompts/
swift run reprompt-harness judge --run runs/<timestamp>
```

`--prompts-dir` points at edited copies of the prompt files so you can iterate without
rebuilding. Every run freezes the prompts it used and their SHA-256. `prompts/` and `runs/`
are gitignored: they hold your real prompts.

## Development

```bash
swift test                              # 312 tests, offline, under a second
git config core.hooksPath scripts/hooks # refuse any push whose suite fails
swift run reprompt-harness axprobe      # what Accessibility sees in the frontmost app
```

The tests run without a network or a key: a `URLProtocol` double serves canned HTTP and
Server-Sent Events, so the real client, streaming, error and cancellation paths are
exercised. What they cannot cover is anything needing the Accessibility grant or another
running application, which is what `axprobe` is for.

Every fix in this repo was verified by reintroducing the defect and confirming a named
test fails. If you send a change, that is the bar.

## License

[MIT](LICENSE)
