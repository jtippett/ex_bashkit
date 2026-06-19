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

## Virtual filesystem backends

Mount an **Elixir-backed filesystem** at a path: the script's reads and writes
under it are serviced by your application, so "files" can be generated on demand
or proxied to a real store. A backend is a module implementing the
`ExBashkit.VirtualFs` behaviour (as `module` or `{module, arg}`), or a single
dispatch function for inline use.

```elixir
session =
  ExBashkit.Session.new(
    virtual_fs: %{
      "/api" => fn
        %{op: :read, path: "/" <> name} -> {:ok, "generated: #{name}\n"}
        _ -> {:error, :enotsup}
      end
    }
  )

ExBashkit.Session.exec(session, "cat /api/widget")
# => {:ok, %ExBashkit.Result{stdout: "generated: widget\n", exit_code: 0}}
```

Reads and writes are both supported (`read`/`write`/`append`/`mkdir`/`remove`/
`list`/`stat`); paths arrive rooted at the mount. It composes with the in-memory
FS, `:files`, and host `:mounts`, and reuses the same back-call machinery (and
failure isolation) as custom builtins.

## Python (optional)

With the optional [`ex_monty`](https://github.com/jtippett/ex_monty) dependency,
a session can run **sandboxed Python that shares the bash filesystem** — so a file
one step writes, the next step reads, across the bash/Python boundary, just like a
real shell.

```elixir
# add {:ex_monty, "~> ..."} to your deps, then:
session = ExBashkit.Session.new(python: true)

ExBashkit.Session.exec(session, """
  printf '1\\n2\\n3\\n' > /nums.txt
  python -c "from pathlib import Path; \\
             print(sum(int(x) for x in Path('/nums.txt').read_text().split()))"
""")
# => {:ok, %ExBashkit.Result{stdout: "6\n", exit_code: 0}}
```

`python: true` registers `python` and `python3`. A script runs `python file.py`,
`python -c "…"`, or a program piped on stdin; Python's `pathlib`/`os` filesystem
operations are routed to the same virtual filesystem (`cat`, `>`, mounts, and
`:virtual_fs` all interoperate). Python runs fully sandboxed — every effect except
the filesystem and `os.getenv` is denied (no network, no clock) — and a Python
error or timeout fails only that command, never the session.

It's an Elixir-defined builtin over the same back-call bridge as `:builtins`, so
there's no change to the precompiled NIF; you opt in purely by adding `ex_monty`
to your deps. (Current limits: no `sys.argv`; `pathlib.Path` I/O, not `open()`.)

**Without `ex_monty`, ExBashkit still compiles and runs normally** — `ex_monty` is
an optional dependency gated at runtime. The only difference: `python: true` then
raises a clear `ArgumentError` at `Session.new/1` telling you to add the dep
(fail-fast, never a mysterious crash mid-script). A session created **without**
`python:` is unaffected — a script that runs `python` simply gets a
command-not-found, exactly as if the executable weren't installed.

## Snapshot & resume

Capture a session's state to a binary and reload it later — after a restart, or
on another node. `snapshot/2` serializes the **shell state** (variables, env,
cwd, aliases, functions) **and in-memory filesystem contents**; `restore/3` loads
it back.

```elixir
session = ExBashkit.Session.new()
{:ok, _} = ExBashkit.Session.exec(session, "x=42; echo data > /work.txt")

{:ok, bytes} = ExBashkit.Session.snapshot(session)
# ...persist `bytes`, restart, come back later...

resumed = ExBashkit.Session.new()
{:ok, resumed} = ExBashkit.Session.restore(resumed, bytes)
ExBashkit.Session.exec(resumed, "echo $x; cat /work.txt")
# => {:ok, %ExBashkit.Result{stdout: "42\ndata\n", exit_code: 0}}
```

A snapshot carries interpreter state, **not** session *configuration*: custom
`:builtins`, `:virtual_fs` backends, host `:mounts`, and `:limits` are live
Elixir processes / builder config, not bytes. To resume a session that used
them, rebuild it with the **same capabilities**, then restore — the backends
re-attach live and only the shell + in-memory FS travel in the snapshot.
`restore/3` preserves the target session's capabilities and validates the whole
snapshot before mutating, so a bad snapshot returns `{:error, _}` and leaves the
session usable.

For snapshots that cross a **trust boundary** (network, shared storage, untrusted
input), pass `key:` — an HMAC secret that must match on restore; a wrong key or
tampered bytes are rejected. Without a key, the embedded digest detects accidental
corruption only (it is public, not a forgery defense). `:exclude_filesystem` and
`:exclude_functions` trim what is captured.

## Using a session as an LLM tool

ExBashkit deliberately ships **no** `Tool` module. Wiring a sandbox to an LLM is a
handful of plain data — a JSON schema, a system prompt, and a function that runs a
tool call and formats the result — and every agent framework wants that data in
its own shape. So it's a short recipe rather than a dependency:

```elixir
session = ExBashkit.Session.new(python: true)

# 1. The tool's input schema (mirrors bashkit's BashTool contract):
schema = %{
  "type" => "object",
  "required" => ["commands"],
  "properties" => %{"commands" => %{"type" => "string"}}
}

# 2. Run one tool call -> the string the model sees:
run = fn %{"commands" => commands} ->
  case ExBashkit.Session.exec(session, commands) do
    {:ok, %ExBashkit.Result{stdout: out, stderr: err, exit_code: code}} ->
      out <> (if err == "", do: "", else: "\n[stderr]\n" <> err) <>
              (if code == 0, do: "", else: "\n[exit #{code}]")
    {:error, message} -> "tool error: #{message}"
  end
end
```

Because a **session** persists state across calls, the model can build up a
workspace over a multi-step turn (write a file, process it, run `python3` on it) —
exactly what you want from an agentic shell. Plug `run` into any framework, e.g.
[ReqLLM](https://hex.pm/packages/req_llm):

```elixir
{:ok, tool} =
  ReqLLM.Tool.new(
    name: "bash",
    description: "Run bash in a sandboxed virtual shell.",
    parameter_schema: [commands: [type: :string, required: true]],
    callback: fn args -> {:ok, run.(args)} end
  )
```

A complete, runnable version (with a system prompt and a simulated agent turn) is
in [`examples/llm_tool.exs`](examples/llm_tool.exs).

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
7. ✅ Dynamic Elixir-backed filesystem (`:virtual_fs` — same back-call bridge)
8. ✅ Sandboxed `python` builtin (optional `ex_monty`; shares the session FS).
   `sqlite`/`typescript` dropped (use a back-call); native bashkit interpreters
   not pursued (not on crates.io, would break the pin)
9. ✅ Snapshot / resume (`snapshot/2` + `restore/3`, keyed or plain)
10. ✅ LLM tool contract — a documented recipe (`examples/llm_tool.exs`), not a
    module: a session is a tool in ~10 lines, framework-agnostic

## Relationship to bashkit

ExBashkit pins an exact bashkit version and vendors no logic — all execution
semantics come from upstream. Version bumps follow
[`UPDATE_PROCEDURE.md`](UPDATE_PROCEDURE.md).

## License

MIT © James Tippett. bashkit is MIT-licensed by its authors.
