# ExBashkit

Elixir NIF wrapper for [**bashkit**](https://github.com/everruns/bashkit) — a
sandboxed, virtual bash interpreter written in Rust.

Run bash scripts safely from Elixir: ~150 builtins (`echo`, `grep`, `sed`,
`awk`, `jq`, `cat`, `find`, `sort`, …) are **reimplemented in Rust**, file I/O
hits an **in-memory virtual filesystem**, and there is **no `fork`/`exec`**
escape hatch. Nothing touches the host OS unless you explicitly grant it. That
makes it safe to run *untrusted* scripts — for example, bash written by an LLM
agent.

> ⚠️ **Early days.** Stateless `ExBashkit.exec/1` and persistent
> `ExBashkit.Session`s are wired up today. The rest of the surface
> (virtual-filesystem mounts, resource limits, a network allowlist,
> Elixir-defined custom builtins, snapshot/resume) is in progress — see
> [`PORTING.md`](PORTING.md) for the plan and current status.

## Installation

```elixir
def deps do
  [
    {:ex_bashkit, "~> 0.1"}
  ]
end
```

A precompiled NIF is downloaded for your platform — no Rust toolchain required
to *use* the library. Supported targets: `{x86_64,aarch64}-apple-darwin` and
`{x86_64,aarch64}-unknown-linux-gnu`.

## Quick start

```elixir
iex> ExBashkit.exec("echo hello | tr a-z A-Z")
{:ok, %ExBashkit.Result{stdout: "HELLO\n", stderr: "", exit_code: 0}}

iex> ExBashkit.exec("for i in 1 2 3; do echo $((i * i)); done")
{:ok, %ExBashkit.Result{stdout: "1\n4\n9\n", exit_code: 0}}

# A non-zero exit is still {:ok, ...} — the script ran and chose to fail,
# exactly like a real shell.
iex> ExBashkit.exec("test -f /etc/passwd")
{:ok, %ExBashkit.Result{exit_code: 1}}
```

## Persistent sessions

`ExBashkit.exec/1` is stateless — each call is a fresh sandbox. When you want
state to carry across calls (like an interactive shell), use a
`ExBashkit.Session`: environment variables, the working directory, the in-memory
filesystem, shell functions and aliases all persist.

```elixir
session = ExBashkit.Session.new()

ExBashkit.Session.exec(session, "export GREETING=hello")
ExBashkit.Session.exec(session, "cd /tmp && echo world > note.txt")

{:ok, result} = ExBashkit.Session.exec(session, "echo $GREETING $(cat /tmp/note.txt)")
result.stdout
# => "hello world\n"
```

Seed the initial state with options:

```elixir
session =
  ExBashkit.Session.new(
    env: %{"LANG" => "C"},
    cwd: "/tmp",
    username: "alice",
    hostname: "my-server"
  )

ExBashkit.Session.exec(session, "whoami")   # => "alice\n"
ExBashkit.Session.exec(session, "pwd")      # => "/tmp\n"
```

A session serializes its own calls — concurrent `exec/2` on the *same* session
run one at a time. Separate sessions are fully independent.

## Virtual filesystem

A session's filesystem is in-memory and shared between scripts and the host. You
can seed inputs, then pull results back out — without going through a script:

```elixir
session = ExBashkit.Session.new(files: %{"/in/data.csv" => "a,1\nb,2\n"})

{:ok, _} = ExBashkit.Session.exec(session, "cut -d, -f1 /in/data.csv | sort > /out.txt")

ExBashkit.Session.read_file(session, "/out.txt")
# => {:ok, "a\nb\n"}
```

- `ExBashkit.Session.new(files: %{path => content})` seeds files up front (content
  is any iodata; parent dirs are created).
- `ExBashkit.Session.write_file(session, path, content)` places a file at any time.
- `ExBashkit.Session.read_file(session, path)` returns `{:ok, binary}` — including
  files a script wrote — round-tripping arbitrary (even non-UTF-8) bytes.

By default the filesystem is fully virtual — no host path is reachable.

## Host mounts

To give a sandbox controlled access to real host directories, map them in with
explicit access modes:

```elixir
session =
  ExBashkit.Session.new(
    mounts: [
      {"/data", "/srv/app/data", :read_only},
      {"/work", "/tmp/sandbox-work", :read_write}
    ]
  )

{:ok, _} = ExBashkit.Session.exec(session, "wc -l /data/*.csv > /work/counts.txt")
# /tmp/sandbox-work/counts.txt now exists on the real disk.
```

- `:read_only` — scripts read host files; writes fail.
- `:read_write` — scripts read **and modify** real host files (a footgun — use a
  dedicated directory).

bashkit enforces the isolation: paths are canonicalized, and `..` traversal or
symlinks that escape the mounted directory are rejected — a mount of
`/srv/app/data` can't reach `/srv/app/secrets`. Sensitive host locations
(`/etc`, `/home`, `/Users`, `/private`, paths with `.ssh`/`.aws`, …) are
**refused by default**; pass `:allowed_mount_paths` to opt in (note: setting it
switches bashkit from the built-in denylist to allowlist-only gating). On macOS,
temp dirs under `/var/folders` canonicalize beneath `/private`, so mounting them
needs an allowlist entry. A refused or misconfigured mount raises from `new/1`.

> `:overlay` mounts (host-backed, copy-on-write) are intentionally **not**
> supported: bashkit has no real-FS overlay mode, and ExBashkit only exposes what
> bashkit does. For copy-on-write behavior, use the in-memory filesystem.

## Resource limits

bashkit bounds execution with safe defaults; tighten them per session for
untrusted scripts. Exceeding a limit returns `{:error, message}`.

```elixir
session = ExBashkit.Session.new(limits: [max_commands: 1_000, timeout_ms: 2_000])

ExBashkit.Session.exec(session, "for i in {1..1000000}; do :; done")
# => {:error, "resource limit exceeded: maximum command count exceeded (1000)"}
```

Available limits: `:max_commands`, `:max_loop_iterations`,
`:max_total_loop_iterations`, `:max_function_depth`, `:max_input_bytes`,
`:timeout_ms`. Each is optional and defaults to bashkit's value.

## Network access

A session cannot reach the network until you grant it an allowlist. `:allow_net`
is default-deny — only requests matching a pattern's scheme, host, port, and
path-prefix are permitted, and redirects are not followed.

```elixir
session = ExBashkit.Session.new(allow_net: ["https://api.example.com"])

ExBashkit.Session.exec(session, "curl -s https://api.example.com/v1/health")
# => {:ok, %ExBashkit.Result{exit_code: 0, ...}}

ExBashkit.Session.exec(session, "curl -s https://evil.example")
# => blocked (non-zero exit) — not on the allowlist
```

Requests to private/reserved IPs (loopback, RFC 1918, link-local, …) are blocked
by default to prevent SSRF, even when the URL is allowlisted; pass
`block_private_ips: false` to reach a localhost service deliberately. Use
`allow_net: :all` only for fully trusted scripts.

## Custom builtins

Register Elixir functions as **virtual executables** the script can call. A
script line `name args…` calls back into your application, which returns the
command's output — the way to expose capabilities you control (a database query,
a lookup, an approval step) without real process or network access.

