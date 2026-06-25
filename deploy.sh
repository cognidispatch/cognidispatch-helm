#!/bin/bash
# =============================================================================
# CogniDispatch KGateway Deployment Script
# =============================================================================
# Run this script on the jumpbox AFTER terraform apply is complete.
# It installs KGateway, applies manifests, waits for the ILB IP,
# then patches the App Gateway backend pool automatically.
#
# Usage:
#   cd ~/cognidispatch-helm
#   bash deploy.sh
# =============================================================================

set -euo pipefail

# --- Configuration -----------------------------------------------------------
RESOURCE_GROUP="test-rg"
CLUSTER_NAME="cogni-aks"
APPGW_NAME="cogni-appgw"
APPGW_BACKEND_POOL="kgateway-backend-pool"
KGATEWAY_NAMESPACE="kgateway-system"
KGATEWAY_GATEWAY_NAME="cogni-gateway"
KGATEWAY_VERSION="v2.4.0-main"
GATEWAY_API_VERSION="v1.5.1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()  { echo -e "${GREEN}==>${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
fail() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# --- Step 1: Get AKS credentials --------------------------------------------
log "Getting AKS credentials..."
az aks get-credentials \
  --resource-group "$RESOURCE_GROUP" \
  --name "$CLUSTER_NAME" \
  --overwrite-existing \
  --admin

# --- Step 2: Install Gateway API CRDs ----------------------------------------
log "Installing Kubernetes Gateway API CRDs (${GATEWAY_API_VERSION})..."
kubectl apply -f \
  "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"

# --- Step 3: Install KGateway via Helm ----------------------------------------
log "Installing KGateway CRDs chart..."
helm upgrade -i kgateway-crds \
  oci://cr.kgateway.dev/kgateway-dev/charts/kgateway-crds \
  --namespace "$KGATEWAY_NAMESPACE" \
  --create-namespace \
  --version "$KGATEWAY_VERSION" \
  --wait

log "Installing KGateway Controller chart..."
helm upgrade -i kgateway \
  oci://cr.kgateway.dev/kgateway-dev/charts/kgateway \
  --namespace "$KGATEWAY_NAMESPACE" \
  --version "$KGATEWAY_VERSION" \
  --wait

# --- Step 4: Apply KGateway manifests -----------------------------------------
log "Applying KGateway manifests..."
kubectl create namespace cogni-dev --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "${SCRIPT_DIR}/kgateway/kgateway-params.yaml"
kubectl apply -f "${SCRIPT_DIR}/kgateway/kgateway-gateway.yaml"
kubectl apply -f "${SCRIPT_DIR}/kgateway/kgateway-routes-dev.yaml"

# --- Step 5: Wait for KGateway ILB IP assignment ------------------------------
log "Waiting for KGateway Service to receive an Internal Load Balancer IP..."
log "(This typically takes 2-4 minutes while Azure provisions the ILB)"

KGATEWAY_IP=""
for i in $(seq 1 72); do
  KGATEWAY_IP=$(kubectl get svc "$KGATEWAY_GATEWAY_NAME" \
    -n "$KGATEWAY_NAMESPACE" \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")

  if [[ -n "$KGATEWAY_IP" ]]; then
    log "KGateway ILB IP assigned: ${KGATEWAY_IP}"
    break
  fi

  echo -ne "\r    Attempt ${i}/72 - still waiting..."
  sleep 5
done

echo ""

if [[ -z "$KGATEWAY_IP" ]]; then
  fail "KGateway Service did not receive an ILB IP within 6 minutes. Check:\n  kubectl describe svc ${KGATEWAY_GATEWAY_NAME} -n ${KGATEWAY_NAMESPACE}"
fi

# --- Step 6: Patch App Gateway backend pool -----------------------------------
log "Patching App Gateway backend pool with KGateway IP: ${KGATEWAY_IP} ..."
az network application-gateway address-pool update \
  --resource-group "$RESOURCE_GROUP" \
  --gateway-name "$APPGW_NAME" \
  --name "$APPGW_BACKEND_POOL" \
  --servers "$KGATEWAY_IP"

log "Waiting 30 seconds for App Gateway to re-probe backend health..."
sleep 30

# --- Step 7: Deploy application (Dev) ----------------------------------------
log "Querying Azure Key Vault and Managed Identity details..."
KEYVAULT_NAME=$(az keyvault list --resource-group "$RESOURCE_GROUP" --query "[0].name" -o tsv || echo "cognidispatch-kv")
POD_IDENTITY_CLIENT_ID=$(az identity show --resource-group "$RESOURCE_GROUP" --name "cogni-pod-identity" --query clientId -o tsv || echo "")
TENANT_ID=$(az account show --query tenantId -o tsv || echo "")

log "Using Key Vault: ${KEYVAULT_NAME}"
log "Using Managed Identity Client ID: ${POD_IDENTITY_CLIENT_ID}"

log "Deploying CogniDispatch application (cogni-dev namespace)..."
helm upgrade -i cognidispatch-dev "${SCRIPT_DIR}" \
  -n cogni-dev \
  -f "${SCRIPT_DIR}/values-dev.yaml" \
  --set keyvault.enabled=true \
  --set keyvault.name="${KEYVAULT_NAME}" \
  --set keyvault.clientId="${POD_IDENTITY_CLIENT_ID}" \
  --set keyvault.tenantId="${TENANT_ID}" \
  --set keyvault.workloadIdentityEnabled=true \
  --create-namespace \
  --wait \
  --timeout 5m

# --- Step 8: Verify -----------------------------------------------------------
log "Verifying deployment..."
echo ""
kubectl get pods -n cogni-dev
echo ""
kubectl get pods -n kgateway-system
echo ""
kubectl get gateway -n kgateway-system
echo ""

APPGW_PUBLIC_IP=$(az network public-ip show \
  -g "$RESOURCE_GROUP" \
  -n "pip-cogni-appgw" \
  --query ipAddress -o tsv)

BACKEND_HEALTH=$(az network application-gateway show-backend-health \
  -g "$RESOURCE_GROUP" \
  -n "$APPGW_NAME" \
  --query "backendAddressPools[0].backendHttpSettingsResults[0].servers[0].health" \
  -o tsv 2>/dev/null || echo "Unknown")

echo ""
echo "============================================================"
echo -e "${GREEN}✅ Deployment Complete!${NC}"
echo "============================================================"
echo "  KGateway ILB IP  : ${KGATEWAY_IP}"
echo "  App Gateway IP   : ${APPGW_PUBLIC_IP}"
echo "  Backend Health   : ${BACKEND_HEALTH}"
echo "  App URL          : http://${APPGW_PUBLIC_IP}"
echo "  API Health       : http://${APPGW_PUBLIC_IP}/api/health"
echo "============================================================"
