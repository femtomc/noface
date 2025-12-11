defmodule NofaceWeb.VaultLiveTest do
  use NofaceWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  alias Noface.TestFixtures

  describe "basic functionality" do
    test "lists and edits notes", %{conn: conn} do
      TestFixtures.with_temp_vault(fn vault ->
        Application.put_env(:noface_elixir, :monowiki_vault, vault)

        {:ok, view, _} = live(conn, "/vault")
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
        |> form("form[phx-submit=append_issue]", %{
          "slug" => "note",
          "issue_id" => "issue-1",
          "note" => "context"
        })
        |> render_submit()

        file = File.read!(Path.join(vault, "note.md"))
        assert file =~ "issue-1"
        assert file =~ "context"

        on_exit(fn -> Application.delete_env(:noface_elixir, :monowiki_vault) end)
      end)
    end
  end

  describe "security" do
    test "ignores vault param from URL", %{conn: conn} do
      TestFixtures.with_temp_vault(fn vault ->
        Application.put_env(:noface_elixir, :monowiki_vault, vault)

        # Attempting to pass a different vault via URL params should be ignored
        {:ok, view, _} = live(conn, "/vault?vault=/etc")
        # Should use the configured vault, not /etc
        html = render(view)
        assert html =~ vault
        refute html =~ "/etc"

        on_exit(fn -> Application.delete_env(:noface_elixir, :monowiki_vault) end)
      end)
    end

    test "rejects path traversal in slug for new note", %{conn: conn} do
      TestFixtures.with_temp_vault(fn vault ->
        Application.put_env(:noface_elixir, :monowiki_vault, vault)

        {:ok, view, _} = live(conn, "/vault")

        # Try to create a note with path traversal
        view
        |> form("form[phx-submit=new]", %{"slug" => "../escape"})
        |> render_submit()

        assert render(view) =~ "Invalid slug"
        refute File.exists?(Path.join(Path.dirname(vault), "escape.md"))

        on_exit(fn -> Application.delete_env(:noface_elixir, :monowiki_vault) end)
      end)
    end

    test "rejects absolute path in slug", %{conn: conn} do
      TestFixtures.with_temp_vault(fn vault ->
        Application.put_env(:noface_elixir, :monowiki_vault, vault)

        {:ok, view, _} = live(conn, "/vault")

        view
        |> form("form[phx-submit=new]", %{"slug" => "/tmp/evil"})
        |> render_submit()

        assert render(view) =~ "Invalid slug"
        refute File.exists?("/tmp/evil.md")

        on_exit(fn -> Application.delete_env(:noface_elixir, :monowiki_vault) end)
      end)
    end

    test "rejects path traversal in save via direct event", %{conn: conn} do
      TestFixtures.with_temp_vault(fn vault ->
        Application.put_env(:noface_elixir, :monowiki_vault, vault)

        {:ok, view, _} = live(conn, "/vault")

        # First select a valid note
        view |> element("div.issue", "note") |> render_click()

        # Send save event directly with path traversal slug
        render_submit(view, :save, %{"slug" => "../escape", "content" => "evil"})

        assert render(view) =~ "Invalid slug"
        refute File.exists?(Path.join(Path.dirname(vault), "escape.md"))

        on_exit(fn -> Application.delete_env(:noface_elixir, :monowiki_vault) end)
      end)
    end

    test "rejects path traversal in append_issue via direct event", %{conn: conn} do
      TestFixtures.with_temp_vault(fn vault ->
        Application.put_env(:noface_elixir, :monowiki_vault, vault)

        {:ok, view, _} = live(conn, "/vault")

        # First select a valid note
        view |> element("div.issue", "note") |> render_click()

        # Send append_issue event directly with path traversal slug
        render_submit(view, :append_issue, %{
          "slug" => "../escape",
          "issue_id" => "evil-1",
          "note" => "escape"
        })

        assert render(view) =~ "Invalid slug"
        refute File.exists?(Path.join(Path.dirname(vault), "escape.md"))

        on_exit(fn -> Application.delete_env(:noface_elixir, :monowiki_vault) end)
      end)
    end
  end
end
