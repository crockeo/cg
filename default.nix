{ lib
, stdenv
, zig
}:

stdenv.mkDerivation rec {
  pname = "cg";
  version = "0.1.0";

  src = lib.cleanSource ./.;

  nativeBuildInputs = [
    zig.hook
  ];

  meta = with lib; {
    description = "cg - Crockeo's Git (UI)";
    homepage = "https://github.com/crockeo/cg";
    license = licenses.mit;
    platforms = platforms.all;
  };
}
