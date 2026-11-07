# Whether the Python module of NeuG can be built with a nixpkgs. It requires exactly one version of
# protobuf (pin.json has it, from pyproject.toml of upstream), for the Python package and for the
# C++ library it bundles, and a nixpkgs with another one fails the build with "Missing
# dependencies: protobuf==X" (25.11 has 5.29.5: not built, see docs/neug.md). It is not offered
# there.
pkgs:
pkgs.python3Packages.protobuf5.version == (pkgs.lib.importJSON ../../pkgs/neug/pin.json)
.python.protobuf
