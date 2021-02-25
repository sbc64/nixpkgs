# pipewire service.
{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.pipewire;
  enable32BitAlsaPlugins = cfg.alsa.support32Bit
                           && pkgs.stdenv.isx86_64
                           && pkgs.pkgsi686Linux.pipewire != null;

  # The package doesn't output to $out/lib/pipewire directly so that the
  # overlays can use the outputs to replace the originals in FHS environments.
  #
  # This doesn't work in general because of missing development information.
  jack-libs = pkgs.runCommand "jack-libs" {} ''
    mkdir -p "$out/lib"
    ln -s "${cfg.package.jack}/lib" "$out/lib/pipewire"
  '';

  prioritizeNativeProtocol = {
    "context.modules" = {
      "libpipewire-module-protocol-native" = {
        _priority = -100;
        _content = null;
      };
    };
  };

  sessionManagerInvocation = {
    "context.exec" = {
      "${cfg.sessionManagerExecutable}" = {
        args = "${lib.concatStringsSep " " cfg.sessionManagerArguments}";
      };
    };
  };

  # Use upstream config files passed through spa-json-dump as the base
  # Patched here as necessary for them to work with this module
  defaults = {
    client = recursiveUpdate (builtins.fromJSON (builtins.readFile ./client.conf.json)) prioritizeNativeProtocol;
    client-rt = recursiveUpdate (builtins.fromJSON (builtins.readFile ./client-rt.conf.json)) prioritizeNativeProtocol;
    jack = recursiveUpdate (builtins.fromJSON (builtins.readFile ./jack.conf.json)) prioritizeNativeProtocol;
    # Remove session manager invocation from the upstream generated file, it points to the wrong path
    pipewire = recursiveUpdate ((removeAttrs (builtins.fromJSON (builtins.readFile ./pipewire.conf.json)) ["context.exec"]) // sessionManagerInvocation) prioritizeNativeProtocol;
    pipewire-pulse = recursiveUpdate (builtins.fromJSON (builtins.readFile ./pipewire-pulse.conf.json)) prioritizeNativeProtocol;
  };

  # Helpers for generating the pipewire JSON config file
  mkSPAValueString = v:
  if builtins.isList v then "[${lib.concatMapStringsSep " " mkSPAValueString v}]"
  else if lib.types.attrs.check v then
    "{${lib.concatStringsSep " " (mkSPAKeyValue v)}}"
  else if builtins.isString v then "\"${lib.generators.mkValueStringDefault { } v}\""
  else lib.generators.mkValueStringDefault { } v;

  mkSPAKeyValue = attrs: map (def: def.content) (
  lib.sortProperties
    (
      lib.mapAttrsToList
        (k: v: lib.mkOrder (v._priority or 1000) "${lib.escape [ "=" ] k} = ${mkSPAValueString (v._content or v)}")
        attrs
    )
  );

  toSPAJSON = attrs: lib.concatStringsSep "\n" (mkSPAKeyValue attrs);
in {

  meta = {
    maintainers = teams.freedesktop.members;
  };

  ###### interface
  options = {
    services.pipewire = {
      enable = mkEnableOption "pipewire service";

      package = mkOption {
        type = types.package;
        default = pkgs.pipewire;
        defaultText = "pkgs.pipewire";
        example = literalExample "pkgs.pipewire";
        description = ''
          The pipewire derivation to use.
        '';
      };

      socketActivation = mkOption {
        default = true;
        type = types.bool;
        description = ''
          Automatically run pipewire when connections are made to the pipewire socket.
        '';
      };

      config = {
        client = mkOption {
          type = types.attrs;
          default = {};
          description = ''
            Configuration for pipewire clients. For details see
            https://gitlab.freedesktop.org/pipewire/pipewire/-/blob/${cfg.package.version}/src/daemon/client.conf.in
          '';
        };

        client-rt = mkOption {
          type = types.attrs;
          default = {};
          description = ''
            Configuration for realtime pipewire clients. For details see
            https://gitlab.freedesktop.org/pipewire/pipewire/-/blob/${cfg.package.version}/src/daemon/client-rt.conf.in
          '';
        };

        jack = mkOption {
          type = types.attrs;
          default = {};
          description = ''
            Configuration for the pipewire daemon's jack module. For details see
            https://gitlab.freedesktop.org/pipewire/pipewire/-/blob/${cfg.package.version}/src/daemon/jack.conf.in
          '';
        };

        pipewire = mkOption {
          type = types.attrs;
          default = {};
          description = ''
            Configuration for the pipewire daemon. For details see
            https://gitlab.freedesktop.org/pipewire/pipewire/-/blob/${cfg.package.version}/src/daemon/pipewire.conf.in
          '';
        };

        pipewire-pulse = mkOption {
          type = types.attrs;
          default = {};
          description = ''
            Configuration for the pipewire-pulse daemon. For details see
            https://gitlab.freedesktop.org/pipewire/pipewire/-/blob/${cfg.package.version}/src/daemon/pipewire-pulse.conf.in
          '';
        };
      };

      sessionManagerExecutable = mkOption {
        type = types.str;
        default = "";
        example = literalExample ''${pkgs.pipewire.mediaSession}/bin/pipewire-media-session'';
        description = ''
          Path to the session manager executable.
        '';
      };

      sessionManagerArguments = mkOption {
        type = types.listOf types.str;
        default = [];
        example = literalExample ''["-p" "bluez5.msbc-support=true"]'';
        description = ''
          Arguments passed to the pipewire session manager.
        '';
      };

      alsa = {
        enable = mkEnableOption "ALSA support";
        support32Bit = mkEnableOption "32-bit ALSA support on 64-bit systems";
      };

      jack = {
        enable = mkEnableOption "JACK audio emulation";
      };

      pulse = {
        enable = mkEnableOption "PulseAudio server emulation";
      };
    };
  };


  ###### implementation
  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.pulse.enable -> !config.hardware.pulseaudio.enable;
        message = "PipeWire based PulseAudio server emulation replaces PulseAudio. This option requires `hardware.pulseaudio.enable` to be set to false";
      }
      {
        assertion = cfg.jack.enable -> !config.services.jack.jackd.enable;
        message = "PipeWire based JACK emulation doesn't use the JACK service. This option requires `services.jack.jackd.enable` to be set to false";
      }
    ];

    environment.systemPackages = [ cfg.package ]
                                 ++ lib.optional cfg.jack.enable jack-libs;

    systemd.packages = [ cfg.package ]
                       ++ lib.optional cfg.pulse.enable cfg.package.pulse;

    # PipeWire depends on DBUS but doesn't list it. Without this booting
    # into a terminal results in the service crashing with an error.
    systemd.user.sockets.pipewire.wantedBy = lib.mkIf cfg.socketActivation [ "sockets.target" ];
    systemd.user.sockets.pipewire-pulse.wantedBy = lib.mkIf (cfg.socketActivation && cfg.pulse.enable) ["sockets.target"];
    systemd.user.services.pipewire.bindsTo = [ "dbus.service" ];
    services.udev.packages = [ cfg.package ];

    # If any paths are updated here they must also be updated in the package test.
    environment.etc."alsa/conf.d/49-pipewire-modules.conf" = mkIf cfg.alsa.enable {
      text = ''
        pcm_type.pipewire {
          libs.native = ${cfg.package.lib}/lib/alsa-lib/libasound_module_pcm_pipewire.so ;
          ${optionalString enable32BitAlsaPlugins
            "libs.32Bit = ${pkgs.pkgsi686Linux.pipewire.lib}/lib/alsa-lib/libasound_module_pcm_pipewire.so ;"}
        }
        ctl_type.pipewire {
          libs.native = ${cfg.package.lib}/lib/alsa-lib/libasound_module_ctl_pipewire.so ;
          ${optionalString enable32BitAlsaPlugins
            "libs.32Bit = ${pkgs.pkgsi686Linux.pipewire.lib}/lib/alsa-lib/libasound_module_ctl_pipewire.so ;"}
        }
      '';
    };
    environment.etc."alsa/conf.d/50-pipewire.conf" = mkIf cfg.alsa.enable {
      source = "${cfg.package}/share/alsa/alsa.conf.d/50-pipewire.conf";
    };
    environment.etc."alsa/conf.d/99-pipewire-default.conf" = mkIf cfg.alsa.enable {
      source = "${cfg.package}/share/alsa/alsa.conf.d/99-pipewire-default.conf";
    };

    environment.etc."pipewire/client.conf" = { text = toSPAJSON (recursiveUpdate defaults.client cfg.config.client); };
    environment.etc."pipewire/client-rt.conf" = { text = toSPAJSON (recursiveUpdate defaults.client-rt cfg.config.client-rt); };
    environment.etc."pipewire/jack.conf" = { text = toSPAJSON (recursiveUpdate defaults.jack cfg.config.jack); };
    environment.etc."pipewire/pipewire.conf" = { text = toSPAJSON (recursiveUpdate defaults.pipewire cfg.config.pipewire); };
    environment.etc."pipewire/pipewire-pulse.conf" = { text = toSPAJSON (recursiveUpdate defaults.pipewire-pulse cfg.config.pipewire-pulse); };

    environment.sessionVariables.LD_LIBRARY_PATH =
      lib.optional cfg.jack.enable "/run/current-system/sw/lib/pipewire";

    # https://gitlab.freedesktop.org/pipewire/pipewire/-/issues/464#note_723554
    systemd.user.services.pipewire.environment."PIPEWIRE_LINK_PASSIVE" = "1";
  };
}
