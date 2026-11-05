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

  # CJK text has no spaces between words, so finding "你好" in "你好世界" depends on how the adapter tokenises it
  for {name, query} <- [{"José Núñez", "josé"}, {"José Núñez", "núñez"}, {"你好世界", "你好"}] do
    test "an indexed user named #{name} is found by searching #{query}" do
      account = fake_account!()
      user = fake_user!(account)
      {:ok, user} = Bonfire.Me.Users.update(user, %{profile: %{name: unquote(name)}})
      {:ok, _} = Bonfire.Search.Indexer.maybe_index_object(user) ~> @adapter.wait_for_task()

      %{users: users} = Search.search_and_load(unquote(query), [], %{}, current_user: user)

      assert Enums.id(user) in Enum.map(users, &Enums.id/1),
             "expected #{unquote(name)} in the results for #{unquote(query)}, got: #{inspect(Enum.map(users, &e(&1, :profile, :name, nil)))}"
    end
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

  describe "groups and topics in the public index" do
    # the public index is what the main search uses unless private contents are included, so a group anyone can see must be found there
    defp in_index?(name, index, category) do
      %{hits: hits} = Search.search(name, index: index, skip_boundary_check: true)
      Enum.any?(List.wrap(hits), &(Enums.id(&1) == Enums.id(category)))
    end

    test "an open group that anyone may post in is found without private contents" do
      user = fake_user!()
      name = "zymurgical quokka openhouse"

      group =
        Bonfire.Classify.Simulate.fake_group!(user, %{
          name: name,
          membership: "open",
          visibility: "global",
          participation: "anyone"
        })

      assert in_index?(name, :public, group)
    end

    test "a public group that only members may post in is found without private contents" do
      user = fake_user!()
      name = "zymurgical quokka reviewers"

      group =
        Bonfire.Classify.Simulate.fake_group!(user, %{
          name: name,
          membership: "on_request",
          visibility: "global",
          participation: "group_members"
        })

      assert in_index?(name, :public, group)
      refute in_index?(name, :closed, group)
    end

    test "a top-level topic is found without private contents" do
      user = fake_user!()
      name = "zymurgical quokka topicality"

      topic = Bonfire.Classify.Simulate.fake_category!(user, nil, %{name: name, type: :topic})

      assert in_index?(name, :public, topic)
    end

    test "an unlisted group stays out of the public index" do
      user = fake_user!()
      name = "zymurgical quokka hideaway"

      group =
        Bonfire.Classify.Simulate.fake_group!(user, %{
          name: name,
          membership: "on_request",
          visibility: "local:unlisted",
          participation: "group_members"
        })

      # prove it was indexed at all before trusting its absence from the public one
      assert in_index?(name, :closed, group)
      refute in_index?(name, :public, group)
    end

    # a preview group may be found by anyone, and what is indexed for a group (its name and summary) is what a guest may see of it
    test "a preview group is found without private contents" do
      user = fake_user!()
      name = "zymurgical quokka peekaboo"

      group =
        Bonfire.Classify.Simulate.fake_group!(user, %{
          name: name,
          membership: "on_request",
          visibility: "preview",
          participation: "group_members"
        })

      assert in_index?(name, :public, group)
    end

    # a guest may see a post in a preview group but not read it: search follows `:see`, as feeds do, so it is in the public index, also when an edit picks the index from its boundaries, and the results show it without its content (`test/web/see_only_results_test.exs`)
    test "a post in a preview group is in the public index, also after an edit" do
      user = fake_user!()

      group =
        Bonfire.Classify.Simulate.fake_group!(user, %{
          membership: "on_request",
          visibility: "preview",
          participation: "group_members",
          default_content_visibility: "public:preview"
        })

      body = "zymurgical quokka previewpost"

      {:ok, post} =
        Posts.publish(
          current_user: user,
          publish_in: group.id,
          boundary: "public:preview",
          post_attrs: %{post_content: %{html_body: body}}
        )

      assert Bonfire.Boundaries.can?(fake_user!(), :see, post),
             "control: an outsider may see the post"

      refute Bonfire.Boundaries.can?(:guest, :read, post), "control: a guest may not read it"

      assert in_index?(body, :public, post)
      refute in_index?(body, :closed, post)

      edited = "zymurgical quokka revisedpost"

      assert {:ok, _} =
               Bonfire.Social.PostContents.edit(user, Enums.id(post), %{html_body: edited})

      assert in_index?(edited, :public, post)
      refute in_index?(edited, :closed, post)
    end

    # guests may see and read a `nonfederated` post, so its boundary name picks the public index on create, as its ACLs do on an edit
    test "a post published nonfederated is in the public index, also after an edit" do
      user = fake_user!()
      body = "zymurgical quokka nonfedpost"

      {:ok, post} =
        Posts.publish(
          current_user: user,
          boundary: "nonfederated",
          post_attrs: %{post_content: %{html_body: body}}
        )

      assert Bonfire.Boundaries.can?(:guest, :read, post), "control: a guest may read it"

      assert in_index?(body, :public, post)
      refute in_index?(body, :closed, post)

      edited = "zymurgical quokka nonfedrevised"

      assert {:ok, _} =
               Bonfire.Social.PostContents.edit(user, Enums.id(post), %{html_body: edited})

      assert in_index?(edited, :public, post)
      refute in_index?(edited, :closed, post)
    end

    defp found_by?(name, index, user, object) do
      %{hits: hits} = Search.search(name, index: index, current_user: user)
      Enum.any?(List.wrap(hits), &(Enums.id(&1) == Enums.id(object)))
    end

    defp local_preview_group(owner, name) do
      Bonfire.Classify.Simulate.fake_group!(owner, %{
        name: name,
        membership: "on_request",
        visibility: "local:preview",
        participation: "group_members",
        default_content_visibility: "members:private"
      })
    end

    # search follows `:see` for groups, and a group only local users may see grants local non-members `:see` but not `:read`
    test "a group only local users may see is found by a local non-member" do
      owner = fake_user!()
      name = "zymurgical quokka localclub"
      group = local_preview_group(owner, name)

      assert in_index?(name, :closed, group)
      assert found_by?(name, :closed, fake_user!(), group)
      # guests search the public index only, as the closed one returns nothing without a user
      refute in_index?(name, :public, group)
    end

    test "a members-only group is found by its members only" do
      owner = fake_user!()
      member = fake_user!()
      name = "zymurgical quokka innercircle"

      group =
        Bonfire.Classify.Simulate.fake_group!(owner, %{
          name: name,
          membership: "invite_only",
          visibility: "members:private",
          participation: "group_members"
        })

      {:ok, _} =
        Bonfire.Classify.Categories.add_member(owner, group, member.id, skip_boundary_check: true)

      assert found_by?(name, :closed, member, group)
      refute found_by?(name, :closed, fake_user!(), group)
    end

    # a local non-member may see the post but not read it: search follows `:see` for every object, as feeds do, so it is found, and the results show it without its content (`test/web/see_only_results_test.exs`); guests may not see it, so it stays out of the public index
    test "a post in a group only local users may see is found by local non-members, and not by guests" do
      owner = fake_user!()
      group = local_preview_group(owner, "zymurgical quokka clubhouse")
      body = "zymurgical quokka clubpost"

      {:ok, post} =
        Posts.publish(
          current_user: owner,
          publish_in: group.id,
          boundary: "local:preview",
          post_attrs: %{post_content: %{html_body: body}}
        )

      assert found_by?(body, :closed, owner, post)
      assert found_by?(body, :closed, fake_user!(), post)
      refute in_index?(body, :public, post)
    end

    # guests find whatever is in the public index, with no boundary check, so a group narrowed to members must leave it
    test "a group narrowed to members only leaves the public index" do
      user = fake_user!()
      name = "zymurgical quokka narrowing"

      group =
        Bonfire.Classify.Simulate.fake_group!(user, %{
          name: name,
          membership: "open",
          visibility: "global",
          participation: "anyone"
        })

      assert in_index?(name, :public, group)

      assert :ok =
               Bonfire.Classify.Boundaries.replace(group, user, %{
                 membership: "invite_only",
                 visibility: "members:private",
                 participation: "group_members"
               })

      refute in_index?(name, :public, group)
      # its members still find it
      assert in_index?(name, :closed, group)
    end

    # the index's own ids, before any loading: Sonic's hits are loaded through their pointers, which leaves out an archived or deleted object, but the index still holds its text, and autocomplete or Meili (whose documents hold the name and summary) read it from there
    defp in_raw_index?(name, index, object) do
      %{hits: hits} = Search.search(name, index: index, raw: true)
      Enum.any?(List.wrap(hits), &(Enums.id(&1) == Enums.id(object)))
    end

    # a narrowing before the fix left a public copy behind; it must go when the group goes, whatever index its boundaries pick now
    defp narrowed_group_with_public_copy(user, name) do
      group =
        Bonfire.Classify.Simulate.fake_group!(user, %{
          name: name,
          membership: "invite_only",
          visibility: "members:private",
          participation: "group_members"
        })

      Search.maybe_index(group, :public, user)
      assert in_raw_index?(name, :public, group)
      assert in_raw_index?(name, :closed, group)
      group
    end

    test "a group archived after it was narrowed leaves both indexes" do
      user = fake_user!()
      name = "zymurgical quokka archivist"
      group = narrowed_group_with_public_copy(user, name)

      assert {:ok, _} = Bonfire.Classify.Categories.soft_delete(group, user)

      refute in_raw_index?(name, :public, group)
      refute in_raw_index?(name, :closed, group)
    end

    test "a group deleted after it was narrowed leaves both indexes" do
      user = fake_user!()
      name = "zymurgical quokka demolition"
      group = narrowed_group_with_public_copy(user, name)

      assert {:ok, _} = Bonfire.Classify.Categories.hard_delete(group, current_user: user)

      refute in_raw_index?(name, :public, group)
      refute in_raw_index?(name, :closed, group)
    end
  end
end
