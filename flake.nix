{
  description = "DSPy: the framework for programming—rather than prompting—language models";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

    pyproject-nix = {
      url = "github:pyproject-nix/pyproject.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    uv2nix = {
      url = "github:pyproject-nix/uv2nix";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    pyproject-build-systems = {
      url = "github:pyproject-nix/build-system-pkgs";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.uv2nix.follows = "uv2nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      pyproject-nix,
      uv2nix,
      pyproject-build-systems,
    }:
    let
      inherit (nixpkgs) lib;

      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      python = pkgs.python313;

      # ----------------------------------------------------------------------
      # pure-impure trick
      # ----------------------------------------------------------------------
      #
      # Duplicated (not depended upon) from
      # https://github.com/NorfairKing/pure-impure-nix
      #
      # Turns a `buildCommand`-based derivation that wants internet access into a
      # fixed-output derivation, which Nix grants network access. We only care
      # whether it *succeeds*, not about its output: $out is replaced by a magic
      # string derived from the derivation's own store hash, so the output hash
      # is known up front (and changes whenever the derivation changes, forcing a
      # rebuild instead of caching a stale success forever).
      makePureImpure =
        drv:
        drv.overrideAttrs (
          old:
          let
            magicString = builtins.unsafeDiscardStringContext (
              builtins.substring 0 12 (baseNameOf drv.drvPath)
            );
            outputHashAlgo = "sha256";
            outputHash = builtins.hashString outputHashAlgo magicString;
          in
          {
            preferHashedMirrors = false;
            inherit outputHashAlgo outputHash;
            buildCommand = ''
              ${old.buildCommand or ""}
              rm -rf $out
              echo -n "${magicString}" > $out
            '';
          }
        );

      # ----------------------------------------------------------------------
      # Full dependency closure from uv.lock, via uv2nix.
      # ----------------------------------------------------------------------

      # Load the uv workspace (pyproject.toml + uv.lock) from the repo root.
      workspace = uv2nix.lib.workspace.loadWorkspace { workspaceRoot = ./.; };

      # Prefer prebuilt wheels from PyPI: dspy's dependency tree contains plenty
      # of compiled packages (pydantic-core, orjson, regex, tokenizers, ...) and
      # using their manylinux wheels avoids compiling everything from source.
      overlay = workspace.mkPyprojectOverlay {
        sourcePreference = "wheel";
      };

      # Project-specific build fixups go here as they come up.
      pyprojectOverrides = _final: _prev: { };

      pythonSet =
        (pkgs.callPackage pyproject-nix.build.packages {
          inherit python;
        }).overrideScope
          (
            lib.composeManyExtensions [
              pyproject-build-systems.overlays.default
              overlay
              pyprojectOverrides
            ]
          );

      # A virtualenv with dspy installed plus its `dev` extra (pytest, pytest-mock,
      # pytest-asyncio, litellm[proxy], numpy, pillow, ...). This mirrors what
      # upstream CI installs for the default test job (`uv sync --extra dev`).
      testVenv = pythonSet.mkVirtualEnv "dspy-test-env" (
        workspace.deps.default // { dspy = [ "dev" ]; }
      );

      # The tests that fetch real URLs over the internet (w3.org PDFs,
      # images.dog.ceo). Listed once and used both to deselect them from the pure
      # offline run and to select them for the pure-impure run.
      networkTests = [
        "tests/signatures/test_adapter_image.py::test_pdf_url_support"
        "tests/signatures/test_adapter_image.py::test_different_mime_types"
        "tests/signatures/test_adapter_image.py::test_mime_type_from_response_headers"
        "tests/signatures/test_adapter_image.py::test_pdf_from_file"
        "tests/signatures/test_adapter_image.py::test_image_input_formats"
        "tests/signatures/test_adapter_image.py::test_predictor_save_load"
      ];

      # ----------------------------------------------------------------------
      # Simple, dependency-light outputs.
      # ----------------------------------------------------------------------

      # A Python interpreter that has the PEP 517 build backend available, so the
      # wheel can be built without build isolation (and so without network) in
      # the Nix sandbox.
      buildPython = python.withPackages (ps: [
        ps.build
        ps.setuptools
        ps.wheel
      ]);

      # The distributable wheel, built the same way upstream CI does.
      dspy = pkgs.stdenvNoCC.mkDerivation {
        pname = "dspy";
        version = "3.3.0b1";
        src = ./.;

        nativeBuildInputs = [ buildPython ];

        buildPhase = ''
          runHook preBuild
          export HOME="$TMPDIR"
          python -m build --wheel --no-isolation --outdir dist
          runHook postBuild
        '';

        installPhase = ''
          runHook preInstall
          mkdir -p "$out"
          cp dist/*.whl "$out/"
          runHook postInstall
        '';

        doCheck = false;
      };

      # Development environment matching how upstream CI works.
      devShell = pkgs.mkShell {
        packages = [
          python
          buildPython
          pkgs.uv
          pkgs.ruff
          pkgs.pre-commit
          pkgs.git
        ];

        env.UV_PYTHON_DOWNLOADS = "never";

        shellHook = ''
          echo "dspy dev shell: $(python --version), uv $(uv --version), ruff $(ruff --version)"
        '';
      };

      # Mirror upstream CI's ruff gate exactly: passes when no automatic fixes
      # are pending.
      lint = pkgs.stdenvNoCC.mkDerivation {
        name = "dspy-lint";
        src = ./.;

        nativeBuildInputs = [ pkgs.ruff ];

        dontBuild = true;

        doCheck = true;
        checkPhase = ''
          runHook preCheck
          export RUFF_CACHE_DIR="$TMPDIR/ruff-cache"
          ruff check --fix-only --diff --exit-non-zero-on-fix .
          runHook postCheck
        '';

        installPhase = ''
          mkdir -p "$out"
        '';
      };

      # The default pytest suite, minus the handful of tests that need real
      # internet access. This is a fully pure, deterministic, network-free build
      # (the markers reliability/extra/llm_call/deno are skipped by conftest, and
      # the litellm test server binds to loopback).
      pytest = pkgs.stdenvNoCC.mkDerivation {
        name = "dspy-pytest";
        src = ./.;

        nativeBuildInputs = [ testVenv ];

        dontConfigure = true;
        dontBuild = true;

        doCheck = true;
        checkPhase = ''
          runHook preCheck
          export HOME="$TMPDIR"
          # Make the `tests` package importable (root conftest does
          # `from tests.test_utils...`).
          export PYTHONPATH="$PWD''${PYTHONPATH:+:$PYTHONPATH}"
          python -m pytest -p no:cacheprovider -vv tests/ \
            ${lib.concatMapStringsSep " \\\n            " (t: ''--deselect "${t}"'') networkTests}
          runHook postCheck
        '';

        installPhase = ''
          mkdir -p "$out"
        '';
      };

      # The internet-dependent tests, run with the pure-impure trick so they
      # still execute inside `nix flake check` (the fixed-output derivation is
      # granted network access). Kept as a small separate derivation so the heavy
      # offline suite above stays a normal, fully reproducible pure build.
      pytestNetwork = makePureImpure (
        pkgs.stdenv.mkDerivation {
          name = "dspy-pytest-network";
          src = ./.;
          dontUnpack = true;

          nativeBuildInputs = [
            testVenv
            pkgs.cacert
          ];

          buildCommand = ''
            export HOME="$TMPDIR"
            export SSL_CERT_FILE="${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
            cp -r "$src" source
            chmod -R u+w source
            cd source
            export PYTHONPATH="$PWD''${PYTHONPATH:+:$PYTHONPATH}"
            python -m pytest -p no:cacheprovider -vv \
              ${lib.concatStringsSep " \\\n              " networkTests}
          '';
        }
      );
    in
    {
      packages.${system} = {
        default = dspy;
        inherit dspy;
        # The full test virtualenv, exposed so it can be built/inspected directly.
        test-env = testVenv;
      };

      devShells.${system}.default = devShell;

      # `nix flake check` builds every entry here: every package, every devShell,
      # the lint gate, the offline pytest suite, and — via the pure-impure trick
      # — the internet-dependent tests too. So the whole suite runs in pure Nix.
      checks.${system} = {
        inherit
          dspy
          lint
          pytest
          pytestNetwork
          ;
        test-env = testVenv;
        devShell = devShell;
      };
    };
}
