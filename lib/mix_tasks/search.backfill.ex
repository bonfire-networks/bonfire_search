defmodule Mix.Tasks.Bonfire.Search.Backfill do
  use Mix.Task

  @shortdoc "Backfills the search index with existing data"

  @moduledoc """
  Indexes pre-existing data into the configured search adapter.

  Needed after enabling search or switching adapters (eg. from Meilisearch to Sonic),
  since indexes only receive objects created or updated *after* the adapter is active —
  without a backfill, search (including user autocompletes) silently misses older data.

  ## Usage

      just mix bonfire.search.backfill              # backfill users (default)
      just mix bonfire.search.backfill --type users
      just mix bonfire.search.backfill --type posts
      just mix bonfire.search.backfill --type all

  Users are indexed respecting each user's discoverability setting; posts are indexed
  into the public or closed index depending on their boundaries.
  """

  import Ecto.Query

  @batch_size 200

  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [type: :string])

    Mix.Task.run("app.start")

    if !Bonfire.Search.adapter() do
      raise "No search adapter is configured or enabled (set SEARCH_ADAPTER and make sure the service is running)"
    end

    case opts[:type] || "users" do
      "users" -> backfill_users()
      "posts" -> backfill_posts()
      "all" -> [backfill_users(), backfill_posts()]
      other -> raise "Unknown --type #{inspect(other)}, expected users, posts or all"
    end
  end

  def backfill_users do
    count =
      backfill(Bonfire.Data.Identity.User, [:profile, character: [:peered]], fn user ->
        Bonfire.Me.Users.maybe_index_user(user)
      end)

    Mix.shell().info("Search backfill: indexed #{count} users")
    count
  end

  def backfill_posts do
    count =
      backfill(Bonfire.Data.Social.Post, [:post_content, :created, :replied], fn post ->
        Bonfire.Search.maybe_index(post, nil, [])
      end)

    Mix.shell().info("Search backfill: indexed #{count} posts")
    count
  end

  defp backfill(schema, preloads, index_fn) do
    repo = Bonfire.Common.Config.repo()

    {:ok, count} =
      repo.transaction(
        fn ->
          from(o in schema, select: o.id)
          |> repo.stream()
          |> Stream.chunk_every(@batch_size)
          |> Stream.map(fn ids ->
            from(o in schema, where: o.id in ^ids)
            |> repo.all()
            |> repo.preload(preloads)
            |> Enum.map(index_fn)
            # count only indexed ones (index_fn can return {:error, _}/nil for skipped)
            |> Enum.count(&match?({:ok, _}, &1))
          end)
          |> Enum.sum()
        end,
        timeout: :infinity
      )

    count
  end
end
