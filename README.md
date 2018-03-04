# minifed

This provisions 3 instances of minikube. A management cluster (`mgmt`) for the federation control plane plus CoreDNS, and 2 sites `alpha` and `beta` under the federation context of `minifed`.


## Usage
**NOTE:** Only the virtualbox vm-driver is supported
From a mac of linux host run the `./init.sh` script in the root of the project directory. This will go through the process of provisioning the federated cluster.

#### Provisioning Process

1) The `kubefed` binary is downloaded to the `bin` directory.
2) The 3 instances of minikube are started.
3) metalLB is deployed to both the `alpha` and `beta` clusters enabling service type `LoadBalancer`.
3) The etcd operator is deployed in the `mgmt` cluster and a single node etcd instance is started.
4) A CoreDNS server is then spun up in the `mgmt` cluster to act as the method of cross-cluster service discovery.
5 ) Once the CoreDNS server is ready, the `alpha` and `beta` nodes are labeled and mock `ingress-uid` configMap entries are created.
6) `kubefed` is then used to initalize the `fed` federation control plane in the `mgmt` cluster.
7) The two clusters `alpha` and `beta` are then  joined to the federation.
8) The clusters are then labeled with additional labels (`gpu=true` and `gpu=false`)
9) Federation is then ready for use

##### Examples and Monitoring the Federation

Open a new terminal window and execute the following to watch the logs of the federation-control plane as the examples are created.
```
kubectl logs -f -l app=federated-cluster,module=federation-controller-manager --context=mgmt -n federation-system
```

##### Examples
**examples/spread.yaml** - Evenly spread the replicas across clusters `alpha` and `beta`.
**examples/selector.yaml** - Restrict scheduling of the pods to clusters that are labeled with `gpu=true`.
**examples/weighted.yaml** - Schedule based on a weighted score and defined min/maxes.

For additional scheduling preferences, see the [types.go](https://github.com/kubernetes/federation/blob/master/apis/federation/types.go) file in the federation repo.


#### Verifying the examples
The generated dns records for the associated services are queryable via the coredns service running in the management cluster.

```
dig selector.default.minifed.svc.myfed "@$(minikube ip -p mgmt)" -p 32222
dig spread.default.minifed.svc.myfed "@$(minikube ip -p mgmt)" -p 32222
dig weighted.default.minifed.svc.myfed "@$(minikube ip -p mgmt)" -p 32222
```

The examples can be accessed directly by adding the CoreDNS server to the host's resolver using the information output'ed by the init script.
```
[Sun Jan 14 12:25:53 EST 2018][INFO] Add a myfed tld
tld name: myfed
nameserver: 192.168.99.100
port: 32222
```

For OSX this would be creating a file `/etc/resolver/myfed` with the contents:
```
nameserver 192.168.99.100
port 32222
```

For other hosts with dnsmasq, adding a line to the config with the following would be sufficient:
```
server=/myfed/192.168.99.100#32222
```


**Note:** Deleting objects in a federated cluster does not function as deleting a normal object within a cluster.
https://github.com/kubernetes/federation/issues/75
