{ config, lib, pkgs, ... }:

let
  cfg = config.services.workmode;
in {
  options.services.workmode = {
    enable = lib.mkEnableOption "Work Mode (VPN + SOCKS5 tunnel)";

    vpn = {
      configFile = lib.mkOption {
        type = lib.types.path;
        default = "/home/${cfg.user}/.config/openfortivpn/config";
        description = "Path to openfortivpn config file.";
      };
    };

    socks5 = {
      port = lib.mkOption {
        type = lib.types.port;
        default = 1080;
        description = "Local port for the SOCKS5 proxy.";
      };

      sshHost = lib.mkOption {
        type = lib.types.str;
        default = "fedora";
        description = "SSH host alias (from ~/.ssh/config) used as bastion.";
      };
    };

    user = lib.mkOption {
      type = lib.types.str;
      description = "User account that owns the SSH tunnel service.";
    };
  };

  config = lib.mkIf cfg.enable {

    # ── System packages ────────────────────────────────────────────────────────
    environment.systemPackages = [ pkgs.openfortivpn ];

    # ── VPN — system service (needs root to create ppp0) ─────────────────────
    systemd.services.workmode-vpn = {
      description = "Work Mode VPN (openfortivpn)";
      after       = [ "network-online.target" ];
      wants       = [ "network-online.target" ];
      # workmode.target pulls this in
      wantedBy    = [ "workmode.target" ];

      serviceConfig = {
        Type            = "notify";
        NotifyAccess    = "all";
        ExecStart       = "${pkgs.openfortivpn}/bin/openfortivpn --config=${cfg.vpn.configFile}";
        Restart         = "on-failure";
        RestartSec      = "5s";
        # openfortivpn must run as root to manage ppp devices
        User            = "root";
        # Harden what we can while still allowing ppp
        ProtectSystem   = "strict";
        ProtectHome     = "read-only";
        PrivateTmp      = true;
        NoNewPrivileges = false; # ppp helper needs this
        AmbientCapabilities = [ "CAP_NET_ADMIN" "CAP_NET_RAW" ];
      };
    };

    # ── Target — aggregate handle for `systemctl start workmode.target` ───────
    systemd.targets.workmode = {
      description = "Work Mode";
      # Bringing up the target also starts all units that WantedBy it.
      # Stopping the target propagates StopWhenUnneededBy semantics; explicit
      # stop of the target will stop its wants because of the BindsTo on the
      # tunnel unit below.
    };

    # ── SOCKS5 tunnel — user service, after VPN interface is up ──────────────
    systemd.user.services.workmode-tunnel = {
      description = "Work Mode SOCKS5 tunnel (ssh -D)";

      # Wait for the system-level VPN service. The sd_notify dance means ppp0
      # exists once workmode-vpn.service reaches active(running).
      after  = [ "workmode-vpn.service" ];
      # If the VPN dies the tunnel is useless — tear it down too.
      bindsTo = [ "workmode-vpn.service" ];
      wantedBy = [ "default.target" ]; # activated by the target slice below

      serviceConfig = {
        Type       = "simple";
        ExecStart  = "${pkgs.openssh}/bin/ssh -D ${toString cfg.socks5.port} -q -N ${cfg.socks5.sshHost}";
        # Retry: VPN might take a moment to finish routing
        Restart    = "on-failure";
        RestartSec = "3s";
        # Keep trying for up to 2 min before giving up on this activation
        StartLimitIntervalSec = "120s";
        StartLimitBurst       = "10";
      };
    };

    # ── Polkit — let the workmode user start/stop the system services ─────────
    security.polkit.extraConfig = ''
      polkit.addRule(function(action, subject) {
        var workmodActions = [
          "org.freedesktop.systemd1.manage-units"
        ];
        if (workmodActions.indexOf(action.id) !== -1 &&
            subject.user === "${cfg.user}" &&
            (action.lookup("unit") === "workmode.target"     ||
             action.lookup("unit") === "workmode-vpn.service")) {
          return polkit.Result.YES;
        }
      });
    '';
  };
}
