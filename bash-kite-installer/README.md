In case kite RBAC creation failed (GKE), run:
```bash
kubectl create clusterrolebinding cluster-admin-binding --clusterrole cluster-admin --user $(gcloud config get-value account)
```

Installer require `column`, so you need to install follow on machine that running the installer:
```bash
apt-get install bsdmainutils
```

Another usefull tools:
```bash
apt-get install apt-utils
```
