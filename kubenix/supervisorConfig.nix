{ ... }:
{
  config = {
    kubernetes.api.resources.configMaps.supervisorconfig = {
      metadata.namespace = "default";
      data = {
        "supervisord.conf" = ''
          [supervisorctl]
          serverurl=unix:///run/supervisor.sock
        '';
        "controller.conf" = ''
          [unix_http_server]
          chmod=0700
          file=/run/supervisor.sock
          [rpcinterface:supervisor]
          supervisor.rpcinterface_factory=supervisor.rpcinterface:make_main_rpcinterface
          [supervisord]
          logfile=/dev/stdout
          logfile_maxbytes=0
          logfile_backups=0
          childlogdir=/var/log
          pidfile=/run/supervisord.pid
          [program:cknix-csi]
          autorestart=true
          autostart=true
          command=nix run --file /cknix/default.nix spackages.cknix-csi -- --controller --loglevel=DEBUG
          stdout_logfile=/dev/stdout
          stdout_logfile_maxbytes=0
          stderr_logfile=/dev/stderr
          stderr_logfile_maxbytes=0
          [program:attic-server]
          autorestart=true
          autostart=true
          command=nix run --file /cknix/default.nix spkgs.attic-server
          stdout_logfile=/dev/stdout
          stdout_logfile_maxbytes=0
          stderr_logfile=/dev/stderr
          stderr_logfile_maxbytes=0
        '';
        "node.conf" = ''
          [unix_http_server]
          chmod=0700
          file=/run/supervisor.sock
          [rpcinterface:supervisor]
          supervisor.rpcinterface_factory=supervisor.rpcinterface:make_main_rpcinterface
          [supervisord]
          logfile=/dev/stdout
          logfile_maxbytes=0
          logfile_backups=0
          childlogdir=/var/log
          ;logfile=/var/log/supervisord.log
          pidfile=/run/supervisord.pid
          [program:cknix-csi]
          autorestart=true
          autostart=true
          command=nix run --file /cknix/default.nix spackages.cknix-csi -- --node --loglevel=DEBUG
          stdout_logfile=/dev/stdout
          stdout_logfile_maxbytes=0
          stderr_logfile=/dev/stderr
          stderr_logfile_maxbytes=0
        '';
      };
    };
  };
}