```elixir
session =
  ExBashkit.Session.new(
    builtins: %{
      "kv_get" => fn call ->
        case Map.fetch(%{"answer" => "42"}, hd(call.args)) do
          {:ok, value} -> {:ok, value <> "\n"}
          :error -> {:error, "no such key\n"}
        end
      end
    }
  )

ExBashkit.Session.exec(session, "echo \"the answer is $(kv_get answer)\"")
# => {:ok, %ExBashkit.Result{stdout: "the answer is 42\n", exit_code: 0}}
```

A builtin receives `%{args:, stdin:, env:}` and returns `{:ok, iodata}` (stdout,
exit 0), `{:error, iodata}` (stderr, exit 1), or a full `%ExBashkit.Result{}`. A
handler that raises or exceeds `:builtin_timeout_ms` fails only that command, not
the session.

## Why a virtual bash?

| | Real `System.cmd/3` | ExBashkit |
|---|---|---|
| Spawns OS processes | yes (`fork`/`exec`) | **no** — pure in-process |
| Host filesystem | full access | **virtual**, empty by default |
| Network | unrestricted | **denied** by default; opt-in per-URL allowlist |
| Safe for untrusted input | no | **yes** |
| Determinism / reproducibility | depends on host | high |

It's the same design philosophy as its sibling
[ExMonty](https://github.com/jtippett/ex_monty) (sandboxed *Python*): the guest
language runs inert, and the host grants capabilities. bashkit even embeds monty
for its optional `python` builtin.

## Security model

- **Filesystem:** in-memory virtual FS; no host paths are reachable unless you
  explicitly mount them (`:read_only` / `:read_write`), with canonicalization,
  escape rejection, and a sensitive-path default-deny enforced by bashkit.
- **Processes:** none. All commands are reimplemented Rust builtins.
- **Network:** off by default; opt-in per-URL allowlist (`:allow_net`) with
  redirect-blocking and private-IP/SSRF protection enforced by bashkit.
- **Resource limits:** command count, loop iterations, recursion depth, input
  size, and a wall-clock timeout — tunable per session via `:limits`.
- **Isolation:** each `exec/1` runs in an independent sandbox; a
  `Session` is an independent sandbox that persists across its own calls.

## Development

To build the NIF from source (instead of downloading a precompiled one):

```bash
export EXBASHKIT_BUILD=1
mix deps.get
mix test
```

This requires a Rust toolchain. The first build is slow — bashkit and its
dependencies are large.

CI runs `mix format --check-formatted`, `cargo fmt --check`,
`cargo clippy -- -D warnings`, and `mix test` on every push/PR.

## Roadmap

See [`PORTING.md`](PORTING.md) for the staged plan. In brief:

1. ✅ Stateless `exec/1` (skeleton, proves the toolchain)
2. ✅ Persistent sessions (state across calls)
3. ✅ Virtual filesystem — in-memory seed/read/write, plus `:read_only` /
   `:read_write` host-directory mounts
4. ✅ Resource limits (`:limits` — commands, loops, recursion, input size, timeout)
5. ✅ Network allowlist (`:allow_net` — default-deny per-URL, SSRF protection)
6. ✅ Elixir-defined custom builtins (`:builtins` — call back into your app)
7. ◻ Dynamic Elixir-backed filesystem (same back-call bridge as custom builtins)
8. ◻ Optional builtins: `sqlite` (Turso), `typescript` (ZapCode), `python` (monty)
9. ◻ Snapshot / resume
10. ◻ LLM tool contract helpers

## Relationship to bashkit

ExBashkit pins an exact bashkit version and vendors no logic — all execution
semantics come from upstream. Version bumps follow
[`UPDATE_PROCEDURE.md`](UPDATE_PROCEDURE.md).

## License

MIT © James Tippett. bashkit is MIT-licensed by its authors.
