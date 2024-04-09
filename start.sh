#!/bin/bash

CURRENT_DIR=`dirname $0`

. ${CURRENT_DIR}/setup.sh

start_local_registry

build_custom_images "localhost:5001"

kind create cluster --config k8s/cluster/kind/kind.yaml
kubectl cluster-info
kubectl get nodes -o wide

setup_local_registry sandbox

kubectl apply -f k8s/crds

# MetalLB
helm repo add metallb https://metallb.github.io/metallb
helm upgrade --install --create-namespace --namespace metallb-system -f k8s/config/metallb-config.yaml metallb metallb/metallb --timeout=90s
# configuration options: https://github.com/metallb/metallb/tree/main/charts/metallb
# MetalLB configuration, need to check IP address pool (`k8s/infra/000-metallb.yaml`): docker network inspect -f '{{.IPAM.Config}}' kind!
# helm show values metallb --repo https://metallb.github.io/metallb

kubectl wait pods -n metallb-system -l app.kubernetes.io/instance=metallb,app.kubernetes.io/name=metallb --for condition=Ready --timeout=300s
kubectl apply -f k8s/cluster/metallb.yaml

# ### NGINX Ingress
# # helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
# # helm upgrade --install --create-namespace --namespace ingress-nginx -f k8s/config/ingress-nginx-config.yaml ingress-nginx ingress-nginx/ingress-nginx --timeout=90s
# #configuration options: https://github.com/kubernetes/ingress-nginx/blob/main/docs/user-guide/nginx-configuration/index.md

kubectl apply -f k8s/cluster/kind/kind-nginx.yaml
kubectl wait --namespace ingress-nginx --for=condition=ready pod --selector=app.kubernetes.io/component=controller --timeout=90s

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm upgrade --install --create-namespace --namespace monitoring -f k8s/config/kube-stack-config.yaml prometheus-community prometheus-community/kube-prometheus-stack
kubectl wait pods -n monitoring -l app=kube-prometheus-stack-operator,app.kubernetes.io/instance=prometheus-community --for condition=Ready --timeout=300s
# configuration options: https://github.com/prometheus-community/helm-charts/blob/main/charts/kube-prometheus-stack/README.md#configuration

helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/
helm upgrade --install --namespace kube-system -f k8s/config/metrics-server-config.yaml metrics-server metrics-server/metrics-server

# helm repo add kedacore https://kedacore.github.io/charts
# helm upgrade --install --create-namespace --namespace keda -f k8s/config/keda-config.yaml keda kedacore/keda
# # configuration options: https://github.com/kedacore/charts/blob/main/keda/README.md

# helm repo add jetstack https://charts.jetstack.io
# helm upgrade --install --create-namespace --namespace cert-manager -f k8s/config/cert-manager-config.yaml cert-manager jetstack/cert-manager
# # configuration options: https://artifacthub.io/packages/helm/cert-manager/cert-manager#configuration

helm repo add strimzi https://strimzi.io/charts
helm upgrade --install --create-namespace --namespace strimzi -f k8s/config/strimzi-config.yaml strimzi-kafka-operator strimzi/strimzi-kafka-operator
# configuration options: https://artifacthub.io/packages/helm/strimzi/strimzi-kafka-operator

helm repo add cnpg https://cloudnative-pg.github.io/charts
helm upgrade --install --create-namespace --namespace cnpg-system -f k8s/config/cnpg-config.yaml cnpg cnpg/cloudnative-pg
# configuration options: https://github.com/cloudnative-pg/charts/tree/main/charts/cloudnative-pg

kubectl wait pods -n strimzi -l strimzi.io/kind=cluster-operator --for condition=Ready --timeout=300s
kubectl wait pods -n cnpg-system -l app.kubernetes.io/name=cloudnative-pg --for condition=Ready --timeout=300s

# istioctl install --set profile=minimal -y

helm repo add istio https://istio-release.storage.googleapis.com/charts
helm upgrade --install --create-namespace --namespace istio-system istio-base istio/base --set defaultRevision=default
helm upgrade --install --namespace istio-system istiod istio/istiod --wait

kubectl apply -f k8s/operators
kubectl wait pods -n activemq-artemis-operator -l control-plane=controller-manager --for condition=Ready --timeout=300s

