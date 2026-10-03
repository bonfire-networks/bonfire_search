defmodule Bonfire.Search.Repo.Migrations.GinIndexes do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true
  # ^ Needed to migrate indexes concurrently. 
  # Disabling DDL transactions removes the guarantee that all of the changes in the migration will happen at once. 
  # Disabling the migration lock removes the guarantee only a single node will run a given migration if multiple nodes are attempting to migrate at the same time.

  def up do
    execute "CREATE EXTENSION IF NOT EXISTS pg_trgm;"

    create_index("bonfire_data_social_named", "name")
    # YugabyteDB fails any join on a ybgin-indexed column (https://github.com/yugabyte/yugabyte-db/issues/33922), and username is joined on
    if System.get_env("DB_ADAPTER") != "yugabyte",
      do: create_index("bonfire_data_identity_character", "username")

    # create_index("bonfire_data_social_profile", "name")
    create_index_fields(
      "bonfire_data_social_profile",
      "name gin_trgm_ops, summary gin_trgm_ops"
    )

    create_index_fields(
      "bonfire_data_social_post_content",
      # "name gin_trgm_ops, summary gin_trgm_ops, html_body gin_trgm_ops"
      "name gin_trgm_ops, summary gin_trgm_ops"
    )
  end

  def down do
    # TODO
  end

  def create_index(table, field) do
    create_index_fields(table, "#{field} gin_trgm_ops")
  end

  def create_index_fields(table, fields) do
    case String.split(fields, ~r/,\s*/) do
      [_, _ | _] = field_list ->
        if System.get_env("DB_ADAPTER") == "yugabyte" do
          # YugabyteDB's ybgin doesn't support multicolumn indexes, so index each column separately
          for field <- field_list do
            [column | _] = String.split(field)
            create_gin_index("#{table}_#{column}_gin_index", table, field)
          end
        else
          create_gin_index("#{table}_gin_index", table, fields)
        end

      _ ->
        create_gin_index("#{table}_gin_index", table, fields)
    end
  end

  defp create_gin_index(name, table, fields) do
    execute """
      DROP INDEX IF EXISTS #{name};
    """

    concurrently = if(System.get_env("DB_MIGRATE_INDEXES_CONCURRENTLY") != "false", do: "CONCURRENTLY", else: "")

    execute """
      CREATE INDEX #{concurrently} #{name}
        ON #{table} 
        USING gin (#{fields});
    """
  end
end
