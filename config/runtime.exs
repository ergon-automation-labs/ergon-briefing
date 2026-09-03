import Config

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
