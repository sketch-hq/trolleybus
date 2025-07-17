defmodule TrolleybusTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  defmodule SomeStruct do
    defstruct [:field]
  end

  defmodule Event1 do
    use Trolleybus.Event

    handler(TrolleybusTest.Handler1)
    handler(TrolleybusTest.Handler2)

    message do
      field(:field1, :string)
      field(:field2, %TrolleybusTest.SomeStruct{}, required: false)
      field(:array_field, {:array, %TrolleybusTest.SomeStruct{}}, required: false)
      field(:binary_field, :binary, required: false)
      field(:explode?, :boolean, default: false)
      field(:timeout?, :boolean, default: false)
    end
  end

  defmodule Event2 do
    use Trolleybus.Event

    handler(TrolleybusTest.Handler1)

    message do
      field(:field1, :string)
      field(:binary_field, :binary, required: false)
    end
  end

  defmodule Handler1 do
    use Trolleybus.Handler

    def handle_event(%TrolleybusTest.Event1{explode?: true}) do
      raise "boom"
    end

    def handle_event(%TrolleybusTest.Event1{timeout?: true}) do
      Process.sleep(200)
      :ok
    end

    def handle_event(%TrolleybusTest.Event1{binary_field: pid_binary} = event) do
      pid = :erlang.binary_to_term(pid_binary)

      send(pid, {:published_handler1, :erlang.monotonic_time(), event})

      :ok
    end

    def handle_event(%TrolleybusTest.Event1{} = _event) do
      :ok
    end

    def handle_event(%TrolleybusTest.Event2{binary_field: pid_binary} = event) do
      pid = :erlang.binary_to_term(pid_binary)

      send(pid, {:published_handler1, :erlang.monotonic_time(), event})

      :ok
    end

    def handle_event(%TrolleybusTest.Event2{}) do
      :ok
    end
  end

  defmodule Handler2 do
    use Trolleybus.Handler

    def handle_event(%TrolleybusTest.Event1{binary_field: pid_binary} = event) do
      pid = :erlang.binary_to_term(pid_binary)

      send(pid, {:published_handler2, :erlang.monotonic_time(), event})

      :ok
    end

    def handle_event(%TrolleybusTest.Event1{} = _event) do
      :ok
    end
  end

  describe "publish/1" do
    test "publishes an event" do
      pid_binary = :erlang.term_to_binary(self())
      assert :ok = Trolleybus.publish(%Event1{field1: "foo", binary_field: pid_binary})

      assert_received {:published_handler1, _, event}
      assert_received {:published_handler2, _, ^event}
      assert %Event1{field1: "foo", binary_field: ^pid_binary} = event
    end

    test "succeeds for the other handler even if one of them fails" do
      pid_binary = :erlang.term_to_binary(self())

      assert capture_log(fn ->
               assert :ok =
                        Trolleybus.publish(%Event1{
                          field1: "foo",
                          binary_field: pid_binary,
                          array_field: [%SomeStruct{}],
                          explode?: true
                        })
             end) =~
               "[#{inspect(__MODULE__)}.Handler1] Event handler failed with ** (RuntimeError) boom"

      refute_received {:published_handler1, _, _}
      assert_received {:published_handler2, _, event}

      assert %Event1{
               field1: "foo",
               binary_field: ^pid_binary,
               array_field: [%SomeStruct{}],
               explode?: true
             } = event
    end

    test "fails for event failing validation" do
      assert_raise Trolleybus.Event.Error, ~r/Event1 is invalid/, fn ->
        Trolleybus.publish(%Event1{explode?: 123})
      end

      assert_raise Trolleybus.Event.Error, ~r/Event1 is invalid/, fn ->
        Trolleybus.publish(%Event1{array_field: [%SomeStruct{}, :bad]})
      end
    end
  end

  describe "transaction/1" do
    test "publishes events" do
      pid_binary = :erlang.term_to_binary(self())

      assert {:ok, :ok} =
               Trolleybus.transaction(fn ->
                 Trolleybus.publish(%Event1{field1: "foo", binary_field: pid_binary})
                 Trolleybus.publish(%Event2{field1: "bar", binary_field: pid_binary})

                 {:ok, :ok}
               end)

      assert_received {:published_handler1, t0, %Event1{} = event1}
      assert_received {:published_handler2, _, ^event1}
      assert_received {:published_handler1, t1, %Event2{} = event2}

      assert t0 <= t1
      assert %Event1{field1: "foo", binary_field: ^pid_binary} = event1
      assert %Event2{field1: "bar", binary_field: ^pid_binary} = event2
    end

    test "does not publish when transaction returns something else than {:ok, ...} tuple" do
      pid_binary = :erlang.term_to_binary(self())

      assert {:error, :error} =
               Trolleybus.transaction(fn ->
                 Trolleybus.publish(%Event1{field1: "foo", binary_field: pid_binary})
                 Trolleybus.publish(%Event2{field1: "bar", binary_field: pid_binary})

                 {:error, :error}
               end)

      refute_received {:published_handler1, _}
      refute_received {:published_handler2, _}
    end

    test "supports nesting" do
      pid_binary = :erlang.term_to_binary(self())

      assert {:ok, :ok} =
               Trolleybus.transaction(fn ->
                 Trolleybus.publish(%Event1{field1: "foo", binary_field: pid_binary})

                 assert [{%Event1{}, _}] = Trolleybus.get_buffer()

                 assert {:ok, :ok} =
                          Trolleybus.transaction(fn ->
                            Trolleybus.publish(%Event2{field1: "bar", binary_field: pid_binary})

                            assert [{%Event2{}, _}] = Trolleybus.get_buffer()

                            {:ok, :ok}
                          end)

                 assert [{%Event1{}, _}, {%Event2{}, _}] = Trolleybus.get_buffer()

                 {:ok, :ok}
               end)

      assert_received {:published_handler1, t0, %Event1{} = event1}
      assert_received {:published_handler2, _, ^event1}
      assert_received {:published_handler1, t1, %Event2{}}
      assert t0 <= t1
    end

    test "publishes outer buffer if inner one fails" do
      # This behavior assumes it's up to the user to check the outcome of the inner
      # transaction and decide to bail out early if it fails. This way it also
      # aligns well with wrapping inside Ecto transactions - the most outer one
      # will always return an error if any of the inner ones fail.

      pid_binary = :erlang.term_to_binary(self())

      assert {:ok, :ok} =
               Trolleybus.transaction(fn ->
                 Trolleybus.publish(%Event1{field1: "foo", binary_field: pid_binary})

                 assert [{%Event1{}, _}] = Trolleybus.get_buffer()

                 assert {:error, :error} =
                          Trolleybus.transaction(fn ->
                            Trolleybus.publish(%Event2{field1: "bar", binary_field: pid_binary})

                            assert [{%Event2{}, _}] = Trolleybus.get_buffer()

                            {:error, :error}
                          end)

                 assert [{%Event1{}, _}] = Trolleybus.get_buffer()

                 {:ok, :ok}
               end)

      assert_received {:published_handler1, _, %Event1{} = event1}
      assert_received {:published_handler2, _, ^event1}
      refute_received {:published_handler1, _, %Event2{}}
    end
  end

  describe "buffered/1" do
    test "returns events but does not publish" do
      pid_binary = :erlang.term_to_binary(self())

      assert {:ok, [{%Event1{}, _}, {%Event2{}, _}]} =
               Trolleybus.buffered(fn ->
                 Trolleybus.publish(%Event1{field1: "foo", binary_field: pid_binary})
                 Trolleybus.publish(%Event2{field1: "bar", binary_field: pid_binary})

                 :ok
               end)

      refute_received {:published_handler1, _}
      refute_received {:published_handler2, _}
    end

    test "supports nesting with transaction" do
      pid_binary = :erlang.term_to_binary(self())

      assert {:ok, [{%Event1{}, _}, {%Event2{}, _}]} =
               Trolleybus.buffered(fn ->
                 Trolleybus.publish(%Event1{field1: "foo", binary_field: pid_binary})

                 {:ok, :ok} =
                   Trolleybus.transaction(fn ->
                     Trolleybus.publish(%Event2{field1: "bar", binary_field: pid_binary})

                     {:ok, :ok}
                   end)

                 :ok
               end)

      refute_received {:published_handler1, _}
      refute_received {:published_handler2, _}
    end
  end

  describe "muffled/1" do
    test "returns only the result and does not publish" do
      pid_binary = :erlang.term_to_binary(self())

      assert :ok =
               Trolleybus.muffled(fn ->
                 Trolleybus.publish(%Event1{field1: "foo", binary_field: pid_binary})
                 Trolleybus.publish(%Event2{field1: "bar", binary_field: pid_binary})

                 assert [{%Event1{}, _}, {%Event2{}, _}] = Trolleybus.get_buffer()

                 :ok
               end)

      refute_received {:published_handler1, _}
      refute_received {:published_handler2, _}
    end

    test "supports nesting with transaction" do
      pid_binary = :erlang.term_to_binary(self())

      assert :ok =
               Trolleybus.muffled(fn ->
                 Trolleybus.publish(%Event1{field1: "foo", binary_field: pid_binary})

                 {:ok, :ok} =
                   Trolleybus.transaction(fn ->
                     Trolleybus.publish(%Event2{field1: "bar", binary_field: pid_binary})

                     {:ok, :ok}
                   end)

                 assert [{%Event1{}, _}, {%Event2{}, _}] = Trolleybus.get_buffer()

                 :ok
               end)

      refute_received {:published_handler1, _}
      refute_received {:published_handler2, _}
    end
  end

  describe "get_buffer/0" do
    test "returns buffer contents containing events along with options" do
      Trolleybus.muffled(fn ->
        Trolleybus.publish(%Event1{field1: "foo"})
        Trolleybus.publish(%Event2{field1: "bar"}, mode: :sync, sync_timeout: 2_000)

        assert [{%Event1{}, []}, {%Event2{}, [mode: :sync, sync_timeout: 2_000]}] =
                 Trolleybus.get_buffer()
      end)
    end
  end
end
