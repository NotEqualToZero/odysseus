# Odysseus — NixOS module + package using uv2nix, no flakes required.
#
# USAGE in /etc/nixos/configuration.nix:
#
#   { config, pkgs, lib, ... }:
#   let
#     # Pin each input to a specific commit for reproducibility.
#     # Update by changing the rev= and running `nix-prefetch-git <url> --rev <rev>`
#     pyproject-nix = import (builtins.fetchGit {
#       url = "https://github.com/pyproject-nix/pyproject.nix.git";
#       rev = "...";
#     }) { inherit lib; };
#
#     uv2nix = import (builtins.fetchGit {
#       url = "https://github.com/pyproject-nix/uv2nix.git";
#       rev = "...";
#     }) { inherit pyproject-nix lib; };
#
#     pyproject-build-systems = import (builtins.fetchGit {
#       url = "https://github.com/pyproject-nix/build-system-pkgs.git";
#       rev = "...";
#     }) { inherit pyproject-nix uv2nix lib; };
#
#     odysseus = import /path/to/odysseus/default.nix {
#       inherit pkgs lib uv2nix pyproject-nix pyproject-build-systems;
#     };
#   in {
#     imports = [ odysseus.nixosModule ];
#     services.odysseus = {
#       enable  = true;
#       dataDir = "/tank/Models/Odysseus";
#       envFile = "/etc/odysseus/env";
#       optionalDeps.whisper    = true;
#       optionalDeps.duckduckgo = true;
#     };
#   }
#
# RUNTIME INSTALLS:
#   A mutable uv venv is created at <dataDir>/venv on first start, extending
#   the immutable base env. Cookbook scripts patched at install time to use
#   `uv pip install` instead of `python3 -m pip install`, targeting this venv.
#   Upstream source is never modified — patches are applied in installPhase.

{ pkgs
, lib                    ? pkgs.lib
, pyproject-nix          ? import (builtins.fetchGit {
    url = "https://github.com/pyproject-nix/pyproject.nix.git";
  }) { inherit lib; }
, uv2nix                 ? import (builtins.fetchGit {
    url = "https://github.com/pyproject-nix/uv2nix.git";
  }) { inherit pyproject-nix lib; }
, pyproject-build-systems ? import (builtins.fetchGit {
    url = "https://github.com/pyproject-nix/build-system-pkgs.git";
  }) { inherit pyproject-nix uv2nix lib; }

  # Top-level optional dep toggles for bare package installs.
  # When using the NixOS module use services.odysseus.optionalDeps instead.
, withWhisper    ? false
, withDuckduckgo ? false
, withMupdf      ? false
, withMarkitdown ? false
}:

