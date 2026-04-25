# Part 2 — K3s and Three Simple Applications

## Overview

This part builds on Part 1 by deploying **3 web applications** on a single K3s server,
routed by hostname using a Kubernetes **Ingress**.

---

## Infrastructure Diagram

```
                        Your Browser
                             |
                    "app1.com:192.168.56.110"
                             |
                    +-----------------+
                    |   VM: yamzilS   |
                    |  192.168.56.110 |
                    |                 |
                    |  K3s Server     |
                    |                 |
                    |  [Ingress]      |  ← reads HOST header
                    |   /    |    \   |
                    |  ↓     ↓     ↓  |
                    | svc1  svc2  svc3|  ← Services
                    |  ↓   ↓↓↓    ↓  |
                    | pod  ppp   pod  |  ← Pods (app2 has 3!)
                    +-----------------+
```

---

## Request Flow — Step by Step

When a user types `app1.com` in their browser:

```
1. Browser sends HTTP request to 192.168.56.110
   with header: "Host: app1.com"
        ↓
2. Ingress Controller (Traefik) receives the request
   and reads the HOST header
        ↓
3. Ingress checks its rules:
   - "app1.com" → forward to app1-service 
   - "app2.com" → forward to app2-service
   - anything else → forward to app3-service (default)
        ↓
4. Service receives the request
   and forwards to one of its healthy pods
        ↓
5. Pod (nginx container) handles the request
   and returns the HTML response
        ↓
6. Response travels back to the browser
```

---

## Key Concepts

### Pod
The **smallest unit** in Kubernetes.
Wraps one or more containers.

```
Pod
└── nginx container (serving HTML)
```

### Deployment
Manages pods automatically.
Ensures the desired number of replicas are always running.

```yaml
spec:
  replicas: 3    # always keep 3 pods running
```

If a pod crashes → Deployment automatically creates a new one.

### Service
Gives pods a **stable internal address**.
Pods have random IPs that change on restart — Service solves this.

```
Before Service:          After Service:
Pod IP: 10.42.0.4  →    app1-service:80 (always works!)
Pod IP: 10.42.0.8        even if pod IPs change
```

### Ingress
Routes **external** HTTP traffic to the correct Service
based on the **hostname** in the request.

```
app1.com → app1-service
app2.com → app2-service
*        → app3-service (default/catch-all)
```


##  Vagrantfile

```ruby
Vagrant.configure("2") do |config|
  config.vm.synced_folder ".", "/vagrant", disabled: true

  config.vm.define "yamzilS" do |control|
    control.vm.box      = "ubuntu/jammy64"
    control.vm.hostname = "yamzilS"
    control.vm.network "private_network", ip: "192.168.56.110"

    control.vm.provider "virtualbox" do |vb|
      vb.memory = 2048
      vb.cpus   = 1
    end

    # Step 1: Install K3s
    control.vm.provision "shell", inline: <<-SHELL
      # Fix SSH
      sudo rm -f /etc/ssh/sshd_config.d/60-cloudimg-settings.conf
      echo "PasswordAuthentication yes" | sudo tee /etc/ssh/sshd_config.d/override.conf
      sudo systemctl reload ssh

      # Install K3s
      sudo apt-get update -y
      sudo apt-get install -y curl
      curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--node-ip=192.168.56.110 \
        --flannel-iface=enp0s8 --write-kubeconfig-mode 644" sh -

      # Configure kubectl
      mkdir -p /home/vagrant/.kube
      while ! sudo test -f /etc/rancher/k3s/k3s.yaml; do
        echo "Waiting for k3s.yaml..."
        sleep 5
      done
      sudo cp /etc/rancher/k3s/k3s.yaml /home/vagrant/.kube/config
      sudo chown vagrant:vagrant /home/vagrant/.kube/config
    SHELL

    # Step 2: Copy config files
    control.vm.provision "file",
      source:      "./confs",
      destination: "/home/vagrant/confs"

    # Step 3: Apply manifests
    control.vm.provision "shell", inline: <<-SHELL
      kubectl apply -f /home/vagrant/confs/
    SHELL
  end
end
```

---

## Application Manifests

### app1.yaml (1 replica)

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app1
  labels:
    app: app1
spec:
  replicas: 1
  selector:
    matchLabels:
      app: app1
  template:
    metadata:
      labels:
        app: app1
    spec:
      containers:
      - name: app1
        image: nginx
        ports:
        - containerPort: 80
        volumeMounts:
        - name: html
          mountPath: /usr/share/nginx/html
      volumes:
      - name: html
        configMap:
          name: app1-html
---
apiVersion: v1
kind: Service
metadata:
  name: app1-service
spec:
  selector:
    app: app1
  ports:
    - protocol: TCP
      port: 80
      targetPort: 80
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: app1-html
data:
  index.html: |
    <html>
      <body><h1>Hello from App1!</h1></body>
    </html>
```

### app2.yaml (3 replicas — High Availability)

Same structure as app1 but with `replicas: 3`.

> **Why 3 replicas?** If one pod crashes, 2 others keep serving traffic.
> Users never experience downtime!

### app3.yaml (default app)

Same structure as app1. Serves as the **default** for unmatched hostnames.

---

## 🚦 Ingress Configuration

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ingress
spec:
  rules:
  - host: app1.com          # matches app1.com exactly
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: app1-service
            port:
              number: 80
  - host: app2.com          # matches app2.com exactly
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: app2-service
            port:
              number: 80
  - http:                   # no host = matches EVERYTHING else
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: app3-service
            port:
              number: 80
```

> **Key insight:** The rule with no `host` field acts as the
> **catch-all default** — any hostname not matched above
> gets routed to app3.

---

## Testing

```bash
# Test app1 routing
curl -H "Host: app1.com" http://192.168.56.110
# Expected: <h1>Hello from App1!</h1>

# Test app2 routing
curl -H "Host: app2.com" http://192.168.56.110
# Expected: <h1>Hello from App2!</h1>

# Test default routing (app3)
curl -H "Host: anything.com" http://192.168.56.110
# Expected: <h1>Hello from App3!</h1>
```

---

## Useful kubectl Commands

```bash
# Check all pods are running (expect 5 total: 1+3+1)
kubectl get pods

# Check services
kubectl get services

# Check ingress routing rules
kubectl get ingress

# Check deployments
kubectl get deployments

# Describe ingress (detailed routing info)
kubectl describe ingress ingress
```

---

## Key Differences: Service vs Ingress

| | Service | Ingress |
|---|---|---|
| **Purpose** | Internal pod discovery | External traffic routing |
| **Routes by** | Label selector | Hostname / path |
| **Scope** | Inside cluster | Outside → inside cluster |
| **Analogy** | Waiter station | Restaurant front door host |

---

## Important Notes

- The **Ingress** is not shown in `kubectl get pods` — show it separately
  with `kubectl get ingress` during your defense
- K3s uses **Traefik** as the Ingress controller (not nginx)
- Traefik handles the catch-all rule via a rule with **no host field**
  (not `defaultBackend` which is nginx-specific)
- App2's **3 replicas** demonstrate high availability —
  Kubernetes automatically restarts crashed pods

---

*Project: Inception-of-Things (IoT) — 42 School*
*Author: Yamzil*
