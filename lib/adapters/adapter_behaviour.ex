defmodule Bonfire.Search.Adapter do
  @moduledoc """
  Behaviour defining the interface for search adapters in Bonfire.
  Adapters must implement all these callbacks to provide search functionality.
  """

  @type search_opts :: map() | keyword()
  @type facets :: map() | list() | nil
  @type index :: atom() | binary()
  @type search_result :: map() | nil
  @type object :: map() | struct()

  @callback search(binary(), search_opts(), boolean(), facets()) :: search_result()
  @callback search(binary(), search_opts()) :: search_result()
  @callback search(binary(), index()) :: search_result()

  @callback search_by_type(binary(), facets()) :: list()

  @callback create_index(binary(), boolean()) :: {:ok, map()} | {:error, term()}
  @callback set_facets(binary(), list() | binary()) :: {:ok, map()} | {:error, term()}
  @callback set_searchable_fields(binary(), list()) :: {:ok, map()} | {:error, term()}

  @callback put(object(), binary()) :: {:ok, map()} | {:error, term()}
  @callback delete(binary(), binary()) :: {:ok, map()} | {:error, term()}

  @callback index_exists(binary()) :: boolean()

  @optional_callbacks [
    index_exists: 1,
    put: 2,
    delete: 2,
    set_facets: 2,
    set_searchable_fields: 2,
    create_index: 2
  ]
end
