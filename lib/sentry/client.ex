defmodule ClientSupervisor do
  use Agent

  def start_link(initial_value) do
    Agent.start_link(fn -> initial_value end, name: __MODULE__)
  end

  def should_drop_event do
    Agent.get(__MODULE__, fn state -> NaiveDateTime.compare(NaiveDateTime.utc_now(), state) == :lt end)
  end

  def disabled_until do
    Agent.get(__MODULE__, fn state -> state end)
  end

  def update_disabled_until(deadline) do
    Agent.update(__MODULE__, fn _state -> deadline end)
  end
end

defmodule Sentry.Client do
  @behaviour Sentry.HTTPClient
  # Max message length per https://github.com/getsentry/sentry/blob/0fcec33ac94ad81a205f86f208072b0f57b39ff4/src/sentry/conf/server.py#L1021
  @max_message_length 8_192

  @moduledoc ~S"""
  This module is the default client for sending an event to Sentry via HTTP.

  It makes use of `Task.Supervisor` to allow sending tasks synchronously or asynchronously, and defaulting to asynchronous. See `Sentry.Client.send_event/2` for more information.

  ### Configuration

  * `:before_send_event` - allows performing operations on the event before
    it is sent.  Accepts an anonymous function or a {module, function} tuple, and
    the event will be passed as the only argument.

  * `:after_send_event` - callback that is called after attempting to send an event.
    Accepts an anonymous function or a {module, function} tuple. The result of the HTTP call as well as the event will be passed as arguments.
    The return value of the callback is not returned.

  Example configuration of putting Logger metadata in the extra context:

      config :sentry,
        before_send_event: fn(event) ->
          metadata = Map.new(Logger.metadata)
          %{event | extra: Map.merge(event.extra, metadata)}
        end,

        after_send_event: fn(event, result) ->
          case result do
            {:ok, id} ->
              Logger.info("Successfully sent event!")
            _ ->
              Logger.info(fn -> "Did not successfully send event! #{inspect(event)}" end)
          end
        end
  """

  alias Sentry.{Config, Event, Util}

  require Logger

  @type send_event_result ::
          {:ok, Task.t() | String.t() | pid()} | {:error, any()} | :unsampled | :excluded
  @type dsn :: {String.t(), String.t(), String.t()}
  @type result :: :sync | :none | :async
  @sentry_version 5
  @max_attempts 4
  # seconds
  @default_retry_after 60
  @hackney_pool_name :sentry_pool

  quote do
    unquote(@sentry_client "sentry-elixir/#{Mix.Project.config()[:version]}")
  end

  @doc """
  Attempts to send the event to the Sentry API up to 4 times with exponential backoff.

  The event is dropped if it all retries fail.
  Errors will be logged unless the source is the Sentry.LoggerBackend, which can deadlock by logging within a logger.

  ### Options
  * `:result` - Allows specifying how the result should be returned. Options include `:sync`, `:none`, and `:async`.  `:sync` will make the API call synchronously, and return `{:ok, event_id}` if successful.  `:none` sends the event from an unlinked child process under `Sentry.TaskSupervisor` and will return `{:ok, ""}` regardless of the result.  `:async` will start an unlinked task and return a tuple of `{:ok, Task.t}` on success where the Task can be awaited upon to receive the result asynchronously.  When used in an OTP behaviour like GenServer, the task will send a message that needs to be matched with `GenServer.handle_info/2`.  See `Task.Supervisor.async_nolink/2` for more information.  `:async` is the default.
  * `:sample_rate` - The sampling factor to apply to events.  A value of 0.0 will deny sending any events, and a value of 1.0 will send 100% of events.
  * Other options, such as `:stacktrace` or `:extra` will be passed to `Sentry.Event.create_event/1` downstream. See `Sentry.Event.create_event/1` for available options.
  """
  @spec send_event(Event.t()) :: send_event_result
  def send_event(%Event{} = event, opts \\ []) do
    result = Keyword.get(opts, :result, :async)
    sample_rate = Keyword.get(opts, :sample_rate) || Config.sample_rate()
    should_log = event.event_source != :logger

    event = maybe_call_before_send_event(event)

    case {event, sample_event?(sample_rate)} do
      {false, _} ->
        :excluded

      {%Event{}, false} ->
        :unsampled

      {%Event{}, true} ->
        encode_and_send(event, result, should_log)
    end
  end

  @spec encode_and_send(Event.t(), result(), boolean()) :: send_event_result()
  defp encode_and_send(event, result, should_log) do
    json_library = Config.json_library()

    render_event(event)
    |> json_library.encode()
    |> case do
      {:ok, body} ->
        result = do_send_event(event, body, result)

        if should_log do
          maybe_log_result(result)
        end

        result

      {:error, error} ->
        {:error, {:invalid_json, error}}
    end
  end

  @spec do_send_event(Event.t(), map(), :async) :: {:ok, Task.t()} | {:error, any()}
  defp do_send_event(event, body, :async) do
    case get_headers_and_endpoint() do
      {endpoint, auth_headers} when is_binary(endpoint) ->
        {:ok,
         Task.Supervisor.async_nolink(Sentry.TaskSupervisor, fn ->
           try_request(endpoint, auth_headers, {event, body})
           |> maybe_call_after_send_event(event)
         end)}

      {:error, :invalid_dsn} ->
        {:error, :invalid_dsn}
    end
  end

  @spec do_send_event(Event.t(), map(), :sync) :: {:ok, String.t()} | {:error, any()}
  defp do_send_event(event, body, :sync) do
    case get_headers_and_endpoint() do
      {endpoint, auth_headers} when is_binary(endpoint) ->
        try_request(endpoint, auth_headers, {event, body})
        |> maybe_call_after_send_event(event)

      {:error, :invalid_dsn} ->
        {:error, :invalid_dsn}
    end
  end

  @spec do_send_event(Event.t(), map(), :none) ::
          {:ok, DynamicSupervisor.on_start_child()} | {:error, any()}
  defp do_send_event(event, body, :none) do
    case get_headers_and_endpoint() do
      {endpoint, auth_headers} when is_binary(endpoint) ->
        Task.Supervisor.start_child(Sentry.TaskSupervisor, fn ->
          try_request(endpoint, auth_headers, {event, body})
          |> maybe_call_after_send_event(event)
        end)

        {:ok, ""}

      {:error, :invalid_dsn} ->
        {:error, :invalid_dsn}
    end
  end

  @spec try_request(
          String.t(),
          list({String.t(), String.t()}),
          {Event.t(), String.t()},
          {pos_integer(), any()}
        ) :: {:ok, String.t()} | {:error, {:request_failure, any()}}
  defp try_request(url, headers, event_body_tuple, current_attempt_and_error \\ {1, nil})

  defp try_request(_url, _headers, {_event, _body}, {current_attempt, last_error})
       when current_attempt > @max_attempts,
       do: {:error, {:request_failure, last_error}}

  defp try_request(url, headers, {event, body}, {current_attempt, _last_error}) do
    if ClientSupervisor.should_drop_event() do
      {:error,
       {:request_failure,
        "Skipping event send because we're disabled due to rate limits until #{
          ClientSupervisor.disabled_until()
        }"}}
    else
      case request(url, headers, body) do
        {:ok, id} ->
          {:ok, id}

        {:error, {:too_many_requests, e}} ->
          {:error, {:request_failure, e}}

        {:error, error} ->
          if current_attempt < @max_attempts, do: sleep(current_attempt)
          try_request(url, headers, {event, body}, {current_attempt + 1, error})
      end
    end
  end

  @doc """
  Makes the HTTP request to Sentry using hackney.

  Hackney options can be set via the `hackney_opts` configuration option.
  """
  @spec request(String.t(), list({String.t(), String.t()}), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def request(url, headers, body) do
    json_library = Config.json_library()

    hackney_opts =
      Config.hackney_opts()
      |> Keyword.put_new(:pool, @hackney_pool_name)

    case :hackney.request(:post, url, headers, body, hackney_opts) do
      {:ok, 200, _, client} ->
        case :hackney.body(client) do
          {:ok, body} ->
            case json_library.decode(body) do
              {:ok, json} ->
                {:ok, Map.get(json, "id")}

              {:err, error} ->
                {:error, error}
            end

          {:err, error} ->
            {:error, error}
        end

      {:ok, 429, headers, client} ->
        :hackney.skip_body(client)
        deadline = parse_retry_after(:proplists.get_value("Retry-After", headers, ""))
        ClientSupervisor.update_disabled_until(deadline)
        error = "Too many requests, backing off till: #{deadline}"
        {:error, {:too_many_requests, error}}

      {:ok, status, headers, client} ->
        :hackney.skip_body(client)
        error_header = :proplists.get_value("X-Sentry-Error", headers, "")
        error = "Received #{status} from Sentry server: #{error_header}"
        {:error, error}

      {e, _reason} ->
        {:error, e}
    end
  end

  @doc """
  Generates a Sentry API authorization header.
  """
  @spec authorization_header(String.t(), String.t()) :: String.t()
  def authorization_header(public_key, secret_key) do
    timestamp = Util.unix_timestamp()

    data = [
      sentry_version: @sentry_version,
      sentry_client: @sentry_client,
      sentry_timestamp: timestamp,
      sentry_key: public_key,
      sentry_secret: secret_key
    ]

    query =
      data
      |> Enum.filter(fn {_, value} -> value != nil end)
      |> Enum.map(fn {name, value} -> "#{name}=#{value}" end)
      |> Enum.join(", ")

    "Sentry " <> query
  end

  @doc """
  Get a Sentry DSN which is simply a URI.

  {PROTOCOL}://{PUBLIC_KEY}[:{SECRET_KEY}]@{HOST}/{PATH}{PROJECT_ID}
  """
  @spec get_dsn :: dsn | {:error, :invalid_dsn}
  def get_dsn do
    dsn = Config.dsn()

    with dsn when is_binary(dsn) <- dsn,
         %URI{userinfo: userinfo, host: host, port: port, path: path, scheme: protocol}
         when is_binary(path) and is_binary(userinfo) <- URI.parse(dsn),
         [public_key, secret_key] <- keys_from_userinfo(userinfo),
         [_, binary_project_id] <- String.split(path, "/"),
         {project_id, ""} <- Integer.parse(binary_project_id),
         endpoint <- "#{protocol}://#{host}:#{port}/api/#{project_id}/store/" do
      {endpoint, public_key, secret_key}
    else
      _ ->
        {:error, :invalid_dsn}
    end
  end

  @spec maybe_call_after_send_event(send_event_result, Event.t()) :: Event.t()
  def maybe_call_after_send_event(result, event) do
    case Config.after_send_event() do
      function when is_function(function, 2) ->
        function.(event, result)

      {module, function} ->
        apply(module, function, [event, result])

      nil ->
        nil

      _ ->
        raise ArgumentError,
          message: ":after_send_event must be an anonymous function or a {Module, Function} tuple"
    end

    result
  end

  @spec maybe_call_before_send_event(Event.t()) :: Event.t() | false
  def maybe_call_before_send_event(event) do
    case Config.before_send_event() do
      function when is_function(function, 1) ->
        function.(event) || false

      {module, function} ->
        apply(module, function, [event]) || false

      nil ->
        event

      _ ->
        raise ArgumentError,
          message:
            ":before_send_event must be an anonymous function or a {Module, Function} tuple"
    end
  end

  def hackney_pool_name do
    @hackney_pool_name
  end

  @doc """
  Transform the Event struct into JSON map.

  Most Event attributes map directly to JSON map, with stacktrace being the
  exception.  If the event does not have stacktrace frames, it should not
  be included in the JSON body.
  """
  @spec render_event(Event.t()) :: map()
  def render_event(%Event{} = event) do
    map = %{
      event_id: event.event_id,
      culprit: event.culprit,
      timestamp: event.timestamp,
      message: String.slice(event.message, 0, @max_message_length),
      tags: event.tags,
      level: event.level,
      platform: event.platform,
      server_name: event.server_name,
      environment: event.environment,
      exception: event.exception,
      release: event.release,
      request: event.request,
      extra: event.extra,
      user: event.user,
      breadcrumbs: event.breadcrumbs,
      fingerprint: event.fingerprint,
      modules: event.modules
    }

    case event.stacktrace do
      %{frames: [_ | _]} ->
        Map.put(map, :stacktrace, event.stacktrace)

      _ ->
        map
    end
  end

  def maybe_log_result(result) do
    message =
      case result do
        {:error, :invalid_dsn} ->
          "Cannot send Sentry event because of invalid DSN"

        {:error, {:invalid_json, error}} ->
          "Unable to encode JSON Sentry error - #{inspect(error)}"

        {:error, {:request_failure, last_error}} ->
          "Error in HTTP Request to Sentry - #{inspect(last_error)}"

        {:error, error} ->
          inspect(error)

        _ ->
          nil
      end

    if message != nil do
      Logger.log(
        Config.log_level(),
        fn ->
          ["Failed to send Sentry event. ", message]
        end
      )
    end
  end

  @spec authorization_headers(String.t(), String.t()) :: list({String.t(), String.t()})
  defp authorization_headers(public_key, secret_key) do
    [
      {"User-Agent", @sentry_client},
      {"X-Sentry-Auth", authorization_header(public_key, secret_key)}
    ]
  end

  defp keys_from_userinfo(userinfo) do
    case String.split(userinfo, ":", parts: 2) do
      [public, secret] -> [public, secret]
      [public] -> [public, nil]
      _ -> :error
    end
  end

  @spec get_headers_and_endpoint ::
          {String.t(), list({String.t(), String.t()})} | {:error, :invalid_dsn}
  defp get_headers_and_endpoint do
    case get_dsn() do
      {endpoint, public_key, secret_key} ->
        {endpoint, authorization_headers(public_key, secret_key)}

      {:error, :invalid_dsn} ->
        {:error, :invalid_dsn}
    end
  end

  defp parse_retry_after(header) do
    case Timex.parse(header, "{RFC1123}") do
      {:ok, retry_after} ->
        retry_after

      {:error, _} ->
        try do
          {retry_after, _} = Integer.parse(header, 10)
          NaiveDateTime.add(NaiveDateTime.utc_now(), retry_after)
        rescue
          _ -> @default_retry_after
        end
    end
  end

  @spec sleep(pos_integer()) :: :ok
  defp sleep(1), do: :timer.sleep(2000)
  defp sleep(2), do: :timer.sleep(4000)
  defp sleep(3), do: :timer.sleep(8000)
  defp sleep(_), do: :timer.sleep(8000)

  @spec sample_event?(number()) :: boolean()
  defp sample_event?(1), do: true
  defp sample_event?(1.0), do: true
  defp sample_event?(0), do: false
  defp sample_event?(0.0), do: false

  defp sample_event?(sample_rate) do
    :rand.uniform() < sample_rate
  end
end
