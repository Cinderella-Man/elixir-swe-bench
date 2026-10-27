# Sitemaps and robots.txt for every Beacon site

## Goal

Search engines find a site's pages through `robots.txt` and XML sitemaps. A Beacon application can run several sites, each mounted in the host application's router under its own path prefix and served by its own endpoint, so writing these files by hand is error-prone. Beacon should serve them itself: a `sitemap.xml` and a `robots.txt` for every mounted site, plus an optional sitemap index that lists every site's sitemap. Every URL in these files must be the URL at which that site's content is actually served.

## Public interface

- **Per-site routes.** Every `beacon_site` mount serves two more routes, relative to the site's full mount path (the enclosing `scope` paths plus the `beacon_site` prefix). No router change is needed.
  - `GET <mount path>/sitemap.xml`
  - `GET <mount path>/robots.txt`
- **`beacon_sitemap_index/1`.** This is a new router macro in `Beacon.Router`, imported by `use Beacon.Router` like `beacon_site/2`. `beacon_sitemap_index "/sitemap_index.xml"` adds a `GET` route that serves the sitemap index at the given path, file name included, relative to the enclosing scope. Inside `scope "/seo"`, `beacon_sitemap_index "/all.xml"` serves `/seo/all.xml`. The macro may be used more than once and in any scope. Like any specific route, it must be declared before a `beacon_site "/"` mount that would otherwise catch the path.

## Example setup

The examples below use this router. `:home`, `:blog` and `:guides` use `MyAppWeb.Endpoint`, whose URL is `http://example.com`. `:shop` uses `MyAppWeb.ShopEndpoint`, whose URL is `https://shop.example.com`. A fifth running site, `:drafts`, names this router in its configuration but is not mounted in it.

```elixir
defmodule MyAppWeb.Router do
  use Phoenix.Router
  use Beacon.Router

  # pipelines omitted

  scope "/" do
    pipe_through :browser
    beacon_sitemap_index "/sitemap_index.xml"
  end

  scope "/", host: "shop.example.com" do
    pipe_through :browser
    beacon_site "/", site: :shop
  end

  scope "/docs" do
    pipe_through :browser
    beacon_site "/guides", site: :guides
  end

  scope "/" do
    pipe_through :browser
    beacon_site "/blog", site: :blog
    beacon_site "/", site: :home
  end
end
```

## sitemap.xml

`GET http://example.com/blog/sitemap.xml` responds `200` with:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
  <url>
    <loc>http://example.com/blog/hello-world</loc>
    <lastmod>2025-01-30T14:05:00.000000Z</lastmod>
  </url>
  <url>
    <loc>http://example.com/blog</loc>
    <lastmod>2025-01-12T09:00:00.000000Z</lastmod>
  </url>
</urlset>
```

- The response is XML (`text/xml` or `application/xml`) in UTF-8. The document is a sitemaps.org `urlset` in the namespace `http://www.sitemaps.org/schemas/sitemap/0.9`, and its `url`, `loc` and `lastmod` children are in the same namespace.
- There is exactly one `url` per published page of that site. Pages of other sites never appear, even when the sites share an endpoint, a router or a mount path on different hosts.
- `loc` is the page's absolute URL. It is the URL of the site's endpoint (scheme, host and port, as its `url/0` returns), then the site's full mount path, then the page path. `/hello-world` on `:blog` becomes `http://example.com/blog/hello-world`, and `/welcome` on `:shop` becomes `https://shop.example.com/welcome`. A page whose path is `/` is listed at the mount URL itself, either `http://example.com/blog` or `http://example.com/blog/`, because a trailing slash is not significant.
- `lastmod` is the time the published version of the page was last updated, that is the published page's `updated_at`. It is an ISO 8601 date-time with a UTC offset. `2025-01-30T14:05:00Z`, `2025-01-30T14:05:00.000000Z` and `2025-01-30T14:05:00+00:00` are all acceptable. A date alone is not.
- Only published content is listed:
  - A page that was never published is left out.
  - A page that was published and then unpublished is left out.
  - A published page with unpublished draft changes is listed as published, with its published path and published `lastmod`. For example, if the draft renames `/news` to `/news-2025`, the sitemap still shows `/news` until the page is published again.
