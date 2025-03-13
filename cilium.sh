#!/bin/bash

# Exit the script on any error
set -e

# Function to output error messages and exit
function error {
    echo "Error: $1"
    exit 1
}

# Helper function to execute commands on the k3s-lead node
# Automatically sets KUBECONFIG for every command
function run_on_k3s_lead() {
    multipass exec k3s-lead -- bash -c "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml && $*"
}

# Check if Homebrew is installed, as it is required to manage Multipass
if ! command -v brew &> /dev/null; then
    error "Homebrew is not installed. Please install it first."
fi

# Check if Multipass is installed; install it if not
if ! command -v multipass &> /dev/null; then
    echo "Installing Multipass..."
    brew install --cask multipass || error "Failed to install Multipass"
fi

# Clean up existing Multipass nodes to start fresh
if multipass list | grep -q "k3s-lead"; then
    echo "Deleting existing k3s-lead node..."
    multipass delete k3s-lead
fi

if multipass list | grep -q "k3s-follower"; then
    echo "Deleting existing k3s-follower node..."
    multipass delete k3s-follower
fi

# Remove any purged instances
multipass purge

# Create a new VM for the k3s leader (control plane)
echo "Creating k3s leader VM..."
multipass launch --name k3s-lead --memory 4G --disk 20G || error "Failed to create k3s leader VM"

# Retrieve the IP address of the k3s leader node
echo "Retrieving k3s leader IP..."
IP=$(multipass info k3s-lead | grep 'IPv4' | awk '{print $2}') || error "Failed to retrieve k3s leader IP"
echo "Leader node IP: $IP"

# Install k3s on the leader node with settings compatible with Cilium
echo "Installing k3s on leader VM..."
run_on_k3s_lead "curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC='--flannel-backend=none --disable-network-policy --advertise-address=$IP --tls-san=$IP' sh -" || error "Failed to install k3s on leader"

# Adjust kubeconfig permissions so it can be accessed for cluster management
echo "Adjusting permissions for kubeconfig..."
run_on_k3s_lead "sudo chmod 644 /etc/rancher/k3s/k3s.yaml" || error "Failed to adjust permissions for kubeconfig"

# Update kubeconfig to use the external IP of the leader node
echo "Updating server address in k3s.yaml..."
run_on_k3s_lead "sudo sed -i 's/server:.*/server: https:\/\/$IP:6443/' /etc/rancher/k3s/k3s.yaml" || error "Failed to update server address in k3s.yaml"

# Mount the BPF filesystem, required for Cilium
echo "Mounting BPF filesystem..."
run_on_k3s_lead "sudo mount bpffs /sys/fs/bpf -t bpf" || error "Failed to mount BPF filesystem"

# Retrieve the node token to add follower nodes to the cluster
echo "Retrieving k3s token..."
TOKEN=$(run_on_k3s_lead "sudo cat /var/lib/rancher/k3s/server/node-token") || error "Failed to retrieve k3s token" ----------

# Create a follower VM to join the cluster
echo "Creating k3s follower VM..."
multipass launch --name k3s-follower --memory 3G --disk 20G || error "Failed to create k3s follower VM"

# Join the follower VM to the cluster using the retrieved token
echo "Joining follower VM to the cluster..."
multipass exec k3s-follower -- bash -c "curl -sfL https://get.k3s.io | K3S_URL=https://$IP:6443 K3S_TOKEN=$TOKEN sh -" || error "Failed to join follower to the cluster"

# Set up kubectl and install Helm for managing deployments
echo "Setting up kubectl and Helm..."
run_on_k3s_lead "curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash" || error "Failed to install Helm" ----------

