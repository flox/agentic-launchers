{ stdenv, lib, callPackage }:

let
  # Built as a scoped intermediate so consumers get one artifact. The helper
  # is a tight implementation detail of the launcher shell layer — nothing
  # else consumes it — so it ships inside the same $out/bin.
  launcher-lock-helper = callPackage ./launcher-lock-helper.nix { };
in

stdenv.mkDerivation {
  pname = "agentic-launchers";
  version = "0.1.0";
  src = lib.fileset.toSource {
    root = ../..;
    fileset = lib.fileset.unions [
      ../../bin
      ../../etc
    ];
  };

  dontConfigure = true;
  dontBuild = true;
  dontPatchShebangs = true;

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/bin" "$out/etc"
    cp -a bin/. "$out/bin/"
    cp -a etc/. "$out/etc/"
    cp "${launcher-lock-helper}/bin/_launcher-lock-helper" "$out/bin/"
    chmod 755 "$out/bin/launch" "$out/bin"/launch-* "$out/bin/_launcher-lock-helper"
    runHook postInstall
  '';

  meta.description = "AI CLI launcher wrappers for ollama and omlx backends";
}
