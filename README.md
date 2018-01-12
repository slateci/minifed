# Federation PoC

This PoC provisions 3 instances of minikube. A management cluster (`mgmt`) for the federation contorl plane plus CoreDNS, and 2 sites `alpha` and `beta` under the federation context of `fed`.


## Usage
From a mac of linux host run the `./init.sh` script in the root of the project directory. This will go through the process of provisioning the federated cluster.

Once provisioning is complete the examples can be created.

Open a new terminal window and execute the following to watch the logs of the federation-control plane as the examples are created.
```
kubectl logs -f -l app=federated-cluster,module=federation-controller-manager --context=mgmt -n federation-system
```

There are 3 examples showing the different methods of scheduling in a federated environment:
**examples/spread.yaml** - Evening spread the replicas across clusters `alpha` and `beta`.
**examples/selector.yaml** - Restrict scheduling of the pods to clusters that are labeled with `gpu=true`.
**examples/weighted.yaml** - Schedule based on a weighted score and defined minimums.

For additional scheduling preferences, see the [types.go](https://github.com/kubernetes/federation/blob/master/apis/federation/types.go) file in the federation repo.

The generated dns records for the associated services are queryable via the coredns service running in the management cluster.

```
dig selector.default.fed.svc.slateci "@$(minikube ip -p mgmt)" -p 32222
dig spread.default.fed.svc.slateci "@$(minikube ip -p mgmt)" -p 32222
dig weighted.default.fed.svc.slateci "@$(minikube ip -p mgmt)" -p 32222
```

**Note:** Deleting objects in a federated cluster does not function as deleting a normal object within a cluster.
https://github.com/kubernetes/federation/issues/75
