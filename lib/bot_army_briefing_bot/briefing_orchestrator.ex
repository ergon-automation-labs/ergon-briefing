defmodule BotArmyBriefingBot.BriefingOrchestrator do
  @moduledoc """
  Orchestrates daily briefing generation and publication.

  Fetches data from multiple sources concurrently with a global timeout.
  If any source fails/times out, the briefing is still generated with
  available data. Logs all failures for debugging.
  """
  use GenServer
  require Logger

  # Global timeout for all data fetches combined. Short NATS timeouts
  # (100ms each) prevent blocking on unresponsive sources.
  @global_fetch_timeout_ms 3_000

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
    Logger.info("[BriefingOrchestrator] Generating briefing (concurrent fetch)")

    # Fetch all data sources concurrently with a global timeout.
    # If any source fails/times out, we continue with what we got.
    sources = [
      {:gtd_tasks, &fetch_gtd_tasks/0},
      {:fitness_plan, &fetch_fitness_plan/0},
      {:health_snapshot, &fetch_health_snapshot/0},
      {:weather, &fetch_weather/0}
    ]

    start_time = System.monotonic_time(:millisecond)

    results =
      sources
      |> Task.async_stream(
        fn {key, fetch_fn} ->
          case catch_timeout(fetch_fn, @global_fetch_timeout_ms) do
            {:ok, data} ->
              {key, data}

            {:timeout, _} ->
              Logger.warning(
                "[BriefingOrchestrator] Fetch #{key} timed out (#{@global_fetch_timeout_ms}ms)"
              )

              {key, nil}

            {:error, reason} ->
              Logger.warning("[BriefingOrchestrator] Fetch #{key} failed: #{inspect(reason)}")
              {key, nil}
          end
        end,
        timeout: @global_fetch_timeout_ms * 2
      )
      |> Enum.map(fn
        {:ok, result} ->
          result

        {:exit, reason} ->
          Logger.error("Task crashed: #{inspect(reason)}")
          nil
      end)
      |> Enum.filter(& &1)
      |> Map.new()

    elapsed = System.monotonic_time(:millisecond) - start_time
    Logger.info("[BriefingOrchestrator] Data fetch completed in #{elapsed}ms")

    briefing_data = %{
      date: Date.to_string(Date.utc_today()),
      gtd_tasks: Map.get(results, :gtd_tasks, []),
      fitness_plan: Map.get(results, :fitness_plan, %{}),
      health_snapshot: Map.get(results, :health_snapshot, %{}),
      weather: Map.get(results, :weather, %{})
    }

    briefing_md = BotArmyBriefingBot.BriefingBuilder.build(briefing_data)

    write_to_para(briefing_md)
    send_discord_notification()

    Logger.info("[BriefingOrchestrator] Briefing generated")
    :ok
  end

  # Wrapper to catch timeouts from blocking operations.
  defp catch_timeout(fetch_fn, timeout_ms) do
    task = Task.async(fetch_fn)

    try do
      case Task.yield(task, timeout_ms) do
        {:ok, result} -> {:ok, result}
        nil -> {:timeout, task}
      end
    rescue
      e ->
        Task.shutdown(task, :brutal_kill)
        {:error, e}
    end
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
    case BotArmyLibraryRuntime.NATS.Publisher.request("gtd.whats_next", %{}, timeout_ms: 100) do
      {:ok, %{"data" => %{"human" => %{"tasks" => tasks}}}} ->
        tasks

      {:ok, response} ->
        Logger.debug("[BriefingOrchestrator] Unexpected GTD response: #{inspect(response)}")
        []

      {:error, :timeout} ->
        Logger.warning(
          "[BriefingOrchestrator] GTD timeout (check if gtd.whats_next responder is running)"
        )

        []

      {:error, reason} ->
        Logger.warning("[BriefingOrchestrator] GTD failed: #{inspect(reason)}")
        []
    end
  end

  defp fetch_fitness_plan do
    case BotArmyLibraryRuntime.NATS.Publisher.request("fitness.workout.today", %{},
           timeout_ms: 100
         ) do
      {:ok, %{"data" => plan}} ->
        plan

      {:ok, response} ->
        Logger.debug("[BriefingOrchestrator] Unexpected fitness response: #{inspect(response)}")
        %{}

      {:error, :timeout} ->
        Logger.warning(
          "[BriefingOrchestrator] Fitness timeout (check if fitness.workout.today responder is running)"
        )

        %{}

      {:error, reason} ->
        Logger.warning("[BriefingOrchestrator] Fitness failed: #{inspect(reason)}")
        %{}
    end
  end

  defp fetch_health_snapshot do
    tenant_id = BotArmyLibraryCore.Tenant.default_tenant_id()
    user_id = "00000000-0000-0000-0000-000000000002"

    case BotArmyLibraryRuntime.NATS.Publisher.request(
           "dispatcher.system.health.digest.query",
           %{"tenant_id" => tenant_id, "user_id" => user_id},
           timeout_ms: 100
         ) do
      {:ok, response} ->
        Map.get(response, "data", response)

      {:error, :timeout} ->
        Logger.warning(
          "[BriefingOrchestrator] Health timeout (check if dispatcher.system.health.digest.query responder is running)"
        )

        %{}

      {:error, reason} ->
        Logger.warning("[BriefingOrchestrator] Health failed: #{inspect(reason)}")
        %{}
    end
  end

  defp fetch_weather do
    case BotArmyLibraryRuntime.NATS.Publisher.request("weather.current.get", %{}, timeout_ms: 100) do
      {:ok, %{"data" => weather}} ->
        weather

      {:ok, response} ->
        Logger.debug("[BriefingOrchestrator] Unexpected weather response: #{inspect(response)}")
        %{}

      {:error, :timeout} ->
        Logger.warning(
          "[BriefingOrchestrator] Weather timeout (check if weather.current.get responder is running)"
        )

        %{}

      {:error, reason} ->
        Logger.warning("[BriefingOrchestrator] Weather failed: #{inspect(reason)}")
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

    case BotArmyLibraryRuntime.NATS.Publisher.publish("para.fs.write", payload) do
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
        "content" => "☀️ Your briefing is ready! Check PARA or open the TUI.",
        "username" => "Daily Briefing"
      }
    }

    case BotArmyLibraryRuntime.NATS.Publisher.publish("bridge.discord.message.send", payload) do
      {:ok, _} ->
        Logger.info("[BriefingOrchestrator] Discord notification sent")

      {:error, reason} ->
        Logger.warning("[BriefingOrchestrator] Failed to send Discord: #{inspect(reason)}")
    end
  end
end
