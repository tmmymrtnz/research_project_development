#!/bin/bash

# Exit the script on any error
set -e

# Function to output error messages and exit
function error {
    echo "Error: $1"
    exit 1
}

# Helper function to execute commands on the k3s-lead node
function run_on_k3s_lead() {
    multipass exec k3s-lead -- bash -c "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml && $*"
}

# Check if Multipass is installed; install it if not
if ! command -v multipass &> /dev/null; then
    echo "Installing Multipass..."
    sudo snap install multipass || error "Failed to install Multipass"
fi

# Clean up existing Multipass nodes to start fresh
if multipass list | grep -q "k3s-lead"; then
    echo "Deleting existing k3s-lead node..."
    multipass delete k3s-lead
    multipass purge
fi

if multipass list | grep -q "k3s-follower"; then
    echo "Deleting existing k3s-follower node..."
    multipass delete k3s-follower
    multipass purge
fi

# Create a new VM for the k3s leader
echo "Creating k3s leader VM..."
multipass launch --name k3s-lead --memory 4G --disk 20G || error "Failed to create k3s leader VM"

# Retrieve the IP address of the k3s leader node
echo "Retrieving k3s leader IP..."
IP=$(multipass info k3s-lead | awk '/IPv4/ {print $2}') || error "Failed to retrieve k3s leader IP"
echo "Leader node IP: $IP"

# Install k3s on the leader node
echo "Installing k3s on leader VM..."
run_on_k3s_lead "curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC='--flannel-backend=none --disable-network-policy --advertise-address=$IP --tls-san=$IP' sh -" || error "Failed to install k3s on leader"

# Adjust kubeconfig permissions
echo "Adjusting permissions for kubeconfig..."
run_on_k3s_lead "sudo chmod 644 /etc/rancher/k3s/k3s.yaml" || error "Failed to adjust permissions for kubeconfig"

# Update kubeconfig with external IP
echo "Updating server address in k3s.yaml..."
run_on_k3s_lead "sudo sed -i 's|server:.*|server: https://$IP:6443|' /etc/rancher/k3s/k3s.yaml" || error "Failed to update server address in k3s.yaml"

# Mount BPF filesystem
echo "Mounting BPF filesystem..."
run_on_k3s_lead "sudo mount bpffs /sys/fs/bpf -t bpf" || error "Failed to mount BPF filesystem"

# Retrieve node token
echo "Retrieving k3s token..."
TOKEN=$(run_on_k3s_lead "sudo cat /var/lib/rancher/k3s/server/node-token") || error "Failed to retrieve k3s token"

# Create follower node
echo "Creating k3s follower VM..."
multipass launch --name k3s-follower --memory 3G --disk 20G || error "Failed to create k3s follower VM"

# Join follower node to cluster
echo "Joining follower VM to cluster..."
multipass exec k3s-follower -- bash -c "curl -sfL https://get.k3s.io | K3S_URL=https://$IP:6443 K3S_TOKEN=$TOKEN sh -" || error "Failed to join follower to cluster"

# Install Helm
echo "Installing Helm..."
run_on_k3s_lead "curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash" || error "Failed to install Helm"

## Install Loki, Fluent Bit, and Grafana for logging
echo "Installing Loki, Fluent Bit, and Grafana..."
run_on_k3s_lead '
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update
helm install loki grafana/loki-stack --version 2.9.11 --namespace logging --create-namespace \
  --set grafana.enabled=true \
  --set grafana.adminPassword=admin
' || error "Failed to install Loki and Grafana"

# Create Fluent Bit ServiceAccount
echo "Creating Fluent Bit ServiceAccount..."
run_on_k3s_lead "kubectl create serviceaccount fluent-bit -n logging --dry-run=client -o yaml | kubectl apply -f -"

# Deploy Fluent Bit first (without the ConfigMap initially)
echo "Deploying Fluent Bit..."
run_on_k3s_lead "kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: fluent-bit
  namespace: logging
  labels:
    app: fluent-bit
