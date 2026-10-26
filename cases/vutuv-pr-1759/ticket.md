# Suggest @-mentions and report which handles will become links

## Goal

Members mention other members and organization pages by typing `@handle` in posts, messages and other Markdown fields. Today the handle is typed from memory, and the first sign of a wrong handle is the save being refused. The editor is getting an `@`-picker. It needs two answers from the server, both for the signed-in member who is writing:

1. **Suggestions.** Which accounts to offer for a half-typed handle, best match first.
2. **Check.** Which handles in a draft will become mention links when the text is rendered.

Build the server side: two functions in `Vutuv.Mentions` and two JSON endpoints. A mention is a notification, so the suggestions must put the accounts the member most likely means first. They must never offer an account that the member or the site has already ruled out. The check must answer exactly what the Markdown renderer will do, so the editor never promises a link that does not appear, and never withholds one that does.

## Suggestions: `Vutuv.Mentions.suggest(viewer, term, limit \\ 8)`

`viewer` is the signed-in member, a `%Vutuv.Accounts.User{}`. The result is a list of at most `limit` accounts, each a `%Vutuv.Accounts.User{}` or a `%Vutuv.Organizations.Organization{}` with its `username` (the handle) loaded, in rank order.

### The term

- The term is normalized the way the site normalizes typed handles: surrounding whitespace is trimmed, a leading `@` is dropped, and the result is lowercased. `"@Ada"`, `" ada "` and `"ADA"` are the same term.
- After normalization, a term shorter than **2 characters** returns `[]`. This covers `""`, `"   "`, `"a"` and `"@a"`. `"ad"` is answered.
- The term is literal text. `%`, `_` and `\` are not wildcards: `"ada_"` matches the handle `ada_x` but not `adaline`, and `"%a"` matches nothing unless a handle or name really contains `%a`.

### Who matches

Matching ignores case.

- A **member** matches when their handle starts with the term, or when their first name, last name, or first and last name joined by one space contains the term. `"lovel"` and `"a lov"` both find Ada Lovelace. A member whose handle only contains the term somewhere after its start, such as `xadax` for `"ada"`, does not match unless their name does.
- An **organization page** matches when it has a root handle and that handle starts with the term, or when its name contains the term. A page without a root handle can never be mentioned, so it is never offered.

### Who is never offered

- The viewer.
- A member the viewer has blocked, and a member who has blocked the viewer.
- A member who has not confirmed their email address. Legacy members whose confirmation flag is empty (`nil`) count as confirmed and are offered.
- A member hidden by moderation: frozen, deactivated, unreachable (every email bounced), or suspended until a time that has not yet passed. A member whose suspension has ended is offered again.
- A page that is not publicly visible: any status other than `"active"`, or frozen by moderation.

Blocks exist only between members, so they never exclude a page.

### Ranking

Members and pages are ranked together in one order:

1. Accounts the viewer follows come first. Following a member and following a page both count, and a muted follow still counts as following.
2. Within each of those two groups, accounts whose handle starts with the term come before accounts that only match by name.
3. Then alphabetically by name, ignoring case. A member's name here is their first and last name joined by a space, without honorifics. A page's name is its name.
4. Accounts with the same name are ordered alphabetically by handle.

The ranking and every exclusion apply to **all** matching accounts before `limit` is taken. The result is the top `limit` of the full ranked list. A followee who only matches by name still comes first when fifty strangers' handles start with the term. Excluded accounts never use up a place, so if thirty blocked members match ahead of one visible account, the visible account is still returned.

### Example

The viewer follows the page `adaclub` ("Ada Club", muted follow) and the member `kfriend` (Ada Friend). These accounts also exist: the member `adams` (Bea Adams), the page `adalab` ("Ada Lab"), the member `lovelace` (Ada Lovelace) and the page `techhub` ("Hub of Ada"). Then `suggest(viewer, "ada")` returns, in order:

`adaclub`, `kfriend`, `adalab`, `adams`, `lovelace`, `techhub`

Here `adaclub` and `kfriend` are followed, with the handle-prefix match first. `adalab` and `adams` are handle-prefix matches, sorted by "ada lab" before "bea adams". `lovelace` and `techhub` match by name only, sorted by "ada lovelace" before "hub of ada".

## Check: `Vutuv.Mentions.check_handles(handles)`

`handles` is a list of strings. The result is `{checked, resolved}`.

- `checked` is a list. Each handle is normalized like a suggestion term (trimmed, a leading `@` dropped, lowercased). Blank entries are dropped and duplicates removed, keeping the order of first appearance. Only the **first 50** distinct handles are kept. `["@Ada", "ada", "  ", "BOB"]` gives `["ada", "bob"]`.
- `resolved` is a `MapSet` of the handles in `checked` that `VutuvWeb.Markdown.render/1` turns into a mention link (an `<a … class="mention">`):
  - A handle held by a member resolves, whatever their confirmation, moderation or block state. The renderer links every member's handle to their profile, and the profile decides what it shows. The one exception is a handle that Markdown formatting takes apart before mentions are linked: `_` marks emphasis, so `@max_mustermann_` renders as `@max` followed by an emphasised `mustermann`. The renderer does not link such a handle, so it does not resolve.
  - A handle held by a page as its root handle resolves only while the page is publicly visible (status `"active"` and not frozen).
  - A handle nobody holds does not resolve.
- No viewer is involved. The answer is the same for everyone.

`check_handles/1` and the renderer must agree for every handle, in both directions. A resolved handle renders as a link, and an unresolved one renders as plain text. This is deliberately narrower than the save-time check: a post may still mention a page that is not publicly visible (the save accepts it, as today), but that handle is not resolved, because the renderer will not link it.

Example: the member `ada`, an unconfirmed member `bob`, a public page `acme` and a pending page `hidden` exist. `check_handles(["@ADA", "bob", "acme", "hidden", "ghost"])` returns `{["ada", "bob", "acme", "hidden", "ghost"], MapSet.new(["ada", "bob", "acme"])}`.

## HTTP endpoints

Both endpoints sit with the other signed-in member pages under `/system/` and follow the same access rules. A request without a signed-in member gets the usual redirect to the home page and no JSON. Both answer `200` with a JSON body for any text in `q` or `handles`, including none. A short or missing query is an empty answer, not an error.

### `GET /system/mentions/suggest?q=<term>`

Answers `suggest(current_member, q)`, with the default limit of 8, as:

```json
{"results": [
  {"kind": "user", "handle": "adalovelace", "name": "Dr. Ada Lovelace", "avatar": null, "initials": "AL"},
  {"kind": "organization", "handle": "acme", "name": "Acme GmbH", "avatar": "/organization_images/<logo token>/…", "initials": "A"}
]}
```

Each row has exactly these five keys:

- `kind`: `"user"` for a member, `"organization"` for a page.
- `handle`: the handle without `@`.
- `name`: for a member, the honorific prefix, first name, last name and honorific suffix joined by single spaces, with blank parts skipped. For a page, its name.
- `avatar`: the URL the site already serves the account's picture at, or `null` when the account has no picture to show. For a member, this is their avatar thumbnail; an avatar still held for moderation review is not a picture to show. For a page, it is its logo, a `/organization_images/<logo token>/…` URL. The site's built-in placeholder image (a `data:` URI) is not a picture: use `null` instead.
- `initials`: what the site's avatar tile shows when there is no picture. For a member, the uppercased first letters of the first two words of their first and last name (Ada Lovelace gives `AL`; honorifics are not included). For a page, the uppercased first letter of its name (Acme GmbH gives `A`).

A missing `q` is treated as an empty term, so the answer is `{"results": []}`.

### `GET /system/mentions/check?handles=<comma-separated handles>`

Splits `handles` on commas and answers `check_handles/1` as:

```json
{"known": ["ada", "acme"], "checked": ["ada", "ghost", "acme"]}
```

- `checked` is the checked list, in its order.
- `known` lists the resolved handles in any order.

The body has exactly these two keys. A missing `handles` answers `{"known": [], "checked": []}`. With more than 50 distinct handles, only the first 50 are checked. `checked` shows which ones were looked at, so a client never reads "not checked" as "unknown".

## Compatibility

- What `VutuvWeb.Markdown` renders stays the same: which handles become links, where they point, and their text.
- Saving stays the same. The existence check still accepts any handle held by a member or a page, public or not, and the limit of 5 mentioned accounts per post is unchanged.
- Existing routes and pages are unchanged. New site pages belong under `/system/`, because profiles own the root paths.
- No new dependencies.

## Non-goals

- The editor itself: the JavaScript picker, chips, keyboard handling, the editor's `data-` attributes, and CSS.
- Translations: gettext catalogs need no changes.
- Completing remote `@user@host` addresses, or suggesting accounts on other servers.
- Changing what saving accepts or what the renderer links.
- Caching and rate limiting.
- Documentation updates are welcome but optional.

## Public interface

- `Vutuv.Mentions.suggest(viewer, term)` and `Vutuv.Mentions.suggest(viewer, term, limit)`: a ranked list of `%Vutuv.Accounts.User{}` and `%Vutuv.Organizations.Organization{}`.
- `Vutuv.Mentions.check_handles(handles)`: returns `{checked :: [String.t()], resolved :: MapSet.t(String.t())}`.
- `GET /system/mentions/suggest?q=`: returns `{"results": [{"kind", "handle", "name", "avatar", "initials"}]}`.
- `GET /system/mentions/check?handles=a,b`: returns `{"known": [...], "checked": [...]}`.
- Product constants: a 2-character minimum term, 8 suggestions by default, and at most 50 handles checked per call.
