# The Python module of NeuG, for one Python: the package `neug` (pure Python, from
# tools/python_bind of the sources of NeuG) and the module neug_py_bind that it imports,
# which is compiled here against the installed NeuG instead of inside the build of NeuG. That
# costs five files and not the 1900 steps of the library, and it is not repeated for every
# Python the library is not built again for.
#
# What the wheel of NeuG does is done in the layout it makes: neug_py_bind*.so at the root of
# site-packages, next to the package. The library is not copied next to it, as the wheel
# does: the module is linked to the one of the package neug.
{
  lib,
  stdenv,
  buildPythonPackage,
  python,
  runCommand,
  cmake,
  ninja,
  setuptools,
  wheel,
  pybind11,
  neug,
  packaging,
  protobuf5,
  requests,
  click,
  prompt-toolkit,
  tabulate,
  pyyaml,
  tqdm,
  flask,
  flask-cors,
}:

let
  pin = lib.importJSON ./pin.json;

  # setup.py asks the sources for nothing outside tools/python_bind except the version
  source = runCommand "neug-python-source-${neug.version}" { } ''
    mkdir -p $out/tools
    cp -r ${neug.src}/tools/python_bind $out/tools/python_bind
    cp ${neug.src}/NEUG_VERSION $out/NEUG_VERSION
    chmod -R u+w $out
  '';

  # the five files of the binding, the linker's version script and the CMake file of this
  # repository, in one tree
  bindingSource = runCommand "neug-py-bind-source-${neug.version}" { } ''
    mkdir -p $out
    cp -r ${neug.src}/tools/python_bind/src $out/src
    cp ${neug.src}/cmake/neug_exports.ld $out/neug_exports.ld
    cp ${./python/CMakeLists.txt} $out/CMakeLists.txt
  '';

  binding = stdenv.mkDerivation {
    pname = "neug-py-bind-python${python.pythonVersion}";
    inherit (neug) version;
    src = bindingSource;

    postPatch = ''
      # The sources include pybind11 as "pybind11/include/pybind11/...", the layout of the
      # copy that NeuG carries; the one used here has its headers under pybind11/
      substituteInPlace src/*.cc src/*.h --replace-quiet 'pybind11/include/pybind11/' 'pybind11/'

      # pybind11 3.1 asks that what a bound method returns by value can be converted to
      # itself, which for an rvalue is its move constructor, and PyConnection deletes it. It
      # is only ever returned by value, so it may have one: the members are a reference and a
      # shared_ptr.
      substituteInPlace src/py_connection.h --replace-fail \
        'PyConnection(PyConnection&& other) = delete;' \
        'PyConnection(PyConnection&& other) = default;'
    '';

    strictDeps = true;
    nativeBuildInputs = [
      cmake
      ninja
    ];
    buildInputs = [
      python
      pybind11
      neug
    ];

    cmakeFlags = [
      (lib.cmakeFeature "Python_EXECUTABLE" python.interpreter)
      (lib.cmakeBool "PYBIND11_FINDPYTHON" true)
    ];

    meta.description = "The module neug_py_bind of NeuG, for Python ${python.pythonVersion}";
  };
in
buildPythonPackage {
  pname = "neug";
  inherit (neug) version;
  pyproject = true;

  src = source;
  sourceRoot = "${source.name}/tools/python_bind";

  postPatch = ''
    # The module is built apart, so nothing here runs CMake: the extension and the commands
    # that build and copy it (one entry of cmdclass each, left as an empty dictionary) go
    substituteInPlace setup.py \
      --replace-fail 'ext_modules=[CMakeExtension(name="neug_py_bind", sourcedir=repo_root)],' "" \
      --replace-fail '"build_py": BuildExtFirst,' "" \
      --replace-fail '"build_ext": CMakeBuild,' "" \
      --replace-fail '"build_proto": BuildProto,' "" \
      --replace-fail '"install_lib": InstallLib,' ""

    # LOAD looks where the package neug has its extensions, and not in the directory of the
    # wheel, which the module sits in. NEUG_EXTENSION_HOME_PYENV still overrides it.
    substituteInPlace neug/__init__.py --replace-fail \
      '        _extension_home = _bind_dir or os.path.join(os.path.dirname(__file__), "..")' \
      '        _extension_home = "${neug}/lib"'
  '';

  # what the build requires, as pyproject.toml lists it (protobuf and packaging for the
  # commands of setup.py that are not run here)
  build-system = [
    setuptools
    wheel
    pybind11
    protobuf5
    packaging
  ];

  dependencies = [
    packaging
    protobuf5
    requests
    click
    prompt-toolkit
    tabulate
    pyyaml
    tqdm
    flask
    flask-cors
  ];

  postInstall = ''
    site=$out/${python.sitePackages}
    install -m755 ${binding}/lib/neug_py_bind*.so $site/
    printf '__commit__ = "%s"\n' ${pin.rev} > $site/neug/_commit.py
  '';

  pythonImportsCheck = [ "neug" ];

  passthru = {
    inherit binding;
  };

  meta = {
    description = "NeuG, an embedded graph database, for Python";
    homepage = "https://github.com/alibaba/neug";
    license = lib.licenses.asl20;
    platforms = lib.platforms.linux;
  };
}
