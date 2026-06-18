# Odysseus — self-contained NixOS module.
#
# USAGE in /etc/nixos/configuration.nix:
#
#   { ... }:
#   {
#     imports = [ /path/to/odysseus/default.nix ];
#
#     services.odysseus = {
#       enable  = true;
#       dataDir = "/tank/Models/Odysseus";
#       envFile = "/etc/odysseus/env";
#       optionalDeps.whisper    = true;
#       optionalDeps.duckduckgo = true;
#     };
#   }
#
# Or if the file lives in your config tree:
#
#   imports = [ ./modules/odysseus ];
#
# PINNING:
#   The odysseus source and uv2nix ecosystem are fetched via builtins.fetchGit.
#   Pin them by setting the `rev` attributes below, or override the fetch by
#   setting services.odysseus.src / services.odysseus.uv2nixSrc etc.
#
# RUNTIME INSTALLS:
#   A mutable uv venv is created at <dataDir>/venv on first start, extending
#   the immutable base env. Cookbook scripts are patched at install time to
#   use `uv pip install` instead of `python3 -m pip install`.

{ config, pkgs, lib, ... }:

let
  cfg = config.services.odysseus;

  # ------------------------------------------------------------------ #
  # Source fetches — overridable via options below                      #
  # ------------------------------------------------------------------ #
  odysseusSrc = cfg.src;

  pyproject-nix = import cfg.pyproject-nixSrc { inherit lib; };

  uv2nix = import cfg.uv2nixSrc { inherit lib pyproject-nix; };

  pyproject-build-systems = import cfg.pyproject-build-systemsSrc {
    inherit lib pyproject-nix uv2nix;
  };

  python = pkgs.python312;

  # ------------------------------------------------------------------ #
  # uv2nix workspace — reads pyproject.toml + uv.lock from odysseusSrc #
  # ------------------------------------------------------------------ #
  workspace = uv2nix.lib.workspace.loadWorkspace {
    workspaceRoot = odysseusSrc;
  };

  overlay = workspace.mkPyprojectOverlay { sourcePreference = "wheel"; };

  baseSet = pkgs.callPackage pyproject-nix.build.packages { inherit python; };

  mkPythonSet = overrides:
    baseSet.overrideScope (
      lib.composeManyExtensions ([
        overlay
        pyproject-build-systems.overlays.default
      ] ++ overrides)
    );

  mkVenv = _extras:
    let
      pythonSet       = mkPythonSet [];
      depsWithoutSelf = builtins.removeAttrs workspace.deps.default [ "odysseus" ];
    in
      pythonSet.mkVirtualEnv "odysseus-env" depsWithoutSelf;

  moduleExtras =
    lib.optionals cfg.optionalDeps.whisper    [ "whisper"    ] ++
    lib.optionals cfg.optionalDeps.duckduckgo [ "duckduckgo" ] ++
    lib.optionals cfg.optionalDeps.mupdf      [ "mupdf"      ] ++
    lib.optionals cfg.optionalDeps.markitdown [ "markitdown" ];

  moduleVenv = mkVenv moduleExtras;

  # ------------------------------------------------------------------ #
  # Cookbook script patches applied at installPhase                     #
  # Replaces `python3 -m pip install` with `uv pip install` targeting  #
  # the mutable venv at <dataDir>/venv. Upstream source untouched.     #
  # ------------------------------------------------------------------ #
  cookbookPatchScript = ''
    echo "Patching cookbook scripts: pip -> uv pip..."
    for f in \
        routes/cookbook_routes.py \
        cookbook_helpers.py \
        src/cookbook_helpers.py \
        routes/cookbook_helpers.py; do
      target="$out/lib/odysseus/$f"
      [ -f "$target" ] || continue
      echo "  patching $f"
      sed -i \
        -e 's|python3 -m pip install --no-cache-dir --user --break-system-packages|uv pip install --python "$VIRTUAL_ENV/bin/python"|g' \
        -e 's|python3 -m pip install --no-cache-dir|uv pip install --python "$VIRTUAL_ENV/bin/python"|g' \
        -e 's|python3 -m pip install --user --break-system-packages|uv pip install --python "$VIRTUAL_ENV/bin/python"|g' \
        -e 's|python3 -m pip install --user|uv pip install --python "$VIRTUAL_ENV/bin/python"|g' \
        -e 's|python3 -m pip install|uv pip install --python "$VIRTUAL_ENV/bin/python"|g' \
        "$target"
    done
  '';

  # ------------------------------------------------------------------ #
  # Package derivation                                                  #
  # ------------------------------------------------------------------ #
  modulePackage = pkgs.stdenv.mkDerivation {
    pname   = "odysseus";
    version = "0-unstable";
    src     = odysseusSrc;

    nativeBuildInputs = [ pkgs.makeWrapper pkgs.gnused ];
    buildInputs       = [ moduleVenv ];
    dontBuild         = true;

    installPhase = ''
      mkdir -p $out/lib/odysseus $out/bin
      cp -r . $out/lib/odysseus/
      [ -f _env ] && cp _env $out/lib/odysseus/.env.example || true

      ${cookbookPatchScript}

      makeWrapper ${moduleVenv}/bin/python $out/bin/odysseus \
        --add-flags "-m uvicorn app:app" \
        --add-flags "--host 127.0.0.1 --port 7000" \
        --set PYTHONPATH "$out/lib/odysseus" \
        --run 'cd "''${ODYSSEUS_HOME:-$HOME/.local/share/odysseus}"'

      makeWrapper ${moduleVenv}/bin/python $out/bin/odysseus-setup \
        --add-flags "$out/lib/odysseus/setup.py" \
        --set PYTHONPATH "$out/lib/odysseus" \
        --run 'cd "''${ODYSSEUS_HOME:-$HOME/.local/share/odysseus}"'
    '';

    meta = with lib; {
      description = "Self-hosted AI assistant UI with RAG, calendar, email, and research tools";
      license     = licenses.mit;
      platforms   = platforms.unix;
      mainProgram = "odysseus";
    };
  };

