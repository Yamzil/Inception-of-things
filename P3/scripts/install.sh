#!/bin/bash
set -e

echo "Fixing SSH"
sudo rm -f /etc/ssh/sshd_config.d/60-cloudimg-settings.conf
echo "PasswordAuthentication yes" | sudo tee /etc/ssh/sshd_config.d/override.conf
sudo systemctl reload ssh

echo "Installing Docker"
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker vagrant

echo "Installing kubectl"
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
rm kubectl

echo "Installing K3d"
curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash

echo "Creating K3d cluster"
k3d cluster create mycluster

# Configure kubectl IMMEDIATELY after cluster creation
echo "Configuring kubectl"
mkdir -p /home/vagrant/.kube
k3d kubeconfig get mycluster > /home/vagrant/.kube/config
chown vagrant:vagrant /home/vagrant/.kube/config
export KUBECONFIG=/home/vagrant/.kube/config

echo "Creating namespaces"
kubectl create namespace argocd
kubectl create namespace dev

echo "Installing Argo CD"
kubectl apply -n argocd --server-side \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

echo "Waiting for Argo CD"
kubectl wait --for=condition=available --timeout=300s \
  deployment/argocd-server -n argocd

echo "Configuring Argo CD Application"
kubectl apply -f /home/vagrant/confs/application.yaml