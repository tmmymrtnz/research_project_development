#!/bin/bash

set -e

# Create Kubernetes resource files
cat <<EOF > namespaces.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: test-a
---
apiVersion: v1
kind: Namespace
metadata:
  name: test-b
EOF

cat <<EOF > deployments.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: pod-a
  namespace: test-a
spec:
  replicas: 1
  selector:
    matchLabels:
      app: pod-a
  template:
    metadata:
      labels:
        app: pod-a
    spec:
      containers:
      - name: client
        image: curlimages/curl
        command: ["sleep", "3600"]
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: pod-b
  namespace: test-b
spec:
  replicas: 1
  selector:
    matchLabels:
      app: pod-b
  template:
    metadata:
      labels:
        app: pod-b
    spec:
      containers:
      - name: http-server
        image: nginx
        ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: pod-b
  namespace: test-b
spec:
  selector:
    app: pod-b
  ports:
  - protocol: TCP
    port: 80
    targetPort: 80
EOF

cat <<EOF > cilium-policy.yaml
apiVersion: "cilium.io/v2"
kind: CiliumNetworkPolicy
metadata:
  name: deny-test-a-to-b
  namespace: test-b
spec:
  endpointSelector:
    matchLabels:
      app: pod-b
  ingress:
  - fromEndpoints:
    - matchLabels:
        app: pod-a
EOF

## Apply resources and wait for readiness
kubectl apply -f namespaces.yaml -f deployments.yaml
kubectl wait --for=condition=ready pod -l app=pod-a -n test-a --timeout=60s
kubectl wait --for=condition=ready pod -l app=pod-b -n test-b --timeout=60s

# Get Pod IP directly to ensure connectivity
POD_B_IP=$(kubectl get pod -l app=pod-b -n test-b -o jsonpath='{.items[0].status.podIP}')
POD_A=$(kubectl get pod -l app=pod-a -n test-a -o jsonpath='{.items[0].metadata.name}')

sleep 5

echo "Testing without network policy (should succeed):"
kubectl exec -n test-a $POD_A -- curl -m 5 -s $POD_B_IP && echo "Success" || echo "Failed"

# Apply Cilium Network Policy
kubectl apply -f cilium-policy.yaml
sleep 5

echo "Testing with network policy (should fail):"
kubectl exec -n test-a $POD_A -- curl -m 5 -s $POD_B_IP && echo "Policy bypassed" || echo "Connection blocked"

# Remove the policy
kubectl delete -f cilium-policy.yaml
sleep 5

echo "Testing after removing network policy (should succeed):"
kubectl exec -n test-a $POD_A -- curl -m 5 -s $POD_B_IP && echo "Success" || echo "Failed"

kubectl delete -f deployments.yaml -f namespaces.yaml
exit 0