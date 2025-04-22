defmodule Bonfire.Search.Web.MeiliTest do
  use Bonfire.Search.ConnCase, async: false
  doctest Bonfire.Search

  use Arrows
  import Bonfire.Common.Simulation
  import Tesla.Mock

  use Bonfire.Common.E
  alias Bonfire.Common.Enums
  alias Bonfire.Common.Types

  alias Bonfire.Search
  alias Bonfire.Search.Indexer

  alias Bonfire.Data.Identity.User
  alias Bonfire.Data.Social.Post

  alias Bonfire.Posts
  alias Bonfire.Messages

  # @adapter Bonfire.Search.DB
  # @adapter Bonfire.Search.Meili
  @adapter Bonfire.Search.MeiliLib

  setup do
    Bonfire.Common.Config.put(:wait_for_indexing, true, :bonfire_search)

    {meili_adapter, tesla_adapter} = prepare_meili_for_tests()

    account = fake_account!()
    me = fake_user!(account)
    alice = fake_user!(account)

    mock_global(fn
      %{method: :get, url: "https://developer.mozilla.org/en-US/docs/Web/API/"} ->
        %Tesla.Env{status: 200, body: "<title>Web APIs | MDN (website)</title>"}
    end)

    conn = conn(user: alice, account: account)

    on_exit(fn ->
      reset_meili_after_tests(meili_adapter, tesla_adapter)

      Bonfire.Common.Config.put(:wait_for_indexing, false, :bonfire_search)
    end)

    {:ok, conn: conn, account: account, me: me, alice: alice}
  end

  test "user can search and see results of public posts", %{
    alice: alice,
    me: me,
    conn: conn
  } do
    # Create a public post by 'me' to test search functionality
    html_body = "test post"
    attrs = %{post_content: %{html_body: html_body}}
    {:ok, _post} = Posts.publish(current_user: me, post_attrs: attrs, boundary: "public")

    conn
    |> visit("/search")
    # Fill in the search term
    |> fill_in("[name=s]", "Search", with: "test")
    # Submit the form by clocking button
    |> click_button("Search")
    # Ensure the results section exists
    |> assert_has("#the_search_results")
    # Check if the result is displayed
    |> assert_has(".activity", text: html_body)

    conn
    |> visit("/search")
    # Fill in the search term
    |> fill_in("[name=s]", "Search", with: "test")
    # try by submitting form instead
    |> submit()
    # Check if the result is displayed
    |> assert_has(".activity", text: html_body)
  end

  test "search results display test post with title", %{
    alice: alice,
    me: me,
    conn: conn
  } do
    # Create a post to test search results
    html_body = "test post with title"
    title = "the post title"

    {:ok, _post} =
      Posts.publish(
        current_user: me,
        post_attrs: %{post_content: %{name: title, html_body: html_body}},
        boundary: "public"
      )

    conn
    |> visit("/search?s=test")
    # |> open_browser()
    # Verify the post is displayed
    |> assert_has(".activity", text: html_body)
    # Verify the title is displayed
    |> assert_has(".activity [data-role=name]", text: title)
  end

  test "search results display test post with content warning", %{
    alice: alice,
    me: me,
    conn: conn
  } do
    # Create a post to test search results
    html_body = "test post with title"
    cw = "the post CW"

    {:ok, _post} =
      Posts.publish(
        current_user: me,
        post_attrs: %{sensitive: true, post_content: %{summary: cw, html_body: html_body}},
        boundary: "public"
      )

    conn
    |> visit("/search?s=test")
    # Verify the post is displayed
    |> assert_has(".activity", text: html_body)
    # Verify the title is displayed
    |> assert_has(".activity [data-role=cw]", text: cw)
  end

  # how to avoid fetching from web since we use real Tesla adapter here?
  @tag :fixme
  test "search results display test post with link or attachments", %{
    alice: alice,
    me: me,
    conn: conn
  } do
    # Create a post to test search results
    body = "test post with link or attachments"
    html_body = "#{body} https://developer.mozilla.org/en-US/docs/Web/API/"

    {:ok, _post} =
      Posts.publish(
        current_user: me,
        post_attrs: %{post_content: %{html_body: html_body}},
        boundary: "public"
      )

    conn
    |> visit("/search?s=test")
    # |> open_browser()
    # Verify the post is displayed
    |> assert_has(".activity", text: body)
    # Verify the post is displayed
    |> assert_has(".activity [data-id=media_title]", text: "Web APIs")
  end

  test "search filters display correct type of results", %{
    alice: alice,
    me: me,
    conn: conn
  } do
    # Create posts and user profiles for filtering
    user_name = "test user for search"
    html_body_post = "test post for search filters"

    {:ok, _post} =
      Posts.publish(
        current_user: me,
        post_attrs: %{post_content: %{html_body: html_body_post}},
        boundary: "public"
      )

    {:ok, me} = Bonfire.Me.Users.update(me, %{profile: %{name: user_name}})

    conn
    |> visit("/search?s=test")
    #  |> open_browser()
    # Verify post-related content
    |> assert_has(".activity", text: html_body_post)
    # Ensure user-related content is shown
    |> assert_has(".activity", text: user_name)

    conn
    # load the "Users" tab
    |> visit("/search?facet[index_type]=Bonfire.Data.Identity.User&s=test")
    #  |> open_browser()
    # Verify user-related content
    |> assert_has(".activity", text: user_name)
    # Ensure post-related content is not shown
    |> refute_has(".activity", text: html_body_post)

    conn
    # load the "Posts" tab
    |> visit("/search?facet[index_type]=Bonfire.Data.Social.Post&s=test")
    # Verify post-related content
    |> assert_has(".activity", text: html_body_post)
    # Ensure user-related content is not shown
    |> refute_has(".activity", text: user_name)

    conn
    |> visit("/search?s=test")
    # start filtering
    # Filter for "Users"
    |> click_link(".tabs a", "Users")
    # |> open_browser()
    # Verify user-related content
    |> assert_has(".activity", text: user_name)
    # Ensure post-related content is not shown
    |> refute_has(".activity", text: html_body_post)
    # filter again
    # Filter for "Posts"
    |> click_link(".tabs a", "Posts")
    # Verify post-related content
    |> assert_has(".activity", text: html_body_post)
    # Ensure user-related content is not shown
    |> refute_has(".activity", text: user_name)
  end

  test "user can switch between public/private search indexes, showing messages I sent in private one",
       %{
         me: bob,
         alice: alice,
         conn: conn
       } do
    html_message = "test direct message from alice"

    attrs = %{
      to_circles: [bob.id],
      post_content: %{html_body: html_message}
    }

    assert {:ok, message} = Messages.send(alice, attrs)

    conn
    # load the "Public" tab
    |> visit("/search?index=public&s=test")
    # Ensure post-related content is not shown
    |> refute_has(".activity", text: html_message)

    conn
    # load the "Private" tab
    |> visit("/search?index=closed&s=test")
    # |> open_browser()
    # Verify post-related content
    |> assert_has(".activity [data-id=object_body]", text: html_message)

    conn
    |> visit("/search?s=test")
    # Ensure post-related content is not shown
    |> refute_has(".activity", text: html_message)
    # Click the "Private" tab
    |> click_button("Private (eg. DMs or custom boundaries)")
    # |> open_browser()
    # |> assert_path("/search?index=closed&s=test") # Verify the path for the "Private" tab
    # Verify post-related content
    |> assert_has(".activity", text: html_message)
  end

  test "private search index shows messages I received", %{
    me: me,
    alice: alice,
    conn: conn
  } do
    html_message = "test direct message to alice"

    attrs = %{
      to_circles: [alice.id],
      post_content: %{html_body: html_message}
    }

    assert {:ok, message} = Messages.send(me, attrs)

    conn
    # load the "Public" tab
    |> visit("/search?index=public&s=test")
    # Ensure post-related content is not shown
    |> refute_has(".activity", text: html_message)

    conn
    # load the "Private" tab
    |> visit("/search?index=closed&s=test")
    # Verify post-related content
    |> assert_has(".activity", text: html_message)

    conn
    |> visit("/search?s=test")
    # Ensure message is not there
    |> refute_has(".activity", text: html_message)

    # Click the label containing the checkbox
    |> click_button("Private (eg. DMs or custom boundaries)")

    # Verify message is there after toggling to private index
    |> assert_has(".activity", text: html_message)

    # Click again to toggle back to public
    |> click_button("Public only")

    # Ensure message is not there after toggling back
    |> refute_has(".activity", text: html_message)
  end
end
