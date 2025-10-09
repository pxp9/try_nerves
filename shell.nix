{ pkgs ? import <nixpkgs> {} }:

with pkgs;

mkShell {
  name = "nervesShell";
  buildInputs = [
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
  ];
  shellHook = ''
    SUDO_ASKPASS=${pkgs.x11_ssh_askpass}/libexec/x11-ssh-askpass
  '';
}
