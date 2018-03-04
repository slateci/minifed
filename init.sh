#!/bin/bash

release="1.8.6"
#1st cluster will be considered fcp cluster
clusters=(mgmt alpha beta)
cluster_labels=("gpu=true" "gpu=false")
cidr_ranges=("192.168.99.208/28" "192.168.99.224/28")
metallb_template=$(cat <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  namespace: metallb-system
  name: config
data:
  config: |
    address-pools:
    - name: __CLUSTER__
      protocol: arp
      cidr:
      - __CIDR_RANGE__
EOF
)

get_kubefed() {
  echo "[$(date)][INFO] Testing for kubefed"
  if [ ! -f bin/kubefed ]; then
    echo "[$(date)][INFO] kubefed not found, fetching"
    if echo "$OSTYPE" | grep -q "darwin"; then
      os="darwin"
    elif echo "$OSTYPE" | grep -q "linux"; then
      os="linux"
    else
      echo "[$(date)][INFO] Running on an unsupported OS, terminating"
      exit 1
    fi
    wget -O bin/client.tar.gz \
      "https://storage.googleapis.com/kubernetes-release/release/$release/kubernetes-client-$os-amd64.tar.gz"
    # switched to bsd compatible tar syntax aka no --strip-components
    tar -xvzf bin/client.tar.gz -C bin kubernetes/client/bin/kubefed
    mv bin/kubernetes/client/bin/kubefed bin/kubefed
    rm -r bin/kubernetes
  fi
}


init_clusters() {
  cluster_modified=()
  cluster_ready=()
  # some really stupid hacks here to make this work with older bash and osx...
  # I am not proud of this
  for cluster in "${clusters[@]}"; do
    cluster_modified+=(false)
    cluster_ready+=(false)
    echo "[$(date)][INFO] Starting $cluster cluster"
    eval "minikube start -p $cluster > /dev/null &"
  done
  while true; do
    for ((i=0; i<${#clusters[*]}; i++)); do
      if ! jobs | grep -q "${clusters[$i]}"; then
        if [ "${cluster_modified[$i]}" == false ]; then
          echo "[$(date)][INFO] Stopping ${clusters[$i]} cluster"
          minikube stop -p "${clusters[$i]}" > /dev/null
          echo "[$(date)][INFO] Modifying ${clusters[$i]} cluster"
          VBoxManage modifyvm "${clusters[$i]}" --natdnshostresolver1 on
          echo "[$(date)][INFO] Starting ${clusters[$i]} cluster"
          eval "minikube start -p ${clusters[$i]} > /dev/null &"
          cluster_modified[$i]=true
        else
          cluster_ready[$i]=true
        fi
      fi
    done
    ready=0
    jobs > /dev/null
    for is_ready in "${cluster_ready[@]}"; do
      if $is_ready; then
        ((ready+=1))
      fi
    done

    if [ $ready -ne ${#clusters[@]} ]; then
      echo "[$(date)][INFO] Waiting for all clusters to become ready [$ready/${#clusters[@]}]"
      sleep 10
    else
      echo "[$(date)][INFO] Waiting for all clusters to become ready [$ready/${#clusters[@]}]"
      echo "[$(date)][INFO] All clusters ready [$ready/${#clusters[@]}]"
      break
    fi
  done
}


init_cluster_lb_services() {
  for ((i=1; i<${#clusters[*]}; i++)); do
    echo "[$(date)][INFO] Creating metalLB in cluster ${clusters[$i]}"
    kubectl apply -f manifests/metalLB.yaml --context="${clusters[$i]}"
    while [ "$(kubectl get deploy controller --no-headers=true --namespace=metallb-system \
            --context="${clusters[$i]}" | awk '{print $5}')" != "1" ]; do
      echo "[$(date)][INFO] Waiting for metalLB to become ready in cluster ${clusters[$i]}"
      sleep 5
    done
    echo "[$(date)][INFO] Creating metalLB config in cluster ${clusters[$i]}"
    echo "$metallb_template" | sed \
          -e "s|__CLUSTER__|${clusters[$i]}|g" -e "s|__CIDR_RANGE__|${cidr_ranges[(($i-1))]}|g" | \
      kubectl create --context="${clusters[$i]}" -f -
  done
}


init_fcp() {
  for cluster in "${clusters[@]}"; do
    kubectl label node "$cluster" \
      failure-domain.beta.kubernetes.io/zone="${cluster}1" \
      failure-domain.beta.kubernetes.io/region="$cluster" --context="$cluster"

    kubectl create configmap ingress-uid --from-literal=uid="${cluster}1" -n \
      kube-system --context="$cluster"
  done
  echo "[$(date)][INFO] Provisioning etcd-operator in ${clusters[0]} cluster"
  kubectl apply -f manifests/etcd_operator.yaml --context="${clusters[0]}"
  while [ "$(kubectl get deploy etcd-operator --no-headers=true --context="${clusters[0]}" | awk '{print $5}')" != "1" ]; do
    echo "[$(date)][INFO] Waiting for etcd-operator to become ready"
    sleep 5
  done
  echo "[$(date)][INFO] Provisioning etcd instance in ${clusters[0]} cluster"
  kubectl apply -f manifests/coreDNS_etcd.yaml --context="${clusters[0]}"
  while kubectl get pods -l app=etcd,etcd_cluster=etcd --no-headers=true --context="${clusters[0]}" 2>&1 \
        | grep -q "No resources found"; do
    echo "[$(date)][INFO] Waiting for etcd cluster to become ready"
    sleep 5
  done
  echo "[$(date)][INFO] Provisioning coreDNS service"
  kubectl apply -f manifests/coreDNS.yaml --context="${clusters[0]}"
  while [ "$(kubectl get deploy coredns --no-headers=true --context="${clusters[0]}" | awk '{print $5}')" != "1" ]; do
    echo "[$(date)][INFO] Waiting for coreDNS to become ready"
    sleep 5
  done
  echo "[$(date)][INFO] Initializing federation control plane as 'minifed'"
  bin/kubefed init minifed --host-cluster-context="${clusters[0]}" \
    --dns-provider="coredns" --dns-zone-name="slateci." \
    --api-server-service-type=NodePort \
    --api-server-advertise-address="$(minikube ip -p "${clusters[0]}")" \
    --apiserver-enable-basic-auth=true \
    --apiserver-enable-token-auth=true \
    --apiserver-arg-overrides="--anonymous-auth=true,--v=4" \
    --dns-provider-config="configs/kubefed/coredns-provider.conf"

  echo "[$(date)][INFO] Creating default namespace"
  kubectl create ns default --context=minifed
}


join_clusters() {
  for ((i=1; i<${#clusters[*]}; i++)); do
    echo "[$(date)][INFO] Joining ${clusters[$i]} cluster to federation"
    bin/kubefed join "${clusters[$i]}" --host-cluster-context="${clusters[0]}" --context=minifed
  done
}


label_clusters() {
  for ((i=1; i<${#clusters[*]}; i++)); do
    echo "[$(date)][INFO] Applying labels to ${clusters[$i]} cluster"
    kubectl label cluster "${clusters[$i]}" "${cluster_labels[(($i-1))]}"  --context=minifed
  done
}


main() {
  get_kubefed
  init_clusters
  init_cluster_lb_services
  init_fcp
  join_clusters
  label_clusters
  kubectl config use-context minifed
  echo "[$(date)][INFO] Add a slateci tld"
  echo "tld name: slateci"
  echo "nameserver: $(minikube ip -p "${clusters[0]}")"
  echo "port: 32222"
}
main "$@"
