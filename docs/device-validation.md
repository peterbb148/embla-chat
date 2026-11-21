# iPhone 17 Pro validation

Status: **physical download, inference, lifecycle and offline proof recorded**.
The original minimal screen called the real pinned Embla runtime. This historical Epic 2
record is retained with its tested commits; #3, #4, #17 and Epic #13 are closed. See the
[working-version audit](working-version-validation.md) for subsequent chat integration.

## Install

1. Finish the macOS update and full Xcode installation. Launch Xcode once, accept
   its license, and install required iOS components. Sign in to your development
   account in Xcode Settings > Accounts. Do not put account credentials in Git.
2. Connect and unlock the iPhone, trust the Mac, and enable Developer Mode when
   prompted. In Xcode's device window, verify that it is the intended iPhone 17 Pro
   and record its actual iOS version. Record marketing model/OS, not the private UDID.
3. In the local checkout, record `git rev-parse HEAD`, open `EmblaChat.xcodeproj`,
   select the shared `EmblaChat` scheme and the physical phone destination. Select
   your own team under Signing & Capabilities for the `EmblaChatApp` target. Keep
   personal signing changes out of the PR. The default bundle ID is
   `dk.peterbb148.embla-chat`; use an owned unique ID if registration requires it.
4. Build and Run. A simulator destination is insufficient for the checks below.
   Capture any build, provisioning, installation or launch error rather than
   describing it as a successful deployment.

The reproducible hosted checks use Xcode 26.2. A newer locally installed Xcode must
be validated separately with the phone's actual OS; do not assume compatibility
merely from installation. Command Line Tools alone cannot install the iOS app.

## Download and load

1. Keep a reliable network connection and at least the shown 5.624 GB plus overhead
   free. Tap Download model. The app prevents automatic sleep while active work is
   in the foreground. Manually backgrounding/locking can interrupt the download;
   explicit retry restarts partial downloads. The app does not perform background
   downloads or inference.
2. Wait for **Model verified and ready**. All four exact-size/SHA-256 checks must
   pass; partial bytes and cancelled downloads do not qualify.
3. Enter “What is the capital of Denmark?” and tap Run. The app verifies the saved
   files again, loads Embla, then streams reasoning and the answer separately.
4. Record actual answer text and the displayed token/timing values. A length limit
   reached during reasoning is not a completed answer; record it honestly.

