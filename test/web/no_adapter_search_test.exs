defmodule Bonfire.Search.Web.NoAdapterSearchTest do
  @moduledoc """
  With no search index configured, the search page still looks up federated actors and posts by @handle or URL, and says why plain text finds nothing.
  """
  use Bonfire.Search.ConnCase, async: false, needs_adapter: false
  @moduletag :federation
  require Phoenix.LiveViewTest

  alias Bonfire.Federate.ActivityPub.AdapterUtils

  @remote_handle "@karen@mocked.local"
  @remote_actor "https://mocked.local/users/karen"
  @no_index_hint "Full-text search isn't available on this instance"

  setup do
    # `ProcessTree` treats a stored nil as unset, so `false` stands for "no adapter": `adapter/0` rejects it as not an enabled module
    Process.put([:bonfire_search, :adapter], false)
    refute Bonfire.Search.adapter()

    Tesla.Mock.mock_global(fn env -> ActivityPub.Test.HttpRequestMock.request(env) end)
    Bonfire.Federate.ActivityPub.set_federating(:instance, true)

    account = fake_account!()
    me = fake_user!(account)

    {:ok, conn: conn(user: me, account: account), me: me}
  end

  test "the empty search page only invites lookups that work without an index", %{conn: conn} do
    conn
    |> visit("/search")
    |> wait_async()
    |> assert_has("#the_search_results, main", text: "Enter a @username@instance")
    |> refute_has("main", text: "Enter some keywords")
  end

  test "plain text finds nothing, and the page says why", %{conn: conn} do
    _findable = fake_user!("Lemming Plaintext")

    conn
    |> visit("/search?s=lemming")
    |> wait_async()
    |> refute_has("[data-role=search_people_strip]")
    |> assert_has("#the_search_results", text: @no_index_hint)
  end

  test "an @handle finds the remote actor", %{conn: conn} do
    conn
    |> visit("/search?s=" <> URI.encode_www_form(@remote_handle))
    |> wait_async()
    |> assert_has("[data-role=search_people_strip]", text: "karen")
  end

  test "a URL opens the remote actor's page", %{conn: conn} do
    # the redirect comes from the async lookup, which PhoenixTest's `wait_async` doesn't follow
    {:ok, view, _html} =
      Phoenix.LiveViewTest.live(conn, "/search?s=" <> URI.encode_www_form(@remote_actor))

    {path, _flash} = Phoenix.LiveViewTest.assert_redirect(view, 5_000)

    {:ok, karen} = AdapterUtils.get_by_url_ap_id_or_username(@remote_actor)

    assert path == Bonfire.Common.URIs.path(karen)
  end
end
