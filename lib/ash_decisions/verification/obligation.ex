# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshDecisions.Verification.Obligation do
  @moduledoc """
  Something the verifier could **not** decide, recorded so that silence is never
  mistaken for proof.

  An undecidable table must not be reported as clean, and it must not block
  publishing either: an `:opaque` cell is usually a perfectly good rule using a
  FEEL construct the recognizer has not been taught, and refusing to publish
  over the verifier's own incompleteness would make the verifier the thing people
  route around. So an obligation is a first-class artefact, not a log line and
  not an error — it is what an auditor is shown alongside the definition: *this
  table was proved non-overlapping and complete except for column `x`, which is
  untyped, and rule `Rule_9`, whose first cell uses a construct the verifier does
  not decide.* That sentence is worth considerably more than a green tick that
  means less than it looks like it means.
  """

  @derive Jason.Encoder

  defstruct [:reason, :path, :message, :detail]

  @type reason ::
          :opaque_entry
          # a cell the recognizer (or the analysis, given the column) would not guess at
          | :untyped_column
          # no typeRef and no inputValues, so no declared domain
          | :unbounded_domain
          # a decidable type whose domain is infinite and uncovered
          | :region_cap
          # the product of the column regions exceeded the analysis cap
          | :hit_policy
  # COLLECT: overlap is legal, so there is nothing to prove

  @type t :: %__MODULE__{
          reason: reason(),
          path: String.t(),
          message: String.t(),
          detail: map()
        }

  @doc "The JSON-safe map stored in a definition's `verification` attribute."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = obligation) do
    %{
      "reason" => to_string(obligation.reason),
      "path" => obligation.path,
      "message" => obligation.message,
      "detail" => obligation.detail || %{}
    }
  end
end
