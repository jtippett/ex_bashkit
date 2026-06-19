defmodule ExBashkit.SessionNetworkTest do
  # Each test that needs a server spins up its own loopback listener on an
  # ephemeral port, so these are independent and safe to run async.
  use ExUnit.Case, async: true

  alias ExBashkit.Session

  describe "default deny" do
    test "without :allow_net, a reachable host is still blocked" do
      # Point curl at a server that is genuinely listening, so the only thing
      # that can stop the body coming back is bashkit's default-deny — not a DNS
      # failure. (A non-resolving hostname would make this pass even if the
      # allowlist were disabled.)
      {port, body} = start_loopback_server("should-not-be-read\n")

      session = Session.new(block_private_ips: false)
      {:ok, result} = Session.exec(session, "curl -s http://127.0.0.1:#{port}/")

      # A blocked request is a *failed command* (non-zero exit), not an
      # interpreter error — bashkit refuses before any socket is opened.
      assert result.exit_code != 0
      refute result.stdout =~ body
    end
  end

  describe ":allow_net allowlist" do
    test "a reachable host that is not on the allowlist is blocked" do
      # The server is up and private IPs are permitted, so reachability and
      # SSRF filtering are both out of the picture: only the allowlist (which
      # lists a *different* URL) can block this request.
      {port, body} = start_loopback_server("should-not-be-read\n")

      session =
        Session.new(allow_net: ["http://127.0.0.1:1"], block_private_ips: false)

      {:ok, result} = Session.exec(session, "curl -s http://127.0.0.1:#{port}/")

      assert result.exit_code != 0
      refute result.stdout =~ body
    end

    test "an allowed loopback URL is reachable end-to-end" do
      {port, body} = start_loopback_server("hello-from-loopback\n")

      session =
        Session.new(
          allow_net: ["http://127.0.0.1:#{port}"],
          # 127.0.0.1 is a private/reserved address; bashkit blocks those by
          # default (SSRF protection). Opt out so we can talk to our test server.
          block_private_ips: false
        )

      {:ok, result} = Session.exec(session, "curl -s http://127.0.0.1:#{port}/")

      assert result.exit_code == 0
      assert result.stdout == body
    end

    test "allow_net: :all permits any host" do
      {port, body} = start_loopback_server("anything\n")

      session = Session.new(allow_net: :all, block_private_ips: false)
      {:ok, result} = Session.exec(session, "curl -s http://127.0.0.1:#{port}/")

      assert result.exit_code == 0
      assert result.stdout == body
    end
  end

  describe "private-IP protection" do
    test "a loopback URL is blocked by default even when allowlisted" do
      {port, _body} = start_loopback_server("should-not-be-read\n")

      # block_private_ips defaults to true: allowlisting the URL is not enough;
      # the request to 127.0.0.1 is still refused.
      session = Session.new(allow_net: ["http://127.0.0.1:#{port}"])
      {:ok, result} = Session.exec(session, "curl -s http://127.0.0.1:#{port}/")

      assert result.exit_code != 0
      refute result.stdout =~ "should-not-be-read"
    end
  end

  describe ":allow_net / :block_private_ips validation" do
    test "a non-list, non-:all :allow_net raises" do
      assert_raise ArgumentError, ~r/allow_net/, fn ->
        Session.new(allow_net: 123)
      end
    end

    test "a non-boolean :block_private_ips raises" do
      assert_raise ArgumentError, ~r/block_private_ips/, fn ->
        Session.new(allow_net: :all, block_private_ips: "no")
      end
    end

    test "a scheme-less :allow_net pattern raises (it could never match)" do
      assert_raise ArgumentError, ~r/allow_net/, fn ->
        Session.new(allow_net: ["api.example.com"])
      end
    end

    test "a non-string :allow_net pattern raises" do
      assert_raise ArgumentError, ~r/allow_net/, fn ->
        Session.new(allow_net: [123])
      end
    end
  end

  # --- a minimal, dependency-free loopback HTTP/1.1 server -------------------

  # Listens on 127.0.0.1:<ephemeral>, answers every connection with a fixed
  # 200 response, and is torn down at the end of the test. Returns {port, body}.
  defp start_loopback_server(body) do
    {:ok, listen} =
      :gen_tcp.listen(0, [
        :binary,
        ip: {127, 0, 0, 1},
        packet: :raw,
        active: false,
        reuseaddr: true
      ])

    {:ok, port} = :inet.port(listen)
    server = spawn_link(fn -> accept_loop(listen, body) end)

    on_exit(fn ->
      # Closing the listener unblocks the acceptor so the process exits.
      :gen_tcp.close(listen)
      Process.exit(server, :kill)
    end)

    {port, body}
  end

  defp accept_loop(listen, body) do
    case :gen_tcp.accept(listen) do
      {:ok, sock} ->
        # Drain the request line/headers (we don't parse them), then reply.
        _ = :gen_tcp.recv(sock, 0, 1_000)

        response =
          "HTTP/1.1 200 OK\r\n" <>
            "Content-Length: #{byte_size(body)}\r\n" <>
            "Connection: close\r\n\r\n" <> body

        :gen_tcp.send(sock, response)
        :gen_tcp.close(sock)
        accept_loop(listen, body)

      {:error, _closed} ->
        :ok
    end
  end
end
