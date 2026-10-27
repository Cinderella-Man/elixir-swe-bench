# Show why downloads failed, list failed media and retry them

## Goal

When a media item fails to download, Pinchflat keeps no record of why. The job is retried or given up quietly, and the user has to dig through logs to learn that a video is private, members-only, region-locked or a live stream that isn't finished yet. Nor can they find every item of a source that failed, or retry them once they have fixed the cause, for example after adding cookies.

Record the reason a download failed on the media item, and show it where media items are shown. Give each source a **Failed** tab listing its failed media, and a **Retry Failed Downloads** action that downloads them again.

## What counts as a failure

A reason is recorded only when the download job actually attempts a download and the attempt does not end with a successfully downloaded item.

| Situation | Reason recorded |
| --- | --- |
| yt-dlp exits with an error, for example `ERROR: [youtube] abc123: Private video` | yt-dlp's error message, exactly as reported, however long and whatever characters it contains |
| yt-dlp exits with an error but its output is empty or only whitespace, for example the runner returning `{:error, "", 1}` | A readable string that includes the printed error term, for example `Unknown error: {:error, "", 1}`. Never an empty or blank string. |
| yt-dlp reports that the media isn't downloadable yet (an active or still-processing live stream) | A non-empty message saying the item isn't ready to be downloaded yet. The wording is up to you. |
| An error that isn't text, for example the runner returning `{:error, :connection_reset}` | A readable string that includes the printed error term, for example `Unknown error: {:error, :connection_reset}`. Never the raw term and never an empty string. |
| yt-dlp downloads the media, but the item can't be updated with the downloaded details, for example because the downloaded title is `youtube video #abc123`, which media items don't accept | A readable, non-empty message. The wording is up to you. |
| A recoverable yt-dlp error (`Unable to communicate with SponsorBlock`) where Pinchflat still saves the details of what it downloaded | yt-dlp's message. The item keeps the saved file details and counts as failed until a later download succeeds. |
| A recoverable error where that recovery fails, including when the item rejects the recovered details as above | yt-dlp's message |
| An error that is never retried (`Video unavailable`, `Sign in to confirm`, members-only) | yt-dlp's message |

These are **not** download attempts and leave any recorded reason exactly as it was: the job skips the download because the source is set to not download media, the item's download is prevented ("manually ignored"), the item is no longer pending, or a user script vetoes it.

Failures of re-downloads count too: a forced download or a quality upgrade that fails records its reason on an item that already has a file.

Whether an unexpected exception raised during an attempt, outside the situations above, records a reason is not specified.

## What is recorded

- `Pinchflat.Media.MediaItem` gets a persisted, nullable string attribute `last_error`. `nil` means no recorded failure.
- Each failed attempt overwrites the previous reason. Only the latest one is kept.
- A successful download sets `last_error` back to `nil`.
- `Pinchflat.Media.create_media_item/1` and `Pinchflat.Media.update_media_item/2` accept `last_error`, like the other system-controlled attributes, so a reason can be set or cleared directly.
- Recording a reason never changes what happens to the download job. A failure that is retried today is still retried, a failure that is never retried still completes the job, and recording the reason never crashes the job.

## Where the reason is shown

1. **Media item page** (`/sources/:source_id/media/:id`): when the item has a recorded reason, the page has a section headed **Last Error** that shows the reason as text. When there is no reason, the page has no such section, and the text "Last Error" does not appear.
2. **Source page media tables** (Pending, Downloaded, Other and the new Failed tab): the row of an item with a recorded reason shows an error indicator by the title. The row's markup contains the reason itself, as visible text or as tooltip or `title` text, not only an icon. Rows of other items are unchanged.
3. **Home page Media History table** (its Downloaded and Pending tabs): the same treatment for each row.

Once a download succeeds, none of these pages shows the old reason.

## The Failed tab

