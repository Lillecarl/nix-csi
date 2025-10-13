{ stdenv, go }:
stdenv.mkDerivation {
  pname = "bigbinary";
  version = "1.0.0";

  src = ./.;

  nativeBuildInputs = [ go ];

  buildPhase = ''
    # Disable CGO and build statically
    export CGO_ENABLED=0
    export GOOS=linux

    go build -ldflags="-s -w" -o bigbinary main.go

    # Verify size
    size=$(stat -c%s bigbinary)
    echo "Binary size: $size bytes"

    # Pad if needed (though the array should make it ~100MB)
    if [ $size -lt 104857600 ]; then
      echo "Padding binary to 100MB"
      truncate -s 104857600 bigbinary
    fi
  '';

  installPhase = ''
    mkdir -p $out/bin
    cp bigbinary $out/bin/
    chmod +x $out/bin/bigbinary
  '';

  meta = {
    description = "100MB test binary for page cache testing";
    mainProgram = "bigbinary";
  };
}
