# nanobind 3, which the Python module of DuckDB 2.0 is written with. nixpkgs has it
# from its unstable (python3Packages.nanobind_3), and not yet in 25.11 and 26.05; this
# is that package, without its tests, for those. Delete it when they have it.
{
  lib,
  buildPythonPackage,
  fetchFromGitHub,
  cmake,
  ninja,
  pathspec,
  scikit-build-core,
  eigen,
}:
buildPythonPackage (finalAttrs: {
  pname = "nanobind";
  version = "3.1.0";
  pyproject = true;
  __structuredAttrs = true;

  src = fetchFromGitHub {
    owner = "wjakob";
    repo = "nanobind";
    tag = "v${finalAttrs.version}";
    fetchSubmodules = true;
    hash = "sha256-k7TIsx+BcOaZKC01cMs4ZqCWG2uWbx1TkilbMq1qkdI=";
  };

  build-system = [
    cmake
    ninja
    pathspec
    scikit-build-core
  ];

  dependencies = [ eigen ];

  dontUseCmakeBuildDir = true;

  # the tests need numpy, scipy, torch and more
  doCheck = false;

  meta = {
    homepage = "https://github.com/wjakob/nanobind";
    changelog = "https://github.com/wjakob/nanobind/blob/${finalAttrs.src.tag}/docs/changelog.rst";
    description = "Tiny and efficient C++/Python bindings";
    license = lib.licenses.bsd3;
  };
})
