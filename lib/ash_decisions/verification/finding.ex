defmodule AshDecisions.Verification.Finding do
  @moduledoc """
  Something the verifier **proved** about a decision table.

  A finding is the outcome of a proof: a region of the input space was
  constructed and every claim in the message is witnessed by it. This is the
  opposite pole from `AshDecisions.Verification.Obligation`, which records what
  the verifier could not decide. Silence is never mistaken for proof, and proof
  is never diluted by speculation — an overlap the verifier cannot construct is
  an obligation, never a finding.

  `path` is the DMN element id, exactly as `AshDecisions.Compiler.error/2` uses
  it, so compile errors and verification findings address the document the same
  way. `detail` is machine-readable and JSON-safe by construction: rule ids,
  column ids and rendered FEEL text, never structs.
  """

  @derive Jason.Encoder

  defstruct [:kind, :severity, :path, :message, :detail, :stage]

  @type kind ::
          :overlap
          # two rules can match the same input
          | :incomplete
          # a region of the input space matches no rule, and there is no default
          | :shadowed
          # a rule that can never fire under FIRST, subsumed by an earlier one
          | :unsatisfiable
          # a rule that can never fire under any policy
          | :malformed_entry

  # `:malformed_entry` extends the kinds in the design note: an input entry that
  # does not parse at all is a parse-stage failure, not an algebraic one, and it
  # belongs to verification — `errors` keeps meaning compiler errors and nothing
  # else. It is publish-blocking (`severity: :error`), which is the whole point
  # of parsing input entries at publish time.

  @type severity :: :error | :warning | :info
  @type stage :: :parse | :type_check | :completeness

  @type t :: %__MODULE__{
          kind: kind(),
          severity: severity(),
          path: String.t(),
          message: String.t(),
          detail: map(),
          stage: stage()
        }

  @doc "The JSON-safe map stored in a definition's `verification` attribute."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = finding) do
    %{
      "kind" => to_string(finding.kind),
      "severity" => to_string(finding.severity),
      "path" => finding.path,
      "message" => finding.message,
      "detail" => finding.detail || %{},
      "stage" => to_string(finding.stage)
    }
  end
end
