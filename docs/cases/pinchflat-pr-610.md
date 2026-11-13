# Record why downloads failed, list failed media and retry them

**Case** `pinchflat-pr-610` · **Feature** in [Pinchflat](https://github.com/kieraneglin/pinchflat)

Pinchflat downloads media from configured sources with yt-dlp, but keeps no record of why a download failed, so users must dig through logs to learn that a video is private, members-only or region-locked. Each media item must record its latest failure reason, cleared by a successful download, and show it on the item page and in media tables. Source pages need a **Failed** tab listing those items and a **Retry Failed Downloads** action that downloads them again.

- [Ticket the agent receives](../../cases/pinchflat-pr-610/ticket.md)
- [Case files](../../cases/pinchflat-pr-610/): grading contract, patches and provenance
- [Upstream pull request](https://github.com/kieraneglin/pinchflat/pull/610) the case is based on
