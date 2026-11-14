# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshDecisions.TryLiveTest do
  @moduledoc """
  The decision trial page (`AshDecisions.Web.TryLive`): run a draft or a published version
  against sample inputs. The refusals come first because the page evaluates tenant-authored
  rules: another tenant, and a person with no read on decisions, get nothing to try; invalid
  input is an error, not an evaluation; and a trial never writes an `Evaluation`.

  The resources are `AshDecisions.TrialHost.*`, which carry a host's read policy, and the
  session is assigned by `AshDecisions.Test.TrialSession`, as a host's `on_mount` would.
  """

  use AshDecisions.WebConnCase, async: false

  alias AshDecisions.Scope
  alias AshDecisions.TrialHost.{Definition, Evaluation}

  @key "discount"
  @xml File.read!("test/fixtures/discount.dmn")
  # The draft changes one answer so a trial can tell the two versions apart.
  @draft_xml String.replace(
               @xml,
               ~s|<outputEntry id="rule_gold_large_2"><text>0.15</text>|,
               ~s|<outputEntry id="rule_gold_large_2"><text>0.20</text>|
             )

  setup do
    tenant = Ecto.UUID.generate()
    engine = Scope.engine(%Scope{tenant: tenant})

    published =
      %{key: @key, name: "Discount", xml: @xml}
      |> Definition.create!(engine)
      |> Definition.publish!(engine)

    draft = Definition.create!(%{key: @key, name: "Discount", xml: @draft_xml}, engine)

    %{tenant: tenant, published: published, draft: draft, reader: reader()}
  end

  defp reader, do: %{id: Ecto.UUID.generate(), decisions?: true}

  defp sign_in(conn, actor, tenant, extra \\ %{}) do
    Plug.Test.init_test_session(conn, Map.merge(%{"actor" => actor, "tenant" => tenant}, extra))
  end

  defp evaluations(tenant) do
    Evaluation
    |> Ash.Query.for_read(:read, %{}, authorize?: false, tenant: tenant)
    |> Ash.read!()
  end

  defp path(key \\ @key), do: "/decisions/#{key}/try"

  defp try_it(view, version, total, tier) do
    view
    |> form("#decision-try-form", %{
      "version" => version.id,
      "inputs" => %{"orderTotal" => total, "customerTier" => tier}
    })
    |> render_submit()
  end

  describe "refusals" do
    test "another tenant has nothing to try, and cannot try by id", ctx do
      other = Ecto.UUID.generate()
      {:ok, view, _html} = live(sign_in(ctx.conn, reader(), other), path())

      assert has_element?(view, "#decision-try-refused")
      refute has_element?(view, "#decision-try-form")

      render_hook(view, "try", %{
        "version" => ctx.draft.id,
        "inputs" => %{"orderTotal" => "1200", "customerTier" => "gold"}
      })

      assert has_element?(view, "#decision-try-refused")
      refute has_element?(view, "#decision-try-result")
      assert evaluations(other) == []
    end

    test "someone in the tenant who may not read decisions has nothing to try", ctx do
      nobody = %{id: Ecto.UUID.generate(), decisions?: false}
      {:ok, view, _html} = live(sign_in(ctx.conn, nobody, ctx.tenant), path())

      assert has_element?(view, "#decision-try-refused")
      refute has_element?(view, "#decision-try-form")
    end

    test "nobody signed in has nothing to try", ctx do
      {:ok, view, _html} = live(sign_in(ctx.conn, nil, ctx.tenant), path())

      assert has_element?(view, "#decision-try-refused")
    end

    test "an unknown key has nothing to try", ctx do
      {:ok, view, _html} = live(sign_in(ctx.conn, ctx.reader, ctx.tenant), path("no.such.key"))

      assert has_element?(view, "#decision-try-refused")
    end

    test "an id that is not a version of this key is refused", ctx do
      {:ok, view, _html} = live(sign_in(ctx.conn, ctx.reader, ctx.tenant), path())

      render_hook(view, "try", %{"version" => "not-a-uuid", "inputs" => %{}})
      assert has_element?(view, "#decision-try-refused")

      render_hook(view, "try", %{"version" => Ecto.UUID.generate(), "inputs" => %{}})
      assert has_element?(view, "#decision-try-refused")
    end
  end

  describe "input errors" do
    test "invalid input shows an error and evaluates nothing", ctx do
      {:ok, view, _html} = live(sign_in(ctx.conn, ctx.reader, ctx.tenant), path())

      try_it(view, ctx.draft, "lots", "gold")

      assert has_element?(view, "#decision-try-error-orderTotal")
      refute has_element?(view, "#decision-try-result")
      assert evaluations(ctx.tenant) == []
    end

    test "a blank input is refused rather than read as empty", ctx do
      {:ok, view, _html} = live(sign_in(ctx.conn, ctx.reader, ctx.tenant), path())

      try_it(view, ctx.draft, "1200", "")

      assert has_element?(view, "#decision-try-error-customerTier")
      refute has_element?(view, "#decision-try-result")
    end
  end

  describe "trying a version" do
    test "a draft opens first and shows its answer and the rule that fired", ctx do
      {:ok, view, _html} = live(sign_in(ctx.conn, ctx.reader, ctx.tenant), path())

      assert has_element?(view, "#decision-try-version option[selected][value='#{ctx.draft.id}']")
      assert has_element?(view, "#decision-try-input-orderTotal")
      assert has_element?(view, "#decision-try-input-customerTier")

      try_it(view, ctx.draft, "1200", "gold")

      assert has_element?(view, "#decision-try-outputs", "0.2")
      assert has_element?(view, "#decision-try-rule-rule_gold_large", "Rule 1")
      refute has_element?(view, "#decision-try-error")
    end

    test "a published version answers as it was published", ctx do
      {:ok, view, _html} = live(sign_in(ctx.conn, ctx.reader, ctx.tenant), path())

      view
      |> form("#decision-try-version-form", %{"version" => ctx.published.id})
      |> render_change()

      try_it(view, ctx.published, "1200", "gold")

      assert has_element?(view, "#decision-try-outputs", "0.15")
      assert has_element?(view, "#decision-try-rule-rule_gold_large")
    end

    test "a case no rule covers is reported as no match", ctx do
      {:ok, view, _html} = live(sign_in(ctx.conn, ctx.reader, ctx.tenant), path())

      try_it(view, ctx.draft, "10", "platinum")

      assert has_element?(view, "#decision-try-no-rules")
    end

    test "trying writes no Evaluation", ctx do
      {:ok, view, _html} = live(sign_in(ctx.conn, ctx.reader, ctx.tenant), path())

      try_it(view, ctx.draft, "1200", "gold")

      view
      |> form("#decision-try-version-form", %{"version" => ctx.published.id})
      |> render_change()

      try_it(view, ctx.published, "500", "standard")
      try_it(view, ctx.published, "oops", "standard")

      assert evaluations(ctx.tenant) == []
    end
  end

  describe "against recorded cases" do
    defp decide!(ctx, total, tier) do
      {:ok, _result} =
        AshDecisions.Evaluator.evaluate(
          ctx.published,
          %{"orderTotal" => total, "customerTier" => tier},
          evaluation_resource: Evaluation,
          scope: %Scope{tenant: ctx.tenant},
          record: :required
        )
    end

    test "replaying the draft lists the recorded case it changes, and records nothing", ctx do
      decide!(ctx, 1200, "gold")
      decide!(ctx, 500, "standard")
      {:ok, view, _html} = live(sign_in(ctx.conn, ctx.reader, ctx.tenant), path())

      view |> element("#decision-try-replay-run") |> render_click()

      assert has_element?(view, "#decision-try-replay-count-changed", "Changed: 1")
      assert has_element?(view, "#decision-try-replay-count-unchanged", "Unchanged: 1")
      assert has_element?(view, "#decision-try-replay-cases", "0.15")
      assert has_element?(view, "#decision-try-replay-cases", "0.20")
      assert length(evaluations(ctx.tenant)) == 2
    end

    test "the published version replays unchanged", ctx do
      decide!(ctx, 1200, "gold")
      {:ok, view, _html} = live(sign_in(ctx.conn, ctx.reader, ctx.tenant), path())

      view
      |> form("#decision-try-version-form", %{"version" => ctx.published.id})
      |> render_change()

      view |> element("#decision-try-replay-run") |> render_click()

      assert has_element?(view, "#decision-try-replay-unchanged")
      refute has_element?(view, "#decision-try-replay-cases")
    end

    test "with nothing recorded, there is nothing to replay", ctx do
      {:ok, view, _html} = live(sign_in(ctx.conn, ctx.reader, ctx.tenant), path())

      view |> element("#decision-try-replay-run") |> render_click()

      assert has_element?(view, "#decision-try-replay-none")
    end

    test "another tenant's recorded cases are not replayed", ctx do
      decide!(ctx, 1200, "gold")
      other = Ecto.UUID.generate()
      engine = Scope.engine(%Scope{tenant: other})
      Definition.create!(%{key: @key, name: "Discount", xml: @xml}, engine)

      {:ok, view, _html} = live(sign_in(ctx.conn, ctx.reader, other), path())
      view |> element("#decision-try-replay-run") |> render_click()

      assert has_element?(view, "#decision-try-replay-none")
    end
  end

  describe "the host's language" do
    test "with `gettext:` and a locale, the page is in that language", ctx do
      conn = sign_in(ctx.conn, ctx.reader, ctx.tenant, %{"locale" => "fr"})
      {:ok, view, _html} = live(conn, "/fr/decisions/#{@key}/try")

      assert has_element?(view, "h1", "Essayer discount")
      assert has_element?(view, "#decision-try-submit", "Essayer")

      try_it(view, ctx.draft, "lots", "gold")

      assert has_element?(view, "#decision-try-error-orderTotal", "Saisissez un nombre")
    end

    test "a message the catalogue lacks falls back to English", ctx do
      conn = sign_in(ctx.conn, ctx.reader, ctx.tenant, %{"locale" => "fr"})
      {:ok, view, _html} = live(conn, "/fr/decisions/#{@key}/try")

      try_it(view, ctx.draft, "10", "platinum")

      assert has_element?(view, "#decision-try-no-rules", "No rule matched.")
    end

    test "without `gettext:` the page is in English whatever the locale", ctx do
      conn = sign_in(ctx.conn, ctx.reader, ctx.tenant, %{"locale" => "fr"})
      {:ok, view, _html} = live(conn, path())

      assert has_element?(view, "h1", "Try discount")
      assert has_element?(view, "#decision-try-submit", "Try it")
    end

    test "the editor takes the same option", ctx do
      conn = sign_in(ctx.conn, nil, nil, %{"locale" => "fr"})
      {:ok, view, _html} = live(conn, "/fr/editor")

      assert has_element?(view, "#decision-save", "Enregistrer")
      assert has_element?(view, "#decision-origin", "rien n’est enregistré")
    end
  end
end
