defmodule NofaceWeb.DashboardLiveTest do
  use NofaceWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  alias Noface.TestFixtures
  alias Phoenix.PubSub

  setup do
    :ok
  end

  test "renders issues and filters", %{conn: conn} do
    issue_a = TestFixtures.build_issue("a", content: %{title: "A", priority: 1})
    issue_b = TestFixtures.build_issue("b", content: %{title: "B"}, status: :completed)

    {:ok, view, _} =
      live_isolated(conn, NofaceWeb.DashboardLive,
        session: %{
          "test_state" => %{
            issues: [issue_a, issue_b],
            status: %{state: %{pending: 1, completed: 1}, workers: %{workers: [], num_workers: 0}}
          }
        }
      )

    assert render(view) =~ "A"
    assert render(view) =~ "B"

    view |> element("button", "closed") |> render_click()
    html = render(view)
    refute html =~ "<span class=\"issue-title\">A</span>"
    assert html =~ "<span class=\"issue-title\">B</span>"
  end

  test "adds comment and updates issue", %{conn: conn} do
    issue = TestFixtures.build_issue("c", content: %{title: "Old"}, status: :pending)

    {:ok, view, _} =
      live_isolated(conn, NofaceWeb.DashboardLive,
        session: %{
          "test_state" => %{
            issues: [issue],
            status: %{state: %{pending: 1}, workers: %{workers: [], num_workers: 0}}
          }
        }
      )

    view |> element("div.issue-header[phx-value-id=\"c\"]") |> render_click()

    view
    |> form("form[phx-submit=add_comment][phx-value-id=\"c\"]", %{
      "comment" => %{"body" => "hi", "author" => "me"}
    })
    |> render_submit()

    assert render(view) =~ "hi"

    view
    |> form("form[phx-submit=update_issue][phx-value-id=\"c\"]", %{
      "issue" => %{"title" => "New title", "priority" => "0"}
    })
    |> render_submit()

    assert render(view) =~ "New title"
  end

  test "reacts to loop updates", %{conn: conn} do
    {:ok, view, _} = live(conn, "/")

    PubSub.broadcast(
      Noface.PubSub,
      "loop",
      {:loop, %{running: true, paused: false, iteration: 2, current_work: :busy}}
    )

    html = render(view)
    assert html =~ "RUNNING"
    assert html =~ "2"
  end

  test "streams agent session events", %{conn: conn} do
    {:ok, view, _} = live(conn, "/")

    send(view.pid, {:session_started, "issue-x"})

    send(
      view.pid,
      {:session_event, "issue-x",
       %{
         event_type: "tool",
         tool_name: "Read",
         raw_json: ~s({\"file_path\":\"foo.txt\"}),
         content: nil
       }}
    )

    send(
      view.pid,
      {:session_event, "issue-x",
       %{event_type: "text", tool_name: nil, raw_json: nil, content: "completed work"}}
    )

    html = render(view)
    assert html =~ "issue-x"
    assert html =~ "Read"
    assert html =~ "foo.txt"
    assert html =~ "completed work"
  end

  describe "loop controls" do
    test "shows NOT STARTED when loop not running", %{conn: conn} do
      {:ok, view, _} =
        live_isolated(conn, NofaceWeb.DashboardLive,
          session: %{
            "test_state" => %{
              issues: [],
              status: %{
                loop: %{running: false, paused: false, iteration: 0},
                state: %{},
                workers: %{workers: [], num_workers: 0}
              }
            }
          }
        )

      html = render(view)
      assert html =~ "NOT STARTED"
      assert html =~ "Loop not started"
      assert html =~ "Start"
    end

    test "shows RUNNING status with pause/interrupt buttons", %{conn: conn} do
      {:ok, view, _} =
        live_isolated(conn, NofaceWeb.DashboardLive,
          session: %{
            "test_state" => %{
              issues: [],
              status: %{
                loop: %{running: true, paused: false, iteration: 5},
                state: %{},
                workers: %{workers: [], num_workers: 0}
              }
            }
          }
        )

      html = render(view)
      assert html =~ "RUNNING"
      assert html =~ "Pause"
      assert html =~ "Interrupt"
      refute html =~ "Resume"
    end

    test "shows PAUSED status with resume/interrupt buttons", %{conn: conn} do
      {:ok, view, _} =
        live_isolated(conn, NofaceWeb.DashboardLive,
          session: %{
            "test_state" => %{
              issues: [],
              status: %{
                loop: %{running: false, paused: true, iteration: 5},
                state: %{},
                workers: %{workers: [], num_workers: 0}
              }
            }
          }
        )

      html = render(view)
      assert html =~ "PAUSED"
      assert html =~ "Resume"
      assert html =~ "Interrupt"
      refute html =~ ">Pause<"
    end
  end
end
