# The packages of nixpkgs' azure-sdk-for-cpp that the azure extension links, for a
# nixpkgs that does not have it (25.11). They are copied as they are in nixpkgs 26.05,
# pkgs/development/libraries/azure-sdk-for-cpp (MIT, as nixpkgs). Delete them when
# the oldest nixpkgs that is supported has the package.
{
  lib,
  newScope,
  stdenv,
  cmake,
  ninja,
  curl,
  openssl,
}:
lib.makeScope newScope (
  self:
  let
    callPackage = self.callPackage;
  in
  {
    inherit
      stdenv
      cmake
      ninja
      curl
      openssl
      ;

    core = callPackage ./core.nix { };
    identity = callPackage ./identity.nix { };
    storage-blobs = callPackage ./storage-blobs.nix { };
    storage-common = callPackage ./storage-common.nix { };
    storage-files-datalake = callPackage ./storage-files-datalake.nix { };

    meta = {
      homepage = "https://azure.github.io/azure-sdk-for-cpp";
      description = "Azure SDK for C++";
      sourceProvenance = [ lib.sourceTypes.fromSource ];
      license = lib.licenses.mit;
      platforms = lib.platforms.all;
    };
  }
)
