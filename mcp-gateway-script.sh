#!/bin/bash
set -euo pipefail

# ---------------------------------------
# CONFIG
# ---------------------------------------
CLUSTER_NAME="mcp"
DEPLOY_FILE="local-deployment.yaml"
NAMESPACE="adapter"
SERVICE_NAME="mcpgateway-service"
SCREEN_SESSION="mcpgateway-forward"

# ---------------------------------------
# 0. Ensure Docker works
# ---------------------------------------
ensure_docker_permissions() {
    echo "🔍 Checking Docker permissions..."

    # Install Docker if missing
    if ! command -v docker >/dev/null 2>&1; then
        echo "⚠ Docker missing! Installing..."
        curl -fsSL https://get.docker.com | sudo bash
    fi
    
    # Fix socket permissions (full access)
    sudo chown root:docker /var/run/docker.sock 2>/dev/null || true
    sudo chmod 660 /var/run/docker.sock 2>/dev/null || true
    sudo chmod 777 /var/run/docker.sock 2>/dev/null || true   # FULL access

    # Final check
    if ! docker info >/dev/null 2>&1; then
        echo "❌ Docker not responding. Please start Docker manually."
        exit 1
    fi

    echo "🚀 Docker is ready."
}

# ---------------------------------------
# 1. Check/install kind
# ---------------------------------------
check_kind() {
    command -v kind >/dev/null 2>&1
}

install_kind() {
    echo "📥 Installing kind..."
    KIND_VERSION=$(curl -s https://api.github.com/repos/kubernetes-sigs/kind/releases/latest \
        | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    curl -Lo ./kind "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-amd64"
    chmod +x ./kind
    sudo mv ./kind /usr/local/bin/kind
    echo "✔ kind installed: $(kind version)"
}

# ---------------------------------------
# 2. Check/install kubectl
# ---------------------------------------
check_kubectl() {
    if ! command -v kubectl >/dev/null 2>&1; then
        echo "📥 Installing kubectl..."
        LATEST=$(curl -L -s https://dl.k8s.io/release/stable.txt)
        curl -LO "https://dl.k8s.io/release/${LATEST}/bin/linux/amd64/kubectl"
        chmod +x kubectl
        sudo mv kubectl /usr/local/bin/kubectl
    fi
}

# ---------------------------------------
# 8. Check/install Helm
# ---------------------------------------
check_helm() {
    command -v helm >/dev/null 2>&1
}

install_helm() {
    echo "📥 Installing Helm..."
    curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
    echo "✔ Helm installed: $(helm version --short)"
}

# ---------------------------------------
# 3. Create kind cluster
# ---------------------------------------
create_cluster() {
    if kind get clusters | grep -qw "$CLUSTER_NAME"; then
        echo "✔ Cluster '$CLUSTER_NAME' already exists."
    else
        echo "🚀 Creating cluster '$CLUSTER_NAME'..."
        kind create cluster --name "$CLUSTER_NAME"
    fi
}

# ---------------------------------------
# 9. Install Helm chart
# ---------------------------------------
install_mssql_helm() {
    RELEASE_NAME="my-mssqlserver-2022"
    CHART="simcube/mssqlserver-2022"
    VERSION="1.2.3"
    NAMESPACE="adapter"

    echo "🔹 Adding Helm repo simcube..."
    helm repo add simcube https://simcubeltd.github.io/simcube-helm-charts/
    helm repo update

    if helm list -n $NAMESPACE | grep -qw "$RELEASE_NAME"; then
        echo "✔ Helm release $RELEASE_NAME already installed."
    else
        echo "🚀 Installing Helm chart $CHART..."
        helm install $RELEASE_NAME $CHART --version $VERSION -n $NAMESPACE --create-namespace
    fi

    echo "⏳ Waiting for pods from Helm release $RELEASE_NAME..."
    while true; do
        NOT_READY=$(kubectl get pods -n $NAMESPACE -l "app.kubernetes.io/instance=$RELEASE_NAME" --no-headers 2>/dev/null \
            | awk '{split($2,a,"/"); if(a[1]!=a[2]) print $1, $2, $3}')
        if [[ -z "$NOT_READY" ]]; then
            echo "✔ All pods for Helm release $RELEASE_NAME are ready."
            break
        else
            echo "⌛ Pods not ready yet:"
            echo "$NOT_READY"
            sleep 5
        fi
    done

    # Fetch the auto-generated MSSQL password from the Helm secret
    PASSWORD=$(kubectl get secret -n $NAMESPACE ${RELEASE_NAME}-secret -o jsonpath="{.data.sapassword}" | base64 --decode)
    echo "🔑 Fetched MSSQL password from Helm chart: $PASSWORD"

    # Export for later use in POST request
    export MSSQL_PASSWORD="$PASSWORD"
}

# ---------------------------------------
# 4. Apply deployment
# ---------------------------------------
apply_deployment() {
    if [[ ! -f "$DEPLOY_FILE" ]]; then
        echo "❌ Deployment file missing: $DEPLOY_FILE"
        exit 1
    fi
    kubectl apply -f "$DEPLOY_FILE"
    echo "✔ Deployment applied."

    # Wait 20 seconds for resources to initialize
    echo "⏳ Waiting 20s for deployment to stabilize..."
    sleep 20
}


# ---------------------------------------
# 5. Wait for pods in namespace
# ---------------------------------------
NAMESPACE="adapter"
wait_for_pods() {
    echo "⏳ Waiting for pods in namespace $NAMESPACE..."
    kubectl get ns "$NAMESPACE" >/dev/null 2>&1 || kubectl create ns "$NAMESPACE"

    while true; do
        NOT_READY=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null \
            | awk '{split($2,a,"/"); if(a[1]!=a[2]) print $1, $2, $3}')
        
        if [[ -z "$NOT_READY" ]]; then
            echo "✔ All pods in $NAMESPACE are ready."
            break
        else
            echo "⌛ Pods not ready yet:"
            echo "$NOT_READY"
            sleep 10
        fi
    done
}


# ---------------------------------------
# 6. Check/install screen
# ---------------------------------------
check_screen() {
    if ! command -v screen >/dev/null 2>&1; then
        echo "📥 Installing screen..."
        sudo apt-get update && sudo apt-get install -y screen
    fi
}

# ---------------------------------------
# 7. Start detached port-forward
# ---------------------------------------
NAMESPACE="adapter"
port_forward_service() {
    echo "🚀 Ensuring port-forward for $SERVICE_NAME..."

    # Kill old screen if exists but not running port-forward
    if screen -list | grep -qw "$SCREEN_SESSION"; then
        if ! pgrep -f "kubectl port-forward.*${SERVICE_NAME}" >/dev/null; then
            screen -S "$SCREEN_SESSION" -X quit || true
        else
            echo "✔ Port-forward already running."
            return
        fi
    fi

    # Start detached screen with auto-restart loop
    screen -dmS "$SCREEN_SESSION" bash -c \
        "while true; do kubectl port-forward svc/${SERVICE_NAME} -n ${NAMESPACE} 8000:8000 --address 0.0.0.0; sleep 5; done"

    echo "📡 Port-forward started in DETACHED SCREEN: $SCREEN_SESSION"

}

# ---------------------------------------
# MAIN
# ---------------------------------------
ensure_docker_permissions
check_kind || install_kind
check_kubectl
create_cluster
check_helm || install_helm 
install_mssql_helm
apply_deployment
wait_for_pods
check_screen
port_forward_service

echo "⏳ Waiting 5s for port-forward to stabilize..."
sleep 5
# -------------------------
# Send POST request AFTER service is ready
# -------------------------
echo "Sending POST request to MCP adapter..."
curl -X POST http://localhost:8000/adapters \
     -H "Content-Type: application/json" \
     -d "{
           \"name\": \"mcp-mssql-2022\",
           \"imageName\": \"mssql-mcp\",
           \"imageVersion\": \"v1\",
           \"description\": \"test\",
           \"environmentVariables\": {
               \"MSSQL_SERVER\": \"my-mssqlserver-2022\",
               \"MSSQL_DATABASE\": \"msdb\",
               \"MSSQL_PORT\": \"1433\",
               \"MSSQL_USER\": \"sa\"
           },
           \"secretName\": \"mcp-mssql-secret\",
           \"secretData\": {
               \"MSSQL_PASSWORD\": \"$MSSQL_PASSWORD\"
           }
         }"

