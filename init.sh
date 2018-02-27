#!/bin/bash
release="v1.8.6"

echo "[$(date)][INFO] Testing for kubefed"
if [ ! -f bin/kubefed ]; then
  echo "[$(date)][INFO] kubefed not found, fetching."
  if echo "$OSTYPE" | grep -q "darwin"; then
    os="darwin"
  elif echo "$OSTYPE" | grep -q "linux"; then
    os="linux"
  else
    echo "[$(date)][INFO] Running on an unsupported OS, terminating."
    exit 1
  fi
  wget -O bin/client.tar.gz \
    "https://storage.googleapis.com/kubernetes-release/release/$release/kubernetes-client-$os-amd64.tar.gz"
  # switched to bsd compatible tar syntax aka no --strip-components
  tar -xvzf bin/client.tar.gz -C bin kubernetes/client/bin/kubefed
  mv bin/kubernetes/client/bin/kubefed bin/kubefed
  rm -r bin/kubernetes
fi

echo "[$(date)][INFO] Starting management cluster."
minikube start -p mgmt
echo "[$(date)][INFO] Creating alpha cluster."
if VBoxManage list vms | grep -q "\"alpha\"" && ! VBoxManage  list runningvms | grep -q "\"alpha\""; then
  VBoxManage modifyvm alpha --natdnshostresolver1 on
  minikube start -p alpha
else
  # awful hack because we can't "create" a minikube instance
  minikube start -p alpha
  echo "[$(date)][INFO] Modifying DNS configuration for alpha cluster."
  minikube stop -p alpha
  VBoxManage modifyvm alpha --natdnshostresolver1 on
  minikube start -p alpha
fi

echo "[$(date)][INFO] Creating beta cluster."
if VBoxManage  list vms | grep -q "\"beta\""  && ! VBoxManage  list runningvms | grep -q "\"beta\""; then
  VBoxManage modifyvm beta --natdnshostresolver1 on
  minikube start -p beta
else
  # awful hack because we can't "create" a minikube instance
  minikube start -p beta
  echo "[$(date)][INFO] Modifying DNS configuration for beta cluster."
  minikube stop -p beta
  VBoxManage modifyvm beta --natdnshostresolver1 on
  minikube start -p beta
fi

mgmt_ip=$(minikube ip -p mgmt)
alpha_ip=$(minikube ip -p alpha)
beta_ip=$(minikube ip -p beta)

echo "[$(date)][INFO] Provisioning etcd-operator in mgmt cluster"
kubectl apply -f etcd/deploy.yaml --context=mgmt
while [ "$(kubectl get deploy etcd-operator --no-headers=true --context=mgmt | awk '{print $5}')" != "1" ]; do
  echo "[$(date)][INFO] Waiting for etcd-operator to become ready."
  sleep 5
done
echo "[$(date)][INFO] Provisioning etcd instance mgmt cluster"
kubectl apply -f etcd/cluster.yaml --context=mgmt
while kubectl get pods -l app=etcd,etcd_cluster=etcd --no-headers=true --context=mgmt 2>&1 \
      | grep -q "No resources found"; do
  echo "[$(date)][INFO] Waiting for etcd cluster to become ready."
  sleep 5
done

echo "[$(date)][INFO] Provisioning coreDNS service."
kubectl apply -f coreDNS/ --context=mgmt
while [ "$(kubectl get deploy coredns --no-headers=true --context=mgmt | awk '{print $5}')" != "1" ]; do
  echo "[$(date)][INFO] Waiting for coreDNS to become ready."
  sleep 5
done

echo "[$(date)][INFO] Seeding cluster information."
kubectl label node alpha \
  failure-domain.beta.kubernetes.io/zone=alpha1 \
  failure-domain.beta.kubernetes.io/region=alpha --context=alpha
kubectl label node beta \
  failure-domain.beta.kubernetes.io/zone=beta1 \
  failure-domain.beta.kubernetes.io/region=beta --context=beta

kubectl create configmap ingress-uid --from-literal=uid=alpha1 -n kube-system --context=alpha
kubectl create configmap ingress-uid --from-literal=uid=beta1 -n kube-system --context=beta

echo "[$(date)][INFO] Initializing federation control plane as 'fed'."
bin/kubefed init fed --host-cluster-context=mgmt \
  --dns-provider="coredns" --dns-zone-name="slateci." \
  --api-server-service-type=NodePort \
  --api-server-advertise-address="$(minikube ip -p mgmt)" \
  --apiserver-enable-basic-auth=true \
  --apiserver-enable-token-auth=true \
  --apiserver-arg-overrides="--anonymous-auth=true,--v=4" \
  --dns-provider-config="config-kubefed/coredns-provider.conf"

echo "[$(date)][INFO] Joining alpha and beta clusters to federation."
kubectl config use-context fed
kubectl create ns default
bin/kubefed join alpha --host-cluster-context=mgmt
bin/kubefed join beta --host-cluster-context=mgmt
echo "[$(date)][INFO] Federation 'fed' ready with alpha and beta clusters joined."
echo "[$(date)][INFO] Labeling clusters."
kubectl label cluster alpha gpu=true
kubectl label cluster beta gpu=false

echo "[$(date)][INFO] Rendering Example templates."
cp -r templates/ examples/
find examples -type f -name '*.yaml' -exec sed -i -e "s/__ALPHA__/$alpha_ip/g" -e "s/__BETA__/$beta_ip/g" {} \;

echo "[$(date)][INFO] Creating nginx helper configMap"
kubectl create cm nginx-entrypoint --from-file=scripts/entrypoint.sh

echo "[$(date)][INFO] Add a slateci tld"
echo "tld name: slateci"
echo "nameserver: $mgmt_ip"
echo "port: 32222"
