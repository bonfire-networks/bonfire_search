defmodule Bonfire.Search.Fuzzy do
  alias Bonfire.Search
  import Untangle
  use Bonfire.Common.Localise
  use Bonfire.Common.Config

  @default_limit 20

  defp limit,
    do:
      Bonfire.Common.Config.get([__MODULE__, :limit], @default_limit,
        name: l("Fuzzy search"),
        description: l("Number of results to include")
      )

  defp facets,
    do:
      Bonfire.Common.Config.get([__MODULE__, :facets], ["index_type"],
        name: l("Fuzzy search"),
        description: l("Facets to include")
      )

  defp default_opts, do: %{limit: limit()}

  def search_filtered(q, facet_filters) do
    search(q, default_opts(), facets(), facet_filters)
  end

  def search(
        q,
        opts \\ default_opts(),
        calculate_facets \\ facets(),
        facet_filters \\ nil
      ) do
    try do
      do_search(q, opts, calculate_facets, facet_filters)

      # try fuzzy search
      sentences_and_words = Bonfire.Search.Stopwords.filter(q)

      # TODO: use some smarter order than order of appearance?
      for sentence <- sentences_and_words do
        # search each sentence
        do_search(
          Enum.join(sentence, " "),
          opts,
          calculate_facets,
          facet_filters
        )

        for word <- sentence do
          # search each word
          do_search(word, opts, calculate_facets, facet_filters)
        end
      end
    catch
      {:break, found} -> found
    end
  end

  def do_search(q, opts, calculate_facets, facet_filters) do
    debug("Search.Fuzzy: try #{q}")

    search = Search.search(q, opts, calculate_facets, facet_filters)

    if(
      is_map(search) and Map.has_key?(search, :hits) and
        length(search[:hits]) > 0
    ) do
      throw({:break, search})
    end
  end
end
