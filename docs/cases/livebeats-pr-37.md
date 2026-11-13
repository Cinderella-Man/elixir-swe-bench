# Show the playing song in the tab and media metadata

**Case** `livebeats-pr-37` · **Feature** in [live_beats](https://github.com/fly-apps/live_beats)

LiveBeats is a music app whose player plays songs from a profile's song list. When a song starts playing, its title and artist must appear in the browser tab and, where supported, in the browser's Media Session metadata, updating whenever the song changes, including through the player's Next and Previous controls. When listening stops on the song list page, the page must restore its ordinary tab title, and playback must keep working in browsers without the Media Session API.

- [Ticket the agent receives](../../cases/livebeats-pr-37/ticket.md)
- [Case files](../../cases/livebeats-pr-37/): grading contract, patches and provenance
- [Upstream pull request](https://github.com/fly-apps/live_beats/pull/37) the case is based on
