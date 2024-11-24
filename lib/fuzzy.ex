defmodule Bonfire.Search.Fuzzy do
  alias Bonfire.Search
  import Untangle

  # TODO: put in config
  @default_limit 20
  @default_opts %{limit: @default_limit}
  @default_calc_facets ["index_type"]

  def search_filtered(q, facet_filters) do
    search(q, @default_opts, @default_calc_facets, facet_filters)
  end

  def search(
        q,
        opts \\ @default_opts,
        calculate_facets \\ @default_calc_facets,
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
