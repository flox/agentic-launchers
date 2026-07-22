{ buildGoModule }:

buildGoModule {
  pname = "launcher-lock-helper";
  version = "0.1.0";
  src = ../../native/launcher-lock-helper;
  vendorHash = null;

  ldflags = [ "-s" "-w" ];

  postInstall = ''
    mv "$out/bin/launcher-lock-helper" "$out/bin/_launcher-lock-helper"
  '';

  meta.description = "flock(2)-based lock helper for agentic-launchers";
}