- The source page (`/sources/:id`) gets a tab titled **Failed**, after **Other** and before **Tasks**. Like the other tabs, the URL fragment `#tab-failed` opens it (tab id `failed`), just as `#tab-pending` opens Pending.
- It lists the source's media items that have a recorded reason, **except** items whose download is prevented. Those stay under Other, where they are shown as manually ignored.
- The existing tabs keep their membership. A failed item appears under Failed **as well as** under whichever of Pending, Downloaded or Other it already belongs to. For example, a failed pending item is listed under both Pending and Failed, and an item recovered from a SponsorBlock error is listed under both Downloaded and Failed.
- It uses the same table as the other tabs: newest upload first, 10 per page, a search box and a refresh button. Each row shows its reason as described above. When nothing has failed, it shows **Nothing Here!**
- It never lists another source's media.

Example, for a source that downloads media:

| Item | State | Recorded reason | Listed under |
| --- | --- | --- | --- |
| A | not downloaded | `ERROR: … Private video` | Pending, Failed |
| B | downloaded (recovered) | `Unable to communicate with SponsorBlock` | Downloaded, Failed |
| C | not downloaded | none | Pending |
| D | not downloaded, download prevented | `ERROR: … Video unavailable` | Other |

## Retry Failed Downloads

- The source page's **Actions** menu gets **Retry Failed Downloads**, next to Download Pending and Redownload Existing. Like Download Pending, it is shown only when the source downloads media, and it asks for confirmation.
- It posts to `POST /sources/:source_id/retry_failed_downloads`, which redirects back to `/sources/:source_id` with an info flash message.
- When the source downloads media, it enqueues one `Pinchflat.Downloading.MediaDownloadWorker` job for each media item currently listed under Failed (A and B in the example). Each job is a **forced** download, the same as the media item page's **Force Download** action. So the download is attempted even when the item is no longer pending, for example because it already has a file from a recovered or earlier download, and existing files may be overwritten.
- Items without a recorded reason, items whose download is prevented and other sources' items get no job (C and D in the example).
- When the source is set to not download media, nothing is enqueued, and the request still redirects back to the source page.
- Enqueuing does not clear the reason. The item stays under Failed until its download runs. If the download then succeeds, the reason is cleared and the item leaves Failed. If it fails again, the new reason replaces the old one and the item stays under Failed.
- Retrying again while those jobs are still queued does not add a second job for the same item.

## Edge cases and errors

- An unknown source id behaves like the existing source actions: `Ecto.NoResultsError`, which is a 404 in production.
- A reason can be long, span several lines or contain any characters, including `<`, `&` and quotes. It is recorded in full and rendered escaped. It may be truncated visually, but the media item page and every table row that shows it must have the full text in their markup, as visible text or as tooltip or `title` text.
- A successful download clears the reason even when that download is not a retry, for example a normal scheduled download after indexing.

## Compatibility

- Existing tabs, actions, routes and their labels are unchanged.
- Whether a failed download job is retried by Oban is unchanged for every kind of failure.
- Existing media items start with no recorded reason. The new column is added as nullable, with no backfill.
- The downloader's internal return values may change, as long as the job's outcome stays the same.

## Non-goals

- A history of past failures. Only the latest reason is kept.
- A Failed tab on the home page's Media History, or a retry action covering every source.
- Notifications about failures.
- Retrying a single item. The existing Force Download already does this.
- Changing which errors are retried, or adding automatic retry schedules.
- Visual design beyond what is described here: tooltip style, icon choice and colours are up to you.

## Public interface

- `Pinchflat.Media.MediaItem.last_error`: a nullable string, accepted by `Pinchflat.Media.create_media_item/1` and `update_media_item/2`.
- The media item page's **Last Error** section.
- The source page's **Failed** tab (tab id `failed`, `#tab-failed`) and its **Nothing Here!** empty state.
- The **Retry Failed Downloads** action: `POST /sources/:source_id/retry_failed_downloads`, linked from the source page's Actions menu as `<a href="/sources/:source_id/retry_failed_downloads">` with that label.
- Downloads are `Pinchflat.Downloading.MediaDownloadWorker` jobs whose args carry the media item's `"id"`, as today.