# -------------------------
# Send POST request for HubSpot adapter
# -------------------------
echo "Sending POST request to MCP adapter (HubSpot)..."
curl -X POST http://localhost:8000/adapters \
     -H "Content-Type: application/json" \
     -d "{
           \"name\": \"hubspot-mcp\",
           \"imageName\": \"mcp-hubspot\",
           \"ReplicaCount\": \"2\",
           \"imageVersion\": \"latest\",
           \"description\": \"test\",
           \"environmentVariables\": {
               \"MSSQL_SERVER\": \"mssql-server\"
           },
           \"secretName\": \"hubspot-access-token\",
           \"secretData\": {
               \"HUBSPOT_ACCESS_TOKEN\": \"FASKFNKSANFKAMMDF\"
           }
         }"

# -------------------------
# Refresh HubSpot token and update K8s secret
# -------------------------
echo "🔄 Refreshing HubSpot access token..."

# Load credentials
source "$HOME/mcp-gateway/credentials.txt"

# Define namespace and secret name
NAMESPACE=adapter
SECRET_NAME=hubspot-access-token
STATEFULSET_NAME=hubspot-mcp  # Optional

# STEP 1: Refresh token
response=$(curl -s --request POST \
  --url https://api.hubapi.com/oauth/v1/token \
  --header "Content-Type: application/x-www-form-urlencoded" \
  --data "grant_type=refresh_token" \
  --data "client_id=$CLIENT_ID" \
  --data "client_secret=$CLIENT_SECRET" \
  --data "refresh_token=$REFRESH_TOKEN")

ACCESS_TOKEN=$(echo "$response" | jq -r '.access_token')
echo "ACCESS_TOKEN: $ACCESS_TOKEN"

if [ -z "$ACCESS_TOKEN" ] || [ "$ACCESS_TOKEN" == "null" ]; then
    echo "❌ Failed to get access token"
    echo "Response: $response"
    exit 1
fi

echo "✔ New access token retrieved successfully"

# STEP 2: Store token in K8s secret
if kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
    kubectl create secret generic "$SECRET_NAME" \
      --from-literal=HUBSPOT_ACCESS_TOKEN="$ACCESS_TOKEN" \
      -n "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
    echo "✔ Secret updated successfully"
else
    kubectl create secret generic "$SECRET_NAME" \
      --from-literal=HUBSPOT_ACCESS_TOKEN="$ACCESS_TOKEN" \
      -n "$NAMESPACE"
    echo "✔ Secret created successfully"
fi

# STEP 3: Restart StatefulSet / Deployment to pick up new secret
if [ -n "$STATEFULSET_NAME" ]; then
    echo "🔄 Restarting StatefulSet $STATEFULSET_NAME..."
    kubectl rollout restart statefulset "$STATEFULSET_NAME" -n "$NAMESPACE"
fi

echo "🎉 HubSpot token refresh complete!"

echo "🎉 MCP Gateway setup complete!"
echo "📌 To view logs: screen -r $SCREEN_SESSION"
echo "📌 To detach: Ctrl+A then D"
