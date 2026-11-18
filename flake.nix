{
  description = "yggdra development environment";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { nixpkgs, ... }:
    let
      inherit (nixpkgs) lib;
      # The MVP targets Linux only.
      forAllSystems =
        f:
        lib.genAttrs [
          "x86_64-linux"
          "aarch64-linux"
        ] (system: f nixpkgs.legacyPackages.${system});
    in
    {
      devShells = forAllSystems (pkgs: {
        # Not mkShellNoCC: its linker setup hook puts raylib on the search path and runpath of Odin programs.
        default = pkgs.mkShell {
          packages = [
            pkgs.go_1_27
            pkgs.gopls
            pkgs.odin
            # Also provides odinfmt.
            pkgs.ols
          ];
          # nixpkgs' Odin links vendor:raylib against the system raylib instead of the bundled one.
          buildInputs = [ pkgs.raylib ];

          env.GOTOOLCHAIN = "local";
        };
      });

      checks = forAllSystems (pkgs: {
        # vendor:raylib binds one raylib version; linking another breaks the ABI without an error.
        raylib-binding = pkgs.runCommand "raylib-binding" { } ''
          binding=${pkgs.odin}/share/vendor/raylib/raylib.odin
          if ! grep -Eq '^VERSION[[:space:]]*::[[:space:]]*"${lib.escapeRegex pkgs.raylib.version}"' "$binding"; then
            echo "raylib ${pkgs.raylib.version} does not match the version vendor:raylib binds:" >&2
            grep -E '^VERSION[[:space:]]*::' "$binding" >&2
            exit 1
          fi
          touch $out
        '';
      });

      formatter = forAllSystems (pkgs: pkgs.nixfmt-tree);
    };
}
