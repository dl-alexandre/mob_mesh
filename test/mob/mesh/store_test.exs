defmodule Mob.Mesh.StoreTest do
  use ExUnit.Case, async: true

  alias Mob.Mesh.{Router, Store}

  test "stores and pops envelopes by destination" do
    {:ok, store} = Store.start_link([])
    envelope = Router.envelope(:a, :b, "hello")

    assert :ok = Store.put(store, :b, envelope)
    assert %{b: [^envelope]} = Store.list(store)
    assert [^envelope] = Store.pop(store, :b)
    assert %{} = Store.list(store)
  end
end
