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

      # Run the default pytest suite (the markers reliability/extra/llm_call/deno
      # are skipped unless their --flags are passed, so this is the network-free
      # unit suite, with the litellm test server bound to loopback).
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
          # These tests fetch real URLs over the internet (w3.org PDFs,
          # images.dog.ceo), which a pure Nix build deliberately has no network
          # for. They are exercised by the impure NixCI test instead (see
          # packages.impure-test). Everything else runs here.
          python -m pytest -p no:cacheprovider -vv tests/ \
            --deselect "tests/signatures/test_adapter_image.py::test_pdf_url_support" \
            --deselect "tests/signatures/test_adapter_image.py::test_different_mime_types" \
            --deselect "tests/signatures/test_adapter_image.py::test_mime_type_from_response_headers" \
            --deselect "tests/signatures/test_adapter_image.py::test_pdf_from_file" \
            --deselect "tests/signatures/test_adapter_image.py::test_image_input_formats" \
            --deselect "tests/signatures/test_adapter_image.py::test_predictor_save_load"
          runHook postCheck
        '';

        installPhase = ''
          mkdir -p "$out"
        '';
      };

      # The full test suite, including the tests that need real internet access
      # (the w3.org / images.dog.ceo fetches). Building this derivation is pure
      # (it is just a wrapper script around the venv); *running* it needs network,
      # so it is executed by NixCI's impure test runner via `nix run` — see the
      # `test` section of nix-ci.nix.
      impureTest = pkgs.writeShellApplication {
        name = "dspy-impure-test";
        runtimeInputs = [
          testVenv
          pkgs.cacert
          # coreutils for mktemp/mkdir etc.; the impure runner does not put them
          # on PATH for us.
          pkgs.coreutils
        ];
        text = ''
          HOME="$(mktemp -d)"
          export HOME
          export SSL_CERT_FILE="${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
          # NixCI runs this with `in-repo = true`, so $PWD is a checkout of the
          # repo; make its `dspy`/`tests` packages importable.
          export PYTHONPATH="$PWD''${PYTHONPATH:+:$PYTHONPATH}"
          exec python -m pytest -p no:cacheprovider -vv tests/
        '';
      };
    in
    {
      packages.${system} = {
        default = dspy;
        inherit dspy;
        # The full test virtualenv, exposed so it can be built/inspected directly.
        test-env = testVenv;
        # Impure full-suite test runner (used by nix-ci.nix's test job).
        impure-test = impureTest;
      };

      devShells.${system}.default = devShell;

      # `nix flake check` builds every entry here: every package, every devShell,
      # the lint gate, and the pytest suite.
      checks.${system} = {
        inherit dspy lint pytest;
        test-env = testVenv;
        # Building the impure runner is pure (it does not run the tests).
        impure-test = impureTest;
        devShell = devShell;
      };
    };
}
