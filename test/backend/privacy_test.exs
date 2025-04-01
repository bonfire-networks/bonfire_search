defmodule Bonfire.Search.MeiliTest do
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
    Bonfire.Common.Config.put(:wait_for_indexing, true, :bonfire_search)

    {meili_adapter, tesla_adapter} = prepare_meili_for_tests()

    on_exit(fn ->
      reset_meili_after_tests(meili_adapter, tesla_adapter)

      Bonfire.Common.Config.put(:wait_for_indexing, false, :bonfire_search)
    end)

    :ok
  end

  test "respects user's discoverability privacy settings" do
    user = fake_user!()
    initial_name = e(user, :character, :username, nil)

    # can find the user
    assert %{hits: [hit]} = Search.search(initial_name)
    assert Enums.id(hit) == Enums.id(user)

    user =
      current_user(
        Bonfire.Common.Settings.put([Bonfire.Me.Users, :undiscoverable], true, current_user: user)
      )

    assert Bonfire.Common.Settings.get([Bonfire.Me.Users, :undiscoverable], nil,
             current_user: user
           ) == true

    #  should have deleted the user from search index
    assert %{hits: []} = Search.search(initial_name)

    user_name = "new undiscoverable user name"
    {:ok, user} = Bonfire.Me.Users.update(user, %{profile: %{name: user_name}})

    #  updated name should not be indexed
    assert %{hits: []} = Search.search(user_name)
  end

  test "respects user's indexing privacy settings" do
    user = fake_user!()
    initial_name = e(user, :character, :username, nil)

    # can find the user
    assert %{hits: [hit]} = Search.search(initial_name)
    assert Enums.id(hit) == Enums.id(user)

    html_body_post = "test post for search privacy test"

    {:ok, post_indexed} =
      Posts.publish(
        current_user: user,
        post_attrs: %{post_content: %{html_body: html_body_post}},
        boundary: "public"
      )

    # can find post
    assert %{hits: [hit]} = Search.search(html_body_post)
    assert Enums.id(hit) == Enums.id(post_indexed)

    user =
      current_user(
        Bonfire.Common.Settings.put([Bonfire.Search.Indexer, :modularity], :disabled,
          current_user: user
        )
      )

    assert Bonfire.Common.Extend.module_enabled?(Bonfire.Search.Indexer, user) == false

    # assert %{hits: []} = Search.search(initial_name) # TODO? delete the user from search index?

    user_name = "new non-indexed user name"
    {:ok, user} = Bonfire.Me.Users.update(user, %{profile: %{name: user_name}})

    %{hits: results} = Search.search(user_name)

    refute results
           |> Enum.any?(fn hit ->
             e(hit, "character", "username", nil) == initial_name
           end),
           "updated name should not be indexed"

    # TODO: old name should be removed
    # assert %{hits: []} = Search.search(initial_name)

    html_body_post_non_indexed = "non-indexed article"

    {:ok, post_non_indexed} =
      Posts.publish(
        current_user: user,
        post_attrs: %{post_content: %{html_body: html_body_post_non_indexed}},
        boundary: "public"
      )

    %{hits: results} = Search.search(html_body_post_non_indexed)

    # For explicitly check our post isn't there
    refute results
           |> Enum.any?(fn hit ->
             Enums.id(hit) == Enums.id(post_non_indexed)
           end),
           "The non-indexed post should not appear in search results"

    #  TODO? delete old posts from search index?
    # %{hits: results} = Search.search(html_body_post)
    # refute results 
    #    |> Enum.any?(fn hit -> 
    #       Enums.id(hit) == Enums.id(post_indexed) 
    #     end), 
    #    "The previously indexed post should no longer appear in search results"
  end
end
