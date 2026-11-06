# The extensions that cannot be linked in, loaded into `duckdb` with LOAD, and what each is
# for. The SQL must fail without the extension, so the check cannot pass by accident. One
# built here is not signed: DuckDB must refuse it unless it is told to load unsigned
# extensions, and the registry's build is signed and loads as it is.
{
  pkgs,
  duckdb,
  loadables,
}:

let
  inherit (pkgs) lib;

  run =
    loadable:
    let
      commands = lib.concatMapStringsSep " " (sql: "-c ${lib.escapeShellArg sql}") loadable.smoke;
      load = "-c ${lib.escapeShellArg "LOAD '${loadable}/${loadable.path}'"}";
      allow = lib.optionalString loadable.unsigned " -unsigned";
      bin = lib.getExe duckdb;
    in
    ''
      echo "loadable: ${loadable.name} (${if loadable.unsigned then "built here" else "the registry's"})"
      ${bin}${allow} -bail ${load} ${commands} >/dev/null

      # the SQL needs the extension
      if ${bin} -bail ${commands} >/dev/null 2>&1; then
        echo "${loadable.name}: the smoke test passed without the extension, so it proves nothing" >&2
        exit 1
      fi
    ''
    + lib.optionalString loadable.unsigned ''

      # without -unsigned it is refused
      if ${bin} -bail ${load} >/dev/null 2>&1; then
        echo "${loadable.name}: an unsigned extension was loaded without -unsigned" >&2
        exit 1
      fi
    ''
    + ''

      # through the extension directory, as LOAD by name
      dir=${loadable}/share/duckdb/extensions
      ${bin}${allow} -bail -c "SET extension_directory = '$dir'" -c "LOAD ${loadable.name}" \
        -c "SELECT CASE WHEN loaded THEN 1 ELSE error('${loadable.name} not loaded') END FROM duckdb_extensions() WHERE extension_name = '${loadable.name}'" >/dev/null
    '';
in
pkgs.runCommand "duckdb-loadable-extensions-check" { } ''
  export HOME=$TMPDIR
  ${lib.concatMapStrings run (lib.attrValues loadables)}
  touch $out
''
