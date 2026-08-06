### rtk — token-optimized CLI proxy

Prefix read-heavy shell commands with `rtk` to cut output tokens by 60–90%:

```bash
rtk git status      rtk git diff      rtk git log     rtk git show
rtk grep …          rtk find …        rtk ls …        rtk cat …
rtk kubectl get …   rtk kubectl logs …                rtk dotnet build
rtk gh pr view …    rtk gh run list …
```

**There is no automatic rewriting in this deployment.** If you do not type
`rtk` yourself, you pay the full token cost. (The auto-rewrite described in
rtk's own documentation is a Claude Code `PreToolUse` hook; netclaw has no hook
system, so nothing rewrites commands on your behalf.)

Use the plain command, never `rtk`, when you need exact unfiltered output —
parsing precise formatting, or debugging the command itself.

Meta commands, always unprefixed:

```bash
rtk gain              # savings so far
rtk gain --history    # per-command history
rtk proxy <cmd>       # raw passthrough, no filtering
```

### Environment

- The toolchain (`dotnet`, `node`, `npm`, `rg`, `kubectl`, `helm`, `terraform`,
  `sops`, `gh`, `aws`, `hugo`, `qmd`, `bru`, `psql`, `ssh`, …) lives on
  `/tools/bin`, mounted **read-only**. Treat it as immutable — do not try to
  install into it. Use `uv` or `npm --prefix` under `$HOME` for anything extra.
- `redis` is at `redis:6379` (`$REDIS_URL`).
- There is **no local browser binary**. A headless Chromium is reachable over
  CDP at `$BROWSER_WS_ENDPOINT`; drive it with `puppeteer-core` via `connect()`,
  not `launch()`.
- Web search is a local SearXNG instance at `http://searxng:8080`
  (`$SEARXNG_URL`). Prefer the `searxng` MCP tools (search + URL reader); the
  raw JSON API also works: `curl "http://searxng:8080/search?q=…&format=json"`.
  There is no external search API key in this deployment.
- `~/.cache` and `~/.nuget` persist across restarts; the rest of `$HOME` outside
  `~/.netclaw` does not.
- Git commits are authored from `~/.netclaw/gitconfig` and signed with an ssh
  key. Pushes authenticate as the `GH_TOKEN` account. Do not change the
  committer identity.
- `csharp-ls` is installed but there is no LSP client here, so it cannot provide
  go-to-definition or find-references. Use `rg` plus the file tools for C#
  navigation.
