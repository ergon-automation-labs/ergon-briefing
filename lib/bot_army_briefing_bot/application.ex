defmodule BotArmyBriefingBot.Application do
  @moduledoc """
  Briefing Bot application supervisor.

  Follows bot army pattern with environment-aware startup:
  - Repo not started in :test (tests inject mocks)
  - PulsePublisher sends `system.health` liveness every 30s and rich `bot.<service>.pulse` every 30 minutes
  - Workers not started in :test (gated by @env)

  Observability: see `PulsePublisher` — fleet UIs keyed on Synapse hydration should use `system.health` freshness (90s), not pulse interval alone.
  """

  use Application

  @env Mix.env()

  @impl true
  def start(_type, _args) do
    # Note: BotArmyLibraryRuntime.Telemetry and BotArmyLibraryRuntime.NATS.Connection are started
    # by bot_army_runtime automatically — do not add them here.

    children =
      []
      |> maybe_add_repo()
      |> maybe_add_pulse_publisher()
      |> maybe_add_workers()

    opts = [strategy: :one_for_one, name: BotArmyBriefingBot.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp maybe_add_repo(children) do
    if is_test?(), do: children, else: [{BotArmyBriefingBot.Repo, []} | children]
  end

  defp maybe_add_pulse_publisher(children) do
    if is_test?(), do: children, else: [{BotArmyBriefingBot.PulsePublisher, []} | children]
  end

  defp maybe_add_workers(children) do
    if is_test?(),
      do: children,
      else: [
        {BotArmyBriefingBot.BriefingOrchestrator, []},
        {BotArmyBriefingBot.NATS.Consumer, []}
        | children
      ]
  end

  defp is_test?() do
    # Using Application.get_env to satisfy Dialyzer exact_eq check
    # while maintaining the environment gate pattern.
    Application.get_env(:bot_army_briefing_bot, :env) == :test
  end
end
