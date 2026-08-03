defmodule Bonfire.Search.PrepareHitsTest do
  @moduledoc """
  Search hits that carry no activity must survive `prepare_hits/3` — and must not pay for activity preloads.

  `@` mention autocomplete searches the `Bonfire.Data.Identity.User` bucket only, and `prepare_hits/3` deliberately returns those hits unwrapped ("no activity wrapping needed"). `hits_preloads/2` nonetheless ran every hit through `Activities.activity_preloads/3`, which cost a `bonfire_data_social_activity` query per user hit and resolved their activity to `nil` — which the `:quote_tags` traversal then crashed on (`BadMapError`), 500ing every autocomplete request.

  Uses `Bonfire.DataCase` rather than `Bonfire.Search.DataCase` on purpose: this path needs no search adapter (`config/test.exs` sets `adapter: nil`, which would skip the module).
  """
  use Bonfire.DataCase, async: true

  @moduletag :backend

  describe "prepare_hits/3" do
    test "returns a user hit without preloading activity data it can never have" do
      user = fake_user!()
      [user_hit] = Bonfire.Boundaries.load_pointers([id(user)], skip_boundary_check: true)

      # precondition: the shape the search adapter hands over — a bare pointer, activity unloaded
      assert %Needle.Pointer{} = user_hit
      refute Ecto.assoc_loaded?(user_hit.activity)

      assert [prepared] =
               Bonfire.Search.prepare_hits([user_hit], :public, skip_boundary_check: true)

      assert id(prepared) == id(user)

      # an activity-scoped preload pass would have resolved this to `nil` (the useless query)
      refute Ecto.assoc_loaded?(prepared.activity)
    end
  end
end
