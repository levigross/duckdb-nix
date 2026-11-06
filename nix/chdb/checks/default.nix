# What must work with the library and with the Python module, each with something that must
# fail, so that a check cannot pass by accident.
{ pkgs }:

let
  inherit (pkgs) chdb;
  chdbPython = chdb.pythonModule pkgs.python3Packages;
  withChdb = pkgs.python3.withPackages (_: [ chdbPython ]);
  # the same interpreter and the same dependencies, without chDB
  without = pkgs.python3.withPackages (ps: [
    ps.pandas
    ps.pyarrow
  ]);
in
{
  # A C program links libchdb, and the engine answers: a sum, the version of the pin, and a
  # round trip through Parquet. A wrong query must come back as an error.
  library = pkgs.runCommandCC "chdb-library-check" { } ''
    export HOME=$TMPDIR
    cd $TMPDIR

    cc -Wall -Werror ${./smoke.c} -I${chdb}/include -L${chdb}/lib -lchdb -o smoke
    readelf -d smoke | grep -q 'NEEDED.*libchdb'

    version="$(./smoke --version)"
    [ "$version" = "${chdb.version}" ] || {
      echo "the library says it is $version, the pin is ${chdb.version}" >&2
      exit 1
    }

    sum="$(./smoke 2>/dev/null)"
    echo "chdb $version: the sum of 1 to 100 is $sum"
    [ "$sum" = 5050 ] || { echo "the sum is not 5050" >&2; exit 1; }

    ./smoke "INSERT INTO FUNCTION file('t.parquet', Parquet) SELECT number AS n FROM numbers(1000)" 2>/dev/null
    [ "$(./smoke "SELECT sum(n) FROM file('t.parquet', Parquet)" 2>/dev/null)" = 499500 ] || {
      echo "the Parquet file did not read back" >&2
      exit 1
    }

    ./smoke "SELECT sum(n) FROM file('t.parquet', Parquet)" 2>/dev/null | sed "s/^/parquet sum: /"

    if ./smoke "SELECT * FROM no_such_table" >/dev/null 2>error; then
      echo "a query of a table that does not exist did not fail" >&2
      exit 1
    fi
    grep -qi 'no_such_table' error
    echo "the wrong query failed, as it should: $(grep -i -m1 no_such_table error | head -c 120)"

    touch $out
  '';
  # A Rust program linked against libchdb through the chdb-rust crate.
  rust-consumer = import ./rust-consumer.nix { inherit pkgs chdb; };

  # The Python module answers, hands a result to pandas, and keeps a table in a session
  # that is opened again. The same script without the module must fail.
  python =
    let
      script = pkgs.writeText "chdb-check.py" ''
        import chdb
        from chdb import session

        assert str(chdb.query("SELECT sum(number + 1) FROM numbers(100)", "CSV")).strip() == "5050"

        frame = chdb.query("SELECT number AS n, toString(number) AS s FROM numbers(3)", "DataFrame")
        assert frame["n"].tolist() == [0, 1, 2], frame

        path = "session"
        first = session.Session(path)
        first.query("CREATE DATABASE d")
        first.query("CREATE TABLE d.t (id UInt32) ENGINE = MergeTree ORDER BY id")
        first.query("INSERT INTO d.t SELECT number FROM numbers(10)")
        first.close()

        second = session.Session(path)
        assert str(second.query("SELECT sum(id) FROM d.t", "CSV")).strip() == "45"
        second.close()
        print("chdb", chdb.__version__, "works")
      '';
    in
    pkgs.runCommand "chdb-python-check" { } ''
      export HOME=$TMPDIR
      cd $TMPDIR
      ${withChdb}/bin/python ${script}

      if ${without}/bin/python ${script} >/dev/null 2>&1; then
        echo "the script worked without chdb, so this check proves nothing" >&2
        exit 1
      fi
      touch $out
    '';
}
