# Every extension in `extensions` is loaded in `duckdb` without INSTALL or
# LOAD, and each has a smoke test that works offline. Counting what is loaded
# is the check that matters: CMake carries on without an extension it could
# not build.
{
  pkgs,
  duckdb,
  extensions,
}:

let
  inherit (pkgs) lib;

  names = lib.concatMapStringsSep ", " (ext: "'${ext.name}'") extensions;

  smoke =
    ext:
    let
      s = ext.smoke;
      run = "${lib.getExe duckdb} -no-agent -bail -c ${lib.escapeShellArg s.sql}";
    in
    ''
      echo "smoke: ${ext.name}"
      ${s.setup}
    ''
    + (
      if s.expectError == null then
        ''
          ${run} >/dev/null
        ''
      else
        ''
          if output=$(${run} 2>&1); then
            echo "${ext.name}: expected a failure containing '${s.expectError}', but it succeeded" >&2
            exit 1
          fi
          grep -qF ${lib.escapeShellArg s.expectError} <<<"$output" || { echo "$output" >&2; exit 1; }
        ''
    );
in
pkgs.runCommand "duckdb-all-extensions-check" { } ''
  export HOME=$TMPDIR
  duckdb="${lib.getExe duckdb} -no-agent"

  not_loaded=$($duckdb -noheader -list -c \
    "SELECT extension_name FROM duckdb_extensions() WHERE extension_name IN (${names}) AND NOT loaded ORDER BY 1")
  [ -z "$not_loaded" ] || { echo "not loaded: $not_loaded" >&2; exit 1; }

  loaded=$($duckdb -noheader -list -c \
    "SELECT count(*) FROM duckdb_extensions() WHERE extension_name IN (${names}) AND loaded")
  [ "$loaded" = ${toString (lib.length extensions)} ] || {
    echo "expected ${toString (lib.length extensions)} loaded, got $loaded" >&2
    exit 1
  }

  ${lib.concatMapStrings smoke (lib.filter (ext: ext.smoke != null) extensions)}
  touch $out
''
