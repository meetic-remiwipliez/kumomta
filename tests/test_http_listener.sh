#!/bin/bash

# Script de test pour le listener HTTP de KumoMTA
# Ce script teste l'injection de messages via l'API HTTP
#
# Usage:
#   ./test_http_listener.sh [fichier_json]
#   ou
#   PAYLOAD_FILE=fichier.json ./test_http_listener.sh
#
# Le fichier JSON peut contenir:
#   - from_email, to_email, from_name, subject, text_body, html_body
#   - reply_to_email, reply_to_name
#   - headers: objet JSON avec des headers personnalisés (ex: {"X-Custom-Header": "value"})

set -e

# ============================================================================
# CONFIGURATION
# ============================================================================

# Fichier JSON contenant les données de test (peut être passé en argument)
if [ -n "$1" ]; then
    PAYLOAD_FILE="$1"
elif [ -n "${PAYLOAD_FILE}" ]; then
    # Utiliser la variable d'environnement si définie
    PAYLOAD_FILE="${PAYLOAD_FILE}"
else
    # Utiliser le fichier par défaut
    PAYLOAD_FILE="$(dirname "$0")/test_payload_generic.json"
fi

# Configuration Kubernetes par défaut
NAMESPACE="${NAMESPACE:-kumomta}"
RELEASE_NAME="${RELEASE_NAME:-kumomta}"
KUBE_CONTEXT="${KUBE_CONTEXT:-dal-lab}"
# Le nom du service suit la convention Helm: {release-name}-{chart-name}
# Si release-name contient déjà le chart-name, alors juste {release-name}
# Par défaut, on essaie d'abord {release-name}, puis {release-name}-kumomta
SERVICE_NAME="${SERVICE_NAME:-${RELEASE_NAME}}"
HTTP_PORT="${HTTP_PORT:-8000}"
LOCAL_HTTP_PORT="${LOCAL_HTTP_PORT:-8000}"

# Authentification HTTP (par défaut depuis values.yaml)
HTTP_USER="${HTTP_USER:-user1}"
HTTP_PASSWORD="${HTTP_PASSWORD:-default-password}"

# ============================================================================
# CHARGEMENT DES DONNÉES DEPUIS LE FICHIER JSON
# ============================================================================

if [ ! -f "${PAYLOAD_FILE}" ]; then
    echo "Erreur: Le fichier de payload ${PAYLOAD_FILE} n'existe pas"
    exit 1
fi

# Charger les valeurs depuis le JSON (nécessite jq)
if command -v jq &> /dev/null; then
    FROM_EMAIL=$(jq -r '.from_email' "${PAYLOAD_FILE}")
    TO_EMAIL=$(jq -r '.to_email' "${PAYLOAD_FILE}")
    FROM_NAME=$(jq -r '.from_name' "${PAYLOAD_FILE}")
    REPLY_TO_EMAIL=$(jq -r '.reply_to_email' "${PAYLOAD_FILE}")
    REPLY_TO_NAME=$(jq -r '.reply_to_name' "${PAYLOAD_FILE}")
    TEXT_BODY_TEMPLATE=$(jq -r '.text_body' "${PAYLOAD_FILE}")
    HTML_BODY_TEMPLATE=$(jq -r '.html_body' "${PAYLOAD_FILE}")
    SUBJECT_TEMPLATE=$(jq -r '.subject' "${PAYLOAD_FILE}")
    
    # Charger les headers personnalisés (si présents)
    if jq -e '.headers' "${PAYLOAD_FILE}" > /dev/null 2>&1; then
        # Extraire les headers en format clé=valeur pour traitement
        HEADERS_JSON=$(jq -c '.headers' "${PAYLOAD_FILE}")
    else
        HEADERS_JSON="{}"
    fi
else
    echo "Erreur: jq n'est pas installé. Installez-le avec: brew install jq (macOS) ou apt-get install jq (Linux)"
    exit 1
fi

# Remplacer les variables dans les templates
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
SUBJECT=$(echo "${SUBJECT_TEMPLATE}" | sed "s/{{TIMESTAMP}}/${TIMESTAMP}/g")
TEXT_BODY=$(echo "${TEXT_BODY_TEMPLATE}" | sed "s/{{TIMESTAMP}}/${TIMESTAMP}/g")
HTML_BODY=$(echo "${HTML_BODY_TEMPLATE}" | sed "s/{{TIMESTAMP}}/${TIMESTAMP}/g")

