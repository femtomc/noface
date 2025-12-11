import Config

# For development, we disable any cache and enable
# debugging and code reloading.
config :noface_elixir, NofaceWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  server: true,
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "noface_dev_secret_key_base_that_is_at_least_64_bytes_long_for_security",
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:noface, ~w(--sourcemap=inline --watch)]}
  ]

# Enable dev routes for dashboard
config :noface_elixir, dev_routes: true

# Do not include metadata nor timestamps in development logs
config :logger, :console, format: "[$level] $message\n"

# Set a higher stacktrace during development
config :phoenix, :stacktrace_depth, 20

# Initialize plugs at runtime for faster development compilation
config :phoenix, :plug_init_mode, :runtime