# Install Cilium CLI for managing Cilium
echo "Installing Cilium CLI..."
run_on_k3s_lead "
CILIUM_CLI_VERSION=\$(curl -s https://raw.githubusercontent.com/tmmymrtnz/my-cilium/main/stable.txt)
ARCH=\$(uname -m)
if [ \"\$ARCH\" = \"x86_64\" ]; then
    ARCH=\"amd64\"
elif [ \"\$ARCH\" = \"aarch64\" ] || [ \"\$ARCH\" = \"arm64\" ]; then
    ARCH=\"arm64\"
else
    error \"Unsupported architecture: \$ARCH\"
fi
curl -L --remote-name-all https://github.com/tmmymrtnz/my-cilium/releases/download/\${CILIUM_CLI_VERSION}/cilium-linux-\${ARCH}.tar.gz{,.sha256sum}
sha256sum --check cilium-linux-\${ARCH}.tar.gz.sha256sum
sudo tar xzvfC cilium-linux-\${ARCH}.tar.gz /usr/local/bin
rm cilium-linux-\${ARCH}.tar.gz{,.sha256sum}
" || error "Failed to install Cilium CLI"

# Install Cilium using Helm
echo "Installing Cilium using Helm..."
run_on_k3s_lead "
helm repo add cilium https://helm.cilium.io && \
helm repo update && \
helm install cilium cilium/cilium \
  --namespace kube-system \
  --set kubeProxyReplacement=true \
  --set k8sServiceHost=$IP \
  --set k8sServicePort=6443 \
  --set ipam.mode=kubernetes
" || error "Failed to install Cilium"

# Wait for Cilium to be fully operational
echo "Waiting for Cilium to be ready..."
run_on_k3s_lead "kubectl wait --for=condition=ready pods -n kube-system -l k8s-app=cilium --timeout=120s"

# Deploy and expose an Nginx server
echo "Deploying Nginx server..."
run_on_k3s_lead "kubectl create deployment nginx --image=nginx" || error "Failed to deploy Nginx"
run_on_k3s_lead "kubectl expose deployment nginx --type=ClusterIP --port=80" || error "Failed to expose Nginx"

# Wait for Nginx pods to become ready
echo "Waiting for Nginx pods to be ready..."
run_on_k3s_lead "kubectl wait --for=condition=ready pods -l app=nginx --timeout=120s"

# Get the ClusterIP of the Nginx service
NGINX_IP=$(run_on_k3s_lead "kubectl get svc nginx -o jsonpath='{.spec.clusterIP}'")
echo "Nginx Service IP: $NGINX_IP"

# Deploy a curlpod to test the Nginx service
echo "Creating curlpod to test Nginx..."
run_on_k3s_lead "kubectl run curlpod --image=curlimages/curl --restart=Never -- /bin/sh -c 'curl $NGINX_IP'"

# Install and configure Hubble for network observability
echo "Installing Hubble..."
HUBBLE_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/hubble/master/stable.txt)
HUBBLE_ARCH=$(uname -m)
if [ "$HUBBLE_ARCH" = "x86_64" ]; then
    HUBBLE_ARCH="amd64"
elif [ "$HUBBLE_ARCH" = "aarch64" ] || [ "$HUBBLE_ARCH" = "arm64" ]; then
    HUBBLE_ARCH="arm64"
else
    error "Unsupported architecture: $HUBBLE_ARCH"
fi
run_on_k3s_lead "
curl -L --remote-name-all https://github.com/cilium/hubble/releases/download/\${HUBBLE_VERSION}/hubble-linux-\${HUBBLE_ARCH}.tar.gz{,.sha256sum}
sha256sum --check hubble-linux-\${HUBBLE_ARCH}.tar.gz.sha256sum
sudo tar xzvf hubble-linux-\${HUBBLE_ARCH}.tar.gz -C /usr/local/bin
rm hubble-linux-\${HUBBLE_ARCH}.tar.gz{,.sha256sum}
" || error "Failed to install Hubble"

# Enable Hubble with Helm upgrade
echo "Enabling Hubble with Helm..."
run_on_k3s_lead "
helm upgrade cilium cilium/cilium --reuse-values \
  --namespace kube-system \
  --set hubble.enabled=true \
  --set hubble.relay.enabled=true \
  --set hubble.ui.enabled=true
"

# Verify Cilium and Hubble status
echo "Verifying Cilium and Hubble status..."
run_on_k3s_lead "cilium status"

echo "K3s cluster with Cilium, Hubble, and Nginx setup is complete!"
