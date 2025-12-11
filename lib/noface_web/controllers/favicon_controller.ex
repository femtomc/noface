defmodule NofaceWeb.FaviconController do
  use Phoenix.Controller, formats: [:html]

  def show(conn, _params) do
    conn
    |> put_resp_content_type("image/x-icon")
    |> send_resp(204, "")
  end
end
