defmodule AshDecisions.PoliciesTest do
  @moduledoc """
  This package's own authority, and the fact that it is declared.

  `ash_bpmn` shipped every generated resource naming `Ash.Policy.Authorizer` as
  its authorizer and then shipping no policies at all, while the engine reached
  past the authorizer with `authorize?: false` at ninety call sites. Both halves
  were defensible on their own — the host owns policy; an engine has to write
  rows no person may write — and together they meant an unauthorized path into
  the tables the package managed, with nothing in any policy set to show for it.

  The fix is one named bypass and a scope that marks the calls it covers. These
  tests are what stop it coming apart again.
  """

  use AshDecisions.DataCase, async: false

  require Ash.Query

  alias AshDecisions.Scope
  alias AshDecisions.TenantTest

  @tenant Ecto.UUID.generate()
  @generated [TenantTest.Definition, TenantTest.Evaluation]

  describe "the generated policy set" do
    test "every resource carries exactly one policy, and it is the bypass" do
      for resource <- @generated do
        assert [policy] = Ash.Policy.Info.policies(resource),
               "#{inspect(resource)} should carry exactly the generated policy"

        assert policy.bypass?, "#{inspect(resource)}'s generated policy should be a bypass"

        # The check is the policy's *condition* -- `bypass Check do … end` puts
        # it there and `authorize_if always()` is the body.
        assert Enum.any?(policy.condition, fn
                 {AshDecisions.Checks.AshDecisionsInteraction, _opts} -> true
                 _ -> false
               end),
               "#{inspect(resource)}'s bypass should be conditioned on AshDecisionsInteraction"
      end
    end
  end

  describe "who the bypass lets through" do
    test "a read carrying the library context is allowed" do
      for resource <- @generated do
        assert {:ok, _} =
                 resource
                 |> Ash.Query.for_read(:read)
                 |> Ash.read(Scope.engine(%Scope{tenant: @tenant}))
      end
    end

    test "a read without it is forbidden — including one with a plausible actor" do
      for resource <- @generated do
        assert {:error, %Ash.Error.Forbidden{}} =
                 resource
                 |> Ash.Query.for_read(:read)
                 |> Ash.read(tenant: @tenant)

        assert {:error, %Ash.Error.Forbidden{}} =
                 resource
                 |> Ash.Query.for_read(:read)
                 |> Ash.read(tenant: @tenant, actor: %{id: Ecto.UUID.generate()})
      end
    end

    test "a tenant on a resource that is not tenant-scoped is harmless" do
      # A host with tenancy of its own but untenanted decision tables will pass a
      # tenant to a resource that has no strategy for one. Ash stores it and the
      # data layer ignores it -- worth pinning, because the alternative would be
      # a break in every such host.
      assert {:ok, _} =
               AshDecisions.Test.Definition
               |> Ash.Query.for_read(:read)
               |> Ash.read(Scope.engine(%Scope{tenant: Ecto.UUID.generate()}))
    end

    test "the check describes itself, so a policy breakdown reads" do
      assert AshDecisions.Checks.AshDecisionsInteraction.describe([]) =~ "ash_decisions"
    end
  end

  describe "the scope" do
    test "engine/2 marks the call and keeps the caller's actor" do
      actor = %{id: Ecto.UUID.generate()}
      opts = Scope.engine(%Scope{actor: actor, tenant: @tenant})

      assert opts[:actor] == actor
      assert opts[:tenant] == @tenant
      assert opts[:context] == %{private: %{ash_decisions?: true}}
    end

    test "engine_actor replaces the actor when a host has configured one" do
      configured = %{id: Ecto.UUID.generate()}
      Application.put_env(:ash_decisions, :engine_actor, configured)
      on_exit(fn -> Application.delete_env(:ash_decisions, :engine_actor) end)

      assert Scope.engine(%Scope{actor: %{id: "someone else"}})[:actor] == configured
    end

    test "from_record takes the tenant off the row rather than being told again" do
      record = %{organization_id: @tenant}
      assert Scope.from_record(record).tenant == @tenant
    end

    test "to_job_args carries the tenant and the domain, and nothing else" do
      scope = %Scope{tenant: @tenant, domain: AshDecisions.Test.Domain, actor: %{id: "x"}}
      args = Scope.to_job_args(scope, %{"decision" => "Discount"})

      assert args == %{
               "decision" => "Discount",
               "tenant" => @tenant,
               "domain" => "Elixir.AshDecisions.Test.Domain"
             }
    end

    test "from_job reverses it" do
      args = Scope.to_job_args(%Scope{tenant: @tenant}, %{})
      assert Scope.from_job(args).tenant == @tenant
    end

    test "a nil tenant is left out of the payload rather than written as null" do
      assert Scope.to_job_args(%Scope{}, %{"a" => 1}) == %{"a" => 1}
    end
  end

  describe "the source itself" do
    test "no module under lib/ passes authorize?: false" do
      offenders =
        "lib/**/*.ex"
        |> Path.wildcard()
        |> Enum.flat_map(fn path ->
          path
          |> File.read!()
          |> String.split("\n")
          |> Enum.with_index(1)
          |> Enum.filter(fn {line, _} ->
            String.contains?(line, "authorize?: false") and not documentation?(line)
          end)
          |> Enum.map(fn {line, number} -> "#{path}:#{number}: #{String.trim(line)}" end)
        end)

      assert offenders == [],
             """
             `authorize?: false` is in lib/.

             This package's own calls go through `AshDecisions.Scope.engine/2`,
             which marks them for the bypass every generated resource declares.
             There is no exception, and adding one should be a conversation
             rather than a one-line diff.

             #{Enum.join(offenders, "\n")}
             """
    end
  end

  # A doc line or a comment mentioning the option is not a call site.
  defp documentation?(line) do
    trimmed = String.trim(line)

    String.starts_with?(trimmed, "#") or String.contains?(line, "`authorize?: false`")
  end
end
