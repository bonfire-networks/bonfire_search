defmodule Bonfire.Search.Acts.Queue do
  @moduledoc """
  An act that enqueues publish/update/delete requests to meilisearch via an oban job queue.
  """
  import Bonfire.Epics
  use Arrows
  require Logger

  # alias Bonfire.Epics
  # alias Bonfire.Epics.Act
  alias Bonfire.Epics.Epic
  alias Bonfire.Common.Utils
  alias Ecto.Changeset

  # see module documentation
  @doc false
  def run(epic, act) do
    on = Keyword.get(act.options, :on, :post)
    object = epic.assigns[on]
    action = Keyword.get(epic.assigns[:options], :action)

    if epic.errors != [] do
      maybe_debug(
        epic,
        act,
        length(epic.errors),
        "Meili: Skipping due to epic errors"
      )

      epic
    else
      case action do
        :delete ->
          maybe_debug(epic, act, action, "Meili queuing")
          maybe_unindex(object)
          epic

        # :insert
        action ->
          maybe_debug(epic, act, action, "Meili queuing")

          # maybe_debug(epic, act, object, "Non-formated object")

          current_user = epic.assigns[:options][:current_user]
          prepared_object = prepare_object(object)

          if prepared_object do
            prepared_object
            |> maybe_indexable_object(current_user)

            Epic.assign(epic, on, prepared_object)
          else
            maybe_debug(
              epic,
              act,
              object,
              "Meili: Skipping due to invalid object"
            )

            epic
          end

          # action ->
          #   maybe_debug(epic, act, action, "Meili: Skipping due to unknown action")
          #   epic
      end
    end
  end

  def prepare_object(thing) do
    case thing do
      # %{activities: [%{object: %{id: _} = object} = activity]} -> prepare_object(activity, object)
      # %{activities: [%{id: _} = activity]} -> prepare_object(activity, thing)
      # %{activity: %{object: %{id: _} = object}} -> prepare_object(thing.activity, object)
      # %{activity: %{id: _}} -> prepare_object(thing.activity, thing)
      # %Activity{object: %{id: _} = object} -> prepare_object(thing, object)
      %Changeset{} ->
        case Changeset.apply_action(thing, :insert) do
          {:ok, thing} ->
            prepare_object(thing)

          {:error, error} ->
            Logger.error("MeiliSearch.Queue: Got error applying an action to changeset: #{error}")

            nil
        end

      %{id: _} ->
        # FIXME: should be done in a Social act
        Bonfire.Common.Utils.maybe_apply(
          Bonfire.Social.Activities,
          :activity_preloads,
          [
            thing,
            [:tags, :feed_by_creator, :with_replied],
            []
          ]
        )

      # Bonfire.Social.Activities.activity_preloads(
      #   thing,
      #   [:tags, :feed_by_creator, :with_replied],
      #   []
      # )

      _ ->
        Logger.error("MeiliSearch.Queue: no clause match for function to_indexable/2")

        IO.inspect(thing, label: "thing")
        nil
    end
  end

  def maybe_indexable_object(object, current_user) do
    if Bonfire.Common.Extend.module_enabled?(
         Bonfire.Search.Indexer,
         Utils.e(object, :created, :creator, nil) ||
           Utils.e(object, :creator, nil) || current_user
       ),
       do:
         object
         # FIXME: should be done in a Social act
         |> Bonfire.Social.Activities.activity_under_object()
         |> Bonfire.Search.Indexer.maybe_indexable_object()
         |> Bonfire.Search.Indexer.maybe_index_object()
  end

  def maybe_unindex(object) do
    if Bonfire.Common.Extend.module_enabled?(Bonfire.Search.Indexer) do
      Bonfire.Search.Indexer.maybe_delete_object(object)
    else
      :ok
    end
  end
end
