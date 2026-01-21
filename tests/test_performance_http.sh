#!/bin/bash

# Script de test de performance pour le listener HTTP de KumoMTA
# Ce script envoie plusieurs messages via l'API HTTP pour tester les queues, spools et générer des métriques
#
# Usage:
#   ./test_performance_http.sh [nombre_de_messages]
#   ou
#   NUM_MESSAGES=100 ./test_performance_http.sh

set -e

# ============================================================================
# CONFIGURATION
# ============================================================================

# Nombre de messages à envoyer (par défaut: 50)
NUM_MESSAGES="${NUM_MESSAGES:-${1:-50}}"

# Configuration Kubernetes par défaut
NAMESPACE="${NAMESPACE:-kumomta}"
RELEASE_NAME="${RELEASE_NAME:-kumomta}"
SERVICE_NAME="${SERVICE_NAME:-${RELEASE_NAME}}"
HTTP_PORT="${HTTP_PORT:-8000}"
LOCAL_HTTP_PORT="${LOCAL_HTTP_PORT:-8000}"

# Authentification HTTP
HTTP_USER="${HTTP_USER:-user1}"
HTTP_PASSWORD="${HTTP_PASSWORD:-default-password}"

# Domaines pour générer les adresses destinataires
DOMAINS=("gmail.com" "yahoo.com" "hotmail.com")

# Couleurs pour l'output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ============================================================================
# FONCTIONS UTILITAIRES
# ============================================================================

