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

The filesystem is still fully virtual — no host path is reachable. (Mounting real
host directories with explicit access modes is the next step; see the roadmap.)

## Why a virtual bash?

| | Real `System.cmd/3` | ExBashkit |
|---|---|---|
| Spawns OS processes | yes (`fork`/`exec`) | **no** — pure in-process |
| Host filesystem | full access | **virtual**, empty by default |
| Network | unrestricted | **denied** by default (allowlist planned) |
| Safe for untrusted input | no | **yes** |
| Determinism / reproducibility | depends on host | high |

It's the same design philosophy as its sibling
[ExMonty](https://github.com/jtippett/ex_monty) (sandboxed *Python*): the guest
language runs inert, and the host grants capabilities. bashkit even embeds monty
for its optional `python` builtin.

## Security model

- **Filesystem:** in-memory virtual FS; no host paths are reachable. (Mounting
  host directories with explicit modes is planned — see the roadmap.)
- **Processes:** none. All commands are reimplemented Rust builtins.
- **Network:** off by default; opt-in per-domain allowlist (planned).
- **Resource limits:** command count, loop iterations, output size, recursion
  depth (planned to be exposed; enforced in bashkit today).
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
3. ◧ Virtual filesystem — in-memory seed/read/write ✅; host-dir mounts
   (`:read_only` / `:read_write` / `:overlay`) next
4. ◻ Resource limits
5. ◻ Network allowlist
6. ◻ Elixir-defined custom builtins (call back into your app)
7. ◻ Optional builtins: `sqlite` (Turso), `typescript` (ZapCode), `python` (monty)
8. ◻ Snapshot / resume
9. ◻ LLM tool contract helpers

## Relationship to bashkit

ExBashkit pins an exact bashkit version and vendors no logic — all execution
semantics come from upstream. Version bumps follow
[`UPDATE_PROCEDURE.md`](UPDATE_PROCEDURE.md).

## License

MIT © James Tippett. bashkit is MIT-licensed by its authors.
