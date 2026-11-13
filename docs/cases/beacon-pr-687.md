# Serve per-site sitemaps, a sitemap index and robots.txt

**Case** `beacon-pr-687` · **Feature** in [Beacon](https://github.com/BeaconCMS/beacon)

Beacon runs several sites in one Phoenix application, each mounted in the router with `beacon_site` under its own path prefix and served by its own endpoint. Every mounted site must serve a `sitemap.xml` listing each published page's absolute URL and last update, and a `robots.txt` that blocks nothing and links that sitemap. A new `beacon_sitemap_index` router macro serves an index of every mounted site's sitemap, and every URL must be the one at which that site's content is actually served.

- [Ticket the agent receives](../../cases/beacon-pr-687/ticket.md)
- [Case files](../../cases/beacon-pr-687/): grading contract, patches and provenance
- [Upstream pull request](https://github.com/BeaconCMS/beacon/pull/687) the case is based on
