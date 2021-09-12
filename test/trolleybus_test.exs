defmodule TrolleybusTest do
  use ExUnit.Case
  doctest Trolleybus

  test "greets the world" do
    assert Trolleybus.hello() == :world
  end
end
