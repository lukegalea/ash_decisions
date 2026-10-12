# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshDecisions.Test.Baselines do
  @moduledoc false

  # A host's baseline seam, reduced to what the editor needs from it: a document to
  # show for a key the scope has stored nothing for, and a way to turn that into the
  # scope's own draft. Where a real host keeps its baselines is its business.

  alias AshDecisions.Test.Definition
  alias AshDecisions.Web.EditorLive.Impl

  @xml """
  <?xml version="1.0" encoding="UTF-8"?>
  <definitions xmlns="https://www.omg.org/spec/DMN/20191111/MODEL/"
               id="Definitions_baseline" name="baseline" namespace="urn:test">
    <decision id="Decision_baseline" name="Baseline decision">
      <literalExpression id="LiteralExpression_1">
        <text>"baseline"</text>
      </literalExpression>
    </decision>
  </definitions>
  """

  def xml, do: @xml

  def baseline(_key, _socket), do: %{xml: @xml, version: 2, name: "Baseline"}

  def customize(key, socket) do
    opts = Impl.scope(socket.assigns)

    {:ok,
     Definition.create!(
       %{key: key, name: "Customized", xml: @xml},
       Keyword.put(opts, :authorize?, false)
     )}
  end

  def refuse(_key, _socket), do: {:error, "No baseline to customize from."}
end
