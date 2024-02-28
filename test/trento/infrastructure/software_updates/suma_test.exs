defmodule Trento.Infrastructure.SoftwareUpdates.SumaTest do
  use Trento.DataCase

  import Mox

  import Trento.Factory

  alias Trento.Infrastructure.SoftwareUpdates.Suma
  alias Trento.Infrastructure.SoftwareUpdates.Suma.HttpExecutor.Mock, as: SumaApiMock
  alias Trento.Infrastructure.SoftwareUpdates.Suma.State
  alias Trento.SoftwareUpdates.Settings

  setup [:set_mox_from_context, :verify_on_exit!]

  @test_integration_name "test_integration"

  setup do
    %Settings{} =
      software_updates_settings =
      insert(:software_updates_settings, [],
        conflict_target: :id,
        on_conflict: :replace_all
      )

    {:ok, %{settings: software_updates_settings}}
  end

  describe "Process start up and identification" do
    test "should find an already started SUMA process" do
      assert {_, {:already_started, pid}} = start_supervised(Suma)

      assert pid == Suma.identify()
    end

    test "should start a new identifiable process" do
      assert {:ok, pid} = start_supervised({Suma, @test_integration_name})

      assert pid == Suma.identify(@test_integration_name)
    end

    test "should have expected initial state" do
      {_, {:already_started, _}} = start_supervised(Suma)
      {:ok, _} = start_supervised({Suma, @test_integration_name})

      expected_state = %State{
        url: nil,
        username: nil,
        password: nil,
        ca_cert: nil,
        auth: nil
      }

      assert :sys.get_state(Suma.identify()) == expected_state
      assert :sys.get_state(Suma.identify(@test_integration_name)) == expected_state
    end
  end

  describe "Setting up SUMA integration service" do
    test "should setup SUMA state", %{
      settings: %Settings{url: url, username: username, password: password, ca_cert: ca_cert}
    } do
      {:ok, _} = start_supervised({Suma, @test_integration_name})

      base_api_url = "#{url}/rhn/manager/api"
      ignored_cookie = "pxt-session-cookie=1234"
      auth_cookie = "pxt-session-cookie=4321"

      expect(SumaApiMock, :login, fn ^base_api_url, ^username, ^password ->
        {:ok,
         %HTTPoison.Response{
           status_code: 200,
           headers: [
             {"Set-Cookie",
              "JSESSIONID=FOOBAR; Path=/; Secure; HttpOnly; HttpOnly;HttpOnly;Secure"},
             {"Set-Cookie",
              "#{ignored_cookie}; Max-Age=0; Expires=Thu, 01 Jan 1970 00:00:10 GMT; Path=/; Secure; HttpOnly;HttpOnly;Secure"},
             {"Set-Cookie",
              "#{auth_cookie}; Max-Age=3600; Expires=Mon, 26 Feb 2024 10:53:57 GMT; Path=/; Secure; HttpOnly;HttpOnly;Secure"}
           ]
         }}
      end)

      assert :ok = Suma.setup(@test_integration_name)

      expected_state = %State{
        url: url,
        username: username,
        password: password,
        ca_cert: ca_cert,
        auth: auth_cookie
      }

      assert @test_integration_name
             |> Suma.identify()
             |> :sys.get_state() == expected_state
    end

    test "should handle error when reaching maximum login retries" do
      {:ok, _} = start_supervised({Suma, @test_integration_name})

      error_causes = [
        {:ok, %HTTPoison.Response{status_code: 401}},
        {:ok, %HTTPoison.Response{status_code: 503}},
        {:error, %HTTPoison.Error{reason: "kaboom"}}
      ]

      for error_cause <- error_causes do
        expect(SumaApiMock, :login, 5, fn _, _, _ -> error_cause end)

        assert {:error, :max_login_retries_reached} = Suma.setup(@test_integration_name)

        expected_state = %State{
          url: nil,
          username: nil,
          password: nil,
          ca_cert: nil,
          auth: nil
        }

        assert @test_integration_name
               |> Suma.identify()
               |> :sys.get_state() == expected_state
      end
    end

    test "should successfully login after retrying" do
      {:ok, _} = start_supervised({Suma, @test_integration_name})

      ignored_cookie = "pxt-session-cookie=1234"
      auth_cookie = "pxt-session-cookie=4321"

      responses = [
        {:ok, %HTTPoison.Response{status_code: 401}},
        {:error, %HTTPoison.Error{reason: "kaboom"}},
        {:ok,
         %HTTPoison.Response{
           status_code: 200,
           headers: [
             {"Set-Cookie",
              "JSESSIONID=FOOBAR; Path=/; Secure; HttpOnly; HttpOnly;HttpOnly;Secure"},
             {"Set-Cookie",
              "#{ignored_cookie}; Max-Age=0; Expires=Thu, 01 Jan 1970 00:00:10 GMT; Path=/; Secure; HttpOnly;HttpOnly;Secure"},
             {"Set-Cookie",
              "#{auth_cookie}; Max-Age=3600; Expires=Mon, 26 Feb 2024 10:53:57 GMT; Path=/; Secure; HttpOnly;HttpOnly;Secure"}
           ]
         }}
      ]

      {:ok, _} = Agent.start_link(fn -> 0 end, name: :login_call_iteration)

      expect(SumaApiMock, :login, 3, fn _, _, _ ->
        iteration = Agent.get(:login_call_iteration, & &1)

        iteration_response = Enum.at(responses, iteration)
        Agent.update(:login_call_iteration, &(&1 + 1))

        iteration_response
      end)

      assert :ok = Suma.setup(@test_integration_name)

      assert %State{
               auth: ^auth_cookie
             } =
               @test_integration_name
               |> Suma.identify()
               |> :sys.get_state()
    end
  end

  describe "Integration service" do
    test "should return an error when a system id was not found for a given fqdn" do
      {:ok, _} = start_supervised({Suma, @test_integration_name})

      fqdn = "machine.fqdn.internal"

      expect(SumaApiMock, :login, 1, fn _, _, _ -> successful_login_response() end)

      error_causes = [
        {:ok, %HTTPoison.Response{status_code: 200, body: ~s({"success":true,"result":[]})}},
        {:ok, %HTTPoison.Response{status_code: 404}},
        {:ok, %HTTPoison.Response{status_code: 503}},
        {:error, %HTTPoison.Error{reason: "kaboom"}}
      ]

      for error_cause <- error_causes do
        expect(SumaApiMock, :get_system_id, 1, fn _, _, ^fqdn -> error_cause end)

        assert {:error, :system_id_not_found} = Suma.get_system_id(fqdn, @test_integration_name)
      end
    end

    test "should get a system for a given fqdn" do
      {:ok, _} = start_supervised({Suma, @test_integration_name})

      fqdn = "machine.fqdn.internal"

      expect(SumaApiMock, :login, 1, fn _, _, _ -> successful_login_response() end)

      expect(SumaApiMock, :get_system_id, 1, fn _, _, ^fqdn ->
        {:ok,
         %HTTPoison.Response{
           status_code: 200,
           body: ~s({"success": true,"result": [{"id":1000010001}]})
         }}
      end)

      assert {:ok, 1_000_010_001} = Suma.get_system_id(fqdn, @test_integration_name)
    end
  end

  defp successful_login_response(
         auth_cookie \\ "pxt-session-cookie=4321",
         ignored_cookie \\ "pxt-session-cookie=1234"
       ) do
    {:ok,
     %HTTPoison.Response{
       status_code: 200,
       headers: [
         {"Set-Cookie", "JSESSIONID=FOOBAR; Path=/; Secure; HttpOnly; HttpOnly;HttpOnly;Secure"},
         {"Set-Cookie",
          "#{ignored_cookie}; Max-Age=0; Expires=Thu, 01 Jan 1970 00:00:10 GMT; Path=/; Secure; HttpOnly;HttpOnly;Secure"},
         {"Set-Cookie",
          "#{auth_cookie}; Max-Age=3600; Expires=Mon, 26 Feb 2024 10:53:57 GMT; Path=/; Secure; HttpOnly;HttpOnly;Secure"}
       ]
     }}
  end
end
