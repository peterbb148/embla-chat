# iPhone 17 Pro validation

Status: **pending physical-device evidence**. The minimal screen calls the real
pinned Embla runtime; compiling it and testing fixtures do not prove the model runs
on the phone. Keep #3, #4, #17 and Epic #13 open until this procedure is evidenced.

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
   the text. New Chat does not delete model files or create a saved-chat archive.
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

Record results on #17 with links to test logs/screenshots where available. This
section remains pending until observations exist:

| Requirement | Observed result |
| --- | --- |
| Physical iPhone 17 Pro + actual iOS version | Pending |
| Installed app source commit and signing/build result | Pending |
| Complete model download and verification | Pending |
| Real loaded-model answer and stream | Pending |
| Verified load time, token counts, decode speed | Pending |
| Measured memory behavior | Pending |
| Stop, idle confirmation, subsequent request | Pending |
| New Chat and background cleanup | Pending |
| Airplane Mode + Wi-Fi off, unused prompt, real answer | Pending |

Only close the Epic 2 issues after the required observations are recorded. Hosted
UI checks prove readiness controls and confirmation behavior, not physical inference.
