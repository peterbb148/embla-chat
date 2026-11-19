# Tool-worker routing experiment

[Issue #93](https://github.com/peterbb148/embla-chat/issues/93) compares a disposable tool
context with the current Embla 1 prompt layout. The opt-in macOS benchmark uses one loaded
copy of the pinned model per run, the real chat tokenizer, the existing prompt builder and
the app's MCP workspace. The baseline reconstructs the current app prompts in the test
harness. The worker variant runs in the same harness and uses temporary inference messages
to return the fixture's structured result to the main conversation.

The loopback server supplies fixed, distinguishable times and a URL through the MCP client.
Its compact Time.Now and Tavily fixtures exercise routing and response grounding. The
token counts therefore apply to this fixture catalogue. The reported 50% usage with the
phone's live catalogue still needs a separate measurement. The benchmark does not measure
physical-device latency, memory, UI behavior or persistence.

## Run locally

Start the fixture and note the loopback port it prints.

```sh
python3 -u Tests/Fixtures/mcp_server.py
```

In another terminal, set `EMBLA_ROUTING_FIXTURE_PORT` to that port and
`EMBLA_REAL_MODEL_ROOT` to the parent of the already verified model revision directory.
Run the two variants sequentially with full Xcode selected.

```sh
EMBLA_WORKER_EXPERIMENT=baseline swift test --disable-automatic-resolution \
  --filter compareToolWorkerRoutes
EMBLA_WORKER_EXPERIMENT=worker swift test --skip-build --filter compareToolWorkerRoutes
```

The benchmark records routing failures as data. Inspect the output for the chosen methods,
arguments, answers and errors. Each turn reports exact initial prompt tokens, input tokens
per generation, the next ordinary prompt and a matched control that omits the measured turn.
Elapsed time covers the turn after workspace preparation through generation and tool calls.

## Results

The savings target was a 25% reduction in the next ordinary prompt for a successful fresh
Hong Kong lookup with either catalogue. Routing and answer grounding were checked separately.

| Catalogue | Variant | Before lookup | Peak input | Next ordinary turn | Matched control | Lookup time |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| Time | Baseline | 864 | 1,008 | 1,057 | 865 | 7.39 s |
| Time | Worker | 249 | 1,008 | 312 | 250 | 16.44 s |
| Time and search | Baseline | 1,052 | 1,196 | 1,245 | 1,053 | 6.26 s |
| Time and search | Worker | 284 | 1,196 | 347 | 285 | 12.48 s |

For successful fresh lookups, the next ordinary prompt fell by 745 tokens (70.5%) and
898 tokens (72.1%). The cost attributable to the measured exchange fell from 192 to 62
tokens with either catalogue. The worker used four generations per fresh lookup and
the baseline used two. Peak worker input matched the baseline in these cases.

| Check | Baseline | Worker with explicit follow-up instructions |
| --- | --- | --- |
| Fresh Hong Kong lookup, both catalogues | Called the time method and used 14:37 | Called the time method and used 14:37 |
| Tokyo follow-up, time only | Called the time method and used 15:37 | Gave 15:37 without a call, so the value was ungrounded |
| Tokyo follow-up, time and search | Called the time method and used 15:37 | Called the time method and used 15:37 |
| Ordinary arithmetic | Answered directly | Answered directly |
| Ordinary search | Called search and used the returned URL | Printed the delegation marker twice without a call |
| Time method disabled | Zero disabled-method calls. Tried other methods and hit the loop cap with search enabled. | Zero disabled-method calls. Explained the limitation with time only and hit the loop cap with search enabled. |

The initial prototype tried delegation as a synthetic function and made zero tool calls.
A single-word delegation prompt then completed fresh lookups and ordinary search, but
failed both Tokyo follow-ups. The final prompt improved one follow-up and regressed search.
These results meet the fixture savings target and fail the routing requirement. The
persistence refactor remains gated on a reliable routing contract.

## Handoff parser update

The iPhone search run returned the delegation decision twice, separated by a closing
reasoning delimiter. The router now accepts a standalone decision or that exact repeated
decision as a handoff. An ambiguous response that mixes a decision with answer text fails
before it can reach the transcript. The worker still receives the original question and
runs separately on the same loaded model.

## Production integration

The main prompt uses short capability descriptions. Complete tool schemas and intermediate
exchanges are scoped to a temporary worker prompt. Both phases use the same serial Metal
session. A successful task saves a compact receipt against its original tool records before
the main model writes the answer. Original records stay available through Inspect response.

The context counter uses the main prompt projection, including the selected skill, project
memory and draft where applicable. Quick actions enter the prompt when they populate or
send the composer. The worker and the main prompt each have their own input budget.
On the tested iPhone 17 Pro configuration, an empty chat dropped from 47% to 5% after
the production change.

The phone regression exercised the actual Send path with loopback time and search fixtures.
A Hong Kong lookup followed by “What about Tokyo?” dispatched a new call for Tokyo with
time alone and with both fixtures enabled. Ordinary search returned the fixture's URL.
The Mac loopback regression uses the same cases through the production Send path.

The archive stores the receipt on the last result row and retains the underlying message
positions for compaction. Older chats can still load their original tool records and saved
summaries. The worker can read previously saved tool evidence from the selected chat,
including after compaction, without replaying a remote tool call.

## Oversized catalogues

The main prompt keeps method names if the descriptions exceed its catalogue allowance.
The normal worker measures the full prompt with the real tokenizer. If it does not fit,
the worker receives a page of up to eight enabled methods, can page forward or back,
and can load the exact schema of one listed method. If it returns a complete call
for a visible method, the host validates that call against the original schema.
An unmarked answer on a partial page advances the scan so later methods remain
discoverable, including between calls. After gathering results, the worker can mark
the request complete and stop scanning as soon as the evidence covers it. Before any
call, an opened method that needs missing input can ask the user a question. If a page
needs more room, the worker uses smaller pages before retrying with compacted history.
Navigation is bounded, local to the worker and absent from the saved transcript. Actual
calls still use the existing validation and execution limit. A single selected schema
still needs to fit with the request.

The opt-in `oversizedCatalogueFindsAndExecutesAMethodOnTheLastPage` test uses
`EMBLA_REAL_PAGED_CATALOGUE=1` and the loopback server above. Its full schema prompt
has 19,769 tokens. The expected search method is on the third page and must execute
once and return the fixture's exact URL.

The device comparison uses two fresh processes with the same signed build and pinned
model. It reads iOS's process physical-footprint high-water mark from
`TASK_VM_INFO.ledger_phys_footprint_peak` after each workload. Peak RSS from
`getrusage` is a separate measurement, and neither value measures system-wide memory.
