defmodule Bonfire.Search.Web.SeeOnlyResultsTest do
  @moduledoc "Search follows `:see`, as feeds do: a hit the viewer may see but not read is found, and shown with its name and summary but none of its body."
  use Bonfire.Search.ConnCase, async: false
  @moduletag :ui

  alias Bonfire.Classify.Simulate

  @adapter Bonfire.Common.Config.get(:adapter, Bonfire.Search.MeiliLib, :bonfire_search)

  # only in the body, so a match on it is a match on the body
  @body_word "gallimaufry"
  @secret "SECRET-DEEP-BODY-xyz"

  setup do
    Bonfire.Common.Config.put(:wait_for_indexing, true, :bonfire_search)
    prev = prepare_indexes_for_tests(@adapter)

    on_exit(fn ->
      reset_indexes_after_tests(@adapter, prev)
      Bonfire.Common.Config.put(:wait_for_indexing, false, :bonfire_search)
    end)

    owner = fake_user!(fake_account!())

    group =
      Simulate.fake_group!(owner, %{
        membership: "on_request",
        visibility: "preview",
        participation: "group_members",
        default_content_visibility: "public:preview"
      })

    {:ok, post} =
      Bonfire.Posts.publish(
        current_user: owner,
        publish_in: group.id,
        boundary: "public:preview",
        post_attrs: %{
          post_content: %{
            name: "Moorhen headline",
            summary: "What the moorhen post is about",
            html_body: "<p>A #{@body_word} of notes.</p><p>#{@secret}</p>"
          }
        }
      )

    {:ok, owner: owner, group: group, post: post}
  end

  defp search(conn) do
    conn
    |> visit("/search?s=#{@body_word}")
    |> wait_async()
  end

  # the body isn't sent at all, not only hidden
  defp refute_in_html(session, text) do
    PhoenixTest.unwrap(session, fn view ->
      html = Phoenix.LiveViewTest.render(view)
      refute html =~ text
      # unwrap takes back the rendered HTML
      html
    end)
  end

  test "a non-member finds a preview post by a word of its body, shown without its body", %{
    post: post
  } do
    viewer_account = fake_account!()
    viewer = fake_user!(viewer_account)

    assert Bonfire.Boundaries.can?(viewer, :see, post), "control: the viewer may see it"
    refute Bonfire.Boundaries.can?(viewer, :read, post), "control: but not read it"

    conn(user: viewer, account: viewer_account)
    |> search()
    |> assert_has("#the_search_results article", text: "Moorhen headline")
    |> assert_has("#the_search_results article", text: "What the moorhen post is about")
    |> refute_has("#the_search_results", text: @secret)
    |> refute_in_html(@secret)
  end

  # the closed index is checked for the viewer on `:see`, so the same card shows there
  test "a non-member finds it among private results too, shown without its body", %{post: _post} do
    viewer_account = fake_account!()
    viewer = fake_user!(viewer_account)

    conn(user: viewer, account: viewer_account)
    |> search()
    |> click_button("#search_boundary button", "Private only")
    |> wait_async()
    |> assert_has("#the_search_results article", text: "Moorhen headline")
    |> refute_has("#the_search_results", text: @secret)
    |> refute_in_html(@secret)
  end

  test "a guest finds it the same way, from the public index", %{post: post} do
    refute Bonfire.Boundaries.can?(:guest, :read, post), "control: a guest may not read it"

    conn()
    |> search()
    |> assert_has("#the_search_results article", text: "Moorhen headline")
    |> refute_has("#the_search_results", text: @secret)
    |> refute_in_html(@secret)
  end

  test "a member finds it with its body", %{owner: owner, group: group} do
    member_account = fake_account!()
    member = fake_user!(member_account)

    {:ok, _} =
      Bonfire.Classify.Categories.add_member(owner, group, member.id, skip_boundary_check: true)

    conn(user: member, account: member_account)
    |> search()
    |> assert_has("#the_search_results", text: @secret)
  end
end
