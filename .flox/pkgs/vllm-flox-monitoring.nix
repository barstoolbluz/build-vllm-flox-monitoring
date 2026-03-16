{ stdenv, lib }:

stdenv.mkDerivation {
  pname = "vllm-flox-monitoring";
  version = "0.9.6";

  # Use the repo root as source, but only pull in what we need
  src = ../..;

  dontBuild = true;

  installPhase = ''
    # Install wrapper scripts
    mkdir -p $out/bin
    for script in vllm-monitoring-init vllm-monitoring-prometheus vllm-monitoring-grafana; do
      install -m 0755 "scripts/$script" "$out/bin/$script"
    done

    # Install static assets
    mkdir -p $out/share/vllm-flox-monitoring
    cp -r share/* $out/share/vllm-flox-monitoring/
  '';

  meta = with lib; {
    description = "Monitoring stack configuration for vLLM (Prometheus + Grafana dashboards, configs, and plugins)";
    platforms = [ "x86_64-linux" "aarch64-linux" ];
  };
}
