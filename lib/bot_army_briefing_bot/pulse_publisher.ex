defmodule BotArmyBriefingBot.PulsePublisher do
  @moduledoc """
  Periodic health publisher for Briefing Bot.

  Two channels, aligned with `docs/SYNAPSE_CONTEXT_HYDRATION_CONTRACT.md`:

  1. **`system.health`** — lightweight liveness envelope every 30s so Synapse
     fleet views (90s staleness) stay **online** when the bot is running.
  2. **`bot.briefing_bot.pulse`** — richer metrics every 30 minutes (lower NATS volume).

  Health signal rules (`health_signal/0` → pulse + heartbeat status):

  - `:nominal` — healthy
  - `:degraded` — minor issues or zero activity
  - `:critical` — errors or operational issues

  Customize `record_metric/2` and `health_signal/0` for domain-specific logic.
  """

  use GenServer
  require Logger

  # Under Synapse `system.health` stale window (90s); 30s cadence leaves margin for jitter.
  @health_interval_ms 30 * 1000
  @publish_interval_ms 30 * 60 * 1000
  @service_name "briefing_bot"
  @envelope_source "bot_army_briefing_bot"

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Logger.info("[PulsePublisher] Starting Briefing Bot pulse publisher")
    started_at = DateTime.utc_now() |> DateTime.truncate(:second)
    send(self(), :publish_health)
    send(self(), :publish_pulse)
    {:ok, %{started_at: started_at, metrics: %{}, error_count: 0}}
  end

  @impl true
  def handle_info(:publish_health, state) do
    Task.start(fn -> publish_system_health(state) end)
    Process.send_after(self(), :publish_health, @health_interval_ms)
    {:noreply, state}
  end

  def record_metric(key, value) do
    GenServer.cast(__MODULE__, {:record_metric, key, value})
  end

  def record_error do
    GenServer.cast(__MODULE__, :record_error)
  end

  @impl true
  def handle_info(:publish_pulse, state) do
    Task.start(fn -> publish_pulse(state) end)
    Process.send_after(self(), :publish_pulse, @publish_interval_ms)
    {:noreply, %{state | metrics: %{}, error_count: 0}}
  end

  @impl true
  def handle_cast({:record_metric, key, value}, state) do
    metrics =
      Map.update(state.metrics, key, value, fn current ->
        if is_number(current) and is_number(value) do
          current + value
        else
          value
        end
      end)

    {:noreply, %{state | metrics: metrics}}
  end

  @impl true
  def handle_cast(:record_error, state) do
    {:noreply, %{state | error_count: state.error_count + 1}}
  end

  # ============================================================================
  # Private Implementation
  # ============================================================================

  defp publish_pulse(state) do
    signal = health_signal(state)

    pulse = %{
      service: @service_name,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      health: signal,
      metrics: state.metrics
    }

    case BotArmyRuntime.NATS.Publisher.publish("bot.#{@service_name}.pulse", pulse) do
      {:ok, _} ->
        Logger.debug("[PulsePublisher] Published pulse: #{signal}")

      {:error, reason} ->
        Logger.warning("[PulsePublisher] Failed to publish pulse: #{inspect(reason)}")
    end
  end

  defp publish_system_health(%{started_at: started_at} = state) do
    tenant_id = System.get_env("BOT_ARMY_TENANT_ID") || BotArmyRuntime.Tenant.default_tenant_id()
    signal = health_signal(state)

    uptime_seconds =
      DateTime.diff(DateTime.utc_now() |> DateTime.truncate(:second), started_at, :second)

    case BotArmyRuntime.SynapseHealth.publish(
           source: @envelope_source,
           service: @service_name,
           tenant_id: tenant_id,
           health_signal: signal,
           uptime_seconds: max(uptime_seconds, 0)
         ) do
      {:ok, _} ->
        Logger.debug("[PulsePublisher] Published system.health: #{signal}")

      {:error, reason} ->
        Logger.warning("[PulsePublisher] Failed to publish system.health: #{inspect(reason)}")
    end
  end

  defp health_signal(state) do
    error_threshold = 5

    cond do
      state.error_count > error_threshold -> :critical
      map_size(state.metrics) == 0 -> :degraded
      true -> :nominal
    end
  end
end
