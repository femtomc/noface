import Config

# Configures the endpoint
config :noface_elixir, NofaceWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Phoenix.Endpoint.Cowboy2Adapter,
  render_errors: [
    formats: [html: NofaceWeb.ErrorHTML, json: NofaceWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Noface.PubSub,
  live_view: [signing_salt: "noface_lv_salt"]

# Configure esbuild (not using CDN, but keeping for potential future use)
config :esbuild,
  version: "0.17.11",
  noface: [
    args:
      ~w(js/app.js --bundle --target=es2017 --outdir=../priv/static/assets --external:/fonts/* --external:/images/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

# Configures Elixir's Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config
import_config "#{config_env()}.exs"
