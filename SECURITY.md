# Security

Please report a vulnerability privately through
[GitHub's security advisories](https://github.com/tbgihu/tidemark/security/advisories/new), not in a public issue.
Include what you found, how to reproduce it, and the commit you tested.

## What Tidemark holds

- **OAuth tokens** for each Claude account you add, in your login keychain (service `io.github.tbgihu.tidemark`,
  account `oauth-tokens`, split over `oauth-tokens#1`… when longer than one item holds). They are never written
  anywhere else, never logged, and only sent to Anthropic.
- **Admin API keys** for each API organisation you add, in a second item of the same service (account
  `admin-api-keys`). They too are never written anywhere else, never logged, and only sent to `api.anthropic.com`.
  An admin key has full admin rights over its organisation, though Tidemark only calls two read-only endpoints with
  it (`/v1/organizations/me` and `/v1/organizations/cost_report`). Use a dedicated key with an expiry, and revoke it
  in the Claude Console when you no longer need it: removing the organisation from Tidemark deletes the key from this
  Mac but doesn't revoke it.
- **Usage data** (percentages and reset times), names and email addresses, organisation names and daily costs in
  `~/Library/Application Support/Tidemark`.
- Each provider's credentials in an item of their own in the same service, one per way of signing in (see
  `Login.secretItem`), held to the same rules: never written anywhere else, never logged, sent only to that provider.
  A provider that signs in on its website keeps its session in a web data store of the account's own, isolated from
  Safari and every other account, and deleted with the account.

### Who can read the Keychain items

Tidemark creates, reads and deletes its items only through Apple's `/usr/bin/security`, so their access list names
that tool rather than one build of Tidemark. That is what lets every rebuild and update read them without asking: a
locally signed app has no Apple team, so macOS would otherwise tie the items to Tidemark's exact build. The cost is
that **any process running as you can read them without a prompt**, by running `security find-generic-password` the
same way. This is the same trust boundary as command-line tools that keep tokens in the Keychain (`gh`, for one):
it protects the secrets at rest and from other users, not from software you already run. A build signed with an
Apple Developer ID would allow a stricter access list naming Tidemark alone; Tidemark is built on your Mac without
one.

Secrets never appear in a process's arguments: they reach `security` on its standard input. Tidemark never hands a
locked keychain to the tool (it would ask for your password); it waits until the keychain is unlocked. Each item
carries a marker, and Tidemark never reads, overwrites or deletes an item it didn't write.

### Where Tidemark connects

Tidemark talks only to the providers of the accounts you add, and only to read: a few requests per refresh, and one
a day to check whom a credential belongs to, each to that provider's own hosts:

- **Claude**: `api.anthropic.com` (`/api/oauth/usage` and `/api/oauth/profile`; for Console organisations,
  `/v1/organizations/me` and `/v1/organizations/cost_report`), `platform.claude.com` (tokens) and, while you sign in,
  `claude.com`/`claude.ai`.
- **OpenAI**: `chatgpt.com` (`/backend-api/wham/usage`) and `auth.openai.com` (device-code sign-in and token
  refresh) for ChatGPT accounts; `api.openai.com` (`/v1/organization/costs`) for API organisations. It keeps a
  ChatGPT account's tokens and the claims it needs from the ID token (ids, name, email), never the ID token itself.
- **Copilot**: `github.com` (device sign-in and token refresh, with Tidemark's own OAuth App and the `read:user`
  scope) and `api.github.com` (`/user` and `/copilot_internal/user`).
- **Cursor**: `cursor.com` (`/api/usage-summary` and `/api/auth/me`) with the session cookie. While you sign in, the
  sheet shows Cursor's own sign-in pages (`authenticator.cursor.sh`, WorkOS) and whichever identity provider you
  choose there, and never leaves the account's isolated data store.
- **Antigravity**: nothing directly. Tidemark runs Antigravity's own command line tool, `agy -p /usage` and `agy -p
  /credits`, in plan mode, sandboxed, in an empty folder and without a `PATH`, and reads what it prints; `agy`
  answers from Google with its own sign-in. Tidemark never reads Antigravity's files or credentials, stores nothing
  for it, and stops a reading that asks to sign in.
- **xAI**: `management-api.x.ai` (the team's prepaid balance, invoice preview and daily usage).
- **OpenRouter**: `openrouter.ai` (`/api/v1/key`, and `/api/v1/credits` with a management key).
- **Warp**: `app.warp.dev` (`/graphql/v2`), whose edge requires a Warp-like User-Agent.
- **DeepSeek**: `api.deepseek.com` (`/user/balance`).
- **Kimi**: `api.kimi.ai` or `api.kimi.com` (Kimi Code usage), `api.moonshot.ai` or `api.moonshot.cn` (Moonshot API
  balance), by the region chosen.
- **z.ai**: `api.z.ai` or `open.bigmodel.cn` (GLM Coding Plan quota), by the region chosen.
- **MiniMax**: `api.minimax.io` or `api.minimaxi.com` (Coding Plan remains), by the region chosen.
- **Ollama**: `ollama.com` (`/api/balance`), at most once a minute, inside its documented 10 requests a minute.
- **OpenCode**: `opencode.ai` (`/zen/go/v1/usage`, and the Console's `/console/api/billing/status` and
  `/console/api/usage/summary`).
- **ElevenLabs**: `api.elevenlabs.io` (`/v1/user/subscription`), with a key that needs only Read access to User.

It never reads the credentials, cookies or files of the providers' own apps or of any browser.

Besides these, its updates run `git fetch` in the clone it was built from, every 2 hours unless they are set to
Manually in Settings. Updates build the newest commit of the clone's remote (its upstream branch), from source, on
this Mac. During an OAuth sign-in it listens on a random port of `127.0.0.1`/`::1` for the redirect, rejects any
request whose `state` doesn't match, and stops listening once the sign-in ends.
