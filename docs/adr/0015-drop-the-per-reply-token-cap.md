# Drop the per-reply token cap

Local Pi runs capped every model reply at 8,192 tokens. When a reply reached that cap before it called a tool, Pi treated the agent as finished. Its loop ends after a reply without a tool call, and it has no setting to continue. The attempt then submitted whatever it had changed so far. Pi's own text mode reports such a reply as truncated, but the JSON mode the bridge uses does not. A reply cut inside a tool call did carry on, because Pi rejects possibly truncated calls and asks the model to send them again.

The ten published local Pi series have 200 attempts. Of their 97 failures, 28 ended on a reply cut at 8,192 tokens: 8 of 20 attempts for Qwen3.8-27B, 7 for Flint and 6 for Ornith-1.5-122B UD-Q5_K_XL. Every cut reply was still reasoning, with no text and no tool call. None was looping: they repeated themselves about as much as the same models' long replies that finished. At the cut, the median of these attempts still had about 46,000 tokens of its generation budget left. The cap was measuring itself rather than the model. It also held local models to a tighter reply limit than Claude API runs (up to 64,000 tokens) and than Claude Code and ChatGPT runs, whose replies the benchmark never capped.

The benchmark therefore sets no per-reply limit. A reply ends when the model ends it, or when the attempt's generation budget or context window runs out:

- **Reply limit on a local server:** each request may generate up to the smaller of the generation budget left and the room the prompt leaves in the context window.
- **Stopping for context:** the model is stopped before a call only when the prompt leaves no room at all.
- **Attributing a length stop:** a reply that stops for length counts against whichever of those two limits bounded it, so it is a generation or context cutoff. The response cutoff no longer occurs.
- **Agent instructions:** they name only the generation budget and the context window.
- **APIs that require a per-reply value:** where an API requires one, as the Claude API does, the request asks for the model's maximum output. That limit belongs to the provider, like the context size.

## Consequences

- **Series.** The per-reply cap is a run setting, so runs made with it and runs made without it belong to different series ([ADR 0011](0011-publish-three-run-series.md)).
  - The ten published local Pi series keep their single 8k run each, but cannot gain seeds.
  - Each of those models needs a new series. That costs ten seed-101 runs beyond the twenty those series still lacked.
  - An 8k point stays published until its model has a run without the cap.
  - Claude Code series are unaffected.
- **Dashboard.** It no longer asks for a per-reply limit, and offers no contribution to a series made with one.
- **Older runs.** A run made with a cap keeps it when it is resumed or its errors are retried.
- **Unused default.** `config/benchmark.json` keeps its old `response_tokens` default, and nothing reads it. Every run froze that file as part of the benchmark definition, and the runner refuses to retry errors in place once the definition changes. Removing the default would therefore block retries for every earlier run.
- **Runaway replies.** A reply that never converges now spends the rest of the generation budget instead of 8,192 tokens. It fails either way, but uses more of the model host.
- **Context rule.** Replayed against the recorded histories, the new context rule would cut no recorded reply. It would let the one attempt stopped for context make another call. Reserving the whole remaining budget instead would have stopped that attempt earlier.
- **Results schema.** The `response_budget` cutoff stays in the results schema for the 8k series.
- **Strata.** Before a Strata run, check that Strata accepts a reply limit of 65,536 tokens.

## Considered options

- **A larger cap, such as 16,384 or 32,768.** It still ends an attempt whenever one reply outgrows it, only less often. The recorded replies cannot show how much less often: each cut one stopped at 8,192.
- **Continue after a cut in the gateway:** send the cut reply back as a prefix and stitch the server's continuation into one reply. Pi would not notice. But it depends on each server and chat template continuing inside a reasoning block, and it amounts to a larger cap delivered in pieces.
- **Continue after a cut in the bridge:** run Pi in RPC mode and send a fixed follow-up message after a cut.
  - The model would see an instruction the benchmark wrote, and an interruption every 8,192 tokens.
  - Pi would no longer own its agent loop alone.
  - A run series would not notice the change, because the Pi harness identity is only its package version and lock.
- **Keep the cap and tag cut-off attempts.** The ten series could keep collecting seeds, but their scores would go on measuring the cap.
- **Reserve the whole remaining generation budget before each call.** Simpler, but it stops attempts while up to 65,536 tokens of the window are still unused.