let
  python = pkgs.python312;

  # ------------------------------------------------------------------ #
  # uv2nix workspace — reads pyproject.toml + uv.lock from the source  #
  # ------------------------------------------------------------------ #
  workspace = uv2nix.lib.workspace.loadWorkspace { workspaceRoot = ./.; };

  # Package overlay generated from uv.lock
  overlay = workspace.mkPyprojectOverlay { sourcePreference = "wheel"; };

  # Base Python package set with no packages yet
  baseSet = pkgs.callPackage pyproject-nix.build.packages { inherit python; };

  # Build a complete package set by composing overlays:
  #   1. uv.lock-derived overlay (pinned versions)
  #   2. build-system packages (setuptools, flit, hatchling, etc.)
  #   3. any custom fixups
  mkPythonSet = overrides:
    baseSet.overrideScope (
      lib.composeManyExtensions ([
        overlay
        pyproject-build-systems.overlays.default
      ] ++ overrides)
    );

  # Build a virtual environment for the given optional extras
  mkVenv = extras:
    let
      pythonSet = mkPythonSet [];
      # workspace.deps.default includes odysseus itself as an entry.
      # We remove it since Odysseus is not an installable library —
      # we copy the source directly in installPhase instead.
      depsWithoutSelf = builtins.removeAttrs workspace.deps.default [ "odysseus" ];
    in
      pythonSet.mkVirtualEnv "odysseus-env" depsWithoutSelf;

  # Extras lists driven by the top-level with* args
  topLevelExtras =
    lib.optionals withWhisper    [ "whisper"    ] ++
    lib.optionals withDuckduckgo [ "duckduckgo" ] ++
    lib.optionals withMupdf      [ "mupdf"      ] ++
    lib.optionals withMarkitdown [ "markitdown" ];

  baseVenv = mkVenv topLevelExtras;

  # ------------------------------------------------------------------ #
  # Cookbook script patches applied at installPhase                     #
  #                                                                     #
  # The upstream cookbook scripts do `python3 -m pip install` to        #
  # self-install llama-cpp-python, faster-whisper, etc. at runtime.    #
  # In a Nix environment pip is not available (the Nix store is         #
  # read-only). These sed patches rewrite those calls to use            #
  # `uv pip install --python $VIRTUAL_ENV/bin/python`, which targets    #
  # the mutable venv at <dataDir>/venv.                                 #
  #                                                                     #
  # The upstream source is never modified — patches are applied only    #
  # to the copies installed into the Nix store derivation.             #
  # Non-Nix installs see no difference.                                 #
  #                                                                     #
  # Upstream PR path: add an ODYSSEUS_INSTALLER=uv env-var check in    #
  # the cookbook scripts so they branch to uv when set, keeping pip    #
  # as the default for non-Nix users.                                  #
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
      # Replace all pip install variants with uv pip install pointing at the
      # mutable venv. The $VIRTUAL_ENV variable is exported by the ExecStart
      # wrapper and inherited by all cookbook tmux sessions.
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
  # Package builder — accepts a venv so the NixOS module can pass in   #
  # one built from cfg.optionalDeps                                     #
  # ------------------------------------------------------------------ #
  mkPackage = venv: pkgs.stdenv.mkDerivation {
    pname   = "odysseus";
    version = "0-unstable";
    src = lib.cleanSourceWith {
      src = ./.;
      filter = path: type:
        let rel = lib.removePrefix (toString ./. + "/") path;
        in !(lib.hasPrefix ".venv"       rel) &&
           !(lib.hasPrefix "data/"       rel) &&
           !(lib.hasPrefix "logs/"       rel) &&
           !(lib.hasPrefix "__pycache__" rel) &&
           !(lib.hasSuffix ".pyc"        rel) &&
           rel != ".env";
    };

    nativeBuildInputs = [ pkgs.makeWrapper pkgs.gnused ];
    buildInputs       = [ venv ];
    dontBuild         = true;

    installPhase = ''
      mkdir -p $out/lib/odysseus $out/bin
      cp -r . $out/lib/odysseus/
      [ -f _env ] && cp _env $out/lib/odysseus/.env.example || true

      # Apply pip -> uv patches to cookbook scripts
      ${cookbookPatchScript}

      # Main server wrapper
      makeWrapper ${venv}/bin/python $out/bin/odysseus \
        --add-flags "-m uvicorn app:app" \
        --add-flags "--host 127.0.0.1 --port 7000" \
        --set PYTHONPATH "$out/lib/odysseus" \
        --run 'cd "''${ODYSSEUS_HOME:-$HOME/.local/share/odysseus}"'

      # First-run setup wrapper
      makeWrapper ${venv}/bin/python $out/bin/odysseus-setup \
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

  package = mkPackage baseVenv;

  # ------------------------------------------------------------------ #
  # NixOS module                                                        #
  # ------------------------------------------------------------------ #
  nixosModule = { config, lib, pkgs, ... }:
    let
      cfg = config.services.odysseus;

      moduleExtras =
        lib.optionals cfg.optionalDeps.whisper    [ "whisper"    ] ++
        lib.optionals cfg.optionalDeps.duckduckgo [ "duckduckgo" ] ++
        lib.optionals cfg.optionalDeps.mupdf      [ "mupdf"      ] ++
        lib.optionals cfg.optionalDeps.markitdown [ "markitdown" ];

      moduleVenv    = mkVenv moduleExtras;
      modulePackage = mkPackage moduleVenv;
    in {
      options.services.odysseus = {
        enable = lib.mkEnableOption "Odysseus AI assistant UI";

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

      config = lib.mkIf cfg.enable {
        users.users.${cfg.user} = {
          isNormalUser = true;
          home         = cfg.dataDir;
          createHome   = true;
          group        = cfg.group;
          shell        = pkgs.bash;   # tmux needs a real login shell
          description  = "Odysseus service user";
        };

        users.groups.${cfg.group} = {};

        # System tools needed by cookbook sessions:
        #   tmux       — background downloads and model serves
        #   llama-cpp  — llama-server binary for local model serving
        #   uv         — runtime package installer replacing pip
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
            # HuggingFace cache under dataDir
            HF_HOME                    = "${cfg.dataDir}/.cache/huggingface";
            HF_HUB_CACHE               = "${cfg.dataDir}/.cache/huggingface/hub";
            # Mutable venv for runtime cookbook installs
            VIRTUAL_ENV                = "${cfg.dataDir}/venv";
            UV_PYTHON                  = "${cfg.dataDir}/venv/bin/python";
            # Signal to cookbook scripts that uv is the installer backend
            ODYSSEUS_INSTALLER         = "uv";
            # Prevent uv from downloading its own Python — use the Nix one
            UV_PYTHON_DOWNLOADS        = "never";
          } // cfg.extraEnv;

          serviceConfig = {
            Type             = "simple";
            User             = cfg.user;
            Group            = cfg.group;
            WorkingDirectory = cfg.dataDir;

            # Wrapper script:
            #   1. Activates the mutable venv so runtime-installed packages
            #      (llama-cpp-python, faster-whisper, etc.) are importable
            #   2. Puts tmux, uv, llama-server, hf on PATH so shutil.which()
            #      and cookbook tmux sessions can find them
            #   3. Exports VIRTUAL_ENV so the patched pip->uv calls know
            #      where to install
            ExecStart = pkgs.writeShellScript "odysseus-start" ''
              # Activate mutable venv (runtime cookbook installs live here)
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

            # Hardening
            # PrivateTmp = false: tmux spawns child shells in the real /tmp;
            # cookbook scripts written to /tmp/odysseus-tmux/ must be visible
            # to those shells. With PrivateTmp=true they're in an isolated
            # namespace the tmux children can't see.
            NoNewPrivileges = true;
            PrivateTmp      = false;
            ProtectSystem   = "strict";
            ReadWritePaths  = [ cfg.dataDir "/tmp" ];
            ProtectHome     = true;
          };

          preStart = ''
            # Fix ownership after any manual operations or earlier root runs
            chown -R ${cfg.user}:${cfg.group} ${cfg.dataDir} || true

            mkdir -p ${cfg.dataDir}/.cache/huggingface/hub
            mkdir -p ${cfg.dataDir}/tmux
            mkdir -p ${cfg.dataDir}/logs

            # Create the mutable venv for runtime cookbook installs.
            # --system-site-packages extends the immutable Nix base env so
            # all core Odysseus deps are importable without reinstalling them.
            # Only runtime extras (llama-cpp-python, etc.) are installed here.
            if [ ! -d "${cfg.dataDir}/venv" ]; then
              echo "Creating mutable venv for runtime installs..."
              ${pkgs.uv}/bin/uv venv \
                --python ${moduleVenv}/bin/python \
                --system-site-packages \
                ${cfg.dataDir}/venv
            fi

            # First-time app setup: creates DB, data dirs, auth.json
            if [ ! -f "${cfg.dataDir}/app.db" ]; then
              echo "Running first-time Odysseus setup..."
              PYTHONPATH=${modulePackage}/lib/odysseus \
                ${moduleVenv}/bin/python \
                ${modulePackage}/lib/odysseus/setup.py
            fi
          '';
        };
      };
    };

in {
  inherit package nixosModule;
  defaultPackage = package;
}
