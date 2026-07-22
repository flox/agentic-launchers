{ stdenv, lib }:

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
    chmod 755 "$out/bin/launch" "$out/bin"/launch-*
    runHook postInstall
  '';

  meta.description = "AI CLI launcher wrappers for ollama and omlx backends";
}
