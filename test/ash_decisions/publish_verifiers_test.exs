# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshDecisions.PublishVerifiersTest do
  @moduledoc """
  The `publish_verifiers` config hook: host-registered gates that run at
  PUBLISH and only at publish. Each receives the definition's identity
  (the shape a certification record carries) and returns `:ok` or
  `{:error, reason}`; the first refusal blocks the publication with its
  reason; an empty config leaves the publish action byte-identical to
  what it was.
  """

  use AshDecisions.DataCase, async: false

  alias AshDecisions.Config
  alias AshDecisions.Test.Definition

  @discount File.read!("test/fixtures/discount.dmn")

  setup do
    on_exit(fn -> Application.delete_env(:ash_decisions, :publish_verifiers) end)
    :ok
  end

  defp key, do: "bands_family#{System.unique_integer([:positive])}"

  defp draft(key \\ nil) do
    Definition.create!(%{key: key || key(), name: "Band table", xml: @discount})
  end

  describe "the config shape" do
    test "empty by default" do
      assert Config.publish_verifiers() == []
    end

    test "MFAs pass through; bare modules normalize to verify/1" do
      Application.put_env(:ash_decisions, :publish_verifiers, [
        {SomeGate, :check, [:arg]},
        OtherGate
      ])

      assert Config.publish_verifiers() == [
               {SomeGate, :check, [:arg]},
               {OtherGate, :verify, []}
             ]
    end
  end

  describe "at publish" do
    test "an empty config is unchanged behaviour" do
      published = draft() |> Definition.publish!()
      assert published.status == :published
    end

    test "an :ok verifier publishes, and receives the definition identity" do
      test_pid = self()

      Application.put_env(:ash_decisions, :publish_verifiers, [
        {__MODULE__.RecordingGate, :verify, [test_pid]}
      ])

      k = key()
      published = draft(k) |> Definition.publish!()

      assert published.status == :published

      assert_received {:verifier_called, identity}
      assert identity.key == k
      assert identity.version == 1
      assert identity.status == :draft
      assert is_binary(identity.content_hash)
      assert identity.id == published.id
    end

    test "the first refusal blocks, its reason travelling to the caller" do
      Application.put_env(:ash_decisions, :publish_verifiers, [
        {__MODULE__.OkGate, :verify, []},
        {__MODULE__.RefusingGate, :verify, ["the calibration run is below min_n"]}
      ])

      definition = draft()

      assert {:error, error} = Definition.publish(definition)
      assert Exception.message(error) =~ "a configured publish verifier refused"
      assert Exception.message(error) =~ "the calibration run is below min_n"

      # And the refusal held: the definition is still a draft.
      assert Definition.by_key_version!(definition.key, 1).status == :draft
    end

    test "a refusal carrying an exception names its message" do
      Application.put_env(:ash_decisions, :publish_verifiers, [
        {__MODULE__.RaisingGate, :verify, []}
      ])

      assert {:error, error} = Definition.publish(draft())
      assert Exception.message(error) =~ "no calibration run for this family"
    end

    test "a crashing verifier blocks the publish (a misconfigured gate is a refusal)" do
      Application.put_env(:ash_decisions, :publish_verifiers, [
        {__MODULE__.CrashingGate, :verify, []}
      ])

      assert {:error, error} = Definition.publish(draft())
      assert Exception.message(error) =~ "verifier refused"
    end

    test "extra MFA args ride along" do
      test_pid = self()

      Application.put_env(:ash_decisions, :publish_verifiers, [
        {__MODULE__.ArgGate, :verify, [test_pid, :clinic_triage]}
      ])

      draft() |> Definition.publish!()

      assert_received {:arg_gate_called, ^test_pid, :clinic_triage, _identity}
    end

    test "verifiers run ONLY at publish — saving XML does not consult them" do
      test_pid = self()

      Application.put_env(:ash_decisions, :publish_verifiers, [
        {__MODULE__.RecordingGate, :verify, [test_pid]}
      ])

      definition = draft()
      definition |> Definition.save_xml!(@discount)

      refute_received {:verifier_called, _}
    end
  end

  ## The gates

  defmodule OkGate do
    @moduledoc false
    def verify(_definition), do: :ok
  end

  defmodule RefusingGate do
    @moduledoc false
    # Config args first, the definition identity last — the hook's MFA order.
    def verify(reason, _definition), do: {:error, reason}
  end

  defmodule RaisingGate do
    @moduledoc false
    def verify(_definition), do: raise("no calibration run for this family")
  end

  defmodule CrashingGate do
    @moduledoc false
    def verify(_definition), do: raise(ArgumentError, message: "boom")
  end

  defmodule RecordingGate do
    @moduledoc false
    def verify(test_pid, definition), do: send(test_pid, {:verifier_called, definition}) && :ok
  end

  defmodule ArgGate do
    @moduledoc false
    def verify(test_pid, family, definition),
      do: send(test_pid, {:arg_gate_called, test_pid, family, definition}) && :ok
  end
end
