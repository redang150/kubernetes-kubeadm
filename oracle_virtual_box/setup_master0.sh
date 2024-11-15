#!/bin/bash

# Prerequisites
echo "Disabling swap..."
sudo swapoff -a
sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

# Install Docker
echo "Installing Docker..."
sudo apt-get update -y
sudo apt-get install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo tee /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update -y
sudo apt-get install -y docker-ce docker-ce-cli containerd.io

# Configure sysctl for Kubernetes networking
echo "Configuring sysctl for Kubernetes networking..."
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
br_netfilter
EOF
sudo modprobe br_netfilter

cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF
sudo sysctl --system

# Configure containerd for Kubernetes
echo "Configuring containerd..."
sudo mkdir -p /etc/containerd
sudo containerd config default | sudo tee /etc/containerd/config.toml

# Modify /etc/containerd/config.toml to enable CRI
sudo sed -i '/disabled_plugins/d' /etc/containerd/config.toml
sudo sed -i '/sandbox_image =/c\    sandbox_image = "registry.k8s.io/pause:3.9"' /etc/containerd/config.toml

# Restart containerd
sudo systemctl restart containerd
sudo systemctl enable containerd

# Manually install crictl
echo "Installing crictl manually..."
CRICTL_VERSION="v1.27.1"
curl -L https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-amd64.tar.gz -o crictl.tar.gz
sudo tar -C /usr/local/bin -xzf crictl.tar.gz
rm -f crictl.tar.gz

# Verify CRI is correctly configured
echo "Verifying CRI configuration with crictl..."
if ! sudo crictl info; then
    echo "CRI configuration failed. Please check containerd setup."
    exit 1
fi

# Install kubeadm, kubelet, and kubectl
echo "Installing kubeadm, kubelet, kubectl..."
sudo apt-get update -y
sudo apt-get install -y apt-transport-https ca-certificates curl gpg
sudo mkdir -p -m 755 /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.31/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.31/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt-get update -y
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl

# Initialize Kubernetes cluster with the correct network interface IP
INTERFACE="enp0s8"
IP_ADDRESS=$(ip -4 addr show $INTERFACE | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
echo "Initializing Kubernetes cluster..."
sudo kubeadm init --apiserver-advertise-address=$IP_ADDRESS --pod-network-cidr=10.244.0.0/16 --ignore-preflight-errors=CRI
if [ $? -ne 0 ]; then
    echo "Kubeadm initialization failed."
    exit 1
fi

# Configure kubectl
echo "Setting up kubectl for the master node..."
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

# Install Flannel network plugin
echo "Installing Flannel network plugin..."
kubectl apply -f https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml --validate=false
if [ $? -ne 0 ]; then
    echo "Flannel installation failed. Please verify network connectivity and configuration."
    exit 1
fi

echo "Master node setup complete. Please save the join command displayed above for use on the worker nodes."

