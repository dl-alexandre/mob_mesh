defmodule Mob.Mesh.Telemetry do
  @moduledoc false

  @spec emit(atom() | [atom()], map(), map()) :: :ok
  def emit(event, measurements \\ %{}, metadata \\ %{}) do
    :telemetry.execute([:mob_mesh] ++ List.wrap(event), measurements, metadata)
  end
end
