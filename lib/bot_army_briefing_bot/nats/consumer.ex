defmodule BotArmyBriefingBot.NATS.Consumer do
  @moduledoc """
  NATS message consumer for briefing_bot.

  Subscribes to NATS subjects and routes messages to handlers.
  Uses standardized Reply format for request/reply patterns.

  All request/reply handlers should return responses using Reply helpers:
  - BotArmyRuntime.NATS.Reply.ok(data) for success
  - BotArmyRuntime.NATS.Reply.error(message, code) for errors
  """

  use GenServer
  require Logger

  @reconnect_delay_ms 5000
  @version Mix.Project.config()[:version]

  # Register subjects with their metadata for runtime discovery
  @subjects [
    %{
      subject: "briefing.generate.now",
      type: :request_reply,
      description: "Generate briefing on demand"
    }
  ]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    Logger.info("Starting NATS consumer")

    state = %{
      subscriptions: [],
      conn: nil,
      opts: opts
    }

    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state) do
    case GenServer.call(BotArmyRuntime.NATS.Connection, :get_connection, 5000) do
      {:ok, conn} ->
        BotArmyRuntime.NATS.Connection.subscribe_to_status()
        Logger.info("Connected to NATS, subscribing to topics")

        subscriptions =
          subscribe_to_subjects([])
          |> Enum.filter(&(not is_nil(&1)))

        # Register subjects for runtime discovery
        BotArmyRuntime.Registry.register("briefing_bot", @subjects, @version)

        {:noreply, %{state | subscriptions: subscriptions, conn: conn}}

      {:error, _reason} ->
        Logger.warning("NATS connection not ready, will retry")
        Process.send_after(self(), :connect_retry, @reconnect_delay_ms)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:connect_retry, state) do
    {:noreply, state, {:continue, :connect}}
  end

  @impl true
  def handle_info({:msg, msg}, state) do
    BotArmyRuntime.Tracing.with_consumer_span(msg.topic, Map.get(msg, :headers), fn ->
      Logger.debug("Received NATS message on subject: #{msg.topic}")
      route_message_by_type(msg, state)
    end)

    {:noreply, state}
  end

  defp route_message_by_type(%{reply_to: reply_to} = msg, state) when not is_nil(reply_to) do
    case msg.topic do
      "briefing.generate.now" ->
        handle_generate_briefing(msg, state)

      _ ->
        Logger.debug("Unknown request/reply subject: #{msg.topic}")
    end
  end

  defp route_message_by_type(msg, _state) do
    case BotArmyCore.NATS.Decoder.decode(msg.body) do
      {:ok, decoded_message} ->
        route_message(decoded_message, msg.topic)

      {:error, reason} ->
        Logger.warning("Failed to decode message from #{msg.topic}: #{inspect(reason)}")
    end
  end

  @impl true
  def handle_info({:nats, :disconnected}, state) do
    Logger.warning("Disconnected from NATS, will reconnect")
    Process.send_after(self(), :connect_retry, @reconnect_delay_ms)
    {:noreply, %{state | subscriptions: [], conn: nil}}
  end

  @impl true
  def handle_info({:nats, :connected}, state) do
    Logger.info("Reconnected to NATS, re-subscribing")
    {:noreply, state, {:continue, :connect}}
  end

  @impl true
  def handle_info(:reconnect, state) do
    {:noreply, state, {:continue, :connect}}
  end

  # Message routing
  defp route_message(message, topic) do
    # Route decoded messages to appropriate handlers
    Logger.debug("Routing message from #{topic}")
  end

  # Request/reply handlers
  defp handle_generate_briefing(msg, state) do
    response =
      case BotArmyBriefingBot.BriefingOrchestrator.generate_now() do
        :ok ->
          BotArmyRuntime.NATS.Reply.ok(%{"status" => "briefing_generated"})

        {:error, reason} ->
          BotArmyRuntime.NATS.Reply.error(inspect(reason), :generation_failed)
      end

    if state.conn do
      Gnat.pub(state.conn, msg.reply_to, response)
    end
  end

  defp subscribe_to_subjects(subjects) do
    Enum.map(subjects, &subscribe_one/1)
  end

  defp subscribe_one(subject) do
    conn = elem(GenServer.call(BotArmyRuntime.NATS.Connection, :get_connection, 5000), 1)

    case Gnat.sub(conn, self(), subject) do
      {:ok, sub} ->
        Logger.info("Subscribed to #{subject}")
        sub

      {:error, reason} ->
        Logger.error("Failed to subscribe to #{subject}: #{inspect(reason)}")
        nil
    end
  end
end