spec:
  selector:
    matchLabels:
      app: fluent-bit
  template:
    metadata:
      labels:
        app: fluent-bit
    spec:
      serviceAccountName: fluent-bit
      containers:
      - name: fluent-bit
        image: fluent/fluent-bit:latest
        imagePullPolicy: Always
        args:
        - -c
        - /fluent-bit/etc/fluent-bit.conf
        env:
        - name: NODE_NAME
          valueFrom:
            fieldRef:
              fieldPath: spec.nodeName
        volumeMounts:
        - name: varlog
          mountPath: /var/log
        - name: fluent-bit-config
          mountPath: /fluent-bit/etc/
          readOnly: true
      terminationGracePeriodSeconds: 10
      volumes:
      - name: varlog
        hostPath:
          path: /var/log
      - name: fluent-bit-config
        configMap:
          name: fluent-bit-config
          defaultMode: 420
  updateStrategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 1
EOF" || error "Failed to deploy Fluent Bit"

# Wait for Fluent Bit to be ready before applying the ConfigMap
echo "Waiting for Fluent Bit to be ready..."
sleep 10  # Adjust if needed

echo "Creating Fluent Bit ConfigMap..."
run_on_k3s_lead "kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: fluent-bit-config
  namespace: logging
data:
  fluent-bit.conf: |-
    [SERVICE]
        Flush        5
        Daemon       Off
        Log_Level    debug
        Parsers_File parsers.conf

    [INPUT]
        Name              tail
        Path              /var/log/containers/*cilium*.log
        Parser            docker
        Tag               kube.*
        Mem_Buf_Limit     5MB
        Refresh_Interval  5

    [FILTER]
        Name              modify
        Match             *
        Add               node \\\${NODE_NAME}

    [OUTPUT]
        Name              loki
        Match             *
        Host              loki.logging.svc.cluster.local
        Port              3100
        Labels            job=fluent-bit,app=cilium,node=\\\${NODE_NAME}
        Line_Format       json
        Auto_Kubernetes_Labels On
EOF" || error "Failed to create Fluent Bit ConfigMap"

# Restart Fluent Bit to load the updated config
echo "Restarting Fluent Bit to apply the ConfigMap..."
run_on_k3s_lead "kubectl rollout restart daemonset fluent-bit -n logging" || error "Failed to restart Fluent Bit"

# Install Cilium using Helm
echo "Installing Cilium using Helm..."
run_on_k3s_lead '
helm repo add cilium https://helm.cilium.io
helm repo update

helm install cilium cilium/cilium \
  --namespace kube-system \
  --set image.repository=docker.io/tmmymrtnez/cilium-dev \
  --set image.digest="sha256:38900aa3da2bbb85c196a4266b11025aa9e217523cecbdc9bf1e9cb04bcdbf6c" \
  --set image.pullPolicy=IfNotPresent \
  --set ipam.mode=kubernetes \
  --set ipam.operator.clusterPoolIPv4PodCIDRList="10.42.0.0/16" \
  --set bpf.mount=true \
  --set debug.enabled=true
' || error "Failed to install Cilium"

# Nullify operator values before installing custom operator
run_on_k3s_lead "helm upgrade cilium cilium/cilium --namespace kube-system --set operator.*=null"

# Deploy custom operator
run_on_k3s_lead "kubectl scale deployment cilium-operator -n kube-system --replicas=0"
sleep 5
run_on_k3s_lead "helm upgrade cilium cilium/cilium --namespace kube-system --reuse-values --set operator.image.override=\"docker.io/tmmymrtnez/operator-generic:amd64\" --set operator.replicas=2"
run_on_k3s_lead "kubectl scale deployment cilium-operator -n kube-system --replicas=2"

# Deploy custom agent
run_on_k3s_lead "helm upgrade cilium cilium/cilium --namespace kube-system --reuse-values --set image.repository=\"docker.io/tmmymrtnez/cilium-dev\" --set image.tag=\"amd64\" --set image.pullPolicy=IfNotPresent --set image.useDigest=false"

# Install Cilium CLI
echo "Installing Cilium CLI..."
run_on_k3s_lead "
CILIUM_CLI_VERSION=\$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
ARCH=\$(uname -m)
CLI_ARCH=\$( [ \"\$ARCH\" = \"x86_64\" ] && echo 'amd64' || echo 'arm64' )

echo \"Downloading Cilium CLI version \$CILIUM_CLI_VERSION for architecture \$CLI_ARCH...\"
curl -L --fail --remote-name-all https://github.com/cilium/cilium-cli/releases/download/\${CILIUM_CLI_VERSION}/cilium-linux-\${CLI_ARCH}.tar.gz{,.sha256sum}

sha256sum --check cilium-linux-\${CLI_ARCH}.tar.gz.sha256sum
sudo tar xzvfC cilium-linux-\${CLI_ARCH}.tar.gz /usr/local/bin
rm cilium-linux-\${CLI_ARCH}.tar.gz cilium-linux-\${CLI_ARCH}.tar.gz.sha256sum
echo 'Cilium CLI installed successfully!'
" || error "Failed to install Cilium CLI"

# Wait for Cilium
echo "Waiting for Cilium to be ready..."
run_on_k3s_lead "kubectl wait --for=condition=ready pods -n kube-system -l k8s-app=cilium --timeout=60s"

# Deploy test Nginx service
echo "Deploying Nginx..."
run_on_k3s_lead "kubectl create deployment nginx --image=nginx" || error "Failed to deploy Nginx"
run_on_k3s_lead "kubectl expose deployment nginx --type=ClusterIP --port=80" || error "Failed to expose Nginx"

# Wait for Nginx pods
echo "Waiting for Nginx to be ready..."
run_on_k3s_lead "kubectl wait --for=condition=ready pods -l app=nginx --timeout=120s"

# Install Hubble
echo "Installing Hubble..."
HUBBLE_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/hubble/master/stable.txt)
HUBBLE_ARCH=amd64
if [ "$(uname -m)" = "arm64" ]; then HUBBLE_ARCH=arm64; fi
curl -L --fail --remote-name-all "https://github.com/cilium/hubble/releases/download/${HUBBLE_VERSION}/hubble-linux-${HUBBLE_ARCH}.tar.gz{,.sha256sum}"
sha256sum --check "hubble-linux-${HUBBLE_ARCH}.tar.gz.sha256sum"
sudo tar xzvf "hubble-linux-${HUBBLE_ARCH}.tar.gz" -C /usr/local/bin
rm "hubble-linux-${HUBBLE_ARCH}.tar.gz" "hubble-linux-${HUBBLE_ARCH}.tar.gz.sha256sum"

# Enable Hubble
echo "Enabling Hubble..."
run_on_k3s_lead "
helm upgrade cilium cilium/cilium --reuse-values \
  --namespace kube-system \
  --set hubble.enabled=true \
  --set hubble.relay.enabled=true \
  --set hubble.ui.enabled=true
"

# Verify installation
echo "Verifying Cilium and Hubble..."
run_on_k3s_lead "cilium status"

# Post-setup check for Grafana
echo "Checking Grafana pod status..."
run_on_k3s_lead "kubectl wait --for=condition=ready pod -n logging -l app=grafana --timeout=120s" || error "Grafana pod not ready"

# Updated Grafana access instructions with port 32000
echo "Setup complete!"
echo "To access Grafana from your host:"
echo "1. Run this on k3s-lead VM:"
echo "   multipass exec k3s-lead -- bash -c 'kubectl port-forward svc/loki-grafana 32000:80 -n logging --address 0.0.0.0'"
echo "2. Open http://$IP:32000 in your browser"
echo "3. Log in with user 'admin' and password from this command (run on k3s-lead):"
echo "   kubectl get secret --namespace logging loki-grafana -o jsonpath=\"{.data.admin-password}\" | base64 --decode ; echo"
echo "4. Ensure port 32000 is open on the VM:"
echo "   multipass exec k3s-lead -- sudo ufw allow 32000"