# The description of an extension that DuckDB can be built with, for
# `duckdb.withExtensions`. Also the way to link an extension of your own, see
# templates/extension.
{ lib }:

{
  name,
  # The source: a directory with the extension's CMakeLists.txt, which calls
  # build_static_extension and build_loadable_extension as DuckDB's extension
  # template does. It is copied and may be patched, so it need not be writable.
  src,
  # what `duckdb_extensions()` reports as its version
  version,
  # where the extension's headers are, relative to `src`, when it is not src/include
  include ? null,
  buildInputs ? [ ],
  nativeBuildInputs ? [ ],
  # The Rust static library the extension links, if it has one: the package
  # that builds it, the archive inside it, and the CMake variable that is
  # given the archive's path (which is not always the package's, see
  # isolate-rust.nix).
  rust ? null,
  # CMake flags for the DuckDB build. Paths of other derivations go here
  # rather than into postPatch, so that patching never waits on a build.
  cmakeFlags ? [ ],
  # extensions that must be linked in before this one
  dependencies ? [ ],
  # C API extensions have their own build and can only be loaded at runtime
  linkable ? true,
  # why this nixpkgs cannot build the extension, if it cannot
  unsupported ? null,
  # What must work offline in a build containing the extension. Either SQL
  # that must succeed, or { sql; setup ? shell to run first; expectError ?
  # text the SQL must fail with }, for clients that need a server. `sql` can
  # be a list, each run as a command of its own: DuckDB parses a whole command
  # before running any of it, so a statement that changes the syntax has to
  # come in an earlier one.
  smoke ? null,
  # Tests of DuckDB's own suite that cannot pass once this extension is
  # linked in, as [ { reason; paths; } ] for SQL test scripts or
  # [ { reason; names; } ] for C++ test cases. Each needs a reason, because
  # skipping a test is giving up on it.
  testSkips ? [ ],
  # Tests that need an extension loaded which the suite would not load by
  # itself, as [ { reason; loads; tests; } ]. The suite loads only what a test
  # names, while the product loads everything linked at startup. Preloading for
  # the whole suite would break the tests that assert an extension is absent, so
  # these run on their own, with `loads` loaded, and are left out of the main run.
  testRuns ? [ ],
}:

{
  _type = "duckdbExtension";
  inherit
    name
    src
    version
    include
    buildInputs
    nativeBuildInputs
    rust
    cmakeFlags
    dependencies
    linkable
    unsupported
    testSkips
    testRuns
    ;
  smoke = lib.mapNullable (
    s:
    {
      setup = "";
      expectError = null;
    }
    // (if builtins.isString s then { sql = s; } else s)
  ) smoke;
}
