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

      dnsServers = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        example = [ "10.2.255.251" "10.2.255.252" ];
        description = "DNS servers pushed by the VPN gateway, applied to ppp0 via resolvectl.";
      };

      dnsDomains = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        example = [ "~tce.go.gov.br" ];
        description = "Routing/search domains for ppp0 (prefix with ~ for routing-only).";
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

    # ── DNS — openresolv bridges openfortivpn ↔ systemd-resolved ─────────────
    # openfortivpn tries resolvconf binary first; without it, it falls back to
    # writing /etc/resolv.conf directly, which is read-only on NixOS.
    networking.resolvconf.enable = lib.mkDefault true;

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
        # openfortivpn looks for resolvconf in PATH; without it it tries to
        # write /etc/resolv.conf directly, which is read-only on NixOS.
        # Expose the openresolv binary so DNS is applied via resolvconf.
        Environment     = "PATH=/run/current-system/sw/bin:/run/wrappers/bin";
        Restart         = "on-failure";
        RestartSec      = "5s";
        # openfortivpn must run as root to manage ppp devices
        User            = "root";
        # ProtectSystem=strict would block resolvconf writing to /run/resolvconf
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

      after   = [ "workmode-vpn.service" ];
      bindsTo = [ "workmode-vpn.service" ];
      wantedBy = [ "default.target" ];

      # StartLimitIntervalSec belongs in unitConfig, not serviceConfig
      unitConfig = {
        StartLimitIntervalSec = "120s";
        StartLimitBurst       = 10;
      };

      serviceConfig = {
        Type       = "simple";
        ExecStart  = "${pkgs.openssh}/bin/ssh -D ${toString cfg.socks5.port} -q -N ${cfg.socks5.sshHost}";
        Restart    = "on-failure";
        RestartSec = "3s";
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
