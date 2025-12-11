defmodule NofaceWeb.CoreComponents do
  @moduledoc """
  Core UI components for the noface web interface.
  """
  use Phoenix.Component

  alias Phoenix.LiveView.JS

  @doc """
  Renders flash messages.
  """
  attr(:flash, :map, required: true)
  attr(:kind, :atom, values: [:info, :error], doc: "used for styling and filtering")

  def flash(assigns) do
    ~H"""
    <div
      :if={msg = Phoenix.Flash.get(@flash, @kind)}
      class={"flash flash-#{@kind}"}
      role="alert"
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind})}
    >
      <%= msg %>
    </div>
    """
  end

  @doc """
  Renders a group of flash messages.
  """
  attr(:flash, :map, required: true)

  def flash_group(assigns) do
    ~H"""
    <.flash kind={:info} flash={@flash} />
    <.flash kind={:error} flash={@flash} />
    """
  end
end
