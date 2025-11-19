#!/bin/bash
set -e

CLUSTER_NAME="mcp"
DEPLOY_FILE="local-deployment.yml"
NAMESPACE="adapter"
SERVICE_NAME="mcpgateway-service"
SCREEN_SESSION="mcpgateway-forward"

# ----------------------------------------------------------
# 0. Ensure script runs with docker permissions
# ----------------------------------------------------------
if ! groups $USER | grep -qw docker; then
    echo "Adding $USER to docker group..."
    sudo groupadd -f docker
    sudo usermod -aG docker "$USER"
    echo "Restarting script with new docker group..."
    exec sg docker "$0" "$@"
fi

# ----------------------------------------------------------
# 1. Check/install Docker
# ----------------------------------------------------------
check_docker() {
    if command -v docker >/dev/null 2>&1; then
        echo "Docker already installed: $(docker --version)"
    else
        echo "Installing Docker..."
        curl -fsSL https://get.docker.com | sudo bash
        sudo systemctl start docker
        sudo systemctl enable docker
        echo "Docker installed."
    fi
}

# ----------------------------------------------------------
# 2. Check/install kind
# ----------------------------------------------------------
check_kind() {
    if command -v kind >/dev/null 2>&1; then
        echo "kind is already installed: $(kind version)"
        return 0
    else
        echo "kind is not installed."
        return 1
    fi
}

install_kind() {
    echo "Installing kind..."
    KIND_VERSION=$(curl -s https://api.github.com/repos/kubernetes-sigs/kind/releases/latest \
        | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    curl -Lo ./kind "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-amd64"
    chmod +x ./kind
    sudo mv ./kind /usr/local/bin/kind
    echo "kind installed: $(kind version)"
}

# ----------------------------------------------------------
# 3. Check/install kubectl
# ----------------------------------------------------------
check_kubectl() {
    if command -v kubectl >/dev/null 2>&1; then
        echo "kubectl already installed: $(kubectl version --client --short)"
    else
        echo "Installing kubectl..."
        LATEST=$(curl -L -s https://dl.k8s.io/release/stable.txt)
        curl -LO "https://dl.k8s.io/release/${LATEST}/bin/linux/amd64/kubectl"
        chmod +x kubectl
        sudo mv kubectl /usr/local/bin/kubectl
        echo "kubectl installed: $(kubectl version --client --short)"
    fi
}

# ----------------------------------------------------------
# 4. Create kind cluster
# ----------------------------------------------------------
create_cluster() {
    if kind get clusters | grep -q "^${CLUSTER_NAME}$"; then
        echo "Cluster '${CLUSTER_NAME}' already exists."
    else
        echo "Creating kind cluster '${CLUSTER_NAME}'..."
        kind create cluster --name "${CLUSTER_NAME}"
        echo "Cluster '${CLUSTER_NAME}' created."
    fi
}

# ----------------------------------------------------------
# 5. Apply deployment
# ----------------------------------------------------------
apply_deployment() {
    if [ ! -f "$DEPLOY_FILE" ]; then
        echo "Deployment file '$DEPLOY_FILE' not found!"
        exit 1
    fi
    echo "Applying deployment from $DEPLOY_FILE..."
    kubectl apply -f "$DEPLOY_FILE"
    echo "Deployment applied."
}

# ----------------------------------------------------------
# 6. Wait for pods
# ----------------------------------------------------------
wait_for_pods() {
    echo "Waiting for pods in namespace '$NAMESPACE'..."
    while true; do
        NOT_RUNNING=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | awk '{print $3}' | grep -v Running || true)
        if [ -z "$NOT_RUNNING" ]; then
            echo "All pods running."
            break
        else
            echo "Pods not ready: $NOT_RUNNING. Retrying..."
            sleep 5
        fi
    done
}

# ----------------------------------------------------------
# 7. Check/install screen
# ----------------------------------------------------------
check_screen() {
    if ! command -v screen >/dev/null 2>&1; then
        echo "Installing screen..."
        sudo apt-get update && sudo apt-get install -y screen
    fi
}

# ----------------------------------------------------------
# 8. Port-forward in screen
# ----------------------------------------------------------
port_forward_service() {
    echo "Ensuring port-forward for '$SERVICE_NAME'..."
    if screen -list | grep -q "$SCREEN_SESSION"; then
        if pgrep -f "kubectl port-forward.*$SERVICE_NAME" >/dev/null; then
            echo "Port-forward already running."
            return
        else
            screen -S "$SCREEN_SESSION" -X quit
        fi
    fi
    screen -dmS "$SCREEN_SESSION" bash -c "while true; do kubectl port-forward svc/$SERVICE_NAME -n $NAMESPACE 8000:8000 --address 0.0.0.0; sleep 5; done"
    echo "Port-forward started in screen session '$SCREEN_SESSION'."
}

# ----------------------------------------------------------
# 9. Send POST request
# ----------------------------------------------------------
send_post_request() {
    echo "Sending POST request..."
    curl -X POST http://localhost:8000/adapters \
         -H "Content-Type: application/json" \
         -d '{
               "name": "mcp-mssql",
               "imageName": "mssql-mcp",
               "imageVersion": "v1",
               "description": "test",
               "environmentVariables": {
                   "MSSQL_SERVER": "mssql-server",
                   "MSSQL_DATABASE": "msdb",
                   "MSSQL_PORT": "1433",
                   "MSSQL_USER": "sa"
               },
               "secretName": "mcp-mssql-secret",
               "secretData": {
                   "MSSQL_PASSWORD": "wi01RPKMnZ4Oqq9ZfyHn"
               }
             }'
}

# ------------------- MAIN -------------------
check_docker
check_kind || install_kind
check_kubectl
create_cluster
apply_deployment
wait_for_pods
check_screen
port_forward_service
send_post_request

echo "Setup completed successfully!"

