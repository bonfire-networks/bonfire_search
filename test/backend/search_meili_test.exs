defmodule Bonfire.Search.MeiliTest do
  use Bonfire.Search.ConnCase, async: false
  doctest Bonfire.Search

  use Arrows
  import Bonfire.Common.Simulation

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
    tesla = Bonfire.Common.Config.get(:adapter, nil, :tesla)
    Bonfire.Common.Config.put(:adapter, @adapter, :bonfire_search)
    Bonfire.Common.Config.put(:adapter, {Tesla.Adapter.Finch, name: Bonfire.Finch}, :tesla)

    # clear the index
    @adapter.delete(:all, "test_public")
    ~> @adapter.wait_for_task()

    @adapter.delete(:all, "test_closed") ~> @adapter.wait_for_task()

    on_exit(fn ->
      Bonfire.Common.Config.put(:adapter, tesla, :tesla)
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
               |> debug()
               ~> @adapter.wait_for_task()

      # Verify it's no longer found
      assert %{hits: []} = Search.search("Delete Me Post")
    end

    test "skips indexing invalid objects" do
      assert is_nil(Indexer.maybe_index_object(nil))
      assert is_nil(Indexer.maybe_index_object(%{invalid: "object"}))
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

  test "indexes and searches public posts" do
    # Create sender 
    account = fake_account!()
    sender = fake_user!(account)

    # Content of the private post
    html_message = "This is a public post"

    post_attrs = %{
      post_content: %{html_body: html_message}
    }

    # Create the post (indexes it in the private index)
    {:ok, post} = Posts.publish(current_user: sender, post_attrs: post_attrs, boundary: "public")

    # Verify it is NOT in the public index
    results =
      Search.search(html_message)

    assert %{hits: [hit]} = results
    assert Enums.id(hit) == Enums.id(post)
  end

  describe "private index" do
    test "can index and search for objects in private index" do
      # Create a post and index it in the private index
      post = %Post{
        id: uid(Post),
        post_content: %{
          name: "Private Post Title",
          summary: "This post is private",
          html_body: "Private content"
        }
      }

      assert {:ok, _} =
               Indexer.maybe_index_object(post, :closed)
               ~> @adapter.wait_for_task()

      # Verify it's not in the public index
      assert %{hits: []} =
               Search.search("Private content", index: :public, skip_boundary_check: true)

      # Verify it is in the private index
      assert %{hits: [hit]} =
               Search.search("Private content", index: :closed, skip_boundary_check: true)

      assert Enums.id(hit) == Enums.id(post)
    end

    test "can remove objects from private index" do
      # Create a post and index it in the private index
      post = %Post{
        id: uid(Post),
        post_content: %{
          name: "To Be Deleted",
          summary: "This will be removed",
          html_body: "Temporary private content"
        }
      }

      assert {:ok, _} =
               Indexer.maybe_index_object(post, :closed)
               ~> @adapter.wait_for_task()

      # Verify it is in the private index
      assert %{hits: [hit]} =
               Search.search("To Be Deleted", index: :closed, skip_boundary_check: true)

      assert Enums.id(hit) == Enums.id(post)

      # Remove it from the private index
      # NOTE: without having to specify which index
      assert {:ok, _} =
               Indexer.maybe_delete_object(Enums.id(post))
               #  Indexer.maybe_delete_object(Enums.id(post), :closed)
               ~> @adapter.wait_for_task()

      # Verify it is no longer in the private index
      assert %{hits: []} =
               Search.search("To Be Deleted", index: :closed, skip_boundary_check: true)
    end

    test "indexes and searches non-public posts with boundary checks" do
      # Create sender and receiver
      account = fake_account!()
      sender = fake_user!(account)
      receiver = fake_user!(account)
      third = fake_user!(account)

      # Content of the private post
      html_post =
        "This is a non-public post for testing @#{e(receiver, :character, :username, nil)}"

      post_attrs = %{
        # to_circles: [receiver.id],
        post_content: %{html_body: html_post}
      }

      # Create the post (indexes it in the private index)
      {:ok, post} =
        Posts.publish(current_user: sender, post_attrs: post_attrs, boundary: "mentions")

      # Verify it is NOT in the public index
      results =
        Search.search(html_post, index: :public, current_user: receiver)

      assert %{hits: []} = results

      # Verify it is in the private index with boundary checks by the receiver
      results =
        Search.search(html_post, index: :closed, current_user: receiver)

      assert %{hits: [hit]} = results
      assert Enums.id(hit) == Enums.id(post)

      # Verify it is in the private index with boundary checks by the sender
      results =
        Search.search(html_post, index: :closed, current_user: sender)

      assert %{hits: [hit]} = results
      assert Enums.id(hit) == Enums.id(post)

      # Verify it is NOT accessible to unauthorized users
      results =
        Search.search(html_post, index: :closed, current_user: third)

      assert %{hits: []} = results

      # Verify it is NOT accessible to non-users
      results =
        Search.search(html_post, index: :closed)

      assert %{hits: []} = results
    end

    test "indexes and searches private messages with boundary checks" do
      # Create sender and receiver
      account = fake_account!()
      sender = fake_user!(account)
      receiver = fake_user!(account)
      third = fake_user!(account)

      # Content of the private message
      html_message = "This is a private message for testing"

      message_attrs = %{
        to_circles: [receiver.id],
        post_content: %{html_body: html_message}
      }

      # Send the message (indexes it in the private index)
      assert {:ok, message} = Messages.send(sender, message_attrs)

      # Verify it is in the private index with boundary checks by the receiver
      results =
        Search.search(html_message, index: :closed, current_user: receiver)

      assert %{hits: [hit]} = results
      assert Enums.id(hit) == Enums.id(message)

      # Verify it is in the private index with boundary checks by the sender
      results =
        Search.search(html_message, index: :closed, current_user: sender)

      assert %{hits: [hit]} = results
      assert Enums.id(hit) == Enums.id(message)

      # Verify it is NOT accessible to unauthorized users
      results =
        Search.search(html_message, index: :closed, current_user: third)

      assert %{hits: []} = results

      # Verify it is NOT accessible to non-users
      results =
        Search.search(html_message, index: :closed)

      assert %{hits: []} = results

      # Verify it is NOT in the public index
      results =
        Search.search(html_message, index: :public, current_user: receiver)

      assert %{hits: []} = results
    end
  end
end