# Génère une adresse email aléatoire sur un des domaines spécifiés
generate_random_email() {
    local domains=("$@")
    local domain=${domains[$((RANDOM % ${#domains[@]}))]}
    local username="test$(date +%s)${RANDOM}"
    echo "${username}@${domain}"
}

# Fonction pour nettoyer le port-forward en cas d'interruption
cleanup() {
    echo -e "\n${YELLOW}Nettoyage du port-forward...${NC}"
    kill $PF_PID 2>/dev/null || true
    wait $PF_PID 2>/dev/null || true
}

trap cleanup EXIT INT TERM

# ============================================================================
# VÉRIFICATIONS PRÉLIMINAIRES
# ============================================================================

echo -e "${BLUE}=== Test de Performance - Listener HTTP KumoMTA ===${NC}"
echo "Service: ${SERVICE_NAME}"
echo "Namespace: ${NAMESPACE}"
echo "Port local: ${LOCAL_HTTP_PORT}"
echo "Nombre de messages: ${NUM_MESSAGES}"
echo ""

# Vérifier que kubectl est disponible
if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}Erreur: kubectl n'est pas installé ou n'est pas dans le PATH${NC}"
    exit 1
fi

# Vérifier que jq est disponible
if ! command -v jq &> /dev/null; then
    echo -e "${RED}Erreur: jq n'est pas installé. Installez-le avec: brew install jq (macOS) ou apt-get install jq (Linux)${NC}"
    exit 1
fi

# Vérifier que curl est disponible
if ! command -v curl &> /dev/null; then
    echo -e "${RED}Erreur: curl n'est pas installé${NC}"
    exit 1
fi

# Vérifier que le service existe
echo -e "${YELLOW}Vérification du service Kubernetes...${NC}"

if ! kubectl get service "${SERVICE_NAME}" -n "${NAMESPACE}" &> /dev/null; then
    echo -e "${YELLOW}Service ${SERVICE_NAME} non trouvé, recherche automatique...${NC}"
    
    FOUND_SERVICE=$(kubectl get services -n "${NAMESPACE}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -E "^${RELEASE_NAME}$|^${RELEASE_NAME}-kumomta$" | head -1)
    
    if [ -n "${FOUND_SERVICE}" ]; then
        echo -e "${GREEN}Service trouvé: ${FOUND_SERVICE}${NC}"
        SERVICE_NAME="${FOUND_SERVICE}"
    else
        echo -e "${RED}Erreur: Le service ${SERVICE_NAME} n'existe pas dans le namespace ${NAMESPACE}${NC}"
        echo ""
        echo "Services disponibles dans le namespace ${NAMESPACE}:"
        kubectl get services -n "${NAMESPACE}" 2>/dev/null || echo "Namespace ${NAMESPACE} non accessible"
        exit 1
    fi
fi

echo -e "${GREEN}✓ Service trouvé${NC}"

# Vérifier si le port local est déjà utilisé
if lsof -i :${LOCAL_HTTP_PORT} > /dev/null 2>&1; then
    echo -e "${YELLOW}⚠ Le port ${LOCAL_HTTP_PORT} est déjà utilisé${NC}"
    EXISTING_PID=$(lsof -ti :${LOCAL_HTTP_PORT})
    echo "   Processus existant (PID: ${EXISTING_PID})"
    echo ""
    read -p "Voulez-vous tuer le processus existant et continuer ? (y/N) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        kill ${EXISTING_PID} 2>/dev/null || true
        sleep 1
        echo -e "${GREEN}✓ Ancien port-forward arrêté${NC}"
    else
        echo -e "${YELLOW}Test annulé. Utilisez un autre port avec: LOCAL_HTTP_PORT=<autre-port> ./test_performance_http.sh${NC}"
        exit 0
    fi
fi

# Démarrer le port-forward en arrière-plan
echo -e "${YELLOW}Démarrage du port-forward (port ${LOCAL_HTTP_PORT})...${NC}"
kubectl port-forward -n "${NAMESPACE}" "service/${SERVICE_NAME}" "${LOCAL_HTTP_PORT}:${HTTP_PORT}" > /tmp/kubectl-port-forward-http-perf.log 2>&1 &
PF_PID=$!

# Attendre que le port-forward soit prêt
sleep 3

# Vérifier que le port-forward fonctionne
if ! kill -0 $PF_PID 2>/dev/null; then
    echo -e "${RED}Erreur: Le port-forward a échoué${NC}"
    echo "Logs du port-forward:"
    cat /tmp/kubectl-port-forward-http-perf.log 2>/dev/null || echo "Aucun log disponible"
    exit 1
fi

# Vérifier que le port est bien ouvert localement
if ! lsof -i :${LOCAL_HTTP_PORT} > /dev/null 2>&1; then
    echo -e "${RED}Erreur: Le port ${LOCAL_HTTP_PORT} n'est pas accessible localement${NC}"
    kill $PF_PID 2>/dev/null || true
    exit 1
fi

echo -e "${GREEN}✓ Port-forward actif (PID: ${PF_PID})${NC}"
echo ""

# ============================================================================
# TEST DE PERFORMANCE
# ============================================================================

echo -e "${BLUE}=== Démarrage du test de performance ===${NC}"
echo ""

# Variables pour les statistiques
SUCCESS_COUNT=0
FAIL_COUNT=0
TOTAL_TIME=0
MIN_TIME=999999
MAX_TIME=0
TIMES=()

# Adresse expéditeur fixe
FROM_EMAIL="perf-test@talk.stir.com"
FROM_NAME="Performance Test"

# Fichier temporaire pour stocker les résultats
RESULTS_FILE=$(mktemp)
echo "Message #,Status,Time (ms),To Email" > "${RESULTS_FILE}"

# Boucle d'envoi des messages
for i in $(seq 1 ${NUM_MESSAGES}); do
    # Générer une adresse destinataire aléatoire
    TO_EMAIL=$(generate_random_email "${DOMAINS[@]}")
    
    # Générer un sujet unique
    SUBJECT="Performance Test #${i} - $(date +%Y%m%d-%H%M%S)"
    
    # Générer le corps du message
    TEXT_BODY="Performance test message #${i}
    
This is a performance test message sent via HTTP API.
Timestamp: $(date '+%Y-%m-%d %H:%M:%S')
Message ID: ${i}
Recipient: ${TO_EMAIL}
    
This message is used to test queues, spools and generate metrics.
Mode: SINK (messages will not be delivered)"
    
    # Construire le payload JSON
    PAYLOAD=$(jq -n \
        --arg envelope_sender "${FROM_EMAIL}" \
        --arg from_email "${FROM_EMAIL}" \
        --arg from_name "${FROM_NAME}" \
        --arg to_email "${TO_EMAIL}" \
        --arg subject "${SUBJECT}" \
        --arg text_body "${TEXT_BODY}" \
        '{
            "envelope_sender": $envelope_sender,
            "content": {
                "text_body": $text_body,
                "from": {
                    "email": $from_email,
                    "name": $from_name
                },
                "subject": $subject
            },
            "recipients": [
                {
                    "email": $to_email
                }
            ]
        }')
    
    # Mesurer le temps de réponse
    START_TIME=$(date +%s%N)
    
    # Envoyer le message
    HTTP_CODE=$(curl -s -w "%{http_code}" -o /dev/null \
        -X POST \
        -H "Content-Type: application/json" \
        -u "${HTTP_USER}:${HTTP_PASSWORD}" \
        -d "${PAYLOAD}" \
        "http://localhost:${LOCAL_HTTP_PORT}/api/inject/v1" \
        --max-time 30)
    
    END_TIME=$(date +%s%N)
    ELAPSED_MS=$(( (END_TIME - START_TIME) / 1000000 ))
    
    # Enregistrer le résultat
    if [ "${HTTP_CODE}" -ge 200 ] && [ "${HTTP_CODE}" -lt 300 ]; then
        STATUS="SUCCESS"
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
        echo -e "${GREEN}✓${NC} Message #${i}: ${STATUS} (${ELAPSED_MS}ms) -> ${TO_EMAIL}"
    else
        STATUS="FAIL"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        echo -e "${RED}✗${NC} Message #${i}: ${STATUS} (HTTP ${HTTP_CODE}, ${ELAPSED_MS}ms) -> ${TO_EMAIL}"
    fi
    
    # Mettre à jour les statistiques de temps
    TIMES+=(${ELAPSED_MS})
    TOTAL_TIME=$((TOTAL_TIME + ELAPSED_MS))
    
    if [ ${ELAPSED_MS} -lt ${MIN_TIME} ]; then
        MIN_TIME=${ELAPSED_MS}
    fi
    
    if [ ${ELAPSED_MS} -gt ${MAX_TIME} ]; then
        MAX_TIME=${ELAPSED_MS}
    fi
    
    # Enregistrer dans le fichier de résultats
    echo "${i},${STATUS},${ELAPSED_MS},${TO_EMAIL}" >> "${RESULTS_FILE}"
    
    # Petite pause pour ne pas surcharger (optionnel, peut être désactivé)
    # sleep 0.1
done

# ============================================================================
# CALCUL DES STATISTIQUES
# ============================================================================

echo ""
echo -e "${BLUE}=== Statistiques ===${NC}"
echo ""

# Calculer le temps moyen
if [ ${SUCCESS_COUNT} -gt 0 ]; then
    AVG_TIME=$((TOTAL_TIME / NUM_MESSAGES))
    
    # Calculer la médiane
    IFS=$'\n' SORTED_TIMES=($(sort -n <<<"${TIMES[*]}"))
    unset IFS
    MIDDLE=$((NUM_MESSAGES / 2))
    if [ $((NUM_MESSAGES % 2)) -eq 0 ]; then
        MEDIAN_TIME=$(( (SORTED_TIMES[$((MIDDLE - 1))] + SORTED_TIMES[$MIDDLE]) / 2 ))
    else
        MEDIAN_TIME=${SORTED_TIMES[$MIDDLE]}
    fi
    
    # Calculer le percentile 95
    P95_INDEX=$((NUM_MESSAGES * 95 / 100))
    if [ ${P95_INDEX} -ge ${NUM_MESSAGES} ]; then
        P95_INDEX=$((NUM_MESSAGES - 1))
    fi
    P95_TIME=${SORTED_TIMES[$P95_INDEX]}
    
    # Calculer le percentile 99
    P99_INDEX=$((NUM_MESSAGES * 99 / 100))
    if [ ${P99_INDEX} -ge ${NUM_MESSAGES} ]; then
        P99_INDEX=$((NUM_MESSAGES - 1))
    fi
    P99_TIME=${SORTED_TIMES[$P99_INDEX]}
else
    AVG_TIME=0
    MEDIAN_TIME=0
    P95_TIME=0
    P99_TIME=0
fi

# Afficher les statistiques
echo -e "Total de messages:     ${NUM_MESSAGES}"
echo -e "${GREEN}Succès:                 ${SUCCESS_COUNT}${NC}"
if [ ${FAIL_COUNT} -gt 0 ]; then
    echo -e "${RED}Échecs:                 ${FAIL_COUNT}${NC}"
else
    echo -e "Échecs:                 ${FAIL_COUNT}"
fi
echo ""
echo -e "Temps de réponse:"
echo -e "  Minimum:              ${MIN_TIME} ms"
echo -e "  Maximum:              ${MAX_TIME} ms"
echo -e "  Moyenne:              ${AVG_TIME} ms"
echo -e "  Médiane:              ${MEDIAN_TIME} ms"
echo -e "  P95:                  ${P95_TIME} ms"
echo -e "  P99:                  ${P99_TIME} ms"
echo ""

# Calculer le taux de succès
SUCCESS_RATE=$((SUCCESS_COUNT * 100 / NUM_MESSAGES))
echo -e "Taux de succès:         ${SUCCESS_RATE}%"
echo ""

# Sauvegarder les résultats dans un fichier CSV
RESULTS_CSV="performance_http_$(date +%Y%m%d_%H%M%S).csv"
cp "${RESULTS_FILE}" "${RESULTS_CSV}"
echo -e "${GREEN}✓ Résultats sauvegardés dans: ${RESULTS_CSV}${NC}"
echo ""

# Afficher un résumé
if [ ${FAIL_COUNT} -eq 0 ]; then
    echo -e "${GREEN}=== Test de performance réussi ===${NC}"
    exit 0
else
    echo -e "${YELLOW}=== Test de performance terminé avec des échecs ===${NC}"
    echo "Vérifiez les logs du pod KumoMTA pour plus de détails:"
    POD_NAME=$(kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/name=kumomta -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [ -n "${POD_NAME}" ]; then
        echo "  kubectl logs -n ${NAMESPACE} ${POD_NAME} --tail=100"
    fi
    exit 1
fi
