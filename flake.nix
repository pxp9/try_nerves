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
              config = {
                allowUnfree = true;
                permittedInsecurePackages = [ "mbedtls-2.28.10" ];
              };
              inherit overlays;
            };
            pkgs-stable = import nixpkgs {
              inherit system;
              config.allowUnfree = true;
            };
          }
        );
    in
    {
      devShells = forEachSupportedSystem (
        { pkgs, pkgs-stable }:
        {
          default = pkgs.mkShell {
            packages =
              with pkgs;
              [
                autoconf
                automake
                curl
                fwup
                libmnl
                git
                beamMinimal27Packages.erlang
                beamMinimal27Packages.elixir
                beamMinimal27Packages.rebar3
                squashfsTools
                x11_ssh_askpass
                pkg-config
                qemu
                xdelta
                screen
                claude-code
                elixir-ls
                inetutils

                ## AVR
                pkgsCross.avr.stdenv.cc
                avrdude

                ## AtomVM / Pico
                gcc-arm-embedded
                picotool
                mbedtls_2
                zlib
                ninja
                doxygen
                python3
                gperf
              ]
              ++ [
                pkgs-stable.cmake
              ];

            shellHook = ''
              export SUDO_ASKPASS=${pkgs.x11_ssh_askpass}/libexec/x11-ssh-askpass

              # Create a local lib directory for symlinks
              mkdir -p .nix-shell-libs

              # Create symlinks for mbedtls with the expected soname
              ln -sf ${pkgs.mbedtls_2}/lib/libmbedtls.so.14 .nix-shell-libs/libmbedtls.so.10
              ln -sf ${pkgs.mbedtls_2}/lib/libmbedcrypto.so.7 .nix-shell-libs/libmbedcrypto.so.1
              ln -sf ${pkgs.mbedtls_2}/lib/libmbedx509.so.1 .nix-shell-libs/libmbedx509.so.1

              export LD_LIBRARY_PATH="$PWD/.nix-shell-libs:${
                pkgs.lib.makeLibraryPath [
                  pkgs.zlib
                  pkgs.mbedtls_2
                ]
              }:$LD_LIBRARY_PATH"

              # Add RISC-V toolchain to PATH if it exists
              # curl https://github.com/raspberrypi/pico-sdk-tools/releases/download/v2.2.0-3/riscv-toolchain-15-x86_64-lin.tar.gz
              export RISCV_TOOLCHAIN="$PWD/atom_vm_firmware/riscv-toolchain-15-x86_64-lin/bin"
              if [ -d "$RISCV_TOOLCHAIN" ]; then
                export PATH="$RISCV_TOOLCHAIN:$PATH"
                # export PICO_TOOLCHAIN_PATH="$RISCV_TOOLCHAIN"
              fi
            '';
          };

        }
      );

    };

}
