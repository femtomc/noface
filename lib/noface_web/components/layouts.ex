defmodule NofaceWeb.Layouts do
  @moduledoc """
  Layout components for the noface web interface.
  """
  use Phoenix.Component

  import Phoenix.Controller, only: [get_csrf_token: 0]
  import NofaceWeb.CoreComponents

  embed_templates "layouts/*"
end
