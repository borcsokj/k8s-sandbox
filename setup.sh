#!/bin/bash

set -o errexit

CURRENT_DIR=`dirname $0`

# https://github.com/rpardini/docker-registry-proxy#kind-cluster
# https://kind.sigs.k8s.io/docs/user/local-registry/

reg_name='registry'
reg_port='5001'

function start_local_registry()
{
  docker pull registry:2

  if [ "$(docker inspect -f '{{.State.Running}}' "${reg_name}" 2>/dev/null || true)" != 'true' ]; then
    docker run \
      -itd --restart=always -p "127.0.0.1:${reg_port}:5000" --network bridge --name "${reg_name}" \
      -v $(pwd)/docker_registry:/var/lib/registry \
      registry:2
  fi

# docker run -itd --name proxy-docker-io \
#   --restart=always \
#   --network bridge \
#   -e REGISTRY_PROXY_REMOTEURL=https://registry-1.docker.io \
#   -v $(pwd)/docker_registry/docker.io:/var/lib/registry \
#   registry:2
#
# docker run -itd --name proxy-quay-io \
#   --restart=always \
#   --network bridge \
#   -e REGISTRY_PROXY_REMOTEURL=https://quay.io \
#   -v $(pwd)/docker_registry/quay.io:/var/lib/registry \
#   registry:2
#
# docker run -itd --name proxy-registry-k8s-io \
#   --restart=always \
#   --network bridge \
#   -e REGISTRY_PROXY_REMOTEURL=https://registry.k8s.io \
#   -v $(pwd)/docker_registry/registry.k8s.io:/var/lib/registry \
#   registry:2
#
# docker run -itd --name proxy-ghcr-io \
#   --restart=always \
#   --network bridge \
#   -e REGISTRY_PROXY_REMOTEURL=https://ghcr.io \
#   -v $(pwd)/docker_registry/ghcr.io:/var/lib/registry \
#   registry:2
}

function setup_local_registry()
{
  cluster_name=$1
  REGISTRY_DIR="/etc/containerd/certs.d/localhost:${reg_port}"
  for node in $(kind get nodes -n $cluster_name); do
    docker exec "${node}" mkdir -p "${REGISTRY_DIR}"
    cat <<EOF | docker exec -i "${node}" cp /dev/stdin "${REGISTRY_DIR}/hosts.toml"
[host."http://${reg_name}:5000"]
EOF
  done

  if [ "$(docker inspect -f='{{json .NetworkSettings.Networks.kind}}' "${reg_name}")" = 'null' ]; then
    docker network connect "kind" "${reg_name}"
#    docker network connect "kind" "proxy-docker-io"
#    docker network connect "kind" "proxy-quay-io"
#    docker network connect "kind" "proxy-ghcr-io"
#    docker network connect "kind" "proxy-registry-k8s-io"
  fi

  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
    host: "localhost:${reg_port}"
    help: "https://kind.sigs.k8s.io/docs/user/local-registry/"
EOF
}

function build_custom_images()
{
  registry="${1:-localhost:5001}"

  debezium_connect_image="${registry}/debezium-connect:0.40.0"
  docker build -t "${debezium_connect_image}" -f "${CURRENT_DIR}/docker/Dockerfile.debezium-connect" .
  docker push "${debezium_connect_image}"

  postgresql_image="${registry}/timescaledb-postgis:16"
  docker build -t "${postgresql_image}" -f "${CURRENT_DIR}/docker/Dockerfile.timescaledb-postgis" .
  docker push "${postgresql_image}"
}
