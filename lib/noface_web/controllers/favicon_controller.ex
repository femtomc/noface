defmodule NofaceWeb.FaviconController do
  use NofaceWeb, :controller

  def show(conn, _params) do
    conn
    |> put_resp_content_type("image/x-icon")
    |> send_resp(204, "")
  end
end
