defmodule Trolleybus.Handler do
  @moduledoc """
  Defines a handler for events published via `Trolleybus`

  An event handler is expected to implement `handle_event/1` callback.

  ## Example

      defmodule App.Handlers.StripeHandler do
        use Trolleybus.Handler

        def handle_event(%EmailInvitedToDocument{email: email} = event) do
          ...
        end

        def handle_event(%UserInvitedToDocument{user: user, document: document) do
          ...
        end
      end

  The shape of the function head for the callback is expected to meet certain
  criteria. Each implemented clause must have one of the following shapes:

      def handle_event(%EventModule{...}) do
        ...
      end

  or:

      def handle_event(%EventModule{...} = event) do
        ...
      end

  Matching on the contents of the event is in turn restricted to binding
  keys to variables only, which means that this clause is accepted:

      def handle_event(%EventModule{field: value}) do
        ...
      end

  while this clause will raise an error:

      def handle_event (%EventModule{field: %{} = value) do
        ...
      end

  Any other pattern in any of the clauses is going to result in raising an
  error. This restriction allows to implicitly infer a list of events
  supported by the handler, which is later used when validating handlers
  declared for the published event in `Trolleybus.Event`. This also
  enforces consistent pattern matching on exact events across
  all implemented handlers and guarantees exhaustive matching.
  """

  @callback handle_event(struct()) :: term()
  @callback __handled_events__() :: [module()]

  defmodule Error do
    defexception [:message]
  end

  defmacro __using__(_opts) do
    quote location: :keep do
      @behaviour Trolleybus.Handler

      Module.register_attribute(__MODULE__, :handler_args, accumulate: true)

      @on_definition Trolleybus.Handler
      @before_compile Trolleybus.Handler
    end
  end

  @spec __on_definition__(Macro.Env.t(), :def | :defp, atom(), list(), list(), term()) :: :ok
  def __on_definition__(env, :def, :handle_event, args, guards, _body) do
    Module.put_attribute(env.module, :handler_args, {args, guards})

    :ok
  end

  def __on_definition__(_env, _kind, _name, _args, _guards, _body) do
    :ok
  end

  defmacro __before_compile__(env) do
    handler_args = Module.get_attribute(env.module, :handler_args, [])

    handled_events =
      handler_args
      |> Enum.map(fn
        {[pattern], [_ | _] = _guards} ->
          raise_pattern_error!(pattern, "The clause can't use guards.")

        {[{:%, _, [{:__aliases__, _, alias}, {:%{}, _, _}]}], []} ->
          {:__aliases__, [], alias}

        {[{:=, _, [{:%, _, [{:__aliases__, _, alias}, {:%{}, _, contents}]}, _]} = pattern], []} ->
          enforce_map_match_pattern!(contents, pattern)
          {:__aliases__, [], alias}

        {[other], []} ->
          raise_pattern_error!(
            other,
            "Pattern must match on event struct and optionally bind it to a variable."
          )
      end)
      |> Enum.uniq()

    quote do
      @impl true
      def __handled_events__() do
        unquote(handled_events)
      end
    end
  end

  def enforce_map_match_pattern!(contents, pattern) when is_list(contents) do
    Enum.each(contents, fn
      {label, {binding, _, nil}} when is_atom(label) and is_atom(binding) ->
        :ok

      _ ->
        raise_pattern_error!(pattern, "Map contents can only bind keys to variables.")
    end)
  end

  def enforce_map_match_pattern!(_contents, pattern) do
    raise_pattern_error!(pattern, "Map contents can only bind keys to variables.")
  end

  def raise_pattern_error!(pattern, message) do
    pattern_string = Macro.to_string(pattern)

    raise Trolleybus.Handler.Error,
      message: """
      Invalid handle_event clause. Reason:

      #{message}

      The clause:

      #{inspect(pattern_string)}
      """
  end
end
