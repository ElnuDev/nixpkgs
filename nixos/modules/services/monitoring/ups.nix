{ config, lib, pkgs, ... }:

# TODO: This is not secure, have a look at the file docs/security.txt inside
# the project sources.
with lib;

let
  cfg = config.power.ups;
  defaultPort = 3493;

  nutFormat = {

    type = with lib.types; let

      singleAtom = nullOr (oneOf [
        bool
        int
        float
        str
      ]) // {
        description = "atom (null, bool, int, float or string)";
      };

      in attrsOf (oneOf [
        singleAtom
        (listOf (nonEmptyListOf singleAtom))
      ]);

    generate = name: value:
      let
        normalizedValue =
          lib.mapAttrs (key: val:
            if lib.isList val
            then forEach val (elem: if lib.isList elem then elem else [elem])
            else
              if val == null
              then []
              else [[val]]
          ) value;

        mkValueString = concatMapStringsSep " " (v:
          let str = generators.mkValueStringDefault {} v;
          in
            # Quote the value if it has spaces and isn't already quoted.
            if (hasInfix " " str) && !(hasPrefix "\"" str && hasSuffix "\"" str)
            then "\"${str}\""
            else str
        );

      in pkgs.writeText name (lib.generators.toKeyValue {
        mkKeyValue = generators.mkKeyValueDefault { inherit mkValueString; } " ";
        listsAsDuplicateKeys = true;
      } normalizedValue);

  };

  installSecrets = source: target: secrets:
    pkgs.writeShellScript "installSecrets.sh" ''
      install -m0600 -D ${source} "${target}"
      ${concatLines (forEach secrets (name: ''
        ${pkgs.replace-secret}/bin/replace-secret \
          '@${name}@' \
          "$CREDENTIALS_DIRECTORY/${name}" \
          "${target}"
      ''))}
      chmod u-w "${target}"
    '';

  upsmonConf = nutFormat.generate "upsmon.conf" cfg.upsmon.settings;

  upsdUsers = pkgs.writeText "upsd.users" (let
    # This looks like INI, but it's not quite because the
    # 'upsmon' option lacks a '='. See: man upsd.users
    userConfig = name: user: concatStringsSep "\n      " (concatLists [
      [
        "[${name}]"
        "password = \"@upsdusers_password_${name}@\""
      ]
      (optional (user.upsmon != null) "upsmon ${user.upsmon}")
      (forEach user.actions (action: "actions = ${action}"))
      (forEach user.instcmds (instcmd: "instcmds = ${instcmd}"))
    ]);
  in concatStringsSep "\n\n" (mapAttrsToList userConfig cfg.users));


  upsOptions = {name, config, ...}:
  {
    options = {
      # This can be inferred from the UPS model by looking at
      # /nix/store/nut/share/driver.list
      driver = mkOption {
        type = types.str;
        description = ''
          Specify the program to run to talk to this UPS.  apcsmart,
          bestups, and sec are some examples.
        '';
      };

      port = mkOption {
        type = types.str;
        description = ''
          The serial port to which your UPS is connected.  /dev/ttyS0 is
          usually the first port on Linux boxes, for example.
        '';
      };

      shutdownOrder = mkOption {
        default = 0;
        type = types.int;
        description = ''
          When you have multiple UPSes on your system, you usually need to
          turn them off in a certain order.  upsdrvctl shuts down all the
          0s, then the 1s, 2s, and so on.  To exclude a UPS from the
          shutdown sequence, set this to -1.
        '';
      };

      maxStartDelay = mkOption {
        default = null;
        type = types.uniq (types.nullOr types.int);
        description = ''
          This can be set as a global variable above your first UPS
          definition and it can also be set in a UPS section.  This value
          controls how long upsdrvctl will wait for the driver to finish
          starting.  This keeps your system from getting stuck due to a
          broken driver or UPS.
        '';
      };

      description = mkOption {
        default = "";
        type = types.str;
        description = ''
          Description of the UPS.
        '';
      };

      directives = mkOption {
        default = [];
        type = types.listOf types.str;
        description = ''
          List of configuration directives for this UPS.
        '';
      };

      summary = mkOption {
        default = "";
        type = types.lines;
        description = ''
          Lines which would be added inside ups.conf for handling this UPS.
        '';
      };

    };

    config = {
      directives = mkOrder 10 ([
        "driver = ${config.driver}"
        "port = ${config.port}"
        ''desc = "${config.description}"''
        "sdorder = ${toString config.shutdownOrder}"
      ] ++ (optional (config.maxStartDelay != null)
            "maxstartdelay = ${toString config.maxStartDelay}")
      );

      summary =
        concatStringsSep "\n      "
          (["[${name}]"] ++ config.directives);
    };
  };

  listenOptions = {
    options = {
      address = mkOption {
        type = types.str;
        description = ''
          Address of the interface for `upsd` to listen on.
          See `man upsd.conf` for details.
        '';
      };

      port = mkOption {
        type = types.port;
        default = defaultPort;
        description = ''
          TCP port for `upsd` to listen on.
          See `man upsd.conf` for details.
        '';
      };
    };
  };

  upsdOptions = {
    options = {
      enable = mkOption {
        type = types.bool;
        defaultText = literalMD "`true` if `mode` is one of `standalone`, `netserver`";
        description = "Whether to enable `upsd`.";
      };

      listen = mkOption {
        type = with types; listOf (submodule listenOptions);
        default = [];
        example = [
          {
            address = "192.168.50.1";
          }
          {
            address = "::1";
            port = 5923;
          }
        ];
        description = ''
          Address of the interface for `upsd` to listen on.
          See `man upsd` for details`.
        '';
      };

      extraConfig = mkOption {
        type = types.lines;
        default = "";
        description = ''
          Additional lines to add to `upsd.conf`.
        '';
      };
    };

    config = {
      enable = mkDefault (elem cfg.mode [ "standalone" "netserver" ]);
    };
  };


  monitorOptions = { name, config, ... }: {
    options = {
      system = mkOption {
        type = types.str;
        default = name;
        description = ''
          Identifier of the UPS to monitor, in this form: `<upsname>[@<hostname>[:<port>]]`
          See `upsmon.conf` for details.
        '';
      };

      powerValue = mkOption {
        type = types.int;
        default = 1;
        description = ''
          Number of power supplies that the UPS feeds on this system.
          See `upsmon.conf` for details.
        '';
      };

      user = mkOption {
        type = types.str;
        description = ''
          Username from `upsd.users` for accessing this UPS.
          See `upsmon.conf` for details.
        '';
      };

      passwordFile = mkOption {
        type = types.str;
        defaultText = literalMD "power.ups.users.\${user}.passwordFile";
        description = ''
          The full path to a file containing the password from
          `upsd.users` for accessing this UPS. The password file
          is read on service start.
          See `upsmon.conf` for details.
        '';
      };

      type = mkOption {
        type = types.str;
        default = "master";
        description = ''
          The relationship with `upsd`.
          See `upsmon.conf` for details.
        '';
      };
    };

    config = {
      passwordFile = mkDefault cfg.users.${config.user}.passwordFile;
    };
  };

  upsmonOptions = {
    options = {
      enable = mkOption {
        type = types.bool;
        defaultText = literalMD "`true` if `mode` is one of `standalone`, `netserver`, `netclient`";
        description = "Whether to enable `upsmon`.";
      };

      monitor = mkOption {
        type = with types; attrsOf (submodule monitorOptions);
        default = {};
        description = ''
          Set of UPS to monitor. See `man upsmon.conf` for details.
        '';
      };

      settings = mkOption {
        type = nutFormat.type;
        default = {};
        defaultText = literalMD ''
          {
            MINSUPPLIES = 1;
            RUN_AS_USER = "root";
            NOTIFYCMD = "''${pkgs.nut}/bin/upssched";
            SHUTDOWNCMD = "''${pkgs.systemd}/bin/shutdown now";
          }
        '';
        description = "Additional settings to add to `upsmon.conf`.";
        example = literalMD ''
          {
            MINSUPPLIES = 2;
            NOTIFYFLAG = [
              [ "ONLINE" "SYSLOG+EXEC" ]
              [ "ONBATT" "SYSLOG+EXEC" ]
            ];
          }
        '';
      };
    };

    config = {
      enable = mkDefault (elem cfg.mode [ "standalone" "netserver" "netclient" ]);
      settings = {
        RUN_AS_USER = "root"; # TODO: replace 'root' by another username.
        MINSUPPLIES = mkDefault 1;
        NOTIFYCMD = mkDefault "${pkgs.nut}/bin/upssched";
        SHUTDOWNCMD = mkDefault "${pkgs.systemd}/bin/shutdown now";
        MONITOR = flip mapAttrsToList cfg.upsmon.monitor (name: monitor: with monitor; [ system powerValue user "\"@upsmon_password_${name}@\"" type ]);
      };
    };
  };

  userOptions = {
    options = {
      passwordFile = mkOption {
        type = types.str;
        description = ''
          The full path to a file that contains the user's (clear text)
          password. The password file is read on service start.
        '';
      };

      actions = mkOption {
        type = with types; listOf str;
        default = [];
        description = ''
          Allow the user to do certain things with upsd.
          See `man upsd.users` for details.
        '';
      };

      instcmds = mkOption {
        type = with types; listOf str;
        default = [];
        description = ''
          Let the user initiate specific instant commands. Use "ALL" to grant all commands automatically. For the full list of what your UPS supports, use "upscmd -l".
          See `man upsd.users` for details.
        '';
      };

      upsmon = mkOption {
        type = with types; nullOr (enum [ "primary" "secondary" ]);
        default = null;
        description = ''
          Add the necessary actions for a upsmon process to work.
          See `man upsd.users` for details.
        '';
      };
    };
  };

in


{
  options = {
    # powerManagement.powerDownCommands

    power.ups = {
      enable = mkEnableOption ''
        support for Power Devices, such as Uninterruptible Power
        Supplies, Power Distribution Units and Solar Controllers
      '';

      mode = mkOption {
        default = "standalone";
        type = types.enum [ "none" "standalone" "netserver" "netclient" ];
        description = ''
          The MODE determines which part of the NUT is to be started, and
          which configuration files must be modified.

          The values of MODE can be:

          - none: NUT is not configured, or use the Integrated Power
            Management, or use some external system to startup NUT
            components. So nothing is to be started.

          - standalone: This mode address a local only configuration, with 1
            UPS protecting the local system. This implies to start the 3 NUT
            layers (driver, upsd and upsmon) and the matching configuration
            files. This mode can also address UPS redundancy.

          - netserver: same as for the standalone configuration, but also
            need some more ACLs and possibly a specific LISTEN directive in
            upsd.conf.  Since this MODE is opened to the network, a special
            care should be applied to security concerns.

          - netclient: this mode only requires upsmon.
        '';
      };

      schedulerRules = mkOption {
        example = "/etc/nixos/upssched.conf";
        type = types.str;
        description = ''
          File which contains the rules to handle UPS events.
        '';
      };

      openFirewall = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Open ports in the firewall for `upsd`.
        '';
      };

      maxStartDelay = mkOption {
        default = 45;
        type = types.int;
        description = ''
          This can be set as a global variable above your first UPS
          definition and it can also be set in a UPS section.  This value
          controls how long upsdrvctl will wait for the driver to finish
          starting.  This keeps your system from getting stuck due to a
          broken driver or UPS.
        '';
      };

      upsmon = mkOption {
        default = {};
        description = ''
          Options for the `upsmon.conf` configuration file.
        '';
        type = types.submodule upsmonOptions;
      };

      upsd = mkOption {
        default = {};
        description = ''
          Options for the `upsd.conf` configuration file.
        '';
        type = types.submodule upsdOptions;
      };

      ups = mkOption {
        default = {};
        # see nut/etc/ups.conf.sample
        description = ''
          This is where you configure all the UPSes that this system will be
          monitoring directly.  These are usually attached to serial ports,
          but USB devices are also supported.
        '';
        type = with types; attrsOf (submodule upsOptions);
      };

      users = mkOption {
        default = {};
        description = ''
          Users that can access upsd. See `man upsd.users`.
        '';
        type = with types; attrsOf (submodule userOptions);
      };

    };
  };

  config = mkIf cfg.enable {

    assertions = [
      (let
        totalPowerValue = foldl' add 0 (map (monitor: monitor.powerValue) (attrValues cfg.upsmon.monitor));
        minSupplies = cfg.upsmon.settings.MINSUPPLIES;
      in mkIf cfg.upsmon.enable {
        assertion = totalPowerValue >= minSupplies;
        message = ''
          `power.ups.upsmon`: Total configured power value (${toString totalPowerValue}) must be at least MINSUPPLIES (${toString minSupplies}).
        '';
      })
    ];

    environment.systemPackages = [ pkgs.nut ];

    networking.firewall = mkIf cfg.openFirewall {
      allowedTCPPorts =
        if cfg.upsd.listen == []
        then [ defaultPort ]
        else unique (forEach cfg.upsd.listen (listen: listen.port));
    };

    systemd.services.upsmon = let
      secrets = mapAttrsToList (name: monitor: "upsmon_password_${name}") cfg.upsmon.monitor;
      createUpsmonConf = installSecrets upsmonConf "/run/nut/upsmon.conf" secrets;
    in {
      enable = cfg.upsmon.enable;
      description = "Uninterruptible Power Supplies (Monitor)";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "forking";
        ExecStartPre = "${createUpsmonConf}";
        ExecStart = "${pkgs.nut}/sbin/upsmon";
        ExecReload = "${pkgs.nut}/sbin/upsmon -c reload";
        LoadCredential = mapAttrsToList (name: monitor: "upsmon_password_${name}:${monitor.passwordFile}") cfg.upsmon.monitor;
      };
      environment.NUT_CONFPATH = "/etc/nut";
      environment.NUT_STATEPATH = "/var/lib/nut";
    };

    systemd.services.upsd = let
      secrets = mapAttrsToList (name: user: "upsdusers_password_${name}") cfg.users;
      createUpsdUsers = installSecrets upsdUsers "/run/nut/upsd.users" secrets;
    in {
      enable = cfg.upsd.enable;
      description = "Uninterruptible Power Supplies (Daemon)";
      after = [ "network.target" "upsmon.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "forking";
        ExecStartPre = "${createUpsdUsers}";
        # TODO: replace 'root' by another username.
        ExecStart = "${pkgs.nut}/sbin/upsd -u root";
        ExecReload = "${pkgs.nut}/sbin/upsd -c reload";
        LoadCredential = mapAttrsToList (name: user: "upsdusers_password_${name}:${user.passwordFile}") cfg.users;
      };
      environment.NUT_CONFPATH = "/etc/nut";
      environment.NUT_STATEPATH = "/var/lib/nut";
      restartTriggers = [
        config.environment.etc."nut/upsd.conf".source
      ];
    };

    systemd.services.upsdrv = {
      enable = cfg.upsd.enable;
      description = "Uninterruptible Power Supplies (Register all UPS)";
      after = [ "upsd.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        # TODO: replace 'root' by another username.
        ExecStart = "${pkgs.nut}/bin/upsdrvctl -u root start";
      };
      environment.NUT_CONFPATH = "/etc/nut";
      environment.NUT_STATEPATH = "/var/lib/nut";
      restartTriggers = [
        config.environment.etc."nut/ups.conf".source
      ];
    };

    environment.etc = {
      "nut/nut.conf".source = pkgs.writeText "nut.conf"
        ''
          MODE = ${cfg.mode}
        '';
      "nut/ups.conf".source = pkgs.writeText "ups.conf"
        ''
          maxstartdelay = ${toString cfg.maxStartDelay}

          ${concatStringsSep "\n\n" (forEach (attrValues cfg.ups) (ups: ups.summary))}
        '';
      "nut/upsd.conf".source = pkgs.writeText "upsd.conf"
        ''
          ${concatStringsSep "\n" (forEach cfg.upsd.listen (listen: "LISTEN ${listen.address} ${toString listen.port}"))}
          ${cfg.upsd.extraConfig}
        '';
      "nut/upssched.conf".source = cfg.schedulerRules;
      "nut/upsd.users".source = "/run/nut/upsd.users";
      "nut/upsmon.conf".source = "/run/nut/upsmon.conf";
    };

    power.ups.schedulerRules = mkDefault "${pkgs.nut}/etc/upssched.conf.sample";

    systemd.tmpfiles.rules = [
      "d /var/state/ups -"
      "d /var/lib/nut 700"
    ];

    services.udev.packages = [ pkgs.nut ];

/*
    users.users.nut =
      { uid = 84;
        home = "/var/lib/nut";
        createHome = true;
        group = "nut";
        description = "UPnP A/V Media Server user";
      };

    users.groups."nut" =
      { gid = 84; };
*/

  };
}
