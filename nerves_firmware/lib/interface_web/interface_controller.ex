defmodule InterfaceWeb.InterfaceController do
  use InterfaceWeb, :controller

  def os(conn, _params) do
    json(conn, os_spec())
  end

  if Mix.target() == :host do
    defp os_spec() do
      os_data = to_string(:erlang.system_info(:system_architecture))

      %{
        os: os_data,
        architecture: os_data
      }
    end
  else
    alias Nerves.Runtime.KV

    defp os_spec() do
      fw_architecture = KV.get_active("nerves_fw_architecture")
      fw_platform = KV.get_active("nerves_fw_platform")
      fw_product = KV.get_active("nerves_fw_product")
      fw_version = KV.get_active("nerves_fw_version")
      fw_uuid = KV.get_active("nerves_fw_uuid")

      %{
        os: "#{fw_product} #{fw_version} (#{fw_uuid}) #{fw_architecture} #{fw_platform}",
        architecture: fw_architecture
      }
    end
  end
end
