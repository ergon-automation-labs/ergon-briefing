defmodule BotArmyBriefingBot.Repo do
  use Ecto.Repo,
    otp_app: :bot_army_briefing_bot,
    adapter: Ecto.Adapters.Postgres
end
