{ pkgs }:

let
  inherit (pkgs) lib duckdb;

  withHttpfs = duckdb.withExtensions (e: [ e.httpfs ]);

  linkable = lib.filter (ext: ext.linkable) (lib.attrValues duckdb.extensions);
  withAll = duckdb.withExtensions (_: linkable);
in
{
  # Every extension must be the commit the DuckDB release pins.
  extension-pins =
    let
      checkPin = ext: ''
        check ${
          lib.escapeShellArgs [
            ext.name
            "https://github.com/${ext.owner}/${ext.repo}"
            ext.rev
          ]
        }
      '';
    in
    pkgs.runCommand "duckdb-extension-pins" { } ''
      status=0
      check() {
        config=${duckdb.src}/.github/config/extensions/$1.cmake
        if [ ! -f "$config" ]; then
          echo "$1: duckdb ${duckdb.version} has no $config" >&2
          status=1
          return
        fi
        url=$(awk '$1 == "GIT_URL" { print $2; exit }' "$config")
        tag=$(awk '$1 == "GIT_TAG" { print $2; exit }' "$config")
        if [ "$url" != "$2" ] || [ "$tag" != "$3" ]; then
          echo "$1: duckdb ${duckdb.version} pins $url@$tag, packaged $2@$3" >&2
          status=1
        fi
      }
      ${lib.concatMapStrings checkPin (lib.attrValues duckdb.extensions)}
      [ "$status" -eq 0 ]
      touch $out
    '';

  # Reads a CSV over HTTP, which needs httpfs. The same query must fail
  # without it, so the check cannot pass by accident.
  httpfs = pkgs.runCommand "duckdb-httpfs-check" { nativeBuildInputs = [ pkgs.python3 ]; } ''
    export HOME=$TMPDIR
    mkdir www
    printf 'a,b\n1,2\n3,4\n' > www/t.csv
    python3 -m http.server 18765 --bind 127.0.0.1 --directory www >/dev/null 2>&1 &
    server=$!
    trap 'kill $server' EXIT
    for _ in $(seq 100); do
      (exec 3<>/dev/tcp/127.0.0.1/18765) 2>/dev/null && break
      sleep 0.1
    done

    query="SELECT sum(b) FROM read_csv('http://127.0.0.1:18765/t.csv')"

    if ${lib.getExe duckdb} -c "$query" >/dev/null 2>&1; then
      echo "plain duckdb read over http, so this check proves nothing" >&2
      exit 1
    fi

    sum=$(${lib.getExe withHttpfs} -noheader -list -c "$query")
    [ "$sum" = 6 ] || { echo "expected 6, got '$sum'" >&2; exit 1; }

    ${lib.getExe withHttpfs} -noheader -list \
      -c "SELECT extension_name FROM duckdb_extensions() WHERE loaded AND extension_name = 'httpfs'" |
      grep -qx httpfs
    touch $out
  '';

  all-extensions = import ./all-extensions-check.nix {
    inherit pkgs;
    duckdb = withAll;
    extensions = linkable;
  };
}
