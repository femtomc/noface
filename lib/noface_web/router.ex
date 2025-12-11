defmodule NofaceWeb.Router do
  use Phoenix.Router

  import Phoenix.LiveView.Router
  import Plug.Conn
  import Phoenix.Controller

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {NofaceWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", NofaceWeb do
    pipe_through :browser

    live "/", DashboardLive, :index
    live "/issues", IssuesLive, :index
    live "/issues/:id", IssuesLive, :show

    # Avoid favicon 404
    get "/favicon.ico", FaviconController, :show
  end

  # API endpoints
  scope "/api", NofaceWeb do
    pipe_through :api

    get "/status", ApiController, :status
    post "/pause", ApiController, :pause
    post "/resume", ApiController, :resume
    post "/interrupt", ApiController, :interrupt
    post "/issues", ApiController, :create_issue
  end

  # Enable LiveDashboard in development
  if Application.compile_env(:noface_elixir, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser
      live_dashboard "/dashboard", metrics: NofaceWeb.Telemetry
    end
  end
end
