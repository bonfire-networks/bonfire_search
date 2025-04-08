defmodule Bonfire.Search.BasicMeiliTest do
  use Bonfire.Search.DataCase, async: false
  doctest Bonfire.Search

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
    {meili_adapter, tesla_adapter} = prepare_meili_for_tests()

    on_exit(fn ->
      reset_meili_after_tests(meili_adapter, tesla_adapter)
    end)

    :ok
  end

  describe "search" do
    test "searches across multiple types" do
      # Create and index some test data
      user = %{
        "character" => %{
          "username" => "testuser",
          "index_type" => "Bonfire.Data.Identity.Character"
        },
        "id" => "01JDFM2DYVKQ1KHRC4GECWK5PC",
        "index_type" => "Bonfire.Data.Identity.User",
        "profile" => %{
          "name" => "Test User",
          "summary" => "Bio here",
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
          "html_body" => "Content that should be searchable",
          "name" => "Test Title",
          "summary" => "Test specific summary"
        }
      }

      assert {:ok, _} =
               Indexer.maybe_index_object(post)
               ~> @adapter.wait_for_task()

      # Test searching by various fields
      assert %{hits: hits} = Search.search("test")
      # Should find both user and post
      assert length(hits) == 2

      assert %{hits: [hit]} = Search.search("Bio here")
      assert Enums.id(hit) == Enums.id(user)

      assert %{hits: [hit]} = Search.search("searchable")
      assert Enums.id(hit) == Enums.id(post)
    end

    test "search_by_type filters results by type" do
      Bonfire.Common.Config.put(:disable_for_autocompletes, false, :bonfire_search)

      # Create and index test data of different types
      user = %User{
        id: uid(User),
        profile: %{name: "Another User"},
        character: %{username: "anotheruser"}
      }

      assert {:ok, _} =
               Indexer.maybe_index_object(user)
               ~> @adapter.wait_for_task()

      post = %Post{
        id: uid(Post),
        post_content: %{
          name: "Another Post",
          summary: "Another summary",
          html_body: "More test content"
        }
      }

      assert {:ok, _} =
               Indexer.maybe_index_object(post)
               ~> @adapter.wait_for_task()

      # Search with type filter
      results = Search.search_by_type("another", Post)
      # |> debug()
      assert length(results) == 1
      [hit] = results
      assert Enums.id(hit) == Enums.id(post)

      results = Search.search_by_type("another", [User])
      assert length(results) == 1
      [hit] = results
      assert Enums.id(hit) == Enums.id(user)
    end
  end

  describe "indexing" do
    test "maybe_index_object indexes searchable objects" do
      post = %Post{
        id: uid(Post),
        post_content: %{
          name: "Unique Post Title",
          summary: "Very specific summary",
          html_body: "Content that should be searchable"
        }
      }

      assert {:ok, _} =
               Indexer.maybe_index_object(post)
               ~> @adapter.wait_for_task()

      # Verify the object is searchable
      assert %{hits: [hit]} = Search.search("Unique Post Title")
      assert Enums.id(hit) == Enums.id(post)

      assert (e(hit, :post_content, :name, nil) ||
                e(hit, :activity, :object, :post_content, :name, nil)) == "Unique Post Title"
    end

    test "maybe_delete_object removes objects from search index" do
      # First index an object
      post = %Post{
        id: uid(Post),
        post_content: %{
          name: "Delete Me Post",
          summary: "This should be removed",
          html_body: "Temporary content"
        }
      }

      assert {:ok, _} =
               Indexer.maybe_index_object(post)
               ~> @adapter.wait_for_task()

      # Verify it's indexed
      assert %{hits: [_hit]} = Search.search("Delete Me Post")

      # Delete it
      assert {:ok, _} =
               Indexer.maybe_delete_object(Enums.id(post))
               ~> @adapter.wait_for_task()
               |> debug()

      # Verify it's no longer found
      assert %{hits: []} = Search.search("Delete Me Post")
    end

    test "skips indexing invalid objects" do
      assert {:error, _} = Indexer.maybe_index_object(nil)
      assert {:error, _} = Indexer.maybe_index_object(%{})
      assert {:error, _} = Indexer.maybe_index_object(%{id: "object"})
    end
  end

  describe "search features" do
    test "supports faceted search" do
      # Index objects with different facets
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
               Indexer.maybe_index_object(user1)
               ~> @adapter.wait_for_task()

      assert {:ok, _} =
               Indexer.maybe_index_object(user2)
               ~> @adapter.wait_for_task()

      # Search with facets
      results = Search.search("facet", %{}, true, %{"index_type" => Types.module_to_str(User)})
      assert %{hits: hits} = results
      assert length(hits) == 2
      assert Enum.all?(hits, &(Types.object_type(e(&1, :activity, :object, nil) || &1) == User))
    end

    test "handles pagination" do
      # Index multiple objects
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

      # Test with different page sizes
      results = Search.search("Pagination", %{limit: 2})
      assert %{hits: hits} = results
      assert length(hits) == 2

      results = Search.search("Pagination", %{limit: 3, offset: 2})
      assert %{hits: hits} = results
      assert length(hits) == 3
    end
  end
end
