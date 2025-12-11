defmodule NofaceWeb.ConnCase do
  @moduledoc """
  Test case for LiveView/conn tests.
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      import Plug.Conn
      import Phoenix.ConnTest
      @endpoint NofaceWeb.Endpoint
    end
  end

  setup _tags do
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