Expected inputs (verify these against the installed build's source):

| Input | Revision/configuration |
| --- | --- |
| Runtime fork | `0c8caaa3616372482d047fa9e953ea656cb34588` |
| Model | `sevren-ai/Embla1-4bit` at `4d23eb7de21fc5b55c3051021c7550af1fdce0e8` |
| Context/output budget | 8,192 / 512 tokens |
| Sampling | temperature 0.6, top-p 0.95 |

Last verified load measures hashing plus runtime initialization. Prompt/decode times
and token counts come from the runtime; generated tokens include its end-token
accounting. The displayed decode rate is `(completionTokens - 1) / decodeSeconds`
when decode time is positive. It is not an upstream benchmark or a prediction.
Observe and record memory in Xcode's memory gauge/Instruments while loading and
running, including peak/steady observations and any memory warning or termination.
Do not substitute total device RAM for the app's measured memory footprint.

## Cancel, reuse and clear

1. On the loaded model, request “List the numbers from 1 to 1000, one per line.”
2. While generation is active, tap Stop. The app must remain busy while it is
   **Stopping**, then become idle. Prefill cannot be interrupted midway by the
   upstream callback; do not claim immediate cancellation.
3. Enter a different short prompt, Run again, and record actual streamed output.
   The old generation must not overlap or append stale text to this request.
4. Start another request and choose New Chat > Start new chat. It must stop and
   drain before clearing the prompt/output. Cancelling the confirmation must keep
   the text. New Chat keeps model files and now saves the previous conversation in history.
   Reopen it from the left sidebar and verify its partial output, summary and draft.
5. Background during a run and reopen. Work must stop and unload as supported by
   the runtime; it must not silently resume. Record any GPU or memory crash.

The runtime has uncatchable preconditions/fatal GPU failures, and cancellation is
cooperative. A background transition while prefill is already executing can exceed
the runtime's cancellation window. Record such a failure as a limitation/blocker;
there is no substitute engine or pretend recovery path.

## Offline proof

1. After download, stop any run. Turn on Airplane Mode and also turn Wi-Fi off on
   the phone. Record these actual settings; network availability must not be faked
   through a launch argument or test backend.
2. Return to the app and submit a new, previously unused prompt. Model loading and
   generation must work using only the local verified files and Metal runtime.
3. Record the prompt, actual streamed answer and timings, along with confirmation
   that the phone had no network connection. Restore normal connectivity afterward.

## Evidence record

Physical observations below were made on 2026-11-14 through the wired Device Hub
display. The installed implementation is `bfa25a448d854c1558ae8dc03be8d8fb1e75255a`.
Results are also tracked on #17.

| Requirement | Observed result |
| --- | --- |
| Physical iPhone 17 Pro + actual iOS version | iPhone 17 Pro, iOS 27.2.1, Developer Mode enabled, wired connection (2026-11-14) |
| Installed app source commit and signing/build result | `bfa25a4`; Xcode 27.2 signed Release build, installation and launch succeeded; personal signing settings remain local |
| Complete model download and verification | Retry completed all four files (5,624,251,762 bytes); app reported Model verified and ready. First attempt terminated during setup and the user restarted it. The corrected build reports continuous byte progress and drains hashing buffers per chunk. |
| Real loaded-model answer and stream | Denmark-capital prompt answered: The capital of Denmark is Copenhagen. Subsequent requests showed reasoning appear while Thinking/Answering, followed by answer text. |
| Verified load time, token counts, decode speed | First verified load 15,424 ms; 18 prompt tokens, 103 generated tokens, prompt 171 ms, decode 987 ms, 103.3 decode tokens/s. After Stop, Red Planet prompt: 19 / 153 tokens, 131 / 1,426 ms, 106.6 tokens/s; answer identified Mars. These are two short observed runs, not a general benchmark. |
| Measured memory behavior | Activity Monitor sampled peak physical footprint 2,361,772,328 bytes (about 2.36 GB), last sample 2,333,116,712 bytes during setup/load/short-run interval; 58 app samples over about 60 seconds. No termination observed in the corrected setup and inference checks. |
| Stop, idle confirmation, subsequent request | Long counting request showed live reasoning; Stop returned to Stopped with Run enabled. A different Red Planet request then completed with Mars, without stale counting output. |
| New Chat and background cleanup | Cancel preserved prompt/output; confirmation cleared them and showed New chat. Backgrounding immediately after starting a counting request, then reopening, showed Model unloaded; no automatic generation restart or crash observed. |
| Airplane Mode + Wi-Fi off, unused prompt, real answer | Device Hub showed Flyfunktion Til, Wi-Fi Fra and Mobildata Fra. After prior background unloading, new prompt What is seven times eight reloaded the saved model and answered Seven times eight is 56. Airplane icon remained visible; no Wi-Fi/cellular connection. Verified load 8,113 ms, 16 prompt / 142 generated tokens, prompt 392 ms, decode 1,335 ms, 105.6 decode tokens/s. |

Memory samples are in [the app-only CSV](evidence/2026-11-14-iphone17pro-memory.csv).
The Xcode 27.2 Activity Monitor trace covered 20:45:06.750–20:46:07.900 CET on the
physical phone. `footprintBytes` is the instrument's physical-footprint column;
`realBytes` is its separate resident-memory column. The peak is the largest sampled
value in that interval, not a guarantee of the lifetime high-water mark. The complete
trace remains local under ignored `build/`; other processes and device identifiers
are excluded from the committed CSV.

The user was asked to restore normal connectivity after the offline observation.
The wired screen connection was used only to control and observe the app, with no
substitute inference backend, model-file injection, or fake network launch mode.

Hosted UI checks prove readiness controls and confirmation behavior, not physical inference.
Later physical observations are recorded separately in the chat, compaction and persistence docs.

## 256K context on iPhone 17 Pro

Issue #97 tested the signed app with the pinned Embla 1 checkpoint and a context
capacity of 262,144. In two fresh processes, the model retrieved the same exact
synthetic fact from the beginning of the prompt. Both prompts fit without compaction.

| Input tokens | Prompt processing | End-to-end time | Peak physical footprint |
| ---: | ---: | ---: | ---: |
| 32,541 | 11.0 s | 25.6 s | 2.85 GiB |
| 257,889 | 3 min 3 s | 3 min 19 s | 2.86 GiB |

End-to-end time includes model loading. Peak physical footprint is the iOS
process high-water mark. These runs used synthetic input and no tools.
