defmodule Trolleybus.Event do
  @moduledoc """
  Defines an event struct for publishing via `Trolleybus`.

  An event definition is composed of a couple of elements:

    * `handler/1` declarations - they define which handlers are called when
      event is published.

    * `message/1` declaration - determines the underlying struct and types
      of fields using `field/3` validated before publishing.

  ## Example

      defmodule App.Events.EmailInvitedToDocument do
        use Trolleybus.Event

        handler(App.Handlers.EmailHandler)
        handler(App.Handlers.StripeHandler)

        message do
          field(:invitee_email, App.Types.Email)
          field(:document, %Document{})
          field(:inviter, %User{})
          field(:message, :string, required: false)
          field(:vat_invoice?, :boolean, default: false)
        end
      end

  Event can declare any number of handlers, including zero. Message shape
  is declared by a series of `field/3` macro calls. Each `field/3` declaration
  maps to a field in the underlying, generated struct.

  Events can be instantiated like any other struct:

      iex> event = %App.Events.EmailInvitedToDocument{
             invitee_email: "alice@example.com",
             document: document,
             inviter: user
           }

  Each event implements `cast!/1` function which is called before publishing
  it. This function returns the same event struct with casted and validated
  message parameters as well as declared handlers.
  """

  defmodule Error do
    @moduledoc """
    Error raised on either invalid event module configuration or event struct
    failing validation.
    """

    defexception [:message, :errors]
  end

  defmacro __using__(_) do
    quote location: :keep do
      Module.register_attribute(__MODULE__, :handlers, accumulate: true)

      @before_compile Trolleybus.Event

      import Trolleybus.Event, only: [handler: 1, message: 1, field: 2, field: 3]

      @spec cast!(map()) :: map()
      def cast!(event) do
        Trolleybus.Event.validate_handlers!(__MODULE__, __handlers__())
        Trolleybus.Event.cast_event!(event)
      end
    end
  end

  @doc """
  Indicates a handler the event is dispatched to.

  The macro accepts a module name. That name is later validated when
  casting the event internally via `cast!/1`. If the handler does not
  implement the`Trolleybus.Handler` behaviour or does not explicitly
  handle that particular event, an error is raised.
  """
  defmacro handler(handler_module) do
    quote do
      Module.put_attribute(__MODULE__, :handlers, unquote(handler_module))
    end
  end

  @doc """
  Defines an event struct.

  Each struct field is defined using `field/3` macro.
  """
  defmacro message(body) do
    quote do
      Module.register_attribute(__MODULE__, :struct_fields, accumulate: true)
      Module.register_attribute(__MODULE__, :scalar_fields, accumulate: true)
      Module.register_attribute(__MODULE__, :required_fields, accumulate: true)
      Module.register_attribute(__MODULE__, :message_definition, accumulate: true)
      Module.register_attribute(__MODULE__, :struct_definition, accumulate: true)

      unquote(body)
    end
  end

  @doc """
  Defines a field on the event with a given name and type.

  All field definitions must be put inside `message/1` block.

  The macro accepts three arguments:

    * `name` - name of the field in the underlying struct.
    * `type` - declares the expected type of the field value. It's validated
      iternally via `cast!/1`.
    * `opts` - additional options for the field. Currently, `required` and
      `default` are accepted.

  ## Options

    * `:required` - boolean determining whether field value can be left empty
      (`nil`). If field's `required` option is set to `true` and event is
      instantiated and casted with that field left empty, an error is raised.
      Defaults to: `true`.

    * `:default` - sets field value to the provided default when field is left
      empty during instantiating the event. Defaults to: `nil`.

  ## Field types

  The underlying validation logic uses `Ecto.Changeset`, so basically any type
  accepted by `Ecto.Schema` is also accepted in message field definition.

  There's a special case for passing structs - `%StructModule{}`. This is
  because we don't want to validate exact contents of the struct, only that
  the value passed is a struct and is of matching type.
  """
  defmacro field(name, type, opts \\ []) do
    quote bind_quoted: [name: name, type: type, opts: opts] do
      type =
        case type do
          %module{} ->
            Module.put_attribute(__MODULE__, :struct_fields, {name, module})

            :map

          {:array, %module{}} ->
            Module.put_attribute(__MODULE__, :struct_fields, {name, {:array, module}})

            {:array, :map}

          other ->
            Module.put_attribute(__MODULE__, :scalar_fields, name)

            other
        end

      if Keyword.get(opts, :required, true) do
        Module.put_attribute(__MODULE__, :required_fields, name)
      end

      default_value = opts[:default]

      Module.put_attribute(__MODULE__, :message_definition, {name, type})
      Module.put_attribute(__MODULE__, :struct_definition, {name, default_value})
    end
  end

  defmacro __before_compile__(_env) do
    handlers = Module.get_attribute(__CALLER__.module, :handlers, [])
    scalar_fields = Module.get_attribute(__CALLER__.module, :scalar_fields, [])
    struct_fields = Module.get_attribute(__CALLER__.module, :struct_fields, [])
    required_fields = Module.get_attribute(__CALLER__.module, :required_fields, [])
    struct_definition = Module.get_attribute(__CALLER__.module, :struct_definition, [])
    message_definition = Module.get_attribute(__CALLER__.module, :message_definition, [])

    quote do
      defstruct unquote(struct_definition)

      @spec __handlers__() :: [module()]
      def __handlers__() do
        unquote(handlers)
      end

      @spec __scalar_fields__() :: [atom()]
      def __scalar_fields__() do
        unquote(scalar_fields)
      end

      @spec __struct_fields__() :: [{atom(), module() | {:array, module()}}]
      def __struct_fields__() do
        unquote(struct_fields)
      end

      @spec __required_fields__() :: [atom()]
      def __required_fields__() do
        unquote(required_fields)
      end

      @spec __message_definition__() :: %{atom() => atom() | module()}
      def __message_definition__() do
        Map.new(unquote(message_definition))
      end
    end
  end

  @doc false
  @spec validate_handlers!(module(), [module()]) :: :ok | no_return()
  def validate_handlers!(module, handlers) do
    {handlers, wrong_handlers} =
      Enum.split_with(handlers, &function_exported?(&1, :__handled_events__, 0))

    no_clause_handlers = Enum.reject(handlers, &(module in &1.__handled_events__()))

    if wrong_handlers != [] or no_clause_handlers != [] do
      error =
        "#{inspect(module)} has invalid handlers configured.\n"
        |> append_handler_errors(wrong_handlers, "Following modules are not valid handlers")
        |> append_handler_errors(
          no_clause_handlers,
          "Following handlers are missing clause for the event"
        )

      raise Trolleybus.Event.Error, message: error
    end

    :ok
  end

  @doc false
  @spec cast_event!(event) :: event | no_return() when event: struct()
  def cast_event!(event) do
    %event_module{} = event

    changeset =
      {struct(event_module, %{}), event_module.__message_definition__()}
      |> Ecto.Changeset.cast(Map.from_struct(event), event_module.__scalar_fields__())
      |> cast_struct_fields(event_module.__struct_fields__())
      |> Ecto.Changeset.validate_required(event_module.__required_fields__())

    if changeset.valid? do
      Ecto.Changeset.apply_changes(changeset)
    else
      errors = build_cast_errors_list(changeset)

      raise Trolleybus.Event.Error,
        message: """
        #{inspect(event_module)} is invalid:

        #{errors}

        Event:

        #{inspect(event)}
        """
    end
  end

  defp append_handler_errors(existing_error, [], _message) do
    existing_error
  end

  defp append_handler_errors(existing_error, bad_handlers, message) do
    bad_handlers_list = Enum.map_join(bad_handlers, "\n", &"- #{inspect(&1)}")

    "#{existing_error}\n#{message}:\n#{bad_handlers_list}"
  end

  defp build_cast_errors_list(changeset) do
    errors =
      Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
        Enum.reduce(opts, message, fn {key, value}, acc ->
          String.replace(acc, "%{#{key}}", to_string(value))
        end)
      end)

    Enum.map_join(errors, "\n", fn {key, errors} -> "- #{key}: #{Enum.join(errors, ", ")}" end)
  end

  defp cast_struct_fields(changeset, struct_fields) do
    Enum.reduce(struct_fields, changeset, fn {name, type}, changeset ->
      check_struct_type(changeset, name, type)
    end)
  end

  defp check_struct_type(changeset, name, {:array, type}) do
    case Map.get(changeset.params, Atom.to_string(name)) do
      nil ->
        changeset

      list when is_list(list) ->
        if Enum.all?(list, &(is_map(&1) and Map.get(&1, :__struct__) == type)) do
          Ecto.Changeset.put_change(changeset, name, list)
        else
          add_invalid_struct_error(changeset, name, {:array, type}, list)
        end

      other ->
        add_invalid_struct_error(changeset, name, type, other)
    end
  end

  defp check_struct_type(changeset, name, type) do
    case Map.get(changeset.params, Atom.to_string(name)) do
      nil ->
        changeset

      %^type{} = struct ->
        Ecto.Changeset.put_change(changeset, name, struct)

      other ->
        add_invalid_struct_error(changeset, name, type, other)
    end
  end

  defp add_invalid_struct_error(changeset, name, expected, got) do
    Ecto.Changeset.add_error(changeset, name, "has invalid type",
      expected_struct: inspect(expected),
      got: inspect(got)
    )
  end
end
