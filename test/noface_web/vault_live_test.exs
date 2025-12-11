defmodule NofaceWeb.VaultLiveTest do
  use NofaceWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  alias Noface.TestFixtures

  test "lists and edits notes", %{conn: conn} do
    TestFixtures.with_temp_vault(fn vault ->
      Application.put_env(:noface_elixir, :monowiki_vault, vault)

      {:ok, view, _} = live(conn, "/vault", params: %{"vault" => vault})
      assert render(view) =~ "note"

       view
       |> form("form[phx-submit=new]", %{"slug" => "fresh"})
       |> render_submit()

       assert File.exists?(Path.join(vault, "fresh.md"))
       assert render(view) =~ "Created fresh"

      view |> element("div.issue", "note") |> render_click()
      assert render(view) =~ "Editing note"

      view
      |> form("form[phx-submit=save]", %{"slug" => "note", "content" => "# note\nupdated"})
      |> render_submit()

      assert File.read!(Path.join(vault, "note.md")) =~ "updated"

      view
      |> form("form[phx-submit=append_issue]", %{"slug" => "note", "issue_id" => "issue-1", "note" => "context"})
      |> render_submit()

      file = File.read!(Path.join(vault, "note.md"))
      assert file =~ "issue-1"
      assert file =~ "context"

      on_exit(fn -> Application.delete_env(:noface_elixir, :monowiki_vault) end)
    end)
  end
end
