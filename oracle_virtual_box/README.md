# Vagrant Kubernetes Cluster Setup
# Overview
This Vagrant script provisions a local Kubernetes cluster environment using VirtualBox, creating one master node and two worker nodes on an Ubuntu Bionic (18.04) base image. The setup enables you to experiment with Kubernetes in a controlled local environment, ideal for testing and learning purposes.

# Purpose
The script automates the provisioning and configuration of virtual machines (VMs) that mimic a Kubernetes cluster. It defines:

One master node: Responsible for managing the cluster, maintaining the API server, and scheduling workloads.
Two worker nodes: Nodes where the applications (pods) will run.
Configuration 

## Network
The virtual machines are connected on a private network with IPs in the range 192.168.56.X. The master node IP starts at 192.168.56.1, while worker nodes increment from 192.168.56.2.

Memory and CPU
Each node is configured with:

- **Memory: 2 GB**
- **CPUs: 2 cores**
Port Forwarding
SSH access to each VM is provided by forwarding ports on the host machine:

**Master Node:** Port 2711 maps to guest port 22.
**Worker Nodes:** Ports 2721 and 2722 map to guest port 22.
Provisioning Scripts
The VMs are configured with two shell scripts:

**setup-hosts.sh:** Updates /etc/hosts in each VM with the IPs and hostnames of all cluster nodes.
**update-dns.sh:** Configures DNS settings specific to this environment.

Usage
Clone this repository and navigate to the directory.
Run vagrant up to start and provision the VMs.
- **Vagrant up**

SSH into the master or worker nodes using
- **vagrant ssh kubenode01**
- **vagrant ssh kubemaster** 
- **vagrant ssh kubenode02**

## Important Notes
**Node Scaling:** To change the number of master or worker nodes, adjust the NUM_MASTER_NODE and NUM_WORKER_NODE values in the script and update the setup-hosts.sh script accordingly.

**Network Interface:** Ensure the network interface enp0s8 is compatible with your host system.

This script is an excellent starting point for experimenting with Kubernetes on a local machine, enabling you to test various cluster configurations and setups.