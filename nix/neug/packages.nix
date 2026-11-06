_:

{
  perSystem =
    {
      lib,
      forEachNixpkgs,
      ...
    }:
    {
      packages = forEachNixpkgs (
        nixpkgs:
        lib.optionalAttrs (lib.meta.availableOn nixpkgs.stdenv.hostPlatform nixpkgs.neug) {
          inherit (nixpkgs) neug;

          # the addon for Node.js, built with the library
          neug-nodejs = nixpkgs.neug.nodejs;

          # Development only: stop after CMake has configured
          dev-configure-neug = nixpkgs.neug.overrideAttrs {
            outputs = [ "out" ];
            dontBuild = true;
            dontFixup = true;
            installPhase = "touch $out";
            postInstall = "";
          };

          # Development only: build everything and keep going past failures, to see every
          # error of a build at once
          dev-keep-going-neug = nixpkgs.neug.overrideAttrs {
            ninjaFlags = [
              "-k"
              "0"
            ];
          };
        }
      );
    };
}
