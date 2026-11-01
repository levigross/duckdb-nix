{ pkgs }:

let
  inherit (pkgs) lib duckdb;

  withHttpfs = duckdb.withExtensions (e: [ e.httpfs ]);

  linkable = duckdb.linkableExtensions;
  withAll = duckdb.withExtensions (_: linkable);
in
{
  extension-pins = import ./extension-pins.nix { inherit pkgs; };

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

  all-extensions = import ./all-extensions.nix {
    inherit pkgs;
    duckdb = withAll;
    extensions = linkable;
  };

  # A Rust program linked against libduckdb finds the extensions.
  rust-consumer = import ./rust-consumer.nix {
    inherit pkgs;
    duckdb = withAll;
    extensions = linkable;
  };
}