kubectl apply -f k8s/infra

kubectl wait pods -n opendj -l app=opendj --for condition=Ready --timeout=300s
kubectl -n opendj exec -it opendj-0 -- /bin/sh -c '/opt/opendj/bin/status --bindDN "${ROOT_USER_DN}" --bindPassword "${ROOT_PASSWORD}"'

kubectl wait kafka/my-cluster --for=condition=Ready --timeout=300s -n kafka
kubectl wait cluster/pg-sandbox --for=condition=Ready --timeout=300s -n databases

GATEWAY_IP=$(kubectl -n istio-ingress get service local-gateway-istio -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
SANDBOX_GATEWAY_IP=$(kubectl -n istio-ingress get service sandbox-gateway-istio -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

# need to write Gateway IPs into /etc/hosts (only if Ingress is replaced by Gateway API)
# sudo echo "${GATEWAY_IP} grafana.local prometheus.local alertmanager.local kafka-ui.local" >> /etc/hosts
# sudo echo "${SANDBOX_GATEWAY_IP} httpbin.sandbox" >> /etc/hosts

helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets
helm upgrade --install --namespace kube-system -f k8s/config/sealed-secrets-config.yaml sealed-secrets sealed-secrets/sealed-secrets
# configuration options: https://github.com/bitnami-labs/sealed-secrets/tree/main/helm/sealed-secrets

kubectl wait --namespace kube-system --for=condition=ready pod --selector=app.kubernetes.io/name=sealed-secrets --timeout=90s

kubeseal --controller-name=sealed-secrets-controller --controller-namespace=kube-system --fetch-cert
# echo -n bar | kubectl create secret generic -n sandbox mysecret --dry-run=client --from-file=foo=/dev/stdin -o json | kubeseal -o yaml | kubectl apply -f -
# kubectl -n sandbox get secrets mysecret -o jsonpath='{.data.foo}' | base64 -d

helm repo add stakater https://stakater.github.io/stakater-charts
helm upgrade --install --namespace kube-system -f k8s/config/reloader-config.yaml reloader stakater/reloader

while [ $(kubectl -n artemis get statefulsets.apps broker-ss -o jsonpath='{.status.availableReplicas}') -ne 3 ]; do echo '  Waiting for broker instances to start...'; sleep 1; done
echo "ActiveMQ Artemis admin account: $(kubectl -n artemis get secrets broker-credentials-secret -o jsonpath='{.data.AMQ_USER}' | base64 -d) / $(kubectl -n artemis get secrets broker-credentials-secret -o jsonpath='{.data.AMQ_PASSWORD}' | base64 -d)"

# kubectl -n artemis exec broker-ss-0 -- /opt/amq/bin/artemis consumer --url tcp://broker-lb:61616 --user user2 --password password2 --protocol core --destination topic://Q.SANDBOX.Demo::Q.SANDBOX.Demo.GROUP2 --threads 1 --message-count 10 --clientID Q.SANDBOX.Demo.GROUP2 --verbose
# kubectl -n artemis exec broker-ss-2 -- /opt/amq/bin/artemis producer --url tcp://broker-lb:61616 --user user1 --password password1 --protocol core --destination topic://Q.SANDBOX.Demo --threads 3 --message-count 10 --text-size 1024 --clientID Q.SANDBOX.Demo --verbose

# kubectl cnpg -n databases psql pg-sandbox sandbox
#  SELECT * FROM pg_available_extensions WHERE name ~ '^postgis' ORDER BY 1;
#  SELECT * FROM pg_available_extensions WHERE name ~ '^timescaledb' ORDER BY 1;
kubectl cnpg -n databases status pg-sandbox

cat sql/sandbox/001-init.sql | kubectl cnpg -n databases psql pg-sandbox sandbox

kubectl apply -f k8s/apps/sandbox/local

kubectl top pods -A
kubectl top nodes

# helm repo add signoz https://charts.signoz.io
# helm upgrade --install --create-namespace --namespace platform -f k8s/config/signoz-config.yaml my-release signoz/signoz
# # configuration options: https://github.com/signoz/charts/blob/main/charts/signoz/README.md#configuration
