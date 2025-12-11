import Config

# Note: This file is only loaded in production.
# Configure your endpoint
config :noface_elixir, NofaceWeb.Endpoint,
  cache_static_manifest: "priv/static/cache_manifest.json",
  server: true

# Runtime production configuration
config :noface_elixir, NofaceWeb.Endpoint,
  http: [port: {:system, "PORT"}],
  url: [host: {:system, "HOST"}, port: {:system, "PORT"}],
  secret_key_base: {:system, "SECRET_KEY_BASE"}
