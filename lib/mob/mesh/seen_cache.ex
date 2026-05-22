defmodule Mob.Mesh.SeenCache do
  @moduledoc """
  Bounded duplicate-suppression cache.

  Membership checks are backed by `MapSet` and eviction order is tracked with
  `:queue`, so recently recorded message IDs are not discarded arbitrarily.
  """

  defstruct ids: MapSet.new(), order: :queue.new(), limit: 4_096

  @type t :: %__MODULE__{
          ids: term(),
          order: term(),
          limit: pos_integer()
        }

  @spec new(pos_integer()) :: t()
  def new(limit) when is_integer(limit) and limit > 0 do
    %__MODULE__{limit: limit}
  end

  @spec member?(t(), term()) :: boolean()
  def member?(%__MODULE__{ids: ids}, id), do: MapSet.member?(ids, id)

  @spec put(t(), term()) :: t()
  def put(%__MODULE__{} = cache, id) do
    if member?(cache, id) do
      cache
    else
      cache
      |> append(id)
      |> trim()
    end
  end

  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{ids: ids}), do: MapSet.size(ids)

  defp append(cache, id) do
    %{cache | ids: MapSet.put(cache.ids, id), order: :queue.in(id, cache.order)}
  end

  defp trim(cache) do
    if MapSet.size(cache.ids) <= cache.limit do
      cache
    else
      {{:value, oldest}, order} = :queue.out(cache.order)
      trim(%{cache | ids: MapSet.delete(cache.ids, oldest), order: order})
    end
  end
end
