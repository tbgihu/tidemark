# Adding a provider

A provider is one folder, `Sources/Providers/<Name>/`, and one line in `Registry.builtIn`
(`Sources/Core/Registry.swift`). Nothing else in Tidemark knows it: the menu bar, the panel, Settings, the scheduler,
the Keychain, history and notifications work from its descriptor alone. `Sources/Providers/Claude/` is the reference.

## The descriptor

```swift
enum Acme {
    static let id = "acme"                                   // reserved in Registry.order, stable for ever
    static let provider = Provider(
        id: id, name: "Acme", company: "Acme Inc.",           // name: tabs, sections, menus; company: status lines
        brandColor: BrandColor(hex: 0x3478F6),                // readable on light and dark menu bars, unlike any other
        order: Registry.order(of: id),
        recommendedMinimumInterval: 300,                      // below this, Settings warns of rate limits
        logins: [apiKey])
}
```

Each `Login` is one way to sign in, shown in the Add menu (a provider with several gets a submenu):

| Field | |
|---|---|
| `id`, `title`, `subtitle`, `symbol` | The Add menu item. |
| `auth` | `.oauth(OAuthPKCE)`, `.deviceCode(DeviceCodeFlow)`, `.secret(SecretForm)` or `.web(WebLogin)`. |
| `secretItem` | Its Keychain item, unique across all logins (`"acme-api-key"`). |
| `identify` | Checks a credential and says whom it belongs to (`Identity`). Runs at sign-in and once a day. |
| `fetch` | One refresh: returns a `Snapshot`. |
| `accountID` | Makes the account id from the identity; prefix it (`{ "acme-" + $0 }`) so it is unique everywhere. |
| `minimumInterval`, `reportsMeters`, `history`, `alerts`, `kindLabel`, `texts` | Optional; see `Provider.swift`. |

### Auth kinds

- **OAuth PKCE**: give the endpoints, client id and scopes; Tidemark runs the browser window, loopback redirect,
  exchange and refresh.
- **Device code**: `DeviceCodeFlow.standard(clientID:deviceURL:tokenURL:scope:)` for RFC 8628; or your own
  `start`/`poll`. The sheet shows the code and opens the verification page.
- **Secret**: a `SecretForm` with a `.secret` field and any `.text` or `.choice` fields (team id, region). The
  first secret becomes `Credential.secret`, the others (an optional second key too) `Credential.fields`. `validate`
  catches a wrong kind of key before any request; `explain` words failures. `APIKey` has the rest: the optional
  `nameInput` and `Region.input` fields, `fingerprint` for an account id that never reveals the key, `name` and
  `hint` to name it, and `LoginTexts.key` for the login's texts. A form without fields only explains and checks:
  for a provider read through its own command line tool, which keeps its own sign-in (Antigravity).
- **Web**: a start URL and the cookie to keep. Tidemark shows a `WKWebView` in a data store of the account's own, only
  while signing in; pages that open a new window open it in the same view. `note` tells the user, above the page,
  what can't work in it. Prefer any of the others when the provider offers one.

## The snapshot

```swift
Snapshot(meters: [Meter(id: "daily", title: "Daily requests", label: "day", percent: 34, resetsAt: reset, short: true)],
         money: [Money(id: "balance", title: "Credit balance", role: .balance, amount: 8.4, currency: "USD", headline: true)],
         plan: "Pro", fetchedAt: Date())
```

- **Meters** are percentages used, 0–100. The menu bar shows the first three by `label` (a few characters). Keep `id`
  stable: history, notifications and their state key on it. Set `reportedSeverity` when the provider grades the limit
  itself; `short` for a window of hours (it notifies later).
- **Money** is exact `Decimal` in major units. `limit` draws a bar against a cap; `start`/`end` say which period an
  amount covers (it is withheld once the period is over); `headline` makes it the menu bar figure of an account with no
  meters.
- **`note`** says why an account reports nothing ("No active plan"), in place of "No usage limits reported". An
  account without a plan or access is a snapshot with a note, not a failure.
- Decode leniently: skip what you don't understand rather than failing the response, and throw `.unreadable` only
  when the body is not a usage response at all. `Wire` reads numbers sent as numbers or strings (`c.number(_:)`),
  moments as ISO 8601 or Unix seconds or milliseconds (`c.moment(_:)`) and trimmed strings (`c.text(_:)`).
- Menu bar labels are at most four characters, named by the window: `5h`, `day`, `w`, `mo`. An account without a
  plan, or whose plan lacks the product, notes `Snapshot.noPlan` or `Snapshot.unavailable(_:)`.

Use `context.http` for every request (`http.decode(request) { … }` maps 401, 403 and 429 with Retry-After). Never
retry or sleep inside `fetch`: the scheduler staggers all accounts, backs off and honours Retry-After. Map provider
errors onto `FetchFailure`; `.unauthorized` is retried once after a token refresh when the login can refresh.

## Tests

Add `Tests/TidemarkTests/<Name>Tests.swift`: decode real (anonymised) responses, run `fetch` and `identify` against
a canned `HTTP` transport (`Canned`), and check the snapshot. `RegistryTests` checks your id, order, colour (readable,
and apart from every other's) and Keychain item for you. Run `make test`, then `make build DEBUG=1` and `--sample 5 --selftest`.

## Privacy rules

- Never read another app's credentials, cookies, keychain items or local files. Sign in only through the auth kinds
  above.
- Secrets go only through the secret store (`Credential`, saved by Tidemark). Never log them, put them in a URL or
  argument, or write them anywhere else. Log nothing that identifies an account.
- Send an honest User-Agent (`HTTP.userAgent`, the default) unless the provider documents another.
- Call only the provider's own hosts, read-only endpoints, with the least privilege it offers. List them in
  SECURITY.md.
