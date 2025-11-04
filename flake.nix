{

  description = "Nerves flake setup";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-23.11";
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixos-unstable";
  };

  outputs =
    { nixpkgs, nixpkgs-unstable, ... }:
    let


      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      overlays = [ ];

      forEachSupportedSystem =
        f:
        nixpkgs.lib.genAttrs supportedSystems (
          system:
          f {
            pkgs = import nixpkgs-unstable {
              inherit system;
              config.allowUnfree = true;
              inherit overlays;
            };
          }
        );

    in
    {

      devShells = forEachSupportedSystem (
        { pkgs }:
        {
          default = pkgs.mkShell {
            packages = with pkgs; [
              autoconf
              automake
              curl
              fwup
              libmnl
              git
              beamMinimal27Packages.erlang
              beamMinimal27Packages.elixir
              beamMinimal27Packages.rebar
              squashfsTools
              x11_ssh_askpass
              pkg-config
              qemu
              xdelta
              screen
              claude-code

              ## AVR
              pkgsCross.avr.stdenv.cc
              avrdude
            ];
          };
          shellHook = ''
            SUDO_ASKPASS=${pkgs.x11_ssh_askpass}/libexec/x11-ssh-askpass
          '';

        }
      );

    };

}
