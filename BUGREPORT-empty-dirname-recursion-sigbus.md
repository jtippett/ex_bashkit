# Bug: an empty VirtualFs directory-entry name causes unbounded traversal → SIGBUS of the host BEAM

> **RESOLVED** (unreleased, on the 0.1.5 → next line). Fixed by validating
> directory-entry names at the native bridge (`ElixirFs::read_dir`,
> `native/ex_bashkit/src/lib.rs`): a name that is empty, `.`, `..`, or contains a
> path separator / NUL now fails the `list` op as a bounded I/O error instead of
> flowing into bashkit's walker. Investigation confirmed the two triggers below
> are distinct: the empty/`.`/`..`/separator "no net progress" cases (fixed here)
> and legitimately unbounded *depth*, which bashkit already bounds with a
> 100-level path-resolution cap. Name validation is the exact complement of that
> cap, so together they close the whole class. Regression tests:
> `test/ex_bashkit/session_vfs_malformed_listing_test.exs`.

**Version:** 0.1.4
**Severity:** Critical — a VirtualFs callback can crash the entire host OS process (all BEAM schedulers), not just the sandbox.
**Reproduces on:** amd64 (prod, SIGBUS) and arm64 (dev, `bus error`). Not platform-specific.

## Summary

When a `VirtualFs` `list/2` callback returns a directory entry whose **name is an
empty string**, the recursive traversal builtins (`find`, `grep -r`, and any
recursive walk) join that empty component onto the parent path. `path.join("")`
resolves back to the *parent directory*, so the walk re-enters the same
directory endlessly. In practice this manifests two ways:

- **`grep -ril <x> /mnt`** — spins until the session wall-clock limit and returns
  `{:error, "resource limit exceeded: execution timeout (15s)"}`. Recoverable, but
  every such command is a guaranteed 15s stall.
- **`find /mnt -type f | sort`** (recursion inside a pipeline) — **crashes the
  native NIF with SIGBUS** (`zsh: bus error`, `[os_mon] ... Erlang has closed`),
  which aborts the whole OS process. Every BEAM scheduler dies; unrelated work on
  the node is lost. The GenServer driving the script never gets a reply.

The wall-clock limiter does **not** reliably contain this: the crash path beats
the watchdog, and even the timeout path only fires after 15s.

## Root cause / injection point

`ExBashkit.Native`'s `read_dir` (native/ex_bashkit/src/lib.rs:523) takes the
`(name, is_dir)` tuples from the Elixir `list` reply and maps each straight into
a `bashkit::DirEntry { name, .. }` **without validating `name`**:

```rust
FsReply::List(entries) => Ok(entries
    .into_iter()
    .map(|(name, is_dir)| bashkit::DirEntry { name, /* ... */ })
    .collect()),
```

An empty (or `.` / `..` / slash-containing) `name` flows unchecked into the
`bashkit` crate's recursive walk, where the child path is built as
`parent.join(name)`. For `name == ""` that is `parent` again → unbounded
recursion → stack overflow surfacing as SIGBUS/SIGSEGV, which in a NIF takes down
the host process rather than unwinding.

## Minimal repro (host side)

A `VirtualFs` whose root listing contains an empty-named directory:

```elixir
defmodule Repro.Fs do
  use ExBashkit.VirtualFs
  # Root has ONE entry: a directory whose NAME IS "".
  def list(_arg, "/"), do: {:ok, [{"", :dir}]}
  def list(_arg, _),   do: {:ok, [{"file.md", :file}]}
  def stat(_arg, _),   do: {:ok, %{type: :dir, size: 0}}
  def read(_arg, _),   do: {:ok, "body\n"}
end

session = ExBashkit.Session.new(virtual_fs: %{"/skills" => {Repro.Fs, nil}})
ExBashkit.Session.exec(session, "find /skills -type f | sort")
#=> bus error (host process aborts)
```

(In our case the empty name came from an application VFS mapping a record's
blank `category` field to a directory segment. We've fixed that data path on our
side, but a sandbox must not be crashable by whatever a callback returns.)

## What we're asking ExBashkit to fix

The library's core guarantee is that untrusted script activity — and a
misbehaving/adversarial VirtualFs callback — **cannot crash the host**. Three
layers, ideally all:

1. **Validate directory-entry names at the bridge** (`read_dir`, lib.rs:523).
   Reject or skip any entry whose name is empty, is `.` / `..`, or contains a
   path separator. An invalid listing should become a Rust `Err` returned to
   Elixir as `{:error, ...}`, never a `DirEntry` fed into the walker.
2. **Make recursive traversal cycle-/depth-safe.** Bound walk depth and/or track
   visited canonical paths so no listing — empty name, self-referential symlink,
   or otherwise — can produce unbounded recursion.
3. **Guarantee no callback input can SIGBUS/segfault the host.** Convert
   traversal stack-overflow risk into a bounded error (iterative walk or an
   explicit depth cap). A resource-limit timeout is acceptable degradation; a
   native crash of the whole BEAM node is not.

Item 3 is the important one: the 15s-timeout mode is merely annoying, but the
SIGBUS mode is a full-node outage triggerable by ordinary data.
