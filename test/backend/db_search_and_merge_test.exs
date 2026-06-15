defmodule Bonfire.Search.DBSearchAndMergeTest do
  @moduledoc """
  Covers the two root causes of live_select autocompletes returning no/wrong results:

  1. `Bonfire.Search.DB.search_by_type/3` composed type-specific conditions with
     `or_where` on top of a base query that already had a `deleted_at` condition,
     so the search conditions were OR'ed away (returning junk or nothing).

  2. `Bonfire.Search.search_by_type/3` returned *only* index hits when the adapter
     returned a non-empty list, so anything not (yet) in the index — eg. all data
     that predates switching adapters — could never be found. It now merges
     index hits with DB matches (see `merge_with_db_results/4`).
  """
  use Bonfire.Search.DataCase, async: true
  use Repatch.ExUnit

  alias Bonfire.Data.Identity.User

  describe "Bonfire.Search.DB.search_by_type/3" do
    test "finds users matching by username/name and not unrelated users" do
      findable = fake_user!("Zanzibar Findable")
      _unrelated = fake_user!("Quorum Unrelated")

      results =
        Bonfire.Search.DB.search_by_type("zanzibar", User, skip_boundary_check: true)

      ids = Enum.map(results, &Enums.id/1)

      assert Enums.id(findable) in ids

      # the or_where composition bug returned arbitrary non-deleted pointers
      refute Enum.any?(results, fn hit ->
               name = e(hit, :profile, :name, nil)
               is_binary(name) and name =~ "Unrelated"
             end)
    end

    test "returns empty when nothing matches" do
      _user = fake_user!("Somebody Else")

      assert [] ==
               Bonfire.Search.DB.search_by_type("xyzzynomatch", User, skip_boundary_check: true)
    end

    test "respects local_only for user search" do
      local = fake_user!("Localfellow Person")

      results =
        Bonfire.Search.DB.search_by_type("localfellow", User,
          skip_boundary_check: true,
          local_only: true
        )

      assert Enums.id(local) in Enum.map(results, &Enums.id/1)
    end
  end

  describe "Bonfire.Search.merge_with_db_results/4" do
    test "finds DB matches even when the index misses them (stale/incomplete index)" do
      findable = fake_user!("Yonderly Indexless")

      # index returned hits, but not the one matching by name — pre-fix this
      # short-circuited the DB lookup and the user could never be found
      index_hits = [%{"id" => uid(User), "index_type" => "Bonfire.Data.Identity.User"}]

      merged =
        Bonfire.Search.merge_with_db_results(index_hits, "yonderly", User,
          skip_boundary_check: true
        )

      assert Enums.id(findable) in Enum.map(merged, &Enums.id/1)
    end

    test "deduplicates DB and index hits by id, keeping the DB-loaded struct" do
      findable = fake_user!("Wystan Duplicated")

      index_hits = [%{"id" => Enums.id(findable), "index_type" => "Bonfire.Data.Identity.User"}]

      merged =
        Bonfire.Search.merge_with_db_results(index_hits, "wystan", User,
          skip_boundary_check: true
        )

      assert Enum.count(merged, &(Enums.id(&1) == Enums.id(findable))) == 1
      # DB result (a loaded struct, not the raw index map) wins
      assert [hit] = Enum.filter(merged, &(Enums.id(&1) == Enums.id(findable)))
      assert is_struct(hit)
    end

    test "keeps index hits that the DB query does not match" do
      other = fake_user!("Vintage Indexed")

      index_hits = [%{"id" => Enums.id(other), "index_type" => "Bonfire.Data.Identity.User"}]

      merged =
        Bonfire.Search.merge_with_db_results(index_hits, "nomatchhere", User,
          skip_boundary_check: true
        )

      assert Enums.id(other) in Enum.map(merged, &Enums.id/1)
    end

    test "respects the limit option" do
      for n <- 1..5, do: fake_user!("Umpteenth#{n} Limited")

      merged =
        Bonfire.Search.merge_with_db_results([], "umpteenth", User,
          skip_boundary_check: true,
          limit: 3
        )

      assert length(merged) <= 3
    end
  end

  describe "Bonfire.Me.Users.search/2 (the function all user live_selects call)" do
    # `db_merge: true` opts into merging a DB query with index hits (off by default now), which is
    # what user live_selects need so DB-only matches (e.g. data predating the index) are still found.
    test "finds users by name prefix" do
      findable = fake_user!("Tamarind Searchable")

      results = Bonfire.Me.Users.search("tamarind", db_merge: true)

      assert Enums.id(findable) in Enum.map(results, &Enums.id/1)
    end

    test "finds users by username prefix" do
      findable = fake_user!("Sassafras")
      username = e(findable, :character, :username, nil)
      assert is_binary(username)

      results = Bonfire.Me.Users.search(String.slice(username, 0, 6), db_merge: true)

      assert Enums.id(findable) in Enum.map(results, &Enums.id/1)
    end

    test "results have profile and character usable by results_for_multiselect" do
      _findable = fake_user!("Rambutan Formatted")

      results = Bonfire.Me.Users.search("rambutan", db_merge: true)

      assert results != []

      for user <- results do
        assert e(user, :profile, :name, nil) || e(user, :character, :username, nil),
               "search results must have profile/character loaded or live_select options get dropped"
      end
    end
  end

  describe "merge gating (merge_with_db_results is now opt-in)" do
    setup do
      # a user findable by DB name search, but NOT returned by the (faked) index
      findable = fake_user!("Merensky DbOnly")

      # pretend a real (non-DB) adapter is configured, returning some unrelated index hit
      Repatch.patch(Bonfire.Search, :adapter, fn -> Bonfire.Search.Sonic end)

      Repatch.patch(Bonfire.Search.Sonic, :search_by_type, fn _string, _facets, _opts ->
        [%{"id" => Needle.UID.generate(), "index_type" => "Bonfire.Data.Identity.User"}]
      end)

      {:ok, findable: findable}
    end

    test "does NOT merge DB results by default", %{findable: findable} do
      ids =
        Bonfire.Search.search_by_type("merensky", User, skip_boundary_check: true)
        |> Enum.map(&Enums.id/1)

      refute Enums.id(findable) in ids
    end

    test "merges DB results when db_merge: true", %{findable: findable} do
      ids =
        Bonfire.Search.search_by_type("merensky", User, skip_boundary_check: true, db_merge: true)
        |> Enum.map(&Enums.id/1)

      assert Enums.id(findable) in ids
    end
  end
end
