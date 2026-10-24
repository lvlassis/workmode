{
  description = "Work Mode — systemd services for connecting to the work network";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }: {
    nixosModules.workmode = import ./modules/workmode.nix;
    nixosModules.default = self.nixosModules.workmode;
  };
}
