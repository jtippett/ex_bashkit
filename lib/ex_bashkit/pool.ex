defmodule ExBashkit.Pool do
  @moduledoc """
  An optional bounded-concurrency gate for running sandboxed scripts under load.

  Every `ExBashkit.exec/1` and `ExBashkit.Session.exec/2` call blocks a **dirty
  scheduler thread** for the whole duration of the script (the native interpreter
  runs synchronously inside a dirty NIF). The dirty pool is bounded — roughly one
  thread per scheduler — so if you let untrusted, possibly-slow scripts run with
  unbounded concurrency, enough of them in flight at once can occupy every dirty
  thread and starve *all* native work on the node until they time out.

  This pool caps how many run concurrently. It hands out a fixed number of
  **permits**; callers over that limit wait in a bounded queue, and callers past
  the queue are rejected with `{:error, :overloaded}` so you can shed load instead
  of piling work onto exhausted schedulers. It is **opt-in**: add it to your
  supervision tree and route untrusted execs through it.

      children = [
        {ExBashkit.Pool, size: 8, max_queue: 100}
      ]

      # Anywhere you'd run an untrusted script:
      ExBashkit.Pool.run(fn -> ExBashkit.Session.exec(session, script) end)
      #=> {:ok, %ExBashkit.Result{}} | {:error, :overloaded}

  `size` and `max_queue` may also be set in config and are overridden by the
  options you pass to the child spec:

      config :ex_bashkit, pool_size: 8, pool_max_queue: 100

  `size` defaults to `System.schedulers_online/0` and `max_queue` to `50`. Pick a
  `size` no larger than your dirty-scheduler budget — keeping it *below* the
  scheduler count leaves headroom for other native work.

  ## Notes

  - The script runs in the **calling process**, not in the pool — the pool only
    gates entry, so throughput still scales across `size` schedulers.
  - A permit is released when the work returns, raises, **or** the caller dies:
    each holder is monitored, so a crashed or killed caller can never leak a slot.
  - `run/1,2` blocks (with no call timeout) while queued; it returns only once a
    permit is granted or the queue is full. A script's own `:timeout_ms` still
    bounds how long any one permit is held.
  - A process must not call `run/1,2` **reentrantly** on a pool it already holds a
    permit on — that would deadlock waiting for a slot only it could free, so it
    raises instead. Nested work belongs on a different pool.
  - The pool is a singleton registered under `:name` (default `ExBashkit.Pool`).
    To run several isolated pools, give each a distinct `:name`.
  """

  use GenServer

  @default_max_queue 50

  # --- Public API -----------------------------------------------------------

  @doc """
  Start the pool. Options:

    * `:name` - the registered name (default `ExBashkit.Pool`).
    * `:size` - max concurrent permits (default: `config :ex_bashkit, :pool_size`,
      else `System.schedulers_online/0`).
    * `:max_queue` - max callers that may wait for a permit before new callers are
      rejected with `{:error, :overloaded}` (default: `config :ex_bashkit,
      :pool_max_queue`, else `#{@default_max_queue}`).
  """
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Run `fun` (a 0-arity function) under a pool permit, returning its value.

  Blocks while waiting for a permit if the pool is at capacity; returns
  `{:error, :overloaded}` immediately if the wait queue is also full. The permit
  is released when `fun` returns or raises (and automatically if the caller dies).
  """
  def run(fun) when is_function(fun, 0), do: run(__MODULE__, fun)

  def run(pool, fun) when is_function(fun, 0) do
    case GenServer.call(pool, :acquire, :infinity) do
      :ok ->
        try do
          fun.()
        after
          GenServer.cast(pool, {:release, self()})
        end

      {:error, :overloaded} = error ->
        error

      {:error, :reentrant} ->
        raise "ExBashkit.Pool.run/2 was called from a process that already holds a permit " <>
                "on this pool. A nested call would block forever waiting for a slot only it " <>
                "could free. Run nested work on a different pool, or outside the pool."
    end
  end

  @doc "Convenience wrapper: `run(pool, fn -> ExBashkit.exec(script) end)`."
  def exec(pool \\ __MODULE__, script) when is_binary(script) do
    run(pool, fn -> ExBashkit.exec(script) end)
  end

  @doc "Convenience wrapper: `run(pool, fn -> ExBashkit.Session.exec(session, script) end)`."
  def session_exec(pool \\ __MODULE__, session, script) when is_binary(script) do
    run(pool, fn -> ExBashkit.Session.exec(session, script) end)
  end

  # --- GenServer ------------------------------------------------------------

  @impl true
  def init(opts) do
    size =
      Keyword.get(opts, :size) || Application.get_env(:ex_bashkit, :pool_size) ||
        System.schedulers_online()

    max_queue =
      Keyword.get(opts, :max_queue) || Application.get_env(:ex_bashkit, :pool_max_queue) ||
        @default_max_queue

    unless is_integer(size) and size > 0 do
      raise ArgumentError,
            "ExBashkit.Pool :size must be a positive integer, got: #{inspect(size)}"
    end

    unless is_integer(max_queue) and max_queue >= 0 do
      raise ArgumentError,
            "ExBashkit.Pool :max_queue must be a non-negative integer, got: #{inspect(max_queue)}"
    end

    # `running`: pid => monitor ref (one permit per process). `waiting`: a FIFO of
    # {from, monitor_ref, pid} blocked on a permit. Every holder and waiter is
    # monitored so its slot is reclaimed if it dies.
    {:ok, %{size: size, max_queue: max_queue, running: %{}, waiting: :queue.new()}}
  end

  @impl true
  def handle_call(:acquire, {pid, _} = from, state) do
    cond do
      # One permit per process. A reentrant acquire would overwrite the holder's
      # monitor ref (leaking it and letting real concurrency exceed `size`), or
      # self-deadlock if the pool is full. Reject it; `run/2` turns this into a
      # loud raise rather than a silent hang.
      Map.has_key?(state.running, pid) ->
        {:reply, {:error, :reentrant}, state}

      map_size(state.running) < state.size ->
        ref = Process.monitor(pid)
        {:reply, :ok, %{state | running: Map.put(state.running, pid, ref)}}

      :queue.len(state.waiting) < state.max_queue ->
        ref = Process.monitor(pid)
        {:noreply, %{state | waiting: :queue.in({from, ref, pid}, state.waiting)}}

      true ->
        {:reply, {:error, :overloaded}, state}
    end
  end

  @impl true
  def handle_cast({:release, pid}, state) do
    case Map.pop(state.running, pid) do
      {nil, _running} ->
        # Unknown pid: already reclaimed via a DOWN, or never held a permit.
        {:noreply, state}

      {ref, running} ->
        Process.demonitor(ref, [:flush])
        {:noreply, promote(%{state | running: running})}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    case Map.get(state.running, pid) do
      ^ref ->
        # A permit holder died before releasing — free its slot.
        {:noreply, promote(%{state | running: Map.delete(state.running, pid)})}

      _ ->
        # A queued waiter died — drop it from the queue (its monitor already fired).
        waiting = :queue.filter(fn {_from, r, _p} -> r != ref end, state.waiting)
        {:noreply, %{state | waiting: waiting}}
    end
  end

  # Grant the next queued waiter a freed permit, if any.
  defp promote(state) do
    case :queue.out(state.waiting) do
      {{:value, {{wpid, _} = from, ref, _pid}}, waiting} ->
        GenServer.reply(from, :ok)
        %{state | running: Map.put(state.running, wpid, ref), waiting: waiting}

      {:empty, _waiting} ->
        state
    end
  end
end
