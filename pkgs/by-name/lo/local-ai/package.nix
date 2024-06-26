{ config
, stdenv
, lib
, addDriverRunpath
, fetchpatch
, fetchFromGitHub
, protobuf
, grpc
, openssl
, llama-cpp
  # needed for audio-to-text
, ffmpeg
, cmake
, pkg-config
, buildGoModule
, makeWrapper
, runCommand
, testers

  # apply feature parameter names according to
  # https://github.com/NixOS/rfcs/pull/169

  # CPU extensions
, enable_avx ? true
, enable_avx2 ? true
, enable_avx512 ? stdenv.hostPlatform.avx512Support
, enable_f16c ? true
, enable_fma ? true

, with_tinydream ? false
, ncnn

, with_openblas ? false
, openblas

, with_cublas ? config.cudaSupport
, cudaPackages

, with_clblas ? false
, clblast
, ocl-icd
, opencl-headers

, with_stablediffusion ? false
, opencv

, with_tts ? false
, onnxruntime
, sonic
, spdlog
, fmt
, espeak-ng
, piper-tts

  # tests
, fetchzip
, fetchurl
, writeText
, symlinkJoin
, linkFarmFromDrvs
, jq
}:
let
  BUILD_TYPE =
    assert (lib.count lib.id [ with_openblas with_cublas with_clblas ]) <= 1;
    if with_openblas then "openblas"
    else if with_cublas then "cublas"
    else if with_clblas then "clblas"
    else "";

  inherit (cudaPackages) libcublas cuda_nvcc cuda_cccl cuda_cudart;

  typedBuiltInputs =
    lib.optionals with_cublas
      [
        cuda_nvcc # should be part of nativeBuildInputs
        cuda_cudart
        cuda_cccl
        (lib.getDev libcublas)
        (lib.getLib libcublas)
      ]
    ++ lib.optionals with_clblas
      [ clblast ocl-icd opencl-headers ]
    ++ lib.optionals with_openblas
      [ openblas.dev ];

  go-llama-ggml = effectiveStdenv.mkDerivation {
    name = "go-llama-ggml";
    src = fetchFromGitHub {
      owner = "go-skynet";
      repo = "go-llama.cpp";
      rev = "2b57a8ae43e4699d3dc5d1496a1ccd42922993be";
      hash = "sha256-D6SEg5pPcswGyKAmF4QTJP6/Y1vjRr7m7REguag+too=";
      fetchSubmodules = true;
    };
    buildFlags = [
      "libbinding.a"
      "BUILD_TYPE=${BUILD_TYPE}"
    ];
    buildInputs = typedBuiltInputs;
    dontUseCmakeConfigure = true;
    nativeBuildInputs = [ cmake ];
    installPhase = ''
      mkdir $out
      tar cf - --exclude=build --exclude=CMakeFiles --exclude="*.o" . \
        | tar xf - -C $out
    '';
  };

  llama-cpp-grpc = (llama-cpp.overrideAttrs (final: prev: {
    name = "llama-cpp-grpc";
    src = fetchFromGitHub {
      owner = "ggerganov";
      repo = "llama.cpp";
      rev = "b06c16ef9f81d84da520232c125d4d8a1d273736";
      hash = "sha256-t1AIx/Ir5RhasjblH4BSpGOXVvO84SJPSqa7rXWj6b4=";
      fetchSubmodules = true;
    };
    postPatch = prev.postPatch + ''
      cd examples
      cp -r --no-preserve=mode ${src}/backend/cpp/llama grpc-server
      cp llava/clip.* llava/llava.* grpc-server
      printf "\nadd_subdirectory(grpc-server)" >> CMakeLists.txt

      cp ${src}/backend/backend.proto grpc-server
      sed -i grpc-server/CMakeLists.txt \
        -e '/get_filename_component/ s;[.\/]*backend/;;' \
        -e '$a\install(TARGETS ''${TARGET} RUNTIME)'
      cd ..
    '';
    cmakeFlags = prev.cmakeFlags ++ [
      (lib.cmakeBool "BUILD_SHARED_LIBS" false)
      (lib.cmakeBool "LLAMA_AVX" enable_avx)
      (lib.cmakeBool "LLAMA_AVX2" enable_avx2)
      (lib.cmakeBool "LLAMA_AVX512" enable_avx512)
      (lib.cmakeBool "LLAMA_FMA" enable_fma)
      (lib.cmakeBool "LLAMA_F16C" enable_f16c)
    ];
    buildInputs = prev.buildInputs ++ [
      protobuf # provides also abseil_cpp as propagated build input
      grpc
      openssl
    ];
  })).override {
    cudaSupport = with_cublas;
    rocmSupport = false;
    openclSupport = with_clblas;
    blasSupport = with_openblas;
  };

  gpt4all = stdenv.mkDerivation {
    name = "gpt4all";
    src = fetchFromGitHub {
      owner = "nomic-ai";
      repo = "gpt4all";
      rev = "27a8b020c36b0df8f8b82a252d261cda47cf44b8";
      hash = "sha256-djq1eK6ncvhkO3MNDgasDBUY/7WWcmZt/GJsHAulLdI=";
      fetchSubmodules = true;
    };
    makeFlags = [ "-C gpt4all-bindings/golang" ];
    buildFlags = [ "libgpt4all.a" ];
    dontUseCmakeConfigure = true;
    nativeBuildInputs = [ cmake ];
    installPhase = ''
      mkdir $out
      tar cf - --exclude=CMakeFiles . \
        | tar xf - -C $out
    '';
  };

  espeak-ng' = espeak-ng.overrideAttrs (self: {
    name = "espeak-ng'";
    inherit (go-piper) src;
    sourceRoot = "source/espeak";
    patches = [ ];
    nativeBuildInputs = [ cmake ];
    cmakeFlags = (self.cmakeFlags or [ ]) ++ [
      (lib.cmakeBool "BUILD_SHARED_LIBS" true)
      (lib.cmakeBool "USE_ASYNC" false)
      (lib.cmakeBool "USE_MBROLA" false)
      (lib.cmakeBool "USE_LIBPCAUDIO" false)
      (lib.cmakeBool "USE_KLATT" false)
      (lib.cmakeBool "USE_SPEECHPLAYER" false)
      (lib.cmakeBool "USE_LIBSONIC" false)
      (lib.cmakeBool "CMAKE_POSITION_INDEPENDENT_CODE" true)
    ];
    preConfigure = null;
    postInstall = null;
  });

  piper-phonemize = stdenv.mkDerivation {
    name = "piper-phonemize";
    inherit (go-piper) src;
    sourceRoot = "source/piper-phonemize";
    buildInputs = [ espeak-ng' onnxruntime ];
    nativeBuildInputs = [ cmake pkg-config ];
    cmakeFlags = [
      (lib.cmakeFeature "ONNXRUNTIME_DIR" "${onnxruntime.dev}")
      (lib.cmakeFeature "ESPEAK_NG_DIR" "${espeak-ng'}")
    ];
    passthru.espeak-ng = espeak-ng';
  };

  piper-tts' = (piper-tts.override { inherit piper-phonemize; }).overrideAttrs (self: {
    name = "piper-tts'";
    inherit (go-piper) src;
    sourceRoot = "source/piper";
    installPhase = null;
    postInstall = ''
      cp CMakeFiles/piper.dir/src/cpp/piper.cpp.o $out/piper.o
      cd $out
      mkdir bin lib
      mv lib*so* lib/
      mv piper piper_phonemize bin/
      rm -rf cmake pkgconfig espeak-ng-data *.ort
    '';
  });

  go-piper = stdenv.mkDerivation {
    name = "go-piper";
    src = fetchFromGitHub {
      owner = "mudler";
      repo = "go-piper";
      rev = "9d0100873a7dbb0824dfea40e8cec70a1b110759";
      hash = "sha256-Yv9LQkWwGpYdOS0FvtP0vZ0tRyBAx27sdmziBR4U4n8=";
      fetchSubmodules = true;
    };
    postUnpack = ''
      cp -r --no-preserve=mode ${piper-tts'}/* source
    '';
    postPatch = ''
      sed -i Makefile \
        -e '/CXXFLAGS *= / s;$; -DSPDLOG_FMT_EXTERNAL=1;'
    '';
    buildFlags = [ "libpiper_binding.a" ];
    buildInputs = [ piper-tts' espeak-ng' piper-phonemize sonic fmt spdlog onnxruntime ];
    installPhase = ''
      cp -r --no-preserve=mode $src $out
      mkdir -p $out/piper-phonemize/pi
      cp -r --no-preserve=mode ${piper-phonemize}/share $out/piper-phonemize/pi
      cp *.a $out
    '';
  };

  go-rwkv = stdenv.mkDerivation {
    name = "go-rwkv";
    src = fetchFromGitHub {
      owner = "donomii";
      repo = "go-rwkv.cpp";
      rev = "661e7ae26d442f5cfebd2a0881b44e8c55949ec6";
      hash = "sha256-byTNZQSnt7qpBMng3ANJmpISh3GJiz+F15UqfXaz6nQ=";
      fetchSubmodules = true;
    };
    buildFlags = [ "librwkv.a" ];
    dontUseCmakeConfigure = true;
    nativeBuildInputs = [ cmake ];
    installPhase = ''
      cp -r --no-preserve=mode $src $out
      cp *.a $out
    '';
  };

  # try to merge with openai-whisper-cpp in future
  whisper-cpp = effectiveStdenv.mkDerivation {
    name = "whisper-cpp";
    src = fetchFromGitHub {
      owner = "ggerganov";
      repo = "whisper.cpp";
      rev = "1558ec5a16cb2b2a0bf54815df1d41f83dc3815b";
      hash = "sha256-UAqWU3kvkHM+fV+T6gFVsAKuOG6N4FoFgTKGUptwjmE=";
    };
    nativeBuildInputs = [ cmake pkg-config ];
    buildInputs = typedBuiltInputs;
    cmakeFlags = [
      (lib.cmakeBool "WHISPER_CUBLAS" with_cublas)
      (lib.cmakeBool "WHISPER_CLBLAST" with_clblas)
      (lib.cmakeBool "WHISPER_OPENBLAS" with_openblas)
      (lib.cmakeBool "WHISPER_NO_AVX" (!enable_avx))
      (lib.cmakeBool "WHISPER_NO_AVX2" (!enable_avx2))
      (lib.cmakeBool "WHISPER_NO_FMA" (!enable_fma))
      (lib.cmakeBool "WHISPER_NO_F16C" (!enable_f16c))
      (lib.cmakeBool "BUILD_SHARED_LIBS" false)
    ];
    postInstall = ''
      install -Dt $out/bin bin/*
    '';
  };

  go-bert = stdenv.mkDerivation {
    name = "go-bert";
    src = fetchFromGitHub {
      owner = "go-skynet";
      repo = "go-bert.cpp";
      rev = "6abe312cded14042f6b7c3cd8edf082713334a4d";
      hash = "sha256-lh9cvXc032Eq31kysxFOkRd0zPjsCznRl0tzg9P2ygo=";
      fetchSubmodules = true;
    };
    buildFlags = [ "libgobert.a" ];
    dontUseCmakeConfigure = true;
    nativeBuildInputs = [ cmake ];
    env.NIX_CFLAGS_COMPILE = "-Wformat";
    installPhase = ''
      cp -r --no-preserve=mode $src $out
      cp *.a $out
    '';
  };

  go-stable-diffusion = stdenv.mkDerivation {
    name = "go-stable-diffusion";
    src = fetchFromGitHub {
      owner = "mudler";
      repo = "go-stable-diffusion";
      rev = "362df9da29f882dbf09ade61972d16a1f53c3485";
      hash = "sha256-A5KvMZOviPsIpPHxM8cacT+qE2x1iFJAbPsRs4sLijY=";
      fetchSubmodules = true;
    };
    buildFlags = [ "libstablediffusion.a" ];
    dontUseCmakeConfigure = true;
    nativeBuildInputs = [ cmake ];
    buildInputs = [ opencv ];
    env.NIX_CFLAGS_COMPILE = " -isystem ${opencv}/include/opencv4";
    installPhase = ''
      mkdir $out
      tar cf - --exclude=CMakeFiles --exclude="*.o" --exclude="*.so" --exclude="*.so.*" . \
        | tar xf - -C $out
    '';
  };

  go-tiny-dream-ncnn = ncnn.overrideAttrs (self: {
    name = "go-tiny-dream-ncnn";
    inherit (go-tiny-dream) src;
    sourceRoot = "source/ncnn";
    cmakeFlags = self.cmakeFlags ++ [
      (lib.cmakeBool "NCNN_SHARED_LIB" false)
      (lib.cmakeBool "NCNN_OPENMP" false)
      (lib.cmakeBool "NCNN_VULKAN" false)
      (lib.cmakeBool "NCNN_AVX" enable_avx)
      (lib.cmakeBool "NCNN_AVX2" enable_avx2)
      (lib.cmakeBool "NCNN_AVX512" enable_avx512)
      (lib.cmakeBool "NCNN_FMA" enable_fma)
      (lib.cmakeBool "NCNN_F16C" enable_f16c)
    ];
  });

  go-tiny-dream = stdenv.mkDerivation {
    name = "go-tiny-dream";
    src = fetchFromGitHub {
      owner = "M0Rf30";
      repo = "go-tiny-dream";
      rev = "772a9c0d9aaf768290e63cca3c904fe69faf677a";
      hash = "sha256-r+wzFIjaI6cxAm/eXN3q8LRZZz+lE5EA4lCTk5+ZnIY=";
      fetchSubmodules = true;
    };
    postUnpack = ''
      rm -rf source/ncnn
      mkdir -p source/ncnn/build
      cp -r --no-preserve=mode ${go-tiny-dream-ncnn} source/ncnn/build/install
    '';
    buildFlags = [ "libtinydream.a" ];
    installPhase = ''
      mkdir $out
      tar cf - --exclude="*.o" . \
        | tar xf - -C $out
    '';
    meta.broken = lib.versionOlder go-tiny-dream.stdenv.cc.version "13";
  };

  GO_TAGS = lib.optional with_tinydream "tinydream"
    ++ lib.optional with_tts "tts"
    ++ lib.optional with_stablediffusion "stablediffusion";

  effectiveStdenv =
    if with_cublas then
    # It's necessary to consistently use backendStdenv when building with CUDA support,
    # otherwise we get libstdc++ errors downstream.
      cudaPackages.backendStdenv
    else
      stdenv;

  pname = "local-ai";
  version = "2.11.0";
  src = fetchFromGitHub {
    owner = "go-skynet";
    repo = "LocalAI";
    rev = "v${version}";
    hash = "sha256-Sqo4NOggUNb1ZemT9TRknBmz8dThe/X43R+4JFfQJ4M=";
  };

  self = buildGoModule.override { stdenv = effectiveStdenv; } {
    inherit pname version src;

    vendorHash = "sha256-3bOr8DnAjTzOpVDB5wmlPxECNteWw3tI0yc1f2Wt4y0=";

    env.NIX_CFLAGS_COMPILE = lib.optionalString with_stablediffusion " -isystem ${opencv}/include/opencv4";

    postPatch =
      let
        cp = "cp -r --no-preserve=mode,ownership";
      in
      ''
        sed -i Makefile \
          -e 's;git clone.*go-llama-ggml$;${cp} ${go-llama-ggml} sources/go-llama-ggml;' \
          -e 's;git clone.*gpt4all$;${cp} ${gpt4all} sources/gpt4all;' \
          -e 's;git clone.*go-piper$;${cp} ${if with_tts then go-piper else go-piper.src} sources/go-piper;' \
          -e 's;git clone.*go-rwkv$;${cp} ${go-rwkv} sources/go-rwkv;' \
          -e 's;git clone.*whisper\.cpp$;${cp} ${whisper-cpp.src} sources/whisper\.cpp;' \
          -e 's;git clone.*go-bert$;${cp} ${go-bert} sources/go-bert;' \
          -e 's;git clone.*diffusion$;${cp} ${if with_stablediffusion then go-stable-diffusion else go-stable-diffusion.src} sources/go-stable-diffusion;' \
          -e 's;git clone.*go-tiny-dream$;${cp} ${if with_tinydream then go-tiny-dream else go-tiny-dream.src} sources/go-tiny-dream;' \
          -e 's, && git checkout.*,,g' \
          -e '/mod download/ d' \

        ${cp} ${llama-cpp-grpc}/bin/*grpc-server backend/cpp/llama/grpc-server
        echo "grpc-server:" > backend/cpp/llama/Makefile
      ''
    ;

    buildInputs = typedBuiltInputs
      ++ lib.optional with_stablediffusion go-stable-diffusion.buildInputs
      ++ lib.optional with_tts go-piper.buildInputs;

    nativeBuildInputs = [ makeWrapper ];

    enableParallelBuilding = false;

    modBuildPhase = ''
      mkdir sources
      make prepare-sources
      go mod tidy -v
    '';

    proxyVendor = true;

    # should be passed as makeFlags, but build system failes with strings
    # containing spaces
    env.GO_TAGS = builtins.concatStringsSep " " GO_TAGS;

    makeFlags = [
      "VERSION=v${version}"
      "BUILD_TYPE=${BUILD_TYPE}"
    ]
    ++ lib.optional with_cublas "CUDA_LIBPATH=${cuda_cudart}/lib"
    ++ lib.optional with_tts "PIPER_CGO_CXXFLAGS=-DSPDLOG_FMT_EXTERNAL=1";

    buildPhase = ''
      runHook preBuild

      mkdir sources
      make prepare-sources
      # avoid rebuild of prebuilt libraries
      touch sources/**/lib*.a
      cp ${whisper-cpp}/lib/static/lib*.a sources/whisper.cpp

      local flagsArray=(
        ''${enableParallelBuilding:+-j''${NIX_BUILD_CORES}}
        SHELL=$SHELL
      )
      _accumFlagsArray makeFlags makeFlagsArray buildFlags buildFlagsArray
      echoCmd 'build flags' "''${flagsArray[@]}"
      make build "''${flagsArray[@]}"
      unset flagsArray

      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall

      install -Dt $out/bin ${pname}

      runHook postInstall
    '';

    # patching rpath with patchelf doens't work. The execuable
    # raises an segmentation fault
    postFixup =
      let
        LD_LIBRARY_PATH = [ ]
          ++ lib.optionals with_cublas [ (lib.getLib libcublas) cuda_cudart addDriverRunpath.driverLink ]
          ++ lib.optionals with_clblas [ clblast ocl-icd ]
          ++ lib.optionals with_openblas [ openblas ]
          ++ lib.optionals with_tts [ piper-phonemize ];
      in
      ''
        wrapProgram $out/bin/${pname} \
        --prefix LD_LIBRARY_PATH : "${lib.makeLibraryPath LD_LIBRARY_PATH}" \
        --prefix PATH : "${ffmpeg}/bin"
      '';

    passthru.local-packages = {
      inherit
        go-tiny-dream go-rwkv go-bert go-llama-ggml gpt4all go-piper
        llama-cpp-grpc whisper-cpp go-tiny-dream-ncnn espeak-ng' piper-phonemize
        piper-tts';
    };

    passthru.features = {
      inherit
        with_cublas with_openblas with_tts with_stablediffusion
        with_tinydream with_clblas;
    };

    passthru.tests = {
      version = testers.testVersion {
        package = self;
        version = "v" + version;
      };
      health =
        let
          port = "8080";
        in
        testers.runNixOSTest {
          name = pname + "-health";
          nodes.machine = {
            systemd.services.local-ai = {
              wantedBy = [ "multi-user.target" ];
              serviceConfig.ExecStart = "${self}/bin/local-ai --debug --localai-config-dir . --address :${port}";
            };
          };
          testScript = ''
            machine.wait_for_open_port(${port})
            machine.succeed("curl -f http://localhost:${port}/readyz")
          '';
        };
    }
    // lib.optionalAttrs with_tts {
      # https://localai.io/features/text-to-audio/#piper
      tts =
        let
          port = "8080";
          voice-en-us = fetchzip {
            url = "https://github.com/rhasspy/piper/releases/download/v0.0.2/voice-en-us-danny-low.tar.gz";
            hash = "sha256-5wf+6H5HeQY0qgdqnAG1vSqtjIFM9lXH53OgouuPm0M=";
            stripRoot = false;
          };
          ggml-tiny-en = fetchurl {
            url = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.en-q5_1.bin";
            hash = "sha256-x3xXZvHO8JtrfUfyG1Rsvd1BV4hrO11tT3CekeZsfCs=";
          };
          whisper-en = {
            name = "whisper-en";
            backend = "whisper";
            parameters.model = ggml-tiny-en.name;
          };
          models = symlinkJoin {
            name = "models";
            paths = [
              voice-en-us
              (linkFarmFromDrvs "whisper-en" [
                (writeText "whisper-en.yaml" (builtins.toJSON whisper-en))
                ggml-tiny-en
              ])
            ];
          };
        in
        testers.runNixOSTest {
          name = pname + "-tts";
          nodes.machine = {
            systemd.services.local-ai = {
              wantedBy = [ "multi-user.target" ];
              serviceConfig.ExecStart = "${self}/bin/local-ai --debug --models-path ${models} --localai-config-dir . --address :${port}";
            };
          };
          testScript =
            let
              request = {
                model = "en-us-danny-low.onnx";
                backend = "piper";
                input = "Hello, how are you?";
              };
            in
            ''
              machine.wait_for_open_port(${port})
              machine.succeed("curl -f http://localhost:${port}/readyz")
              machine.succeed("curl -f http://localhost:${port}/tts --json @${writeText "request.json" (builtins.toJSON request)} --output out.wav")
              machine.succeed("curl -f http://localhost:${port}/v1/audio/transcriptions --header 'Content-Type: multipart/form-data' --form file=@out.wav --form model=${whisper-en.name} --output transcription.json")
              machine.succeed("${jq}/bin/jq --exit-status 'debug | .segments | first.text == \"${request.input}\"' transcription.json")
            '';
        };
    };

    meta = with lib; {
      description = "OpenAI alternative to run local LLMs, image and audio generation";
      homepage = "https://localai.io";
      license = licenses.mit;
      maintainers = with maintainers; [ onny ck3d ];
      platforms = platforms.linux;
    };
  };
in
self
