defmodule BotArmyBriefingBot.BriefingOrchestrator do
  @moduledoc """
  Orchestrates daily briefing generation and publication.
  """
  use GenServer
  require Logger

  @gtd_timeout_ms 5_000
  @health_timeout_ms 5_000
  @weather_timeout_ms 5_000
  @fitness_timeout_ms 5_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def generate_now do
    GenServer.call(__MODULE__, :generate_briefing, 30_000)
  end

  @impl true
  def init(_opts) do
    Logger.info("[BriefingOrchestrator] Started")
    schedule_next_briefing()
    {:ok, %{last_generated_at: nil}}
  end

  @impl true
  def handle_call(:generate_briefing, _from, state) do
    result = generate_briefing()
    {:reply, result, %{state | last_generated_at: DateTime.utc_now()}}
  end

  @impl true
  def handle_info(:generate_briefing, state) do
    generate_briefing()
    schedule_next_briefing()
    {:noreply, %{state | last_generated_at: DateTime.utc_now()}}
  end

  defp generate_briefing do
    Logger.info("[BriefingOrchestrator] Generating briefing")

    gtd_tasks = fetch_gtd_tasks()
    fitness_plan = fetch_fitness_plan()
    health_snapshot = fetch_health_snapshot()
    weather = fetch_weather()

    briefing_data = %{
      date: Date.to_string(Date.utc_today()),
      gtd_tasks: gtd_tasks,
      fitness_plan: fitness_plan,
      health_snapshot: health_snapshot,
      weather: weather
    }

    briefing_md = BotArmyBriefingBot.BriefingBuilder.build(briefing_data)

    write_to_para(briefing_md)
    send_discord_notification()

    Logger.info("[BriefingOrchestrator] Briefing generated")
    :ok
  end

  defp schedule_next_briefing do
    ms = ms_until_briefing()
    Process.send_after(self(), :generate_briefing, ms)
  end

  defp ms_until_briefing do
    now = DateTime.utc_now()
    today_630 = DateTime.new!(DateTime.to_date(now), ~T[06:30:00], "Etc/UTC")

    target =
      if DateTime.compare(now, today_630) == :lt,
        do: today_630,
        else: DateTime.add(today_630, 1, :day)

    DateTime.diff(target, now, :millisecond) |> max(1000)
  end

  defp fetch_gtd_tasks do
    case BotArmyRuntime.NATS.Publisher.request("gtd.whats_next", %{}, timeout_ms: @gtd_timeout_ms) do
      {:ok, %{"data" => %{"human" => %{"tasks" => tasks}}}} ->
        tasks

      _ ->
        []
    end
  end

  defp fetch_fitness_plan do
    case BotArmyRuntime.NATS.Publisher.request("fitness.workout.today", %{},
           timeout_ms: @fitness_timeout_ms
         ) do
      {:ok, %{"data" => plan}} ->
        plan

      _ ->
        %{}
    end
  end

  defp fetch_health_snapshot do
    tenant_id = BotArmyCore.Tenant.default_tenant_id()
    user_id = "00000000-0000-0000-0000-000000000002"

    case BotArmyRuntime.NATS.Publisher.request(
           "dispatcher.system.health.digest.query",
           %{"tenant_id" => tenant_id, "user_id" => user_id},
           timeout_ms: @health_timeout_ms
         ) do
      {:ok, response} ->
        Map.get(response, "data", response)

      _ ->
        %{}
    end
  end

  defp fetch_weather do
    case BotArmyRuntime.NATS.Publisher.request("weather.current.get", %{},
           timeout_ms: @weather_timeout_ms
         ) do
      {:ok, %{"data" => weather}} ->
        weather

      _ ->
        %{}
    end
  end

  defp write_to_para(briefing_md) do
    date_str = Date.to_string(Date.utc_today())

    payload = %{
      "schema_version" => "1.0",
      "relative_path" => "resources/briefings/#{date_str}.md",
      "content" => briefing_md,
      "mode" => "write"
    }

    case BotArmyRuntime.NATS.Publisher.publish("para.fs.write", payload) do
      {:ok, _} ->
        Logger.info("[BriefingOrchestrator] Briefing written to PARA")

      {:error, reason} ->
        Logger.warning("[BriefingOrchestrator] Failed to write to PARA: #{inspect(reason)}")
    end
  end

  defp send_discord_notification do
    payload = %{
      "event" => "bridge.discord.message.send",
      "source" => "bot_army_briefing_bot",
      "payload" => %{
        "bot_name" => "briefing",
        "channel" => "general",
        "content" => "☀️ Your briefing is ready! Check Obsidian on your phone or open the TUI.",
        "username" => "Daily Briefing"
      }
    }

    case BotArmyRuntime.NATS.Publisher.publish("bridge.discord.message.send", payload) do
      {:ok, _} ->
        Logger.info("[BriefingOrchestrator] Discord notification sent")

      {:error, reason} ->
        Logger.warning("[BriefingOrchestrator] Failed to send Discord: #{inspect(reason)}")
    end
  end
end
