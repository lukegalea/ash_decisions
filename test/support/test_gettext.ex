# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshDecisions.Test.Gettext do
  @moduledoc """
  A host's Gettext backend, for the LiveViews' `gettext:` option. Its catalogue is a
  French `ash_decisions.po` holding a few of the shipped msgids.
  """
  use Gettext.Backend, otp_app: :ash_decisions, priv: "priv/test_gettext"
end
