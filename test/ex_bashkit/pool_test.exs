defmodule ExBashkit.PoolTest do
  use ExUnit.Case, async: true

  alias ExBashkit.{Pool, Result}

  # Start an isolated, uniquely-named pool for one test.
  defp start_pool(opts) do
    name = :"pool_#{System.unique_integer([:positive])}"
    start_supervised!({Pool, Keyword.put(opts, :name, name)})
    name
  end

  # Spawn a worker that runs a gated fun under the pool. The fun signals the test
  # when it starts running, then blocks until told to finish — so we can observe
  # concurrency without sleeping. Returns the worker pid (where the fun runs).
  defp spawn_gated(pool, value \\ :result) do
    test = self()

    spawn(fn ->
      result =
        Pool.run(pool, fn ->
          send(test, {:running, self()})

          receive do
            :finish -> :ok
          end

          value
        end)

      send(test, {:done, self(), result})
    end)
  end

  test "permits cap concurrency; an extra caller waits until one frees" do
    pool = start_pool(size: 1, max_queue: 10)

    a = spawn_gated(pool)
    assert_receive {:running, ^a}

    b = spawn_gated(pool)
    # b is queued, not running, while a holds the only permit.
    refute_receive {:running, ^b}, 100

    send(a, :finish)
    assert_receive {:done, ^a, :result}

    # Freeing a's permit promotes b.
    assert_receive {:running, ^b}
    send(b, :finish)
    assert_receive {:done, ^b, :result}
  end

  test "a caller past a full queue is rejected with {:error, :overloaded}" do
    pool = start_pool(size: 1, max_queue: 0)

    a = spawn_gated(pool)
    assert_receive {:running, ^a}

    b = spawn_gated(pool)
    # No queue slots: b never runs, it is shed immediately.
    assert_receive {:done, ^b, {:error, :overloaded}}
    refute_receive {:running, ^b}, 50

    send(a, :finish)
    assert_receive {:done, ^a, :result}
  end

  test "a permit is reclaimed when its holder is killed, never leaked" do
    # max_queue: 1 makes promotion deterministic regardless of whether the pool
    # processes b's :acquire before or after a's :DOWN: b either acquires the freed
    # permit immediately, or queues and is promoted when the DOWN reclaims it. If
    # the permit had leaked, b would instead wait forever.
    pool = start_pool(size: 1, max_queue: 1)

    a = spawn_gated(pool)
    assert_receive {:running, ^a}

    Process.exit(a, :kill)

    b = spawn_gated(pool)
    assert_receive {:running, ^b}
    send(b, :finish)
    assert_receive {:done, ^b, :result}
  end

  test "run/2 returns the function's value" do
    pool = start_pool(size: 2, max_queue: 0)
    assert Pool.run(pool, fn -> 42 end) == 42
  end

  test "run releases the permit after the function raises" do
    # max_queue: 1 so our own acquire deterministically queues behind the raising
    # holder and is promoted only when its `after` releases the permit.
    pool = start_pool(size: 1, max_queue: 1)
    test = self()

    # Unlinked, so the deliberate raise doesn't reach the test process.
    spawn(fn ->
      Pool.run(pool, fn ->
        send(test, :acquired)
        raise "boom"
      end)
    end)

    # Confirm the holder actually held the only permit before we contend for it,
    # so success below can only come from release-after-raise — not a lucky race.
    assert_receive :acquired
    assert Pool.run(pool, fn -> :ok end) == :ok
  end

  test "a reentrant run on the same pool raises instead of deadlocking" do
    pool = start_pool(size: 1, max_queue: 1)

    assert_raise RuntimeError, ~r/already holds a permit/, fn ->
      Pool.run(pool, fn -> Pool.run(pool, fn -> :inner end) end)
    end
  end

  test "size scales real concurrent execs" do
    pool = start_pool(size: 2, max_queue: 0)

    a = spawn_gated(pool)
    b = spawn_gated(pool)

    # Both permits available: both run at once.
    assert_receive {:running, ^a}
    assert_receive {:running, ^b}

    send(a, :finish)
    send(b, :finish)
    assert_receive {:done, ^a, :result}
    assert_receive {:done, ^b, :result}
  end

  test "exec/2 wrapper runs a script through the pool" do
    pool = start_pool(size: 1, max_queue: 1)
    assert {:ok, %Result{stdout: "hi\n"}} = Pool.exec(pool, "echo hi")
  end
end
