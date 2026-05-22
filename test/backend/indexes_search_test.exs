defmodule Bonfire.Search.IndexesSearchTest do
  use Bonfire.Search.DataCase, async: false
  alias Bonfire.Search
  alias Bonfire.Search.Indexer
  alias Bonfire.Data.Identity.User
  alias Bonfire.Data.Social.Post

  alias Bonfire.Posts
  alias Bonfire.Messages

  doctest Bonfire.Search

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

  # Index settings diff tests only apply to Meilisearch (Sonic has no facet/searchable-field settings)
  if @adapter == Bonfire.Search.MeiliLib do
    describe "index settings diff" do
      test "does not update facets when already matching" do
        index_name = Indexer.index_name(:public)
        @adapter.set_facets(index_name, Indexer.main_facets()) |> @adapter.wait_for_task()

        @adapter.set_searchable_fields(index_name, Indexer.main_searcheable_fields())
        |> @adapter.wait_for_task()

        # init should return no settings update tasks when settings already match
        assert Indexer.init_index(:public) == []
      end

      test "updates facets when they differ" do
        index_name = Indexer.index_name(:public)
        @adapter.set_facets(index_name, ["other_field"]) |> @adapter.wait_for_task()

        {:ok, current} = @adapter.list_facets(index_name)
        assert current == ["other_field"]

        Indexer.init_index(:public) |> @adapter.wait_for_task()

        {:ok, after_init} = @adapter.list_facets(index_name)
        assert Enum.sort(after_init) == Enum.sort(Indexer.main_facets())
      end

      test "updates searchable fields when they differ" do
        index_name = Indexer.index_name(:public)
        @adapter.set_searchable_fields(index_name, ["other_field"]) |> @adapter.wait_for_task()

        {:ok, current} = @adapter.list_searchable_fields(index_name)
        assert current == ["other_field"]

        Indexer.init_index(:public) |> @adapter.wait_for_task()

        {:ok, after_init} = @adapter.list_searchable_fields(index_name)
        assert after_init == Indexer.main_searcheable_fields()
      end
    end
  end

  test "indexes and searches public posts, and preloads required data" do
    # Create sender 
    account = fake_account!()
    sender = fake_user!(account)
    op = fake_user!(account)

    reply_to_message = "What we will reply to"

    post1_attrs = %{
      post_content: %{html_body: reply_to_message}
    }

    {:ok, post1} = Posts.publish(current_user: op, post_attrs: post1_attrs, boundary: "public")

    # Content of the private post
    html_message = "This is a public post"

    post_attrs = %{
      reply_to_id: post1.id,
      post_content: %{html_body: html_message}
    }

    # Create the post (indexes it in the private index)
    {:ok, post2} = Posts.publish(current_user: sender, post_attrs: post_attrs, boundary: "public")

    # Verify it is NOT in the public index
    results =
      Search.search(html_message)

    assert %{hits: [hit]} = results
    assert Enums.id(hit) == Enums.id(post2)
    assert activity = e(hit, :activity, nil)
    assert object = e(activity, :object, nil)

    assert e(activity, :replied, :reply_to_id, nil) != nil
    assert e(activity, :replied, :reply_to, nil) != nil
    assert e(activity, :replied, :reply_to, nil) != nil
    assert e(activity, :replied, :reply_to, :post_content, nil) != nil

    assert e(object, :created, :creator_id, nil) != nil
    assert e(object, :created, :creator, nil) != nil
    assert e(object, :created, :creator, :profile, nil) != nil
    assert e(object, :created, :creator, :profile, :name, nil) != nil
  end

  test "search_and_load returns activities with preloaded data" do
    account = fake_account!()
    sender = fake_user!(account)

    html_message = "xyloquartz luminiferous search_and_load"

    {:ok, post} =
      Posts.publish(
        current_user: sender,
        post_attrs: %{post_content: %{html_body: html_message}},
        boundary: "public"
      )

    result = Search.search_and_load(html_message, [], %{}, current_user: sender)

    assert %{activities: activities, users: users} = result
    assert length(activities) >= 1

    activity_hit =
      Enum.find(
        activities,
        &(Enums.id(&1) == Enums.id(post) or e(&1, :activity, :object_id, nil) == Enums.id(post))
      )

    assert activity_hit != nil

    activity = e(activity_hit, :activity, nil) || activity_hit
    object = e(activity, :object, nil)

    assert object != nil

    assert (e(object, :post_content, nil) != nil ||
              e(object, :post_content, :html_body, nil) != nil) or
             Types.object_type(object) == Post
  end

  test "search_and_load returns users separately from activities" do
    account = fake_account!()
    user = fake_user!(account)
    user_name = "zymurgy separate user search_and_load"
    {:ok, user} = Bonfire.Me.Users.update(user, %{profile: %{name: user_name}})
    {:ok, _} = Bonfire.Search.Indexer.maybe_index_object(user) ~> @adapter.wait_for_task()

    html_body = "zymurgy separate post search_and_load"

    {:ok, _post} =
      Posts.publish(
        current_user: user,
        post_attrs: %{post_content: %{html_body: html_body}},
        boundary: "public"
      )

    result = Search.search_and_load("zymurgy separate", [], %{}, current_user: user)

    assert %{activities: activities, users: users} = result

    assert length(users) >= 1, "expected at least one user hit, got: #{inspect(result)}"
    user_hit = hd(users)

    assert e(user_hit, :profile, :name, nil) != nil,
           "user profile name should be preloaded, got: #{inspect(user_hit)}"

    assert e(user_hit, :character, :username, nil) != nil,
           "user character username should be preloaded, got: #{inspect(user_hit)}"

    assert length(activities) >= 1, "expected at least one activity hit, got: #{inspect(result)}"
    activity_hit = hd(activities)
    activity = e(activity_hit, :activity, nil) || activity_hit
    assert e(activity, :object, nil) != nil, "activity object should be preloaded"

    assert e(activity, :subject_id, nil) != nil or e(activity_hit, :subject_id, nil) != nil,
           "activity subject_id should be set"
  end

  test "searches across multiple types and filters by type" do
    account = fake_account!()
    user = fake_user!(account)

    user_attrs = %{post_content: %{html_body: "zephyranthes multitype luminiferous"}}

    {:ok, _post_by_user} =
      Posts.publish(current_user: user, post_attrs: user_attrs, boundary: "public")

    post_attrs = %{post_content: %{html_body: "noctilucent multitype luminiferous"}}
    {:ok, post} = Posts.publish(current_user: user, post_attrs: post_attrs, boundary: "public")

    assert %{hits: hits} = Search.search("luminiferous")
    assert length(hits) >= 1

    results = Search.search_by_type("noctilucent", Post)
    assert length(results) == 1
    assert Enums.id(hd(results)) == Enums.id(post)
  end

  test "delete from public index removes object" do
    account = fake_account!()
    user = fake_user!(account)

    {:ok, post} =
      Posts.publish(
        current_user: user,
        post_attrs: %{post_content: %{html_body: "obliterable zymurgical compendium"}},
        boundary: "public"
      )

    assert %{hits: [_]} = Search.search("obliterable")

    assert Bonfire.Common.Enums.has_ok?(
             Indexer.maybe_delete_object_all_indexes(Enums.id(post))
             |> @adapter.wait_for_task()
           )

    assert %{hits: []} = Search.search("obliterable")
  end

  test "supports faceted search filtering by type" do
    account = fake_account!()
    user = fake_user!(account)

    {:ok, _post} =
      Posts.publish(
        current_user: user,
        post_attrs: %{post_content: %{html_body: "faceted search test content"}},
        boundary: "public"
      )

    assert {:ok, _} =
             Indexer.maybe_index_object(user)
             ~> @adapter.wait_for_task()

    results =
      Search.search(
        "faceted search test",
        %{},
        true,
        %{"index_type" => Types.module_to_str(Post)}
      )

    assert %{hits: hits} = results
    assert Enum.all?(hits, &(Types.object_type(e(&1, :activity, :object, nil) || &1) == Post))
  end

  describe "private index" do
    test "can index and search for objects in private index" do
      account = fake_account!()
      sender = fake_user!(account)

      {:ok, post} =
        Posts.publish(
          current_user: sender,
          post_attrs: %{post_content: %{html_body: "private zymurgical content luminiferous"}},
          boundary: "mentions"
        )

      # Verify it's not in the public index
      assert %{hits: []} =
               Search.search("private zymurgical content luminiferous",
                 index: :public,
                 skip_boundary_check: true
               )

      # Verify it is in the private index
      assert %{hits: [hit]} =
               Search.search("private zymurgical content luminiferous",
                 index: :closed,
                 skip_boundary_check: true
               )

      assert Enums.id(hit) == Enums.id(post)
    end

    test "can remove objects from private index" do
      account = fake_account!()
      sender = fake_user!(account)

      {:ok, post} =
        Posts.publish(
          current_user: sender,
          post_attrs: %{post_content: %{html_body: "evanescent obliterate zymurgical private"}},
          boundary: "mentions"
        )

      assert %{hits: [hit]} =
               Search.search("evanescent obliterate zymurgical private",
                 index: :closed,
                 skip_boundary_check: true
               )

      assert Enums.id(hit) == Enums.id(post)

      assert Bonfire.Common.Enums.has_ok?(
               Indexer.maybe_delete_object_all_indexes(Enums.id(post))
               |> @adapter.wait_for_task()
             )

      assert %{hits: []} =
               Search.search("evanescent obliterate zymurgical private",
                 index: :closed,
                 skip_boundary_check: true
               )
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
