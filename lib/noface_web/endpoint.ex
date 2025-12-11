defmodule NofaceWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :noface_elixir

  # The session will be stored in the cookie and signed,
  # this means its contents can be read but not tampered with.
  @session_options [
    store: :cookie,
    key: "_noface_key",
    signing_salt: "noface_salt",
    same_site: "Lax"
  ]

  socket("/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: false
  )

  # Serve static assets
  plug(Plug.Static,
    at: "/",
    from: :noface_elixir,
    gzip: false,
    only: NofaceWeb.static_paths()
  )

  # Code reloading can be explicitly enabled under the
  # :code_reloader configuration of your endpoint.
  if code_reloading? do
    plug(Phoenix.CodeReloader)
  end

  plug(Plug.RequestId)
  plug(Plug.Telemetry, event_prefix: [:phoenix, :endpoint])

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()
  )

  plug(Plug.MethodOverride)
  plug(Plug.Head)
  plug(Plug.Session, @session_options)
  plug(NofaceWeb.Router)
end
