defmodule TrolleybusAsyncTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  defmodule Event do
    use Trolleybus.Event

    handler(TrolleybusAsyncTest.Handler1)
    handler(TrolleybusAsyncTest.Handler2)

    message do
      field(:field1, :string)
      field(:binary_field, :binary, required: false)
      field(:explode?, :boolean, default: false)
      field(:timeout?, :boolean, default: false)
    end
  end

  defmodule Handler1 do
    use Trolleybus.Handler

    def handle_event(%TrolleybusAsyncTest.Event{explode?: true}) do
      raise "boom"
    end

    def handle_event(%TrolleybusAsyncTest.Event{timeout?: true}) do
      Process.sleep(200)
      :ok
    end

    def handle_event(%TrolleybusAsyncTest.Event{binary_field: pid_binary} = event) do
      pid = :erlang.binary_to_term(pid_binary)

      send(pid, {:published_handler1, event})

      :ok
    end

    def handle_event(%TrolleybusAsyncTest.Event{} = _event) do
      :ok
    end
  end

  defmodule Handler2 do
    use Trolleybus.Handler

    def handle_event(%TrolleybusAsyncTest.Event{binary_field: pid_binary} = event) do
      pid = :erlang.binary_to_term(pid_binary)

      send(pid, {:published_handler2, event})

      :ok
    end

    def handle_event(%TrolleybusAsyncTest.Event{} = _event) do
      :ok
    end
  end

  describe "publish/2 async" do
    test "publishes asynchronously" do
      pid_binary = :erlang.term_to_binary(self())

      assert :ok =
               Trolleybus.publish(%Event{field1: "foo", binary_field: pid_binary},
                 full_sync: false
               )

      assert_receive {:published_handler1, event}
      assert_receive {:published_handler2, ^event}
      assert %Event{field1: "foo", binary_field: ^pid_binary} = event
    end

    test "publishes synchronously" do
      pid_binary = :erlang.term_to_binary(self())

      assert :ok =
               Trolleybus.publish(%Event{field1: "foo", binary_field: pid_binary},
                 async: false,
                 full_sync: false
               )

      assert_receive {:published_handler1, event}
      assert_receive {:published_handler2, ^event}
      assert %Event{field1: "foo", binary_field: ^pid_binary} = event
    end

    test "handles crash gracefully when run async" do
      pid_binary = :erlang.term_to_binary(self())

      assert capture_log(fn ->
               assert :ok =
                        Trolleybus.publish(
                          %Event{
                            field1: "foo",
                            binary_field: pid_binary,
                            explode?: true
                          },
                          full_sync: false
                        )

               refute_receive {:published_handler1, _}
               assert_receive {:published_handler2, event}
               assert %Event{field1: "foo", binary_field: ^pid_binary} = event
             end) =~
               "[#{inspect(__MODULE__)}.Handler1] Event handler failed with ** (RuntimeError) boom"
    end

    test "handles crash gracefully when run sync" do
      pid_binary = :erlang.term_to_binary(self())

      assert capture_log(fn ->
               assert :ok =
                        Trolleybus.publish(
                          %Event{
                            field1: "foo",
                            binary_field: pid_binary,
                            explode?: true
                          },
                          async: false,
                          full_sync: false
                        )
             end) =~
               "[#{inspect(__MODULE__)}.Handler1] Event handler failed with ** (RuntimeError) boom"

      refute_receive {:published_handler1, _}
      assert_receive {:published_handler2, event}
      assert %Event{field1: "foo", binary_field: ^pid_binary} = event
    end

    test "handles sync timeout gracefully" do
      pid_binary = :erlang.term_to_binary(self())

      log =
        capture_log(fn ->
          assert :ok =
                   Trolleybus.publish(
                     %Event{field1: "foo", binary_field: pid_binary, timeout?: true},
                     async: false,
                     sync_timeout: 100,
                     full_sync: false
                   )
        end)

      assert log =~ "Dispatch failed while publishing"
      assert log =~ "Got: {:exit, :timeout}"

      refute_receive {:published_handler1, _}
      assert_receive {:published_handler2, event}
      assert %Event{field1: "foo", binary_field: ^pid_binary} = event
    end
  end
end
