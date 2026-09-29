defmodule Bonfire.Search.NoAdapterSearchTest do
  @moduledoc """
  With no search index configured, the extension stays enabled: `search_by_type` answers from DB queries for types that have a `search_query/2`, returns nil for the rest (so callers run their own lookup), and the everything search finds nothing rather than falling back to the slow multi-type DB query.
  """
  use Bonfire.Search.DataCase, async: true, needs_adapter: false

  alias Bonfire.Data.Identity.User
  alias Bonfire.Data.Social.Post
  alias Bonfire.Posts

  setup do
    # `ProcessTree` treats a stored nil as unset, so `false` stands for "no adapter": `adapter/0` rejects it as not an enabled module
    Process.put([:bonfire_search, :adapter], false)
    refute Bonfire.Search.adapter()
    :ok
  end

  describe "Bonfire.Search.search_by_type/3" do
    test "finds users from the DB" do
      findable = fake_user!("Nightjar Findable")
      _unrelated = fake_user!("Quokka Unrelated")

      ids =
        Bonfire.Search.search_by_type("nightjar", User, skip_boundary_check: true)
        |> Enum.map(&Enums.id/1)

      assert ids == [Enums.id(findable)]
    end

    test "finds posts by title from the DB" do
      user = fake_user!()

      {:ok, post} =
        Posts.publish(
          current_user: user,
          post_attrs: %{post_content: %{name: "Quillwort almanac", html_body: "some body"}},
          boundary: "public"
        )

      ids =
        Bonfire.Search.search_by_type("quillwort", Post, skip_boundary_check: true)
        |> Enum.map(&Enums.id/1)

      assert Enums.id(post) in ids
    end

    test "returns nil when a type has no search_query/2, so callers run their own lookup" do
      _user = fake_user!("Pangolin Mixed")

      # tag autocomplete's `+` facets
      assert nil ==
               Bonfire.Search.search_by_type("pangolin", [Bonfire.Classify.Category, Bonfire.Tag])

      # one unsupported type among supported ones: a partial (users-only) answer would hide the other types from the caller's own lookup
      assert nil ==
               Bonfire.Search.search_by_type("pangolin", [User, Bonfire.Tag],
                 skip_boundary_check: true
               )
    end
  end

  describe "callers of search_by_type" do
    test "Users.search finds users" do
      findable = fake_user!("Ocelot Caller")

      assert Enums.id(findable) in (Bonfire.Me.Users.search("ocelot") |> Enum.map(&Enums.id/1))
    end

    test "Geolocations.search falls back to its own query instead of looping through search_by_type" do
      assert is_list(Bonfire.Geolocate.Geolocations.search("marmot"))
    end
  end

  describe "everything search" do
    test "finds no content even when the DB has a match" do
      user = fake_user!("Lemming Everything")

      # the positive control: the type search does see this user
      assert Enums.id(user) in (Bonfire.Search.search_by_type("lemming", User,
                                  skip_boundary_check: true
                                )
                                |> Enum.map(&Enums.id/1))

      result = Bonfire.Search.search_and_load("lemming", [], %{}, current_user: user)

      assert result.activities == []
      assert result.users == []
    end
  end
end
