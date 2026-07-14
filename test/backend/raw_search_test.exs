defmodule Bonfire.Search.RawSearchTest do
  use Bonfire.Search.DataCase, async: false
  doctest Bonfire.Search

  alias Bonfire.Search
  alias Bonfire.Search.Indexer
  alias Bonfire.Data.Identity.User
  alias Bonfire.Data.Social.Post

  alias Bonfire.Posts
  alias Bonfire.Messages

  @adapter Bonfire.Common.Config.get(:adapter, Bonfire.Search.MeiliLib, :bonfire_search)

  setup do
    Bonfire.Common.Config.put(:wait_for_indexing, true, :bonfire_search)
    prev = prepare_indexes_for_tests(@adapter)

    on_exit(fn ->
      reset_indexes_after_tests(@adapter, prev)
      Bonfire.Common.Config.put(:wait_for_indexing, false, :bonfire_search)
    end)

    :ok
  end

  describe "search" do
    test "searches across multiple types" do
      user = %{
        "character" => %{
          "username" => "testuser",
          "index_type" => "Bonfire.Data.Identity.Character"
        },
        "id" => "01JDFM2DYVKQ1KHRC4GECWK5PC",
        "index_type" => "Bonfire.Data.Identity.User",
        "profile" => %{
          "name" => "Zephyranthes User",
          "summary" => "Biographic zephyr",
          "index_type" => "Bonfire.Data.Identity.Profile"
        }
      }

      assert {:ok, _} =
               Indexer.maybe_index_object(user)
               ~> @adapter.wait_for_task()

      post = %{
        "id" => "01JDFM2DD9HWFB1JSP4ZAYTXTN",
        "index_type" => "Bonfire.Data.Social.Post",
        "post_content" => %{
          "index_type" => "Bonfire.Data.Social.PostContent",
          "html_body" => "Quixotic content zephyranthes searchable",
          "name" => "Quixotic Title",
          "summary" => "Quixotic specific summary"
        }
      }

      assert {:ok, _} =
               Indexer.maybe_index_object(post)
               ~> @adapter.wait_for_task()

      assert %{hits: hits} = Search.search("zephyranthes", %{raw: true})
      assert length(hits) == 2

      assert %{hits: [hit]} = Search.search("biographic", %{raw: true})
      assert e(hit, "id", nil) == e(user, "id", nil)

      assert %{hits: [hit]} = Search.search("quixotic", %{raw: true})
      assert e(hit, "id", nil) == e(post, "id", nil)
    end

    test "search_by_type filters results by type" do
      Bonfire.Common.Config.put(:disable_for_autocompletes, false, :bonfire_search)

      user = %User{
        id: uid(User),
        profile: %{name: "Veridian Wanderer"},
        character: %{username: "veridianuser"}
      }

      assert {:ok, _} =
               user
               # `skip_err`: this hand-built User's `character` is a bare map with no loadable
               # `:peered`, so opt into best-effort preload rather than crashing the indexer
               |> Bonfire.Me.Users.indexing_object_format(skip_err: true, preload_if_needed: false)
               |> Indexer.maybe_index_object()
               ~> @adapter.wait_for_task()

      post = %Post{
        id: uid(Post),
        post_content: %{
          name: "Veridian Manuscript",
          summary: "Veridian compendium",
          html_body: "Veridian compendium manuscript"
        }
      }

      assert {:ok, _} =
               Indexer.maybe_index_object(post)
               ~> @adapter.wait_for_task()

      results = Search.search_by_type("manuscript", Post, raw: true)
      assert length(results) == 1
      [hit] = results
      assert e(hit, "id", nil) == Enums.id(post)

      results = Search.search_by_type("wanderer", [User], raw: true)
      assert length(results) == 1
      [hit] = results
      assert e(hit, "id", nil) == Enums.id(user)
    end
  end

  describe "indexing" do
    test "maybe_index_object indexes searchable objects" do
      post = %Post{
        id: uid(Post),
        post_content: %{
          name: "Noctilucent Trajectory",
          summary: "Noctilucent specifics",
          html_body: "Noctilucent trajectory content"
        }
      }

      assert {:ok, _} =
               Indexer.maybe_index_object(post)
               ~> @adapter.wait_for_task()

      assert %{hits: [hit]} = Search.search("noctilucent", %{raw: true})
      assert e(hit, "id", nil) == Enums.id(post)
    end

    test "maybe_delete_object removes objects from search index" do
      post = %Post{
        id: uid(Post),
        post_content: %{
          name: "Obliterate Zymurgy Post",
          summary: "Zymurgy obliterate",
          html_body: "Zymurgy obliterate content"
        }
      }

      assert {:ok, _} =
               Indexer.maybe_index_object(post)
               ~> @adapter.wait_for_task()

      assert %{hits: [_hit]} = Search.search("zymurgy", %{raw: true})

      assert Bonfire.Common.Enums.has_ok?(
               Indexer.maybe_delete_object_all_indexes(Enums.id(post))
               |> @adapter.wait_for_task()
             )

      assert %{hits: []} = Search.search("zymurgy", %{raw: true})
    end

    test "skips indexing invalid objects" do
      assert {:error, _} = Indexer.maybe_index_object(nil)
      assert {:error, _} = Indexer.maybe_index_object(%{})
      assert {:error, _} = Indexer.maybe_index_object(%{id: "object"})
    end
  end

  describe "search features" do
    test "supports faceted search" do
      user1 = %User{
        id: uid(User),
        profile: %{name: "Facet User"},
        character: %{username: "facetuser1"}
      }

      user2 = %User{
        id: uid(User),
        profile: %{name: "Another Facet User"},
        character: %{username: "facetuser2"}
      }

      assert {:ok, _} =
               user1
               # `skip_err`: bare-map `character` with no loadable `:peered` (see above)
               |> Bonfire.Me.Users.indexing_object_format(skip_err: true, preload_if_needed: false)
               |> Indexer.maybe_index_object()
               ~> @adapter.wait_for_task()

      assert {:ok, _} =
               user2
               |> Bonfire.Me.Users.indexing_object_format(skip_err: true, preload_if_needed: false)
               |> Indexer.maybe_index_object()
               ~> @adapter.wait_for_task()

      results =
        Search.search("facet", %{raw: true}, true, %{"index_type" => Types.module_to_str(User)})

      assert %{hits: hits} = results
      assert length(hits) == 2

      # Meilisearch raw hits include document fields, so we can verify the type;
      # Sonic raw hits only contain %{"id" => id} with no document fields
      if @adapter == Bonfire.Search.MeiliLib do
        assert Enum.all?(hits, &(Types.object_type(e(&1, :activity, :object, nil) || &1) == User))
      end
    end

    test "handles pagination" do
      for i <- 1..5 do
        %Post{
          id: uid(Post),
          post_content: %{
            name: "A Pagination Post #{i}",
            summary: "A summary #{i}",
            html_body: "Page content #{i}"
          }
        }
      end
      |> Indexer.maybe_index_object()
      ~> @adapter.wait_for_task()

      results = Search.search("Pagination", %{limit: 2, raw: true})
      assert %{hits: hits} = results
      assert length(hits) == 2

      results = Search.search("Pagination", %{limit: 3, offset: 2, raw: true})
      assert %{hits: hits} = results
      assert length(hits) == 3
    end
  end
end
