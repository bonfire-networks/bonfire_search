defmodule Bonfire.Search.Web.SearchTest do
  use Bonfire.Search.ConnCase, async: false
  require Phoenix.LiveViewTest
  doctest Bonfire.Search
  doctest Bonfire.Search.Filters

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

  @adapter Bonfire.Common.Config.get(:adapter, Bonfire.Search.MeiliLib, :bonfire_search)

  describe "Bonfire.Search.Filters casting" do
    alias Bonfire.Search.Filters, as: SearchFilters

    test "cast_filters keeps only the search filter keys" do
      uid = Needle.UID.generate()

      assert %{
               subjects: [^uid],
               media_types: [:image],
               object_types: [:post],
               origin: [:local]
             } =
               cast =
               SearchFilters.cast_filters(%{
                 "subjects" => [uid],
                 "media_types" => ["image"],
                 "object_types" => ["post"],
                 "origin" => "local",
                 "sort_order" => "asc",
                 "feed_ids" => ["x"],
                 "evil" => "1"
               })

      assert map_size(cast) == 4
    end

    test "cast_filters of empty input, or the editor's 'Anywhere' origin, is empty" do
      assert SearchFilters.cast_filters(%{}) == %{}
      assert SearchFilters.cast_filters(nil) == %{}
      assert SearchFilters.cast_filters(%{"origin" => "all"}) == %{}
    end

    test "extract_selected_authors reads only the named picker field" do
      uid1 = Needle.UID.generate()
      uid2 = Needle.UID.generate()

      # shape LiveSelect posts in tags mode: JSON-encoded value maps in a list,
      # nested under form name -> field name
      params = %{
        "_target" => ["multi_select", "search_filters_include_people"],
        "multi_select" => %{
          "search_filters_include_people" => [
            Jason.encode!(%{"id" => uid1, "name" => "Alice", "type" => "user"}),
            Jason.encode!(%{"id" => uid2, "name" => "Bob", "type" => "user"})
          ],
          "search_filters_include_people_text_input" => ""
        }
      }

      assert [%{id: ^uid1, name: "Alice"}, %{id: ^uid2, name: "Bob"}] =
               Bonfire.UI.Social.FeedFiltersModalContentLive.extract_selected_authors(params, "search_filters_include_people")

      # nothing selected (no list present at all)
      assert Bonfire.UI.Social.FeedFiltersModalContentLive.extract_selected_authors(%{
               "_target" => ["x"],
               "multi_select" => %{"another_picker" => [uid1], "whatever_text_input" => "ali"}
             }, "search_filters_include_people") == []
    end

    test "filters round-trip through the Posts tab URL" do
      uid = Needle.UID.generate()

      filters = %{
        subjects: [uid],
        media_types: [:image, :video],
        origin: ["mastodon.social"],
        tags: ["bonfire"]
      }

      url = SearchFilters.tab_url("cats", "public", filters, SearchFilters.posts_tab())
      params = url |> URI.parse() |> Map.fetch!(:query) |> Plug.Conn.Query.decode()

      assert SearchFilters.cast_filters(params["filters"]) == filters
      assert length(Bonfire.UI.Social.FeedControlsLive.active_filters(filters)) == 5
    end
  end

  test "All still offers a hand-off when filtering removes every hit on a candidate page" do
    html = Phoenix.LiveViewTest.render_component(&Bonfire.Search.Web.ResultsLive.render/1, %{
      __context__: %{},
      search: "quartz",
      hits: [],
      user_hits: [],
      page_info: %{has_next_page: true, end_cursor: "20"}
    })

    links = html |> Floki.parse_document!() |> Floki.find("a")
    assert Floki.text(links) =~ "See all posts"
    refute html =~ "Nothing relevant was found"
  end

  describe "search page with no query" do
    setup do
      account = fake_account!()
      me = fake_user!(account)
      conn = conn(user: me, account: account)

      {:ok, conn: conn, account: account, me: me}
    end

    test "shows a prompt instead of tabs or a 'nothing found' message", %{conn: conn} do
      conn
      |> visit("/search")
      |> assert_has("main", text: "Search for people, posts and hashtags")
      |> refute_has(".tabs a")
      |> refute_has("main", text: "Nothing relevant was found")
    end

    test "a facet link without a search term does not crash or run a search", %{conn: conn} do
      conn
      |> visit("/search?facet[index_type]=Bonfire.Data.Social.Post")
      |> assert_has("main", text: "Search for people, posts and hashtags")
      |> refute_has(".tabs a")
    end

    test "load_activities_for_search applies feed_filters DB-side", %{me: me, account: account} do
      alice = fake_user!(account)

      {:ok, post1} =
        Posts.publish(
          current_user: alice,
          post_attrs: %{post_content: %{html_body: "filter check by alice"}},
          boundary: "public"
        )

      {:ok, post2} =
        Posts.publish(
          current_user: me,
          post_attrs: %{post_content: %{html_body: "filter check by bob"}},
          boundary: "public"
        )

      ids = [post1.id, post2.id]

      unfiltered = Search.load_activities_for_search(ids, current_user: me)
      assert length(unfiltered) == 2

      filtered =
        Search.load_activities_for_search(ids,
          current_user: me,
          feed_filters: %{subjects: [alice.id]}
        )

      assert Enum.map(filtered, &Enums.id/1) == [post1.id]

      excluded =
        Search.load_activities_for_search(ids,
          current_user: me,
          feed_filters: %{exclude_subjects: [alice.id]}
        )

      assert Enum.map(excluded, &Enums.id/1) == [post2.id]

      # both test posts are local
      local_only =
        Search.load_activities_for_search(ids,
          current_user: me,
          feed_filters: %{origin: :local}
        )

      assert length(local_only) == 2

      remote_only =
        Search.load_activities_for_search(ids,
          current_user: me,
          feed_filters: %{origin: :remote}
        )

      assert remote_only == []
    end

    test "tabs (including Hashtags) appear only once there is a query", %{me: me, conn: conn} do
      {:ok, _post} =
        Posts.publish(
          current_user: me,
          post_attrs: %{post_content: %{html_body: "tab visibility check post"}},
          boundary: "public"
        )

      conn
      |> visit("/search?s=visibility")
      |> assert_has(".tabs a", text: "Hashtags")
      # filters apply to posts only, so All has no filters widget
      |> refute_has("[data-role=search_filters_widget]")
      # regression: the Hashtags tab used to link to /search/tag/ (no segment) when built without a query
      |> click_link(".tabs a", "Hashtags")
      |> assert_path("/search/tag/visibility")
    end
  end

  describe "when searching" do
    setup do
      Bonfire.Common.Config.put(:wait_for_indexing, true, :bonfire_search)

      prev = prepare_indexes_for_tests(@adapter)

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
        reset_indexes_after_tests(@adapter, prev)
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
      html_body = "xyloquartz luminiferous post"
      attrs = %{post_content: %{html_body: html_body}}
      {:ok, _post} = Posts.publish(current_user: alice, post_attrs: attrs, boundary: "public")

      conn
      |> visit("/search?s=xyloquartz")
      |> wait_async()
      |> assert_has("#the_search_results")
      |> assert_has(".activity", text: html_body)
      |> assert_has_or_open_browser(".activity [data-id=subject_name]",
        text: e(alice, :profile, :name, nil)
      )

      conn
      |> visit("/search")
      |> within("main", fn session ->
        session
        |> fill_in("Search content", with: "xyloquartz")
        |> submit()
      end)
      |> wait_async()
      |> assert_has_or_open_browser(".activity", text: html_body)
      |> assert_has_or_open_browser(".activity [data-id=subject_name]",
        text: e(alice, :profile, :name, nil)
      )
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

      for i <- 1..4 do
        attrs = %{post_content: %{html_body: "crepuscular pagination post #{i}"}}
        {:ok, _post} = Posts.publish(current_user: me, post_attrs: attrs, boundary: "public")
      end

      conn
      |> visit("/search?facet[index_type]=Bonfire.Data.Social.Post&s=crepuscular")
      |> wait_async()
      |> assert_has("#the_search_results")
      |> assert_has(".activity", count: 2)
      |> assert_has("[data-id=load_more]")
      |> click_button("[data-id=load_more]", "Load more")
      |> assert_has(".activity", count: 4)
    end

    test "search results display post with title, content warning, and author's avatar, without the post being replied to",
         %{
           me: me,
           conn: conn,
           me_avatar_path: me_avatar_path,
           me_avatar_url: me_avatar_url
         } do
      op = fake_user!()

      reply_to_message = "noctilucent reply-to content"

      post1_attrs = %{
        post_content: %{html_body: reply_to_message}
      }

      {:ok, post1} = Posts.publish(current_user: op, post_attrs: post1_attrs, boundary: "public")

      html_body = "fulgurescent post with title"
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
      |> visit("/search?s=fulgurescent")
      |> wait_async()
      |> assert_has_or_open_browser(".activity", text: html_body)
      # a matching reply stands alone in search (its parent isn't a hit)
      |> refute_has(".activity", text: reply_to_message)
      |> assert_has_or_open_browser(".activity [data-role=name]", text: title)
      |> assert_has_or_open_browser(".activity [data-role=cw]", text: cw)
      |> assert_has_or_open_browser(".activity [data-id=subject_name]",
        text: e(me, :profile, :name, nil)
      )
      |> assert_has_or_open_browser(".activity [data-id=subject_avatar]")
    end

    # how to avoid fetching from web since we use real Tesla adapter here?
    @tag :todo
    test "search results display test post with link or attachments", %{
      alice: alice,
      me: me,
      conn: conn
    } do
      body = "iridescent post with link or attachments"
      html_body = "#{body} https://developer.mozilla.org/en-US/docs/Web/API/"

      {:ok, _post} =
        Posts.publish(
          current_user: me,
          post_attrs: %{post_content: %{html_body: html_body}},
          boundary: "public"
        )

      conn
      |> visit("/search?s=iridescent")
      |> assert_has(".activity", text: body)
      |> assert_has(".activity [data-id=media_title]", text: "Web APIs")
    end

    test "Search filters display posts result", %{
      alice: alice,
      me: me,
      conn: conn
    } do
      body = "phosphorescent luminous post"
      html_body = "#{body}"

      {:ok, _post} =
        Posts.publish(
          current_user: me,
          post_attrs: %{post_content: %{html_body: html_body}},
          boundary: "public"
        )

      conn
      |> visit("/search?facet[index_type]=Bonfire.Data.Social.Post&index=public&s=phosphorescent")
      |> assert_has_or_open_browser(".activity", text: body)
    end

    test "search filters display correct type of results", %{
      alice: alice,
      me: me,
      conn: conn
    } do
      user_name = "veridian wanderer profile"
      html_body_post = "veridian compendium manuscript"

      {:ok, _post} =
        Posts.publish(
          current_user: me,
          post_attrs: %{
            sensitive: true,
            post_content: %{html_body: html_body_post}
          },
          boundary: "public"
        )

      {:ok, me} = Bonfire.Me.Users.update(me, %{profile: %{name: user_name}})

      conn
      |> visit("/search?s=veridian")
      |> wait_async()
      |> assert_has_or_open_browser(".activity", text: html_body_post)
      |> assert_has_or_open_browser(".activity [data-role=cw]")
      |> assert_has_or_open_browser("[data-role=character] [data-id=profile_name]",
        text: user_name
      )

      conn
      |> visit("/search?facet[index_type]=Bonfire.Data.Identity.User&s=veridian")
      |> wait_async()
      |> assert_has_or_open_browser("[data-role=character] [data-id=profile_name]",
        text: user_name
      )
      |> refute_has(".activity", text: html_body_post)

      conn
      |> visit("/search?facet[index_type]=Bonfire.Data.Social.Post&s=veridian")
      |> wait_async()
      |> assert_has_or_open_browser(".activity", text: html_body_post)
      |> assert_has_or_open_browser(".activity [data-role=cw]")
      |> refute_has("[data-role=character] [data-id=profile_name]", text: user_name)

      conn
      |> visit("/search?s=veridian")
      |> click_link(".tabs a", "Users")
      |> wait_async()
      |> assert_has_or_open_browser("[data-role=character] [data-id=profile_name]",
        text: user_name
      )
      |> refute_has(".activity", text: html_body_post)
      |> click_link(".tabs a", "Posts")
      |> wait_async()
      |> assert_has_or_open_browser(".activity", text: html_body_post)
      |> assert_has_or_open_browser(".activity [data-role=cw]")
      |> refute_has("[data-role=character] [data-id=profile_name]", text: user_name)
    end

    test "search results can be filtered by author via URL params", %{
      alice: alice,
      me: me,
      conn: conn
    } do
      {:ok, _} =
        Posts.publish(
          current_user: alice,
          post_attrs: %{post_content: %{html_body: "brontosaurus dispatch from alice"}},
          boundary: "public"
        )

      {:ok, _} =
        Posts.publish(
          current_user: me,
          post_attrs: %{post_content: %{html_body: "brontosaurus dispatch from bob"}},
          boundary: "public"
        )

      conn
      |> visit("/search?s=brontosaurus")
      |> wait_async()
      |> assert_has(".activity", text: "brontosaurus dispatch from alice")
      |> assert_has(".activity", text: "brontosaurus dispatch from bob")

      conn
      |> visit("/search?s=brontosaurus&facet[index_type]=Bonfire.Data.Social.Post&filters[subjects][]=#{alice.id}")
      |> wait_async()
      |> assert_has(".activity", text: "brontosaurus dispatch from alice")
      |> refute_has(".activity", text: "brontosaurus dispatch from bob")
      # active-filter count badge on the Filters button
      |> assert_has("[data-role=open_search_filters] .badge", text: "1")
    end

    test "newly typed hashtags update the draft and filter results with one Apply", %{me: me, conn: conn} do
      {:ok, _} =
        Posts.publish(
          current_user: me,
          post_attrs: %{post_content: %{html_body: "quicksilver post without hashtags"}},
          boundary: "public"
        )

      for tags <- ["#missingfilterone", "#missingfilterone #missingfiltertwo"] do
        conn
        |> visit("/search?s=quicksilver&facet[index_type]=Bonfire.Data.Social.Post")
        |> wait_async()
        |> assert_has(".activity", text: "quicksilver post without hashtags")
        |> within("[data-role=search_filters_widget]", fn session ->
          session
          |> fill_in("Hashtags", with: tags)
          |> assert_has("[data-row=hashtags] [data-role=row_value]", text: "#missingfilterone")
        end)
        |> assert_has(".activity", text: "quicksilver post without hashtags")
        |> within("[data-role=search_filters_widget]", fn session ->
          click_button(session, "Apply filters")
        end)
        |> wait_async()
        |> assert_has(".tabs a.active", text: "Posts")
        |> refute_has(".activity", text: "quicksilver post without hashtags")
      end
    end

    if System.get_env("PHX_SERVER") != "yes" do
      @tag :skip
    end
    @tag :browser
    test "typing keeps the hashtag row open and focused until one Apply", %{me: me, conn: conn} do
      assert {:ok, _} = Posts.publish(
        current_user: me,
        post_attrs: %{post_content: %{html_body: "quicksilver browser filter post"}},
        boundary: "public"
      )

      # PhoenixTest's server driver cannot exercise native details state or focus.
      {:ok, _} = Application.ensure_all_started(:wallaby)
      metadata = Phoenix.Ecto.SQL.Sandbox.metadata_for(Bonfire.Common.Repo, self())
      {:ok, browser} = Wallaby.start_session(metadata: metadata)
      on_exit(fn -> Wallaby.end_session(browser) end)
      alias Wallaby.Browser
      alias Wallaby.Query

      authenticated = get(conn, "/search?s=quicksilver")
      assert map_size(authenticated.resp_cookies) > 0
      browser = browser |> Browser.resize_window(1440, 1000) |> Browser.visit(@endpoint.url())
      browser = Enum.reduce(authenticated.resp_cookies, browser, fn {key, cookie}, browser ->
        Browser.set_cookie(browser, key, cookie.value)
      end)

      browser = browser
      |> Browser.visit(@endpoint.url() <> "/search?s=quicksilver&facet[index_type]=Bonfire.Data.Social.Post")
      |> Browser.assert_has(Query.css(".activity", text: "quicksilver browser filter post"))
      |> Browser.click(Query.css("[data-role=search_filters_widget] [data-row=hashtags] summary"))
      |> Browser.click(Query.css("[data-role=search_filters_widget] input[name=tags_text]"))

      for {keys, summary} <- [{"b", "#b"}, {"o", "#bo"}, {"nfiremissing", "#bonfiremissing"}] do
        browser
        |> Browser.send_keys(keys)
        |> Browser.assert_has(Query.css("[data-role=search_filters_widget] [data-row=hashtags][open] [data-role=row_value]", text: summary))
        |> Browser.assert_has(Query.css("[data-role=search_filters_widget] input[name=tags_text]:focus"))
        |> Browser.assert_has(Query.css(".activity", text: "quicksilver browser filter post"))
      end

      browser
      |> Browser.click(Query.css("[data-role=search_filters_widget] [data-role=apply_filters]"))
      |> Browser.assert_has(Query.css(".tabs a.active", text: "Posts"))
      |> Browser.refute_has(Query.css(".activity", text: "quicksilver browser filter post"))
    end

    test "hashtag filters keep posts matching either selected tag", %{me: me, conn: conn} do
      Process.put([:bonfire, :default_pagination_limit], 3)

      for body <- ["quicksilver #filteralpha", "quicksilver #filterbeta", "quicksilver untagged"] do
        assert {:ok, _} = Posts.publish(
          current_user: me,
          post_attrs: %{post_content: %{html_body: body}},
          boundary: "public"
        )
      end

      conn
      |> visit("/search?s=quicksilver&facet[index_type]=Bonfire.Data.Social.Post")
      |> wait_async()
      |> assert_has(".activity", text: "quicksilver untagged")
      |> within("[data-role=search_filters_widget]", fn session ->
        session
        |> fill_in("Hashtags", with: "#filteralpha #filterbeta")
        |> click_button("Apply filters")
      end)
      |> wait_async()
      |> assert_has(".activity", text: "filteralpha")
      |> assert_has(".activity", text: "filterbeta")
      |> refute_has(".activity", text: "quicksilver untagged")
    end

    test "newly typed instances update the draft and filter results with one Apply", %{me: me, conn: conn} do
      {:ok, _} =
        Posts.publish(
          current_user: me,
          post_attrs: %{post_content: %{html_body: "quicksilver local instance post"}},
          boundary: "public"
        )

      conn
      |> visit("/search?s=quicksilver&facet[index_type]=Bonfire.Data.Social.Post")
      |> wait_async()
      |> within("[data-role=search_filters_widget]", fn session ->
        session
        |> click_button("[role=radio]", "Other instances")
        |> fill_in("Only these instances", with: "missing.example")
        |> assert_has("[data-row=origin] [data-role=row_value]", text: "missing.example")
      end)
      |> assert_has(".activity", text: "quicksilver local instance post")
      |> within("[data-role=search_filters_widget]", fn session ->
        click_button(session, "Apply filters")
      end)
      |> wait_async()
      |> refute_has(".activity", text: "quicksilver local instance post")
    end

    test "Posts includes articles and Only articles retains matching articles", %{
      me: me,
      conn: conn
    } do
      {:ok, _} =
        Posts.publish(
          current_user: me,
          post_attrs: %{post_content: %{html_body: "glimmering filterable post"}},
          boundary: "public"
        )

      {:ok, _article} =
        Bonfire.Articles.publish(
          current_user: me,
          post_attrs: %{post_content: %{name: "Glimmering article", html_body: "glimmering long-form article"}},
          boundary: "public"
        )

      conn
      |> visit("/search?s=glimmering")
      |> wait_async()
      |> assert_has(".activity", text: "glimmering filterable post")
      |> click_link(".tabs a", "Posts")
      |> wait_async()
      |> assert_has(".activity", text: "glimmering long-form article")
      |> assert_has(".activity", text: "glimmering filterable post")
      # drive the sidebar widget instance of the shared filters editor
      |> within("[data-role=search_filters_widget]", fn session ->
        session
        |> click_button("[data-toggle='article'] button", "Only")
      end)
      |> wait_async()
      |> assert_has(".activity", text: "glimmering filterable post")
      |> within("[data-role=search_filters_widget]", fn session ->
        click_button(session, "Apply filters")
      end)
      |> wait_async()
      |> refute_has(".activity", text: "glimmering filterable post")
      |> assert_has(".activity", text: "glimmering long-form article")
      |> assert_has(".tabs a.active", text: "Posts")
      |> within("[data-role=search_filters_widget]", fn session ->
        click_button(session, "[data-role=reset_filters]", "Reset")
      end)
      |> wait_async()
      |> refute_has(".activity", text: "glimmering filterable post")
      |> within("[data-role=search_filters_widget]", fn session ->
        click_button(session, "Apply filters")
      end)
      |> wait_async()
      |> assert_has(".activity", text: "glimmering filterable post")
      |> assert_has(".activity", text: "glimmering long-form article")
    end

    test "active filters survive re-searching from the main box", %{
      alice: alice,
      me: me,
      conn: conn
    } do
      {:ok, _} =
        Posts.publish(
          current_user: alice,
          post_attrs: %{post_content: %{html_body: "wisteria blossom from alice"}},
          boundary: "public"
        )

      {:ok, _} =
        Posts.publish(
          current_user: me,
          post_attrs: %{post_content: %{html_body: "wisteria blossom from bob"}},
          boundary: "public"
        )

      conn
      |> visit("/search?s=wisteria&facet[index_type]=Bonfire.Data.Social.Post&filters[subjects][]=#{alice.id}")
      |> wait_async()
      |> assert_has(".activity", text: "wisteria blossom from alice")
      |> refute_has(".activity", text: "wisteria blossom from bob")
      # re-searching with a new term from the main search box keeps the author filter
      |> within("main", fn session ->
        session
        |> fill_in("Search content", with: "blossom")
        |> submit()
      end)
      |> wait_async()
      |> assert_has(".activity", text: "wisteria blossom from alice")
      |> refute_has(".activity", text: "wisteria blossom from bob")
      |> assert_has(".tabs a.active", text: "Posts")
      |> assert_has("[data-role=open_search_filters] .badge", text: "1")
    end

    test "only the Posts tab has filters", %{conn: conn} do
      conn
      |> visit("/search?s=quokka&facet[index_type]=Bonfire.Data.Social.Post&filters[origin]=local")
      |> wait_async()
      |> assert_has("[data-role=open_search_filters] .badge", text: "1")
      |> assert_has("[data-role=search_filters_widget] h4", text: "Content types")
      |> click_link(".tabs a", "All")
      |> wait_async()
      |> refute_has("[data-role=search_filters_widget]")
      |> refute_has("[data-role=open_search_filters]")
      |> click_link(".tabs a", "Users")
      |> wait_async()
      |> refute_has("[data-role=search_filters_widget]")
      # filters in an All URL are ignored
      |> visit("/search?s=quokka&filters[origin]=local")
      |> wait_async()
      |> refute_has("[data-role=open_search_filters]")
    end

    test "switching tabs discards unapplied filters from the previous tab", %{conn: conn} do
      conn
      |> visit("/search?s=quartz&facet[index_type]=Bonfire.Data.Social.Post")
      |> wait_async()
      |> within("[data-role=search_filters_widget]", fn session ->
        click_button(session, "[data-toggle='article'] button", "Only")
      end)
      |> click_link(".tabs a", "All")
      |> wait_async()
      |> click_link(".tabs a", "Posts")
      |> wait_async()
      |> assert_has("[data-role=search_filters_widget] [data-toggle=article][data-state=default]")
    end

    test "mobile inline filters stay pending until Apply without feed-only controls", %{
      me: me,
      conn: conn
    } do
      {:ok, _} =
        Posts.publish(
          current_user: me,
          post_attrs: %{post_content: %{html_body: "peregrine modal-typed post"}},
          boundary: "public"
        )

      conn
      |> visit("/search?s=peregrine&facet[index_type]=Bonfire.Data.Social.Post")
      |> wait_async()
      |> assert_has(".activity", text: "peregrine modal-typed post")
      # small screens: the same editor expands inline under the tabs (the sidebar
      # widget isn't shown there), in its :search row configuration
      |> click_button("[data-role=open_search_filters]", "Filters")
      |> within("[data-role=search_filters_inline]", fn session ->
        session
        |> assert_has("h4", text: "From people")
        |> assert_has("h4", text: "Hashtags")
        |> assert_has("h4", text: "Content types")
        |> refute_has("h4", text: "Activity types")
        |> refute_has("h4", text: "Time range")
        |> refute_has("*", text: "Save as custom feed")
        |> assert_has("button", text: "Apply filters")
        |> click_button("[data-toggle='article'] button", "Only")
      end)
      |> wait_async()
      |> assert_has(".activity", text: "peregrine modal-typed post")
      |> within("[data-role=search_filters_inline]", fn session ->
        click_button(session, "Apply filters")
      end)
      |> wait_async()
      |> refute_has(".activity", text: "peregrine modal-typed post")
      |> assert_has(".tabs a.active", text: "Posts")
    end

    test "user can switch between public/private search indexes, showing messages I sent in private one",
         %{
           me: bob,
           alice: alice,
           conn: conn
         } do
      html_message = "zymurgy clandestine dispatch from alice"

      attrs = %{
        to_circles: [bob.id],
        post_content: %{html_body: html_message}
      }

      assert {:ok, message} = Messages.send(alice, attrs)

      conn
      |> visit("/search?index=public&s=zymurgy")
      |> wait_async()
      |> refute_has(".activity", text: html_message)

      conn
      |> visit("/search?index=closed&s=zymurgy")
      |> wait_async()
      |> assert_has(".activity [data-id=object_body]", text: html_message)

      conn
      |> visit("/search?index=public&s=zymurgy")
      |> wait_async()
      |> refute_has(".activity", text: html_message)

      conn
      |> visit("/search?index=closed&s=zymurgy")
      |> wait_async()
      |> assert_has(".activity", text: html_message)
    end

    test "private search index shows messages I received", %{
      me: me,
      alice: alice,
      conn: conn
    } do
      html_message = "quixotic clandestine dispatch received"

      attrs = %{
        to_circles: [alice.id],
        post_content: %{html_body: html_message}
      }

      assert {:ok, message} = Messages.send(me, attrs)

      conn
      |> visit("/search?index=public&s=quixotic")
      |> wait_async()
      |> refute_has(".activity", text: html_message)

      conn
      |> visit("/search?index=closed&s=quixotic")
      |> wait_async()
      |> assert_has(".activity", text: html_message)

      conn
      |> visit("/search?index=public&s=quixotic")
      |> wait_async()
      |> refute_has(".activity", text: html_message)

      conn
      |> visit("/search?index=closed&s=quixotic")
      |> wait_async()
      |> assert_has(".activity", text: html_message)

      conn
      |> visit("/search?index=public&s=quixotic")
      |> wait_async()
      |> refute_has(".activity", text: html_message)
    end
  end
end
