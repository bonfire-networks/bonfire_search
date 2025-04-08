defmodule Bonfire.Search.IndexesMeiliTest do
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
      assert Bonfire.Common.Enums.has_ok?(
               Indexer.maybe_delete_object_all_indexes(Enums.id(post))
               #  Indexer.maybe_delete_object(Enums.id(post), :closed)
               |> @adapter.wait_for_task()
             )

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
