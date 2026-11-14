# Model download and storage

The setup screen downloads the four files required by Embla from
`sevren-ai/Embla1-4bit`, revision `4d23eb7de21fc5b55c3051021c7550af1fdce0e8`.
The bundled [manifest](../Sources/EmblaCore/Resources/model-manifest.json) is the
single source of download URLs, expected byte sizes and SHA-256 hashes. Required
files total 5,624,251,762 bytes (5.624 GB decimal). The model is MIT licensed; the
upstream license notices are bundled with the app under `third-party/`.

The large-file SHA-256 values come from Hugging Face LFS metadata. For `config.json`
and `tokenizer.json`, bytes fetched at the pinned revision were checked against
the recorded Git blob IDs, then SHA-256 digests were calculated. Git blob IDs and
file SHA-256 hashes are different identifiers.

## Readiness and integrity

`EmblaCore.ModelRepository` owns the files and is independent of the iPhone UI.
Downloads use URLSession disk-backed temporary files, never a multi-gigabyte Data
buffer. Each file must have HTTP status 200, the exact expected size, and the expected
SHA-256 before moving into staging. Only after all four verify is staging renamed
to the installed revision directory. No model path is returned for partial staging.
Readiness checks after relaunch rehash every required installed asset; this can take
time for 5.6 GB. A corrupted installed model must be deleted and downloaded again.
Each 8 MiB hashing iteration drains its autorelease pool so Foundation read buffers
do not accumulate across a multi-gigabyte file. In a local optimized macOS
reproduction hashing the same sparse 512 MiB file, peak footprint fell from
539,936,768 to 10,142,784 bytes with an identical SHA-256 digest. These are local
hash-loop measurements, not iPhone inference-memory measurements.

Files live under Application Support/EmblaModels inside the app sandbox. The model
root is excluded from iCloud backup before any model download starts. The revision
folder is the model directory accepted by the runtime API; actual runtime loading
and physical-device inference are verified in #4 and #17, not by fixture tests.

## Progress, interruption, retry and deletion

The screen shows the expected download size, received bytes, verification status,
errors, and storage occupied by complete or partial files. The preflight check
requires free capacity for all required assets; filesystem overhead and other apps
can still cause a later storage failure, which is reported rather than ignored.
Byte progress comes from a delegate-based URLSession download task. The async
download convenience method does not forward these byte callbacks; physical testing
exposed that earlier implementation as updating only between completed files.

Cancel cancels the asynchronous download or stops chunked hashing. Controls remain
busy until cancellation finishes. A failed, cancelled or interrupted download may
leave staging bytes, but they never become a ready model. Explicit retry removes
staging and restarts from the beginning. There is no background download or partial
resume in this version: iOS suspension/termination may interrupt work. Relaunch
checks the installed revision; the user can retry or delete remaining partial files.

Delete Model removes only the model root, after confirmation. It never deletes chat
storage. No server credentials, Hugging Face token, model weights or signing secrets
are stored in Git. Failure to fetch or verify Embla is shown as an error.

## Validation

`swift test` under full Xcode runs fixtures covering successful install and relaunch,
same-size corruption, failure after a partial download, explicit retry, cancellation,
concurrent deletion prevention, low-storage preflight, and model deletion.
These fixtures are small test bytes and do not prove the real model runs.

An explicit small provider test exercises URLSession against the pinned 5 KB config:
it also requires the transport to report all received bytes through its progress callback.

```sh
EMBLA_LIVE_DOWNLOAD_TESTS=1 swift test --filter livePinnedConfigDownload
```

CI runs that provider check, the fixture suite, the unsigned iOS Release build,
and the model-setup UI launch test. It does not download model weights. Local Xcode
27.2 package tests and a signed Release build for iPhone 17 Pro also pass.
Full-model download, readiness on iPhone, and runtime acceptance still require device
integration evidence in Epic 2.
