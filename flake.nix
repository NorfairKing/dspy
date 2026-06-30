{
  description = "DSPy: the framework for programming—rather than prompting—language models";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
  };

  outputs =
    { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      python = pkgs.python3;

      # A Python interpreter that has the PEP 517 build backend (setuptools) and
      # `build` available, so the wheel can be produced without build isolation
      # (and therefore without any network access) inside the Nix sandbox.
      buildPython = python.withPackages (ps: [
        ps.build
        ps.setuptools
        ps.wheel
      ]);

      # DSPy's runtime dependency closure (litellm, gepa, json-repair, ...) is
      # large and only partly packaged in nixpkgs, and `gepa[dspy]` even depends
      # back on dspy. Rather than resolving that whole tree here, we build the
      # distributable wheel the same way upstream CI does (`python -m build`),
      # which is the artifact that actually gets published to PyPI.
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

      # Development environment that mirrors how upstream CI works: a Python
      # interpreter plus uv, ruff and pre-commit. Run `uv sync --extra dev` inside
      # the shell to materialise the full dependency set from uv.lock.
      devShell = pkgs.mkShell {
        packages = [
          python
          buildPython
          pkgs.uv
          pkgs.ruff
          pkgs.pre-commit
          pkgs.git
        ];

        # Use the nixpkgs Python instead of letting uv download its own.
        env.UV_PYTHON_DOWNLOADS = "never";

        shellHook = ''
          echo "dspy dev shell: $(python --version), uv $(uv --version), ruff $(ruff --version)"
        '';
      };

      # Mirror upstream CI's ruff gate exactly: this passes when no automatic
      # fixes are pending (`ruff check --fix-only --diff --exit-non-zero-on-fix`),
      # which is what the "Check Ruff Fix" job enforces.
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
    in
    {
      packages.${system} = {
        default = dspy;
        inherit dspy;
      };

      devShells.${system}.default = devShell;

      # `nix flake check` builds every entry here. We expose every package and
      # every devShell as a check (so they are all built), plus the lint gate.
      checks.${system} = {
        inherit dspy lint;
        devShell = devShell;
      };
    };
}
