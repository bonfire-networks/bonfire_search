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

  # a group is typed with whichever prefix someone is used to (`!group@host` from the threadiverse, `&` and `+` from Bonfire), and every place that reads a handle takes them all, so the lookup starts for each, as it does for `@` (the test above)
  for prefix <- ["!", "&", "+"] do
    test "a #{prefix}handle finds the remote actor too", %{conn: conn} do
      conn
      |> visit("/search?s=" <> URI.encode_www_form(unquote(prefix) <> "karen@mocked.local"))
      |> wait_async()
      |> assert_has("[data-role=search_people_strip]", text: "karen")
    end
  end

  # or none: anything shaped like `name@host.tld` is a handle someone pasted
  test "a handle with no prefix finds the remote actor too", %{conn: conn} do
    conn
    |> visit("/search?s=" <> URI.encode_www_form("karen@mocked.local"))
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

  # a group is not a person: the lookup's result goes into its own list, which the Groups tab can reuse, and not into the people strip or the Users tab
  test "a remote group's handle shows the group among the groups, and not as a person", %{
    conn: conn
  } do
    remote_group = "https://mocked.local/c/cooks"

    group_json =
      Bonfire.Federate.ActivityPub.Simulate.actor_json(remote_group, "cooks", %{
        "type" => "Group",
        "name" => "Remote cooks"
      })

    Tesla.Mock.mock_global(fn
      %{method: :get, url: "https://mocked.local/.well-known/webfinger" <> _ = url} ->
        case URI.decode_query(URI.parse(url).query || "")["resource"] do
          "acct:cooks@mocked.local" ->
            Tesla.Mock.json(Bonfire.Federate.ActivityPub.Simulate.webfingered("cooks", remote_group))

          _ ->
            %Tesla.Env{status: 404, body: ""}
        end

      %{method: :get, url: ^remote_group} ->
        Tesla.Mock.json(group_json)

      %{method: :post} ->
        %Tesla.Env{status: 202, body: ""}

      env ->
        ActivityPub.Test.HttpRequestMock.request(env)
    end)

    handle = URI.encode_www_form("!cooks@mocked.local")

    conn
    |> visit("/search?s=" <> handle)
    |> wait_async()
    |> assert_has("[data-role=search_group_hit]", text: "Remote cooks")
    |> refute_has("[data-role=search_people_strip]", text: "Remote cooks")

    conn
    |> visit("/search?s=" <> handle <> "&facet[index_type]=Bonfire.Data.Identity.User")
    |> wait_async()
    |> refute_has("#the_search_results", text: "Remote cooks")

    # with no index, the Groups tab shows only what the lookup found
    conn
    |> visit("/search?s=" <> handle <> "&facet[index_type]=Bonfire.Classify.Category")
    |> wait_async()
    |> assert_has("[data-role=search_group_hit]", text: "Remote cooks")
  end

  test "plain text on the Groups tab finds nothing, and the page says why", %{conn: conn, me: me} do
    Bonfire.Classify.Simulate.fake_group!(me, %{name: "Lemming herders"})

    conn
    |> visit("/search?s=lemming&facet[index_type]=Bonfire.Classify.Category")
    |> wait_async()
    |> refute_has("[data-role=search_group_hit]")
    |> assert_has("#the_search_results", text: @no_index_hint)
  end
end
