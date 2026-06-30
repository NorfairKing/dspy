# NixCI per-commit configuration.
# https://staging.nix-ci.com/documentation/configuration
{
  # Besides the pure `nix flake check` (which already runs the offline test
  # suite via checks.x86_64-linux.pytest), run the *full* test suite impurely so
  # the handful of tests that fetch real URLs over the internet are covered too.
  test = {
    pytest = {
      branches = "any";
      # Run inside a checkout of the repository so pytest can see ./tests.
      in-repo = true;
      package = "packages.x86_64-linux.impure-test";
    };
  };
}
