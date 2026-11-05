defmodule Bonfire.Search.Web.HashtagChipsTest do
  @moduledoc "Matching hashtags show on the All tab as a line of chips, each opening its feed, from a search of the Hashtag bucket on the first page; there is no Hashtags tab."
  use Bonfire.Search.ConnCase, async: false
  @moduletag :ui

  @adapter Bonfire.Common.Config.get(:adapter, Bonfire.Search.MeiliLib, :bonfire_search)

  setup do
    Bonfire.Common.Config.put(:wait_for_indexing, true, :bonfire_search)
    prev = prepare_indexes_for_tests(@adapter)

    on_exit(fn ->
      reset_indexes_after_tests(@adapter, prev)
      Bonfire.Common.Config.put(:wait_for_indexing, false, :bonfire_search)
    end)

    account = fake_account!()
    me = fake_user!(account)

    {:ok, conn: conn(user: me, account: account), me: me}
  end

  test "All shows a matching hashtag as a chip that opens its feed", %{conn: conn} do
    {:ok, _} = Bonfire.Tag.get_or_create_hashtag("zebrafinch")

    conn
    |> visit("/search?s=zebrafinch")
    |> wait_async()
    |> assert_has("[data-role=search_hashtag_chips] a[href='/search/tag/zebrafinch']",
      text: "#zebrafinch"
    )
  end

  test "no chip line when no hashtag matches", %{conn: conn, me: me} do
    {:ok, _} =
      Bonfire.Posts.publish(
        current_user: me,
        boundary: "public",
        post_attrs: %{post_content: %{html_body: "a quiet heron by the reeds"}}
      )

    conn
    |> visit("/search?s=heron")
    |> wait_async()
    |> assert_has("#the_search_results", text: "a quiet heron")
    |> refute_has("[data-role=search_hashtag_chips]")
  end

  test "there is no Hashtags tab, and a typed #hashtag still opens its feed", %{conn: conn} do
    {:ok, _} = Bonfire.Tag.get_or_create_hashtag("zebrafinch")

    conn
    |> visit("/search?s=zebrafinch")
    |> wait_async()
    |> assert_has(".tabs a", text: "Users")
    |> refute_has(".tabs a", text: "Hashtags")
    |> visit("/search?s=" <> URI.encode_www_form("#zebrafinch"))
    |> assert_path("/search/tag/zebrafinch")
  end

  test "All makes three index searches on its first page, and one on a later page", %{
    conn: conn
  } do
    {:ok, _} = Bonfire.Tag.get_or_create_hashtag("zebrafinch")

    first_page =
      count_index_searches(@adapter, "zebrafinch", fn ->
        # kept for the later page, since the traced function's result isn't returned
        Process.put(:hashtag_chips_session, conn |> visit("/search?s=zebrafinch") |> wait_async())
      end)

    # the people strip (User bucket), groups and content (`all`), and the hashtag chips (Hashtag bucket)
    assert first_page == 3

    session = Process.get(:hashtag_chips_session)

    later_page =
      count_index_searches(@adapter, "zebrafinch", fn ->
        PhoenixTest.unwrap(session, fn view ->
          Phoenix.LiveViewTest.render_hook(view, "Bonfire.Search.LiveHandler:load_more", %{
            "after" => "2"
          })
        end)
      end)

    # the strips and chips are for the first page only, so a later page is the `all` search alone
    assert later_page == 1
  end
end
