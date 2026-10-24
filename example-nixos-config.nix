# Example: how to import workmode in your NixOS flake
#
# In your dotfiles flake.nix inputs:
#   workmode.url = "github:lvinicius/workmode";   # or path:./workmode
#
# Then in your NixOS configuration:

{ inputs, ... }: {
  imports = [ inputs.workmode.nixosModules.default ];

  services.workmode = {
    enable   = true;
    user     = "senku";          # your login user
    vpn.configFile = "/home/senku/.config/openfortivpn/config";
    socks5 = {
      port    = 1080;
      sshHost = "fedora";        # alias in ~/.ssh/config
    };
  };
}
