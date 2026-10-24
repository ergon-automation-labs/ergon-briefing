import Config

# The salt-rendered config file has to be put somewhere before it can be read: the launchd
# wrapper deliberately skips sourcing an Elixir `%{}` file (it is not shell), and
# `ConfigLoader.get/2` reads `:config_data` from this app's env and then `System.get_env/1` —
# so without these two lines every pillar knob in this file is inert and the release quietly
# runs on its compiled defaults. Measured across the fleet 2026-10-24 (gtd 33c845f5): on
# wife_care the file named the 27B for the press and the running VM answered `nil`, so the
# press silently used the 4B. A bot that reads `ConfigLoader` without loading it reads
# nothing. Guarded off `:test` because a test run has no rendered file and no business
# reading the node's credentials.
if config_env() != :test do
  config_data = BotArmyLibraryRuntime.ConfigLoader.load_config()
  Application.put_env(:bot_army_library_runtime, :config_data, config_data)
end

# Runtime configuration — evaluated when the app starts, not at compile time
# This allows environment variables set by launchd/Salt to be read properly

if config_env() != :test do
  config :bot_army_briefing_bot,
    bot_army_tenant_id: BotArmyLibraryRuntime.ConfigLoader.get("BOT_ARMY_TENANT_ID", "")

  config :bot_army_briefing_bot, BotArmyBriefingBot.Repo,
    username: System.get_env("BOT_ARMY_BRIEFING_BOT_DB_USER"),
    password: System.get_env("BOT_ARMY_BRIEFING_BOT_DB_PASSWORD"),
    hostname: System.get_env("BOT_ARMY_BRIEFING_BOT_DB_HOST"),
    port: String.to_integer(System.get_env("BOT_ARMY_BRIEFING_BOT_DB_PORT") || "5432"),
    database: System.get_env("BOT_ARMY_BRIEFING_BOT_DB_NAME"),
    pool_size: 10
end
