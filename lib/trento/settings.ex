defmodule Trento.Settings do
  @moduledoc """
  Provides a set of functions of settings related usecases.
  """

  alias Trento.Repo

  alias Trento.SoftwareUpdates.Discovery, as: SoftwareUpdatesDiscovery

  alias Trento.Settings.{
    ActivityLogSettings,
    ApiKeySettings,
    InstallationSettings,
    SSOCertificatesSettings,
    SuseManagerSettings
  }

  alias Trento.Support.DateService

  require Trento.ActivityLog.RetentionPeriodUnit, as: RetentionPeriodUnit

  require Logger

  @type suse_manager_settings_save_submission :: %{
          url: String.t(),
          username: String.t(),
          password: String.t(),
          ca_cert: String.t() | nil
        }

  @type suse_manager_settings_change_submission :: %{
          url: String.t() | nil,
          username: String.t() | nil,
          password: String.t() | nil,
          ca_cert: String.t() | nil
        }

  @spec get_installation_id :: String.t()
  def get_installation_id do
    %InstallationSettings{installation_id: installation_id} =
      Repo.one!(InstallationSettings.base_query())

    installation_id
  end

  @spec create_api_key_settings(map()) :: {:ok, ApiKeySettings.t()} | {:error, any}
  def create_api_key_settings(settings) do
    %ApiKeySettings{}
    |> ApiKeySettings.changeset(settings)
    |> Repo.insert()
  end

  @spec get_api_key_settings() :: {:ok, ApiKeySettings.t()} | {:error, any}
  def get_api_key_settings do
    case Repo.one(ApiKeySettings.base_query()) do
      nil -> {:error, :api_key_settings_missing}
      api_key_settings -> {:ok, api_key_settings}
    end
  end

  @spec update_api_key_settings(DateTime.t()) :: {:ok, ApiKeySettings.t()} | {:error, any}
  def update_api_key_settings(expiration) do
    case get_api_key_settings() do
      {:ok, settings} ->
        settings
        |> ApiKeySettings.changeset(%{
          created_at: DateTime.utc_now(),
          expire_at: expiration,
          jti: UUID.uuid4()
        })
        |> Repo.update()

      error ->
        error
    end
  end

  # SUMA settings

  @spec get_suse_manager_settings ::
          {:ok, SuseManagerSettings.t()} | {:error, :settings_not_configured}
  def get_suse_manager_settings do
    settings = Repo.one(SuseManagerSettings.base_query())

    if settings do
      {:ok, settings}
    else
      {:error, :settings_not_configured}
    end
  end

  @spec save_suse_manager_settings(suse_manager_settings_save_submission, module()) ::
          {:ok, SuseManagerSettings.t()}
          | {:error, :settings_already_configured}
          | {:error, any()}
  def save_suse_manager_settings(settings_submission, date_service \\ DateService) do
    with {:ok, :settings_not_configured, settings} <- ensure_no_suse_manager_settings_configured() do
      settings
      |> save_or_update_suse_manager_settings(settings_submission, date_service)
      |> log_error("Error while saving software updates settings")
    end
  end

  @spec change_suse_manager_settings(suse_manager_settings_change_submission, module()) ::
          {:ok, SuseManagerSettings.t()}
          | {:error, :settings_not_configured}
          | {:error, any()}
  def change_suse_manager_settings(settings_submission, date_service \\ DateService) do
    with {:ok, settings} <- get_suse_manager_settings() do
      settings
      |> save_or_update_suse_manager_settings(settings_submission, date_service)
      |> log_error("Error while updating software updates settings")
    end
  end

  @spec clear_suse_manager_settings :: :ok
  def clear_suse_manager_settings do
    Repo.delete_all(SuseManagerSettings.base_query())

    SoftwareUpdatesDiscovery.clear_software_updates_discoveries()

    :ok
  end

  # Activity log settings

  @spec get_activity_log_settings() ::
          {:ok, ActivityLogSettings.t()} | {:error, :activity_log_settings_not_configured}
  def get_activity_log_settings do
    case Repo.one(ActivityLogSettings.base_query()) do
      %ActivityLogSettings{} = settings -> {:ok, settings}
      nil -> {:error, :activity_log_settings_not_configured}
    end
  end

  @spec change_activity_log_retention_period(integer(), RetentionPeriodUnit.t()) ::
          {:ok, ActivityLogSettings.t()}
          | {:error, :activity_log_settings_not_configured}
  def change_activity_log_retention_period(value, unit) do
    case get_activity_log_settings() do
      {:ok, settings} ->
        settings
        |> ActivityLogSettings.changeset(%{
          retention_time: %{
            value: value,
            unit: unit
          }
        })
        |> Repo.update()
        |> log_error("Error while updating activity log retention period")

      error ->
        error
    end
  end

  # Certificates settings

  @spec get_sso_certificates() :: [SSOCertificatesSettings.t()]
  def get_sso_certificates do
    Repo.one(SSOCertificatesSettings.base_query())
  end

  defp ensure_no_suse_manager_settings_configured do
    case Repo.one(SuseManagerSettings.base_query()) do
      nil ->
        {:ok, :settings_not_configured, nil}

      %SuseManagerSettings{} ->
        Logger.error("Error: software updates settings already configured")
        {:error, :settings_already_configured}
    end
  end

  defp save_or_update_suse_manager_settings(settings, settings_submission, date_service) do
    result =
      case settings do
        nil ->
          %SuseManagerSettings{}
          |> SuseManagerSettings.changeset(settings_submission, date_service)
          |> Repo.insert()

        %SuseManagerSettings{} ->
          settings
          |> SuseManagerSettings.changeset(settings_submission, date_service)
          |> Repo.update()
      end

    case result do
      {:ok, _} = success ->
        SoftwareUpdatesDiscovery.clear()

        Task.Supervisor.start_child(Trento.TasksSupervisor, fn ->
          SoftwareUpdatesDiscovery.discover_software_updates()
        end)

        success

      {:error, _} = error ->
        error
    end
  end

  defp log_error({:error, _} = error, message) do
    Logger.error("#{message}: #{inspect(error)}")
    error
  end

  defp log_error(result, _), do: result
end