# Remplacer les variables dans les headers
if [ "${HEADERS_JSON}" != "{}" ]; then
    HEADERS_JSON=$(echo "${HEADERS_JSON}" | sed "s/{{TIMESTAMP}}/${TIMESTAMP}/g")
fi

# Couleurs pour l'output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${YELLOW}=== Test du listener HTTP KumoMTA ===${NC}"
echo "Context: ${KUBE_CONTEXT}"
echo "Service: ${SERVICE_NAME}"
echo "Namespace: ${NAMESPACE}"
echo "Port local: ${LOCAL_HTTP_PORT}"
echo "Payload file: ${PAYLOAD_FILE}"
echo "From: ${FROM_EMAIL}"
echo "To: ${TO_EMAIL}"
echo ""

# Fonction pour nettoyer le port-forward en cas d'interruption
cleanup() {
    echo -e "\n${YELLOW}Nettoyage du port-forward...${NC}"
    kill $PF_PID 2>/dev/null || true
    wait $PF_PID 2>/dev/null || true
}

trap cleanup EXIT INT TERM

# Vérifier que kubectl est disponible
if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}Erreur: kubectl n'est pas installé ou n'est pas dans le PATH${NC}"
    exit 1
fi

# Vérifier que le service existe
echo -e "${YELLOW}Vérification du service Kubernetes...${NC}"

