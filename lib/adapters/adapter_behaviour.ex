defmodule Bonfire.Search.Adapter do
  @moduledoc """
  Behaviour defining the interface for search adapters in Bonfire.

  `use Bonfire.Search.Adapter` to adopt the behaviour and get no-op defaults
  for index-management callbacks (only meaningful for external search engines
  like Meilisearch, not for DB-based adapters).
  """

  @type search_opts :: map() | keyword()
  @type facets :: map() | list() | nil
  @type index :: atom() | binary()
  @type search_result :: map() | nil
  @type object :: map() | struct()

  # Required — every adapter must search
  @callback search(binary(), search_opts(), boolean(), facets()) :: search_result()
  @callback search(binary(), search_opts()) :: search_result()
  @callback search(binary(), index()) :: search_result()
  @callback search_by_type(binary(), facets()) :: list()

  # Optional — index-management (no-ops for DB adapter)
  @callback healthy?() :: boolean()
  @callback index_exists(binary()) :: boolean()
  @callback create_index(binary(), boolean()) :: {:ok, map()} | {:error, term()}
  @callback list_facets(binary()) :: {:ok, list()} | {:error, term()}
  @callback set_facets(binary(), list() | binary()) :: {:ok, map()} | {:error, term()}
  @callback list_searchable_fields(binary()) :: {:ok, list()} | {:error, term()}
  @callback set_searchable_fields(binary(), list()) :: {:ok, map()} | {:error, term()}
  @callback wait_for_task(term()) :: {:ok, term()} | {:error, term()}
  @callback put_documents(object(), binary()) :: {:ok, map()} | {:error, term()}
  @callback delete(binary(), binary()) :: {:ok, map()} | {:error, term()}

  @optional_callbacks [
    healthy?: 0,
    index_exists: 1,
    create_index: 2,
    list_facets: 1,
    set_facets: 2,
    list_searchable_fields: 1,
    set_searchable_fields: 2,
    wait_for_task: 1,
    put_documents: 2,
    delete: 2
  ]

  defmacro __using__(_opts) do
    quote do
      @behaviour Bonfire.Search.Adapter

      def healthy?, do: true
      def index_exists(_index_name), do: false
      def create_index(_index_name, _fail_silently \\ false), do: {:ok, %{}}
      def list_facets(_index_name), do: {:ok, []}
      def set_facets(_index_name, _facets), do: {:ok, %{}}
      def list_searchable_fields(_index_name), do: {:ok, []}
      def set_searchable_fields(_index_name, _fields), do: {:ok, %{}}
      def wait_for_task(task), do: {:ok, task}
      def put_documents(_object, _index_name), do: {:ok, %{}}
      def delete(_object, _index_name), do: {:ok, %{}}

      defoverridable healthy?: 0,
                     index_exists: 1,
                     create_index: 2,
                     list_facets: 1,
                     set_facets: 2,
                     list_searchable_fields: 1,
                     set_searchable_fields: 2,
                     wait_for_task: 1,
                     put_documents: 2,
                     delete: 2
    end
  end
end
