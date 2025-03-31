defmodule Bonfire.Search.Acts.Queue do
  @moduledoc """
  An act that enqueues publish/update/delete requests to meilisearch via an oban job queue.
  """
  import Bonfire.Epics
  use Arrows
  require Logger
  use Bonfire.Common.E

  # alias Bonfire.Epics
  # alias Bonfire.Epics.Act
  alias Bonfire.Epics.Epic
  alias Bonfire.Common.Utils
  use Bonfire.Common.Repo
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
          Bonfire.Search.maybe_unindex(object)
          epic

        # :insert
        action ->
          maybe_debug(epic, act, action, "Meili queuing")

          # maybe_debug(epic, act, object, "Non-formated object")

          current_user = Bonfire.Common.Utils.current_user(epic.assigns[:options])

          # check it here to avoid preparing the object if disabled
          if Bonfire.Common.Extend.module_enabled?(
               Bonfire.Search.Indexer,
               e(object, :created, :creator, nil) ||
                 e(object, :creator, nil) || current_user
             ) do
            prepared_object = prepare_object(object)

            if prepared_object,
              do:
                Bonfire.Search.maybe_index(
                  prepared_object,
                  epic.assigns[:options][:boundary],
                  current_user: current_user
                )

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

        debug(thing, "thing")
        nil
    end
  end
end