# Essayer de trouver le service automatiquement si SERVICE_NAME n'existe pas
if ! kubectl --context="${KUBE_CONTEXT}" get service "${SERVICE_NAME}" -n "${NAMESPACE}" &> /dev/null; then
    echo -e "${YELLOW}Service ${SERVICE_NAME} non trouvé, recherche automatique...${NC}"
    
    # Chercher les services kumomta dans le namespace (essayer d'abord {release-name}, puis {release-name}-kumomta)
    FOUND_SERVICE=$(kubectl --context="${KUBE_CONTEXT}" get services -n "${NAMESPACE}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -E "^${RELEASE_NAME}$|^${RELEASE_NAME}-kumomta$" | head -1)
    
    if [ -n "${FOUND_SERVICE}" ]; then
        echo -e "${GREEN}Service trouvé: ${FOUND_SERVICE}${NC}"
        SERVICE_NAME="${FOUND_SERVICE}"
    else
        echo -e "${RED}Erreur: Le service ${SERVICE_NAME} n'existe pas dans le namespace ${NAMESPACE}${NC}"
        echo ""
        echo "Services disponibles dans le namespace ${NAMESPACE}:"
        kubectl --context="${KUBE_CONTEXT}" get services -n "${NAMESPACE}" 2>/dev/null || echo "Namespace ${NAMESPACE} non accessible"
        echo ""
        echo "Indiquez le nom du service avec: SERVICE_NAME=<nom-du-service> ./test_http_listener.sh"
        exit 1
    fi
fi

echo -e "${GREEN}✓ Service trouvé${NC}"

# Démarrer le port-forward en arrière-plan vers le service kumomta
echo -e "${YELLOW}Démarrage du port-forward vers service/${SERVICE_NAME} (port ${LOCAL_HTTP_PORT}:${HTTP_PORT})...${NC}"
kubectl --context="${KUBE_CONTEXT}" port-forward -n "${NAMESPACE}" "service/${SERVICE_NAME}" "${LOCAL_HTTP_PORT}:${HTTP_PORT}" > /tmp/kumomta-port-forward.log 2>&1 &
PF_PID=$!

# Attendre que le port-forward soit prêt
sleep 3

# Vérifier que le port-forward fonctionne
if ! kill -0 $PF_PID 2>/dev/null; then
    echo -e "${RED}Erreur: Le port-forward a échoué${NC}"
    echo "Logs du port-forward:"
    cat /tmp/kumomta-port-forward.log 2>/dev/null || echo "Aucun log disponible"
    exit 1
fi

echo -e "${GREEN}✓ Port-forward actif (PID: ${PF_PID})${NC}"

# Test de connexion HTTP
echo -e "${YELLOW}Test de connexion HTTP...${NC}"
if ! curl -s -f -o /dev/null "http://localhost:${LOCAL_HTTP_PORT}/api/check-liveness/v1"; then
    echo -e "${RED}Erreur: Impossible de se connecter au listener HTTP${NC}"
    echo "Vérifiez que le service est bien démarré et accessible"
    exit 1
fi

echo -e "${GREEN}✓ Connexion HTTP réussie${NC}"

# Préparer le payload JSON pour l'API HTTP
# jq gère automatiquement l'échappement des caractères spéciaux
# Inclure les headers personnalisés s'ils sont présents
if [ "${HEADERS_JSON}" != "{}" ]; then
    PAYLOAD=$(jq -n \
        --arg envelope_sender "${FROM_EMAIL}" \
        --arg from_email "${FROM_EMAIL}" \
        --arg from_name "${FROM_NAME}" \
        --arg to_email "${TO_EMAIL}" \
        --arg subject "${SUBJECT}" \
        --arg text_body "${TEXT_BODY}" \
        --arg html_body "${HTML_BODY}" \
        --arg reply_to_email "${REPLY_TO_EMAIL}" \
        --arg reply_to_name "${REPLY_TO_NAME}" \
        --argjson headers "${HEADERS_JSON}" \
        '{
            "envelope_sender": $envelope_sender,
            "content": {
                "text_body": $text_body,
                "html_body": $html_body,
                "from": {
                    "email": $from_email,
                    "name": $from_name
                },
                "subject": $subject,
                "reply_to": {
                    "email": $reply_to_email,
                    "name": $reply_to_name
                },
                "headers": $headers
            },
            "recipients": [
                {
                    "email": $to_email
                }
            ]
        }')
else
    PAYLOAD=$(jq -n \
        --arg envelope_sender "${FROM_EMAIL}" \
        --arg from_email "${FROM_EMAIL}" \
        --arg from_name "${FROM_NAME}" \
        --arg to_email "${TO_EMAIL}" \
        --arg subject "${SUBJECT}" \
        --arg text_body "${TEXT_BODY}" \
        --arg html_body "${HTML_BODY}" \
        --arg reply_to_email "${REPLY_TO_EMAIL}" \
        --arg reply_to_name "${REPLY_TO_NAME}" \
        '{
            "envelope_sender": $envelope_sender,
            "content": {
                "text_body": $text_body,
                "html_body": $html_body,
                "from": {
                    "email": $from_email,
                    "name": $from_name
                },
                "subject": $subject,
                "reply_to": {
                    "email": $reply_to_email,
                    "name": $reply_to_name
                }
            },
            "recipients": [
                {
                    "email": $to_email
                }
            ]
        }')
fi

# Envoyer le message via l'API HTTP
echo -e "${YELLOW}Envoi du message de test via HTTP API...${NC}"
echo "Endpoint: http://localhost:${LOCAL_HTTP_PORT}/api/inject/v1"
echo ""

RESPONSE=$(curl -s -w "\n%{http_code}" \
    -X POST \
    -H "Content-Type: application/json" \
    -u "${HTTP_USER}:${HTTP_PASSWORD}" \
    -d "${PAYLOAD}" \
    "http://localhost:${LOCAL_HTTP_PORT}/api/inject/v1")

HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
BODY=$(echo "$RESPONSE" | sed '$d')

# Afficher la réponse
echo "Réponse HTTP:"
echo "$BODY" | jq '.' 2>/dev/null || echo "$BODY"
echo ""
echo "Code HTTP: ${HTTP_CODE}"

# Vérifier le résultat
if [ "${HTTP_CODE}" -ge 200 ] && [ "${HTTP_CODE}" -lt 300 ]; then
    echo -e "${GREEN}✓ Message envoyé avec succès (HTTP ${HTTP_CODE})${NC}"
    echo ""
    echo -e "${GREEN}=== Test HTTP réussi ===${NC}"
    exit 0
else
    echo -e "${RED}✗ Échec de l'envoi du message (HTTP ${HTTP_CODE})${NC}"
    echo ""
    echo "Vérifiez les logs du pod KumoMTA:"
    echo "  kubectl --context=${KUBE_CONTEXT} logs -n ${NAMESPACE} -l app.kubernetes.io/name=kumomta --tail=50"
    exit 1
fi