in {

  # ------------------------------------------------------------------ #
  # Options                                                             #
  # ------------------------------------------------------------------ #
  options.services.odysseus = {

    enable = lib.mkEnableOption "Odysseus AI assistant UI";

    # Source overrides — useful for pinning or pointing at a local checkout
    src = lib.mkOption {
      type        = lib.types.path;
      default     = builtins.fetchGit {
        url = "https://github.com/pewdiepie-archdaemon/odysseus.git";
        ref = "main";
        # rev = "abc123...";  # uncomment to pin
      };
      description = "Odysseus source tree (must contain pyproject.toml and uv.lock).";
    };

    pyproject-nixSrc = lib.mkOption {
      type    = lib.types.path;
      default = builtins.fetchGit {
        url = "https://github.com/pyproject-nix/pyproject.nix.git";
        # rev = "abc123...";
      };
      description = "pyproject-nix source (passed to uv2nix).";
    };

    uv2nixSrc = lib.mkOption {
      type    = lib.types.path;
      default = builtins.fetchGit {
        url = "https://github.com/pyproject-nix/uv2nix.git";
        # rev = "abc123...";
      };
      description = "uv2nix source.";
    };

    pyproject-build-systemsSrc = lib.mkOption {
      type    = lib.types.path;
      default = builtins.fetchGit {
        url = "https://github.com/pyproject-nix/build-system-pkgs.git";
        # rev = "abc123...";
      };
      description = "pyproject-build-systems source.";
    };

    host = lib.mkOption {
      type        = lib.types.str;
      default     = "127.0.0.1";
      description = "Bind address for the uvicorn server.";
    };

    port = lib.mkOption {
      type        = lib.types.port;
      default     = 7000;
      description = "Port for the uvicorn server.";
    };

    dataDir = lib.mkOption {
      type        = lib.types.path;
      default     = "/var/lib/odysseus";
      description = "Directory for persistent data (database, uploads, auth, venv, etc.).";
    };

    user = lib.mkOption {
      type        = lib.types.str;
      default     = "odysseus";
      description = "User account under which Odysseus runs.";
    };

    group = lib.mkOption {
      type        = lib.types.str;
      default     = "odysseus";
      description = "Group account under which Odysseus runs.";
    };

    envFile = lib.mkOption {
      type        = lib.types.nullOr lib.types.path;
      default     = null;
      description = ''
        Path to a .env file containing secrets (API keys, passwords, etc.).
        See the bundled .env.example for available options.
      '';
    };

    extraEnv = lib.mkOption {
      type    = lib.types.attrsOf lib.types.str;
      default = {};
      example = {
        SEARXNG_INSTANCE = "http://localhost:8080";
        OLLAMA_HOST      = "http://127.0.0.1:11434";
      };
      description = "Extra environment variables passed to the service.";
    };

    optionalDeps = {
      whisper = lib.mkOption {
        type        = lib.types.bool;
        default     = false;
        description = ''
          Install faster-whisper for local CPU/GPU speech-to-text.
          Enables the "local" STT provider in Odysseus settings.
        '';
      };

      duckduckgo = lib.mkOption {
        type        = lib.types.bool;
        default     = false;
        description = "Install ddgs to add DuckDuckGo as a search provider.";
      };

      mupdf = lib.mkOption {
        type        = lib.types.bool;
        default     = false;
        description = ''
          Install PyMuPDF for PDF form-filling.
          WARNING: PyMuPDF is AGPL-3.0 — see ACKNOWLEDGMENTS.md.
        '';
      };

      markitdown = lib.mkOption {
        type        = lib.types.bool;
        default     = false;
        description = "Install markitdown for Office/EPUB text extraction.";
      };
    };
  };

  # ------------------------------------------------------------------ #
  # Config                                                              #
  # ------------------------------------------------------------------ #
  config = lib.mkIf cfg.enable {

    users.users.${cfg.user} = {
      isNormalUser = true;
      home         = cfg.dataDir;
      createHome   = true;
      group        = cfg.group;
      shell        = pkgs.bash;
      description  = "Odysseus service user";
    };

    users.groups.${cfg.group} = {};

    environment.systemPackages = [
      pkgs.tmux
      pkgs.llama-cpp
      pkgs.uv
    ];

    systemd.services.odysseus = {
      description = "Odysseus AI assistant UI";
      wantedBy    = [ "multi-user.target" ];
      after       = [ "network.target" ];

      environment = {
        ODYSSEUS_DATA_DIR          = cfg.dataDir;
        DATABASE_URL               = "sqlite:///${cfg.dataDir}/app.db";
        PYTHONPATH                 = "${modulePackage}/lib/odysseus";
        ODYSSEUS_SKIP_RUN_HINT     = "1";
        ODYSSEUS_SKIP_ADMIN_PROMPT = "1";
        HOME                       = cfg.dataDir;
        HF_HOME                    = "${cfg.dataDir}/.cache/huggingface";
        HF_HUB_CACHE               = "${cfg.dataDir}/.cache/huggingface/hub";
        VIRTUAL_ENV                = "${cfg.dataDir}/venv";
        UV_PYTHON                  = "${cfg.dataDir}/venv/bin/python";
        ODYSSEUS_INSTALLER         = "uv";
        UV_PYTHON_DOWNLOADS        = "never";
      } // cfg.extraEnv;

      serviceConfig = {
        Type             = "simple";
        User             = cfg.user;
        Group            = cfg.group;
        WorkingDirectory = cfg.dataDir;

        ExecStart = pkgs.writeShellScript "odysseus-start" ''
          if [ -f "${cfg.dataDir}/venv/bin/activate" ]; then
            source "${cfg.dataDir}/venv/bin/activate"
          fi

          export PATH="${modulePackage}/bin:${pkgs.uv}/bin:${pkgs.tmux}/bin:${pkgs.llama-cpp}/bin:${moduleVenv}/bin:/run/current-system/sw/bin:$PATH"
          export PYTHONPATH="${modulePackage}/lib/odysseus"
          export VIRTUAL_ENV="${cfg.dataDir}/venv"
          export UV_PYTHON="${cfg.dataDir}/venv/bin/python"
          export UV_PYTHON_DOWNLOADS="never"

          exec ${moduleVenv}/bin/python -m uvicorn app:app \
            --host ${cfg.host} \
            --port ${toString cfg.port}
        '';

        EnvironmentFile = lib.mkIf (cfg.envFile != null) cfg.envFile;
        Restart         = "on-failure";
        RestartSec      = "5s";

        NoNewPrivileges = true;
        PrivateTmp      = false;
        ProtectSystem   = "strict";
        ReadWritePaths  = [ cfg.dataDir "/tmp" ];
        ProtectHome     = true;
      };

      preStart = ''
        chown -R ${cfg.user}:${cfg.group} ${cfg.dataDir} || true

        mkdir -p ${cfg.dataDir}/.cache/huggingface/hub
        mkdir -p ${cfg.dataDir}/tmux
        mkdir -p ${cfg.dataDir}/logs

        if [ ! -d "${cfg.dataDir}/venv" ]; then
          echo "Creating mutable venv for runtime installs..."
          ${pkgs.uv}/bin/uv venv \
            --python ${moduleVenv}/bin/python \
            --system-site-packages \
            ${cfg.dataDir}/venv
        fi

        if [ ! -f "${cfg.dataDir}/app.db" ]; then
          echo "Running first-time Odysseus setup..."
          PYTHONPATH=${modulePackage}/lib/odysseus \
            ${moduleVenv}/bin/python \
            ${modulePackage}/lib/odysseus/setup.py
        fi
      '';
    };
  };
}
