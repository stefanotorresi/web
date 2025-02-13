defmodule TrentoWeb.V2.ClusterJSON do
  alias Trento.Support.StructHelper

  def clusters(%{clusters: clusters}), do: Enum.map(clusters, &cluster(%{cluster: &1}))

  def cluster(%{cluster: cluster}) do
    cluster
    |> StructHelper.to_atomized_map()
    |> Map.delete(:deregistered_at)
  end

  def cluster_registered(%{cluster: cluster}), do: Map.delete(cluster(%{cluster: cluster}), :tags)

  def cluster_restored(%{cluster: cluster}), do: cluster(%{cluster: cluster})

  def cluster_details_updated(%{data: data}) do
    data
    |> Map.from_struct()
    |> Map.delete(:cluster_id)
    |> Map.put(:id, data.cluster_id)
  end

  def cluster_health_changed(%{cluster: %{id: id, name: name, health: health}}),
    do: %{cluster_id: id, name: name, health: health}
end
