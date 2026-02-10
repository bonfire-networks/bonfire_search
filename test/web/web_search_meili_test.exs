defmodule Bonfire.Search.Web.MeiliTest do
  use Bonfire.Search.ConnCase, async: false
  doctest Bonfire.Search

  use Arrows
  import Bonfire.Common.Simulation
  import Bonfire.Files.Simulation
  import Tesla.Mock
  use Bonfire.Common.Config

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

  describe "when searching with meili" do
    setup do
      Bonfire.Common.Config.put(:wait_for_indexing, true, :bonfire_search)

      {meili_adapter, tesla_adapter} = prepare_meili_for_tests()

      account = fake_account!()
      alice = fake_user!(account)
      me = fake_user!(account)

      %{user: me, upload: upload, path: me_avatar_path, url: me_avatar_url} =
        fake_user_with_avatar!()

      mock_global(fn
        %{method: :get, url: "https://developer.mozilla.org/en-US/docs/Web/API/"} ->
          %Tesla.Env{status: 200, body: "<title>Web APIs | MDN (website)</title>"}
      end)

      conn = conn(user: alice, account: account)

      on_exit(fn ->
        reset_meili_after_tests(meili_adapter, tesla_adapter)

        Bonfire.Common.Config.put(:wait_for_indexing, false, :bonfire_search)
      end)

      {:ok,
       conn: conn,
       account: account,
       me: me,
       alice: alice,
       me_avatar_path: me_avatar_path,
       me_avatar_url: me_avatar_url}
    end

    test "user can search and see results of public posts", %{
      alice: alice,
      conn: conn
    } do
      # Create a public post by 'alice' to test search functionality
      html_body = "test post"
      attrs = %{post_content: %{html_body: html_body}}
      {:ok, _post} = Posts.publish(current_user: alice, post_attrs: attrs, boundary: "public")

      conn
      |> visit("/search")
      # Fill in the search term
      |> fill_in("[name=s]", "Search content", with: "test")
      # Submit the form by clocking button
      |> click_button("Search")
      |> wait_async()
      # Ensure the results section exists
      |> assert_has("#the_search_results")
      # Check if the result is displayed
      |> assert_has(".activity", text: html_body)
      |> assert_has_or_open_browser(".activity [data-id=subject_name]",
        text: e(alice, :profile, :name, nil)
      )

      conn
      |> visit("/search")
      # Fill in the search term
      |> fill_in("[name=s]", "Search content", with: "test")
      # try by submitting form instead
      |> submit()
      |> wait_async()
      # Check if the result is displayed
      |> assert_has_or_open_browser(".activity", text: html_body)
      |> assert_has_or_open_browser(".activity [data-id=subject_name]",
        text: e(alice, :profile, :name, nil)
      )

      # TODO
      # |> assert_has_or_open_browser("[data-id=subject_avatar]")
      # |> assert_has_or_open_browser("[data-id=subject_avatar] img[src]")
      # #  ensure it is a generated avatar, since we didn't upload a custom one
      # |> assert_has_or_open_browser("[data-id=subject_avatar] img[src*='gen_avatar']")
    end

    test "Search results paginate correctly", %{
      alice: alice,
      me: me,
      conn: conn
    } do
      original_limit = Bonfire.Common.Config.get(:default_pagination_limit)
      Bonfire.Common.Config.put(:default_pagination_limit, 2)

      on_exit(fn ->
        Bonfire.Common.Config.put(:default_pagination_limit, original_limit)
      end)

      # Create multiple public post to test search functionality
      html_body = "test post"
      attrs = %{post_content: %{html_body: html_body}}
      {:ok, _post} = Posts.publish(current_user: me, post_attrs: attrs, boundary: "public")

      html_body = "test2 post"
      attrs = %{post_content: %{html_body: html_body}}
      {:ok, _post} = Posts.publish(current_user: me, post_attrs: attrs, boundary: "public")

      html_body = "test3 post"
      attrs = %{post_content: %{html_body: html_body}}
      {:ok, _post} = Posts.publish(current_user: me, post_attrs: attrs, boundary: "public")

      html_body = "test4 post"
      attrs = %{post_content: %{html_body: html_body}}
      {:ok, _post} = Posts.publish(current_user: me, post_attrs: attrs, boundary: "public")

      # Wait a bit for indexing to complete
      # Process.sleep(100)

      conn
      # Visit Posts tab directly with search term (pagination only available on type-specific tabs)
      |> visit("/search?facet[index_type]=Bonfire.Data.Social.Post&s=test")
      |> wait_async()
      # Ensure the results section exists
      |> assert_has("#the_search_results")
      # |> PhoenixTest.open_browser()
      # Should only show 2 activities initially due to pagination limit
      |> assert_has(".activity", count: 2)
      # Should have a load more button (debug first if missing)
      # |> PhoenixTest.open_browser()
      |> assert_has("[data-id=load_more]")
      # Click load more to get the remaining results
      |> click_button("[data-id=load_more]", "Load more")
      # Should now show all 4 activities
      |> assert_has(".activity", count: 4)
    end

    test "search results display post with title, content warning, and author's avatar, along with the post being replied to",
         %{
           me: me,
           conn: conn,
           me_avatar_path: me_avatar_path,
           me_avatar_url: me_avatar_url
         } do
      op = fake_user!()

      reply_to_message = "Reply-to this"

      post1_attrs = %{
        post_content: %{html_body: reply_to_message}
      }

      {:ok, post1} = Posts.publish(current_user: op, post_attrs: post1_attrs, boundary: "public")

      # Create a post to test search results
      html_body = "test post with title"
      title = "the post title"
      cw = "the post CW"

      {:ok, _post} =
        Posts.publish(
          current_user: me,
          post_attrs: %{
            reply_to_id: post1.id,
            sensitive: true,
            post_content: %{summary: cw, name: title, html_body: html_body}
          },
          boundary: "public"
        )

      conn
      |> visit("/search?s=test")
      |> wait_async()
      # Verify the post is displayed
      |> assert_has_or_open_browser(".activity", text: html_body)
      |> assert_has_or_open_browser(".activity", text: reply_to_message)
      # Verify the title is displayed
      |> assert_has_or_open_browser(".activity [data-role=name]", text: title)
      |> assert_has_or_open_browser(".activity [data-role=cw]", text: cw)
      |> assert_has_or_open_browser(".activity [data-id=subject_name]",
        text: e(me, :profile, :name, nil)
      )
      |> assert_has_or_open_browser(".activity [data-id=subject_avatar]")
      # TODO: investigate why avatar img[src] doesn't render in search results
      # |> assert_has_or_open_browser(".activity [data-id=subject_avatar] img[src]")
      # |> assert_has_or_open_browser(".activity [data-id=subject_avatar] img[src*='gen_avatar']")
      # |> assert_has_or_open_browser("[data-id=subject_avatar] img[src=\"#{me_avatar_url}\"]")
    end

    # how to avoid fetching from web since we use real Tesla adapter here?
    @tag :todo
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

    test "Search filters display posts result", %{
      alice: alice,
      me: me,
      conn: conn
    } do
      body = "simple test post"
      html_body = "#{body}"

      {:ok, _post} =
        Posts.publish(
          current_user: me,
          post_attrs: %{post_content: %{html_body: html_body}},
          boundary: "public"
        )

      conn
      |> visit("/search?facet[index_type]=Bonfire.Data.Social.Post&index=public&s=test")
      # Verify the post is displayed
      |> assert_has_or_open_browser(".activity", text: body)
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
          post_attrs: %{
            # set as sensitive to test CW handled in indexing
            sensitive: true,
            post_content: %{html_body: html_body_post}
          },
          boundary: "public"
        )

      {:ok, me} = Bonfire.Me.Users.update(me, %{profile: %{name: user_name}})

      conn
      |> visit("/search?s=test")
      |> wait_async()
      # Verify post-related content
      |> assert_has_or_open_browser(".activity", text: html_body_post)
      |> assert_has_or_open_browser(".activity [data-role=cw]")
      # Ensure user-related content is shown
      |> assert_has_or_open_browser(".activity [data-id=profile_name]", text: user_name)

      conn
      # load the "Users" tab
      |> visit("/search?facet[index_type]=Bonfire.Data.Identity.User&s=test")
      |> wait_async()
      #  |> open_browser()
      # Verify user-related content
      |> assert_has_or_open_browser(".activity [data-id=profile_name]", text: user_name)
      # Ensure post-related content is not shown
      |> refute_has(".activity", text: html_body_post)

      conn
      # load the "Posts" tab
      |> visit("/search?facet[index_type]=Bonfire.Data.Social.Post&s=test")
      |> wait_async()
      # Verify post-related content
      |> assert_has_or_open_browser(".activity", text: html_body_post)
      |> assert_has_or_open_browser(".activity [data-role=cw]")
      # Ensure user-related content is not shown
      |> refute_has(".activity [data-id=profile_name]", text: user_name)

      conn
      |> visit("/search?s=test")
      # start filtering
      # Filter for "Users"
      |> click_link(".tabs a", "Users")
      |> wait_async()
      # |> open_browser()
      # Verify user-related content
      |> assert_has_or_open_browser(".activity [data-id=profile_name]", text: user_name)
      # Ensure post-related content is not shown
      |> refute_has(".activity", text: html_body_post)
      # filter again
      # Filter for "Posts"
      |> click_link(".tabs a", "Posts")
      |> wait_async()
      # Verify post-related content
      |> assert_has_or_open_browser(".activity", text: html_body_post)
      |> assert_has_or_open_browser(".activity [data-role=cw]")
      # Ensure user-related content is not shown
      |> refute_has(".activity [data-id=profile_name]", text: user_name)
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
      # Verify DM is not in public index
      |> visit("/search?index=public&s=test")
      |> refute_has(".activity", text: html_message)

      conn
      # Verify DM is in closed index
      |> visit("/search?index=closed&s=test")
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
      # Verify DM is not in public index
      |> visit("/search?index=public&s=test")
      |> refute_has(".activity", text: html_message)

      conn
      # Verify DM is in closed index
      |> visit("/search?index=closed&s=test")
      |> assert_has(".activity", text: html_message)

      conn
      # Verify DM is not there after switching back to public
      |> visit("/search?index=public&s=test")
      |> refute_has(".activity", text: html_message)
    end
  end
end
