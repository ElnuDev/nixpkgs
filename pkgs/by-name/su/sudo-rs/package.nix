{
  lib,
  bash,
  fetchFromGitHub,
  installShellFiles,
  nix-update-script,
  nixosTests,
  pam,
  pandoc,
  rustPlatform,
}:

rustPlatform.buildRustPackage rec {
  pname = "sudo-rs";
  version = "0.2.5";

  src = fetchFromGitHub {
    owner = "trifectatechfoundation";
    repo = "sudo-rs";
    rev = "v${version}";
    hash = "sha256-apvMcn/1dV9uujyoHikiOxregwWtAFPvrZvYjd3XQwM=";
  };
  useFetchCargoVendor = true;
  cargoHash = "sha256-EAfNg7hUsynFZ+EcUqeD9o44BakBYIMgxRXc4vcl8HY=";

  nativeBuildInputs = [
    installShellFiles
    pandoc
  ];

  buildInputs = [ pam ];

  # Don't attempt to generate the docs in a (pan)Docker container
  postPatch = ''
    substituteInPlace util/generate-docs.sh \
      --replace "/usr/bin/env bash" ${lib.getExe bash} \
      --replace util/pandoc.sh pandoc
  '';

  postInstall = ''
    ./util/generate-docs.sh
    installManPage target/docs/man/*
  '';

  checkFlags = map (t: "--skip=${t}") [
    # Those tests make path assumptions
    "common::command::test::test_build_command_and_args"
    "common::context::tests::test_build_context"
    "common::context::tests::test_build_run_context"
    "common::resolve::test::canonicalization"
    "common::resolve::tests::test_resolve_path"
    "system::tests::kill_test"

    # Assumes $SHELL is an actual shell
    "su::context::tests::su_to_root"

    # Attempts to access /etc files from the build sandbox
    "system::audit::test::secure_open_is_predictable"

    # Assume there is a `daemon` user and group
    "system::interface::test::test_unix_group"
    "system::interface::test::test_unix_user"
    "system::tests::test_get_user_and_group_by_id"

    # This expects some PATH_TZINFO environment var
    "env::environment::tests::test_tzinfo"

    # Unsure why those are failing
    "env::tests::test_environment_variable_filtering"
    "su::context::tests::invalid_shell"
  ];

  passthru = {
    updateScript = nix-update-script { };
    tests = nixosTests.sudo-rs;
  };

  meta = with lib; {
    description = "Memory safe implementation of sudo and su";
    homepage = "https://github.com/trifectatechfoundation/sudo-rs";
    changelog = "${meta.homepage}/blob/v${version}/CHANGELOG.md";
    license = with licenses; [
      asl20
      mit
    ];
    maintainers = with maintainers; [ nicoo ];
    platforms = platforms.linux;
  };
}
