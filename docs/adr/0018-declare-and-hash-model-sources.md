# Declare each local model's source and identify it by the bytes served

A model was identified by its file name, the quantization read from that name and the maker its GGUF header names. That cannot tell two releases apart. Makers re-upload files under the same name. Unsloth replaced its Qwen3.8-27B UD-Q6_K_L with a "v3.1" quant that scores a few percent differently, and the only record of which one was run was a commit message. A run of the older file would have joined the same run series and been averaged with the newer one. Once a file is overwritten, the old one cannot be downloaded from the link that names it.

The operator now declares where the served file came from, and the model host's files are hashed:

- **Declared source:** before a local run (llama.cpp or Strata), the dashboard's **Model file source** form asks for the file's URL and an optional release label such as "v3.1". The design tree previously said "no manual artifact pins". This declaration is a pin the operator gives, and it is checked against the served bytes rather than trusted. A Hugging Face link is parsed into author, repository, revision and path, and every shard of a numbered set is included. Other hosts are kept as the URL without its query, because a signed query can hold credentials. The last declaration for a served file is offered again on the next connection, but not applied, because the file may have been replaced since.
- **Hub lookup:** declaring a Hugging Face file looks it up on the Hub. The lookup records the commit the revision points to, plus each shard's sha256, size and the commit that last changed it. If the lookup fails, for example offline or for a gated repository, the declaration is kept and the error is shown.
- **Measured hashes:** the memory collector reads each served weight file once. It caches the sha256 on the model host by path, size, inode and modification and change times, and reports the hashes after its ready identity, so sampling is not delayed. If a file changed after the server started, it may not be what the server loaded, so nothing is reported. Only a benchmark that asks for hashes gets them, so an older controller is not sent an event it does not know.
- **Series identity:** a run series' setup gains `model.sha256`, the measured hashes in shard order, when they are known. A re-upload is therefore another series. A contribution started before the hashes were read is compared again when it is exported, as the maker already was. A series published before hashes were recorded keeps its ID, and still takes runs started for it. Once its record holds files, runs of other files are refused.
- **Verification at publication:** the measured hashes are compared with the lookup. If the declared revision has moved on, the repository's history is searched, newest first, for the upload with those bytes. Commits that hold the same upload are skipped, and at most 40 are read. The result is `verified` (naming the upload commit), `differs` or `not_checked`. A mismatch is published, not refused: the hashes still say exactly which file ran.
- **More from the file:** the GGUF header's release, provenance and calibration keys are recorded, such as `general.version`, `quantize.imatrix.dataset`, the base model and the repository URL; a calibration path is kept as its file name only. The server's command line is recorded privately, with its API key and token values replaced. llama.cpp's KV cache types are taken from it and published as the run's `kv_cache`, as Strata's already were.

Public schema 8 adds `model.source`, `model.weight_files` and `model.gguf`; each is null when unknown. The results page shows the source with a link pinned to the upload commit, the release label after the quantization, each shard's sha256 and the GGUF details.

## Consequences

- Runs of a re-uploaded file no longer share a series with the file they replaced, and a published series names the exact upload it was made with, even after the link moves on.
- **Run** on the dashboard needs a declared source for a local model. Resumes keep the source their run recorded. A case run again, which is never published, records whatever the connected model declares.
- Hashes need a configured collector. A deployment without one records the declared source unchecked, and its series identity is unchanged.
- The collector must be rebuilt and reinstalled on the model host to hash files. The first run of a new file reads all of it there once; that read is file access, not a measurement.
- Series published before this change are migrated to schema 8 with null sources and hashes. They are not re-keyed.
- `mix eab.results add` takes `--source-url` and `--release-label` for a run that declared none, marked as given by the publisher.

## Considered options

- **Hash only the first shard.** Shard 1 holds the header and the first tensors, so a requantization changes it. But the Hub publishes a hash per file, and a Strata pack can mix files from two releases; hashing every file compares them one for one.
- **Hash at connect time, before the run.** This gives an answer before Run, but it would hold the dashboard for minutes on a large model. The cache makes the in-run hash immediate from the second run on.
- **Trust the Hub's hash for the declared revision.** It records what the link pointed to when it was declared, not what was downloaded earlier. A file overwritten after the download would be misnamed.
- **Refuse to publish a mismatch.** A file found nowhere in the history, such as a locally requantized one, could never be published, though its hashes identify it.
