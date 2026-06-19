# Run with:  mix run examples/network.exs
#
# Network access: a session reaches the network only through an explicit,
# default-deny allowlist. This demo talks to a throwaway loopback server so it
# runs offline — in real use you would allowlist public hosts like
# "https://api.example.com".

alias ExBashkit.Session

defmodule Demo do
  def show(session, label, script) do
    case Session.exec(session, script) do
      {:ok, %ExBashkit.Result{stdout: out, exit_code: 0}} ->
        IO.puts("\n# #{label}  (ok)")
        if out != "", do: IO.write(out)

      {:ok, %ExBashkit.Result{exit_code: code}} ->
        IO.puts("\n# #{label}  (blocked, exit #{code})")

      {:error, message} ->
        IO.puts("\n# #{label}  (error)")
        IO.puts([IO.ANSI.yellow(), message, IO.ANSI.reset()])
    end
  end

  # A minimal loopback HTTP/1.1 server returning a fixed body. Returns its port.
  def start_server(body) do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, packet: :raw, active: false, reuseaddr: true])

    {:ok, port} = :inet.port(listen)
    spawn_link(fn -> accept_loop(listen, body) end)
    port
  end

  defp accept_loop(listen, body) do
    case :gen_tcp.accept(listen) do
      {:ok, sock} ->
        _ = :gen_tcp.recv(sock, 0, 1_000)
        resp = "HTTP/1.1 200 OK\r\nContent-Length: #{byte_size(body)}\r\nConnection: close\r\n\r\n" <> body
        :gen_tcp.send(sock, resp)
        :gen_tcp.close(sock)
        accept_loop(listen, body)

      {:error, _} ->
        :ok
    end
  end
end

port = Demo.start_server("pong\n")
url = "http://127.0.0.1:#{port}"

# Default: no network at all.
denied = Session.new()
Demo.show(denied, "default-deny: curl is refused", "curl -s #{url}/ping")

# Allowlist the loopback URL. 127.0.0.1 is a private address, which bashkit
# blocks by default to prevent SSRF — opt out for this trusted dev server.
allowed = Session.new(allow_net: [url], block_private_ips: false)
Demo.show(allowed, "allowlisted host is reachable", "curl -s #{url}/ping")

# A host that is not on the allowlist stays blocked.
Demo.show(allowed, "unlisted host is still blocked", "curl -s http://127.0.0.1:1/ping")
