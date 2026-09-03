defmodule BotArmyBriefingBot.Release do
  @moduledoc """
  Release management for the Briefing Bot.
  """

  @app :bot_army_briefing_bot

  @doc """
  Runs database migrations using the shared BotArmyRuntime.Ecto.MigrationRunner.
  """
  def migrate do
    BotArmyLibraryRuntime.Ecto.MigrationRunner.run(
      repo_module: BotArmyBriefingBot.Repo,
      app_module: @app
    )
  end
end
