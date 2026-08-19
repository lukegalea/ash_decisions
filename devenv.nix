{ pkgs, lib, config, ... }:

let
  # Same OTP/Elixir pairing as ash_enterprise (and the ash-hq installer), so the
  # library is built against the combination the Ash ecosystem tests against.
  beam = pkgs.beam.packages.erlang_27;
in
{
  name = "ash_decisions";

  languages.erlang = {
    enable = true;
    package = beam.erlang;
    lsp.enable = false;
  };

  languages.elixir = {
    enable = true;
    package = beam.elixir_1_18;
    lsp.enable = false;
  };

  # Node is here for the designer's npm deps (bpmn-js) when smoke-testing the
  # hook against a host app; the library itself ships plain ESM in priv/js.
  languages.javascript = {
    enable = true;
    package = pkgs.nodejs_22;
  };

  packages = with pkgs; [
    git
    jq
    # `boxic_dmn` validates DMN documents against the normative XSD by shelling out to
    # `xmllint`; without it on PATH, `Boxic.DMN.load_xml/1` returns
    # `:schema_validator_unavailable` and every model fails to load. It is a runtime
    # dependency of the decision engine, not a development convenience.
    libxml2
  ];

  # devenv shifts the Postgres port when the requested one is taken (Docker,
  # another checkout of a sibling package), rewriting postgresql.conf but leaving
  # the exported $PGPORT at the value it asked for. The two then disagree and
  # every client connects to the wrong cluster -- or, worse, to a different
  # project's. postgresql.conf is the authoritative answer, so read it back.
  # It does not exist on a cold checkout, before the first `devenv up`.
  enterShell = ''
    if [ -f "$DEVENV_STATE/postgres/postgresql.conf" ]; then
      _pgport="$(sed -n 's/^port = \([0-9]\+\).*/\1/p' "$DEVENV_STATE/postgres/postgresql.conf" | tail -n1)"
      [ -n "$_pgport" ] && export PGPORT="$_pgport"
      unset _pgport
    fi
  '';

  services.postgres = {
    enable = true;
    package = pkgs.postgresql_16;
    listen_addresses = "127.0.0.1";
    initialDatabases = [
      { name = "ash_decisions_test"; }
    ];
    initialScript = ''
      CREATE ROLE postgres WITH LOGIN SUPERUSER PASSWORD 'postgres';
    '';
  };
}
