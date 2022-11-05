defmodule Trolleybus do
  @moduledoc """
  Defines a local, application-level PubSub API for dispatching side effects.

  This PubSub mechanism is dedicated to handling side-effects in business logic.
  Instead of calling side effects directly, an event is published. The event is
  then routed to one or more handlers, according to declared routing.

  ## Example

  Let's assume we have a code path in business logic where we want to trigger
  two side effects after core logic is done.

      def accept_invite(...) do
        ...
        App.Emails.notify_invite_accepted(document, inviter, user)
        App.Webhooks.notify_auth_update(document, user)
        ...
      end

  First, we define the event using `Trolleybus.Event`:

      defmodule App.Documents.Events.MembershipInviteAccepted do
        use Trolleybus.Event

        handler App.Documents.EmailEventHandler
        handler App.Webhooks.EventHandler

        message do
          field :membership, %App.Memberships.Membership{}
          field :document, %App.Documents.Document{}
          field :inviter, %App.Users.User{}, required: false
          field :user, %App.Users.User{}
        end
      end

  Next, we define new or extend existing event handlers using
  `Trolleybus.Handler`:

      defmodule App.Documents.EmailEventHandler do
        use Trolleybus.Handler

        alias App.Documents.Events.MembershipInviteAccepted

        def handle_event(%MembershipInviteAccepted{
          document: document,
          inviter: inviter,
          user: user
        }) do
          App.Emails.notify_invite_accepted(document, inviter, user)
        end
        ...
      end

      defmodule App.Webhooks.EventHandler do
        use Trolleybus.Handler

        alias App.Documents.Events.MembershipInviteAccepted

        def handle_event(%MembershipInviteAccepted{
          document: document,
          user: user
        }) do
          App.Webhooks.notify_auth_update(document, user)
        end
        ...
      end

  Finally, we publish an event instead of calling `Emails` and `Webhooks`
  directly:

      alias App.Documents.Events

      def accept_invite(...) do
        ...
        Trolleybus.publish(%Events.MembershipInviteAccepted{
          membership: membership,
          document: document,
          inviter: inviter,
          user: user
        })
        ...
      end

  ## Publishing

  A `publish/2` call triggers the dispatch logic for the event. The dispatch
  retrieves all handlers provided in event's definition and passes it to
  those handlers.

  Publishing may be executed in three modes:

    * fully synchronous `:full_sync` (default) - executes all handlers
      sequentially and synchronously, within the same process as caller,
    * asynchronous `:async` - executes side effects in separate processes
      not waiting for them to finish executing,
    * synchronous `:sync` - blocks until all processes executing event
      handlers complete.

  The wait time in case of synchronous publish is limited by timeout setup via
  `:sync_timeout` option, expressed in milliseconds (defaults to 5000). Any
  handler execution process running for longer than the setup timeout is killed.

  For simplicity, `Trolleybus` is neither concerned with persistence nor retrying
  failed handler calls. If a particular case calls for this kind of guarantees,
  it can be realised by, for instance, making relevant handler use job processing
  library like [Oban](https://hexdocs.pm/oban/Oban.html).

  ## Buffering

  There are cases where publishing events may have to be either deferred or
  abandoned completely. This problem can be solved by using one of buffering
  wrappers: `transaction/1`, `buffered/1` or `muffled/1`. The underlying
  mechanism is the same for all three. Before a block of code is executed, a
  buffer is opened. The buffer is an agent process storing a list of events
  along with their respective publish options, if any are passed. Each call to
  `publish/2` inside that block puts the event in that list instead of actually
  publishing it. Once the block of code finishes executing, further behavior
  depends on the wrapper. `buffered/1` and `muffled/1` discard the events (the
  former returns them too, along with the result). `transaction/1` fetches
  contents of the current buffer, closes it and re-publishes all the events from
  the list. If wrappers are nested, the re-publishing will result by putting the
  events in another buffer opened by the outer wrapper. Eventually, the events
  get either dispatched to respective handlers or discarded.

  Current buffer as well as buffer stack are tracked using process dictionary.
  This means that buffering will only work for code executed within a single
  process.

  ## Events inside transactions

  In case of more complex logic, there can be multiple events published along a
  single code path. This code path can in turn contain multiple subroutines
  changing system state, wrapped in one big transaction. It's often hard to
  defer all the side effects outside of that transaction without clunky
  workarounds. That's where `transaction/1` comes into play. It's especially
  useful when events are published inside a large, multi-stage `Ecto.Multi` based
  transaction.

  Assuming we have events published somewhere inside a big transaction, like
  this:

      def update_memberships(memberships) do
        Ecto.Multi.run(:updated_memberships,
          fn _, %{old_memberships: memberships} ->
            updated_memberships = Enum.map(memberships, fn membership ->
              Trolleybus.publish(%MembershipChanged{...})

              ...
            end)

            {:ok, updated_memberships}
          end)
      end

  we can defer actual publishing of all events until after the transaction is
  executed by wrapping the top level `Ecto` transaction with `Trolleybus`
  transaction:

      def process(multi) do
        case Trolleybus.transaction(fn -> Repo.transaction(multi) end) do
          {:ok, ...} ->
            ...
        end
      end

  ## Nesting transactions

  Buffered transactions wrapped with `transaction/1` can be arbitrarily nested
  and it's guaranteed that only the outermost one will publish the events:

      Trolleybus.transaction(fn -> # all events will be published
                                   # only after this outer block finishes
        ...
        Trolleybus.transaction(fn ->
          ...
        end)
        ...
      end)

  ## Reusing code publishing events

  We often want to reuse existing logic as a part of larger, more complex
  routines. The problem is that this existing logic may already publish events
  specific to that original context. It may often be undesirable, because we
  want to emit events specific to the wrapping routine and need existing logic
  only for its data manipulation part. Another use case where that may be an
  issue is reusing business logic for setting up system state in tests instead
  of synthetic factories. In order to make it possible, we can wrap the reused
  code with `muffled/1`:

      {:ok, %{membership: accepted_membership}} = Trolleybus.muffled(fn ->
        AcceptInvite.accept_membership_invite(user, membership)
      end)

  Wrapping it this way will send all the events to a buffer which will be
  promptly discarded after the code block completes.

  ## Testing events

  When we want to test what events does a given piece of logic publish
  instead of relying on checking side effects, we can use `buffered/1`:

      {{:ok, %{membership}}, events} = Trolleybus.buffered(fn ->
        AcceptInvite.accept_membership_invite(user, membership)
      end)

      assert [{%MembershipInviteAccepted{}, []}] = events

  Events published inside `buffered/1` are stored in a buffer, whose contents
  are returned along with the result of the code block in a tuple. The events
  are then promptly discarded, so no handler gets triggered.

  Another potentially handy function is `get_buffer/0`, which allows to "peek"
  into contents of the buffer at any point when buffer is open. It can be used
  inside any of `buffered/1`, `muffled/1` or `transaction/1` blocks:

      Trolleybus.muffled(fn ->
        ...

        assert [{%SomeEvent{}, []}] = get_buffer()

        ...
      end)

  One important thing to note is that publishing mode can be overridden in all
  calls using Application configuration:

      config :trolleybus, mode_override: :full_sync

  This allows users to force all events to be published using a given mode, for
  example `:full_sync` in `config/test.exs` to make testing side effects
  simpler. This lets us avoiding any issues related to running handlers
  in a separate process, like having to explicitly handle `Ecto` sandbox
  allowance.

  ## Listing routes

  In order to print all events and associated handlers in the project,
  a dedicated mix task can be run:

      mix trolleybus.routes

  The output has a following form:

      * App.Events.DocumentTransferred
          => App.Webhooks.EventHandler
          => App.Memberships.EmailEventHandler

      * App.Events.UserInvitedToDocument
          => App.Memberships.EmailEventHandler

      ...
  """

  alias Trolleybus.TaskSupervisor

  require Logger

  @type publish_mode() :: :full_sync | :async | :sync

  @type publish_option() :: {:mode, publish_mode()} | {:sync_timeout, non_neg_integer()}

  @name_field :bus_current_buffer
  @stack_field :bus_stack

  @doc """
  Publishes event.

  ## Example

      :ok = Trolleybus.publish(%SomeEvent{name: "value"})
      :ok = Trolleybus.publish(%OtherEvent{flag: true}, mode: :async)
      :ok = Trolleybus.publish(
        %AnotherEvent{number: 123}, mode: :sync, sync_timeout: 1_000
      )

  ## Options

    * `:mode` - Event dispatch mode. Can be one of `:full_sync`, `:async`
      or `:sync`. See "Dispatch modes" below for detailed explanation.
      Default: `:full_sync`.
    * `:sync_timeout` - Timeout in milliseconds after which synchronous
      dispatch is cancelled and handler processes still in progress are
      killed. Works only for `:sync` mode. Default: 5000

  ## Disptach modes

  Publishing may be executed in three modes:

    * `:full_sync` - Executes all handlers sequentially and synchronously,
      within the same process as caller.
    * `:async` - Executes handlers in separate processes fully asynchronously,
      not waiting for them to finish executing.
    * `:sync` - Executes handlers in separate processes in parallel and waits
      until they complete executing. Waiting time is determined by
      `:sync_timeout` option. Handler processes running past timeout are killed.
  """
  @spec publish(struct(), [publish_option()]) :: :ok
  def publish(event, opts \\ []) do
    %event_module{} = event

    event = event_module.cast!(event)

    case current() do
      {:buffer, pid} ->
        publish_to_buffer(pid, event, opts)

      __MODULE__ ->
        publish_directly(event, opts)
    end
  end

  @doc """
  Returns events published in the given function.

  The events are returned along with the result of the function, without
  dispatching them to defined handlers.

  Order of events in the list is always consistent with order of publishing
  inside the wrapped function.

  ## Example

      {"result", [{%SomeEvent{}, []},
                  {%OtherEvent{}, mode: :async},
                  {%AnotherEvent{}, mode: :sync, sync_timeout: 1_000}]} =
        Trolleybus.buffered(fn ->
          Trolleybus.publish(%SomeEvent{name: "value"})
          Trolleybus.publish(%OtherEvent{flag: true}, mode: :async)
          Trolleybus.publish(%AnotherEvent{number: 123}, mode: :sync, sync_timeout: 1_000)

          "result"
        end)
  """
  @spec buffered((() -> result)) :: {result, [{struct(), [publish_option()]}]}
        when result: term()
  def buffered(fun) when is_function(fun, 0) do
    buffer = open_buffer()

    try do
      result = fun.()
      {result, get_buffer()}
    after
      if current() == buffer do
        close_buffer()
      end
    end
  end

  @doc """
  Discards events published in the given function without dispatching them
  to defined handlers.

  ## Example

      "result" =
        Trolleybus.muffled(fn ->
          Trolleybus.publish(%SomeEvent{name: "value"})

          "result"
        end)
  """
  @spec muffled((() -> result)) :: result when result: term()
  def muffled(fun) when is_function(fun, 0) do
    buffer = open_buffer()

    try do
      fun.()
    after
      if current() == buffer do
        close_buffer()
      end
    end
  end

  @doc """
  Lists all published but not yet dispatched events so far.

  Order of events in the list is always consistent with order of publishing
  inside the wrapped function.

  ## Example

      Trolleybus.muffled(fn ->
        Trolleybus.publish(%SomeEvent{name: "value"})
        Trolleybus.publish(%OtherEvent{flag: true}, mode: :async)

        [{%SomeEvent{}, []},
         {%OtherEvent{}, mode: :async}] = Trolleybus.get_buffer()

        Trolleybus.publish(%AnotherEvent{number: 123}, mode: :sync, sync_timeout: 1_000)

        [{%SomeEvent{}, []},
         {%OtherEvent{}, mode: :async},
         {%AnotherEvent{}, mode: :sync, sync_timeout: 1_000}] = Trolleybus.get_buffer()
      end)
  """
  @spec get_buffer() :: [{struct(), publish_option()}]
  def get_buffer() do
    case current() do
      {:buffer, pid} ->
        Agent.get(pid, fn buffer -> Enum.reverse(buffer) end)

      __MODULE__ ->
        raise "No buffer to get."
    end
  end

  @doc """
  Dispatches published events after running the given function.

  Dispatching to event handlers is done only if the result is in
  `{:ok, ...}` tuple format. Otherwise, events are discarded.

  ## Example

      {:ok, "result"} =
        Trolleybus.transaction(fn ->
          Trolleybus.publish(%SomeEvent{name: "value"})

          {:ok, "result"}
        end)
  """
  @spec transaction((() -> result)) :: result when result: term()
  def transaction(fun) when is_function(fun, 0) do
    buffer = open_buffer()

    try do
      case fun.() do
        {:ok, _} = result ->
          commit_buffer()
          result

        other ->
          other
      end
    after
      if current() == buffer do
        close_buffer()
      end
    end
  end

  defp open_buffer() do
    {:ok, pid} = Agent.start_link(fn -> [] end)

    set_current({:buffer, pid})
  end

  defp commit_buffer() do
    case current() do
      {:buffer, _pid} ->
        buffer = get_buffer()
        close_buffer()

        for {event, opts} <- Enum.reverse(buffer) do
          publish(event, opts)
        end

      __MODULE__ ->
        raise "No buffer to commit."
    end
  end

  defp close_buffer() do
    case current() do
      {:buffer, pid} ->
        pop_current()
        Agent.stop(pid)

      __MODULE__ ->
        raise "No buffer to close."
    end
  end

  defp current() do
    Process.get(@name_field, __MODULE__)
  end

  defp set_current(name) do
    stack = Process.get(@stack_field, [])
    current_name = Process.get(@name_field)

    if current_name do
      Process.put(@stack_field, [current_name | stack])
    end

    Process.put(@name_field, name)

    name
  end

  defp pop_current() do
    stack = Process.get(@stack_field, [])

    case stack do
      [] ->
        Process.delete(@name_field)

      [head | stack] ->
        Process.put(@stack_field, stack)
        Process.put(@name_field, head)
    end
  end

  defp publish_to_buffer(pid, event, opts) do
    Agent.update(pid, fn buffer -> [{event, opts} | buffer] end)
  end

  defp publish_directly(event, opts) do
    %event_type{} = event

    # Users can specify a mode via `opts`
    default_mode = Keyword.get(opts, :mode, :full_sync)

    # The mode can also be overridden in all circumstances using application
    # config.
    # This is useful, for example, to make sure that events are always published
    # synchronously in tests to avoid race conditions.
    mode = Application.get_env(:trolleybus, :mode_override, default_mode)

    sync_timeout = Keyword.get(opts, :sync_timeout, 5_000)

    handlers = event_type.__handlers__()

    case mode do
      :full_sync ->
        Enum.each(handlers, &run_handler(&1, event))

      :sync ->
        run_handlers_synchronously(handlers, event, sync_timeout)

      :async ->
        run_handlers_asynchronously(handlers, event)
    end
  end

  defp run_handlers_asynchronously(handlers, event) do
    Enum.each(handlers, fn handler ->
      Task.Supervisor.start_child(TaskSupervisor, fn ->
        run_handler(handler, event)
      end)
    end)
  end

  defp run_handlers_synchronously(handlers, event, sync_timeout) do
    results =
      Task.Supervisor.async_stream_nolink(
        TaskSupervisor,
        handlers,
        &run_handler(&1, event),
        ordered: true,
        on_timeout: :kill_task,
        timeout: sync_timeout
      )

    Enum.each(results, fn result ->
      case result do
        {:ok, _result} ->
          :ok

        error_or_exit ->
          Logger.error(
            "[#{inspect(__MODULE__)}] Dispatch failed while publishing #{inspect(event)}. " <>
              "Got: #{inspect(error_or_exit)}",
            grouping_title: "Dispatch failed while publishing #{inspect(event.__struct__)}",
            extra_info: %{event: inspect(event), error: inspect(error_or_exit)}
          )
      end
    end)
  end

  defp run_handler(handler, event) do
    handler.handle_event(event)
  catch
    kind, reason ->
      formatted = Exception.format(kind, reason, __STACKTRACE__)

      Logger.error(
        "[#{inspect(handler)}] Event handler failed with #{formatted} for event " <>
          "#{inspect(event)}",
        grouping_title:
          "Event handler #{inspect(handler)} failed for event #{inspect(event.__struct__)}",
        extra_info: %{
          handler: inspect(handler),
          event: inspect(event),
          exception: inspect(formatted)
        }
      )
  end
end