- Every published page is listed, however many the site has. A site can have hundreds of pages, and the sitemap is not paginated.
- The order of `url` entries is not significant.
- The document is well-formed XML. Characters in a page path that XML reserves are escaped. For example, `/q&a` appears as `<loc>http://example.com/q&amp;a</loc>`, and `/a<b` as `<loc>http://example.com/a&lt;b</loc>`. Percent-encoding those characters (`/q%26a`) is also acceptable. Control characters that XML cannot represent at all are percent-encoded: the path `"/a\x01b"` (with U+0001) appears as `<loc>http://example.com/a%01b</loc>`.
- A site with no published pages responds `200` with an empty `urlset`.

## robots.txt

`GET http://example.com/blog/robots.txt` responds `200` with:

```text
# http://www.robotstxt.org
User-agent: *
Sitemap: http://example.com/blog/sitemap.xml
```

- The response is `text/plain` in UTF-8.
- It allows everything: there is a `User-agent: *` group, and no `Disallow` rule blocks any path. An empty `Disallow:` is fine. Comment lines are optional.
- There is exactly one `Sitemap:` line. It holds the absolute URL of this site's own sitemap, built like the page URLs above. `:home` gives `http://example.com/sitemap.xml`, `:guides` gives `http://example.com/docs/guides/sitemap.xml` and `:shop` gives `https://shop.example.com/sitemap.xml`.

## Sitemap index

`GET http://example.com/sitemap_index.xml` responds `200` with:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<sitemapindex xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
  <sitemap>
    <loc>http://example.com/blog/sitemap.xml</loc>
  </sitemap>
  <sitemap>
    <loc>http://example.com/docs/guides/sitemap.xml</loc>
  </sitemap>
  <sitemap>
    <loc>http://example.com/sitemap.xml</loc>
  </sitemap>
  <sitemap>
    <loc>https://shop.example.com/sitemap.xml</loc>
  </sitemap>
</sitemapindex>
```

- The response is XML (`text/xml` or `application/xml`) in UTF-8. It is a sitemaps.org `sitemapindex` in the same namespace as the sitemap, with `sitemap` and `loc` children.
- It has one `sitemap` entry for every running Beacon site that is mounted with `beacon_site` in the router named in that site's configuration (the `:router` option). Each entry holds the same sitemap URL that the site's `robots.txt` advertises.
- Every such site is listed, whichever host or endpoint serves the site and whichever host or path the index request uses. Every declaration of the index serves the same list. The index is declared in the router that mounts the sites. Declaring it only in some other router is not specified.
- A running site that its configured router does not mount is left out, and so is a site whose configured router does not `use Beacon.Router` at all. `:drafts` in the example is one. Such sites never cause an error.
- Entries are sorted by URL in ascending plain string order.
- Whether index entries carry a `lastmod` is not specified.

## Edge cases

- Only the exact `<mount path>/sitemap.xml` and `<mount path>/robots.txt` paths are new. A page whose path is `/sitemap` or `/robots`, and every other page path, still renders as a page.
- Two sites mounted at the same path on different hosts each serve their own files. In the example, `http://example.com/sitemap.xml` is `:home`'s and `https://shop.example.com/sitemap.xml` is `:shop`'s.
- Whether a page whose path has dynamic segments (`/posts/:id`, `/*rest`) is listed is not specified.
- Whether the sitemap is well-formed when a page path contains the Unicode noncharacters U+FFFE or U+FFFF is not specified.

## Compatibility

- `beacon_site/2`, its options and existing routers keep working unchanged. A router that does not declare a sitemap index keeps compiling and gains only the per-site routes.
- The existing routes inside a mount keep working: media, assets, the reachability check route and page rendering.
- The existing public helpers and content APIs keep their current behaviour.

## Non-goals

- `changefreq` and `priority`, excluding individual pages (for example `noindex` pages), and splitting sitemaps above 50,000 URLs or compressing them.
- Configurable `robots.txt` rules, or `robots.txt` and the sitemap index at the top level of a proxy endpoint.
- Caching headers. They may be set, but they are not specified.
- Changes to the `mix beacon.*` generators.
- Percent-encoding of non-ASCII page paths, and endpoint `url` configuration with a `:path`.
- Documentation and CHANGELOG updates are welcome but optional.
