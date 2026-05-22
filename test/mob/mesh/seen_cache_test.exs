defmodule Mob.Mesh.SeenCacheTest do
  use ExUnit.Case, async: true

  alias Mob.Mesh.SeenCache

  test "evicts the oldest message id first" do
    cache =
      2
      |> SeenCache.new()
      |> SeenCache.put("one")
      |> SeenCache.put("two")
      |> SeenCache.put("three")

    refute SeenCache.member?(cache, "one")
    assert SeenCache.member?(cache, "two")
    assert SeenCache.member?(cache, "three")
    assert SeenCache.size(cache) == 2
  end

  test "does not duplicate existing ids in the eviction queue" do
    cache =
      2
      |> SeenCache.new()
      |> SeenCache.put("one")
      |> SeenCache.put("one")
      |> SeenCache.put("two")

    assert SeenCache.member?(cache, "one")
    assert SeenCache.member?(cache, "two")
    assert SeenCache.size(cache) == 2
  end
end
