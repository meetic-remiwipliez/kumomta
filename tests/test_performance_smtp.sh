#!/bin/bash

# Script de test de performance pour le listener SMTP de KumoMTA
# Ce script envoie plusieurs messages via SMTP pour tester les queues, spools et générer des métriques
#
# Usage:
#   ./test_performance_smtp.sh [nombre_de_messages]
#   ou
#   NUM_MESSAGES=100 ./test_performance_smtp.sh

# Ne pas utiliser set -e pour permettre la gestion d'erreurs manuelle
set -o pipefail

# ============================================================================
# CONFIGURATION
# ============================================================================

# Nombre de messages à envoyer (par défaut: 50)
NUM_MESSAGES="${NUM_MESSAGES:-${1:-50}}"

# Configuration Kubernetes par défaut
NAMESPACE="${NAMESPACE:-kumomta}"
RELEASE_NAME="${RELEASE_NAME:-kumomta}"
SERVICE_NAME="${SERVICE_NAME:-${RELEASE_NAME}}"
SMTP_PORT="${SMTP_PORT:-2500}"
LOCAL_SMTP_PORT="${LOCAL_SMTP_PORT:-2500}"

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

# Variable pour suivre si on utilise un port-forward existant
USE_EXISTING_PF=false

# Fonction pour nettoyer le port-forward en cas d'interruption
cleanup() {
    if [ "${USE_EXISTING_PF}" != "true" ] && [ -n "${PF_PID}" ]; then
        echo -e "\n${YELLOW}Nettoyage du port-forward...${NC}"
        kill $PF_PID 2>/dev/null || true
        wait $PF_PID 2>/dev/null || true
    fi
}

trap cleanup EXIT INT TERM

# ============================================================================
# VÉRIFICATIONS PRÉLIMINAIRES
# ============================================================================

echo -e "${BLUE}=== Test de Performance - Listener SMTP KumoMTA ===${NC}"
echo "Service: ${SERVICE_NAME}"
echo "Namespace: ${NAMESPACE}"
echo "Port local: ${LOCAL_SMTP_PORT}"
echo "Nombre de messages: ${NUM_MESSAGES}"
echo ""

# Vérifier que kubectl est disponible
if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}Erreur: kubectl n'est pas installé ou n'est pas dans le PATH${NC}"
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

# Vérifier que le listener SMTP est activé (optionnel, pour info)
POD_NAME=$(kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/name=kumomta -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [ -n "${POD_NAME}" ]; then
    # Vérification rapide dans les logs
    if kubectl logs -n "${NAMESPACE}" "${POD_NAME}" --tail=500 2>/dev/null | grep -qiE "start_esmtp_listener|listening.*0\.0\.0\.0:2500|listening.*:2500"; then
        echo -e "${GREEN}✓ Listener SMTP détecté${NC}"
    else
        echo -e "${YELLOW}⚠ Listener SMTP non détecté dans les logs (peut être normal)${NC}"
    fi
fi

# Vérifier si swaks est disponible (recommandé pour SMTP)
if command -v swaks &> /dev/null; then
    SMTP_CLIENT="swaks"
    echo -e "${GREEN}✓ Client SMTP trouvé: swaks${NC}"
elif command -v telnet &> /dev/null; then
    SMTP_CLIENT="telnet"
    echo -e "${YELLOW}⚠ Utilisation de telnet (swaks recommandé pour de meilleures performances)${NC}"
    echo "   Installation: brew install swaks (macOS) ou apt-get install swaks (Linux)"
elif command -v nc &> /dev/null; then
    SMTP_CLIENT="nc"
    echo -e "${YELLOW}⚠ Utilisation de nc (swaks recommandé pour de meilleures performances)${NC}"
else
    echo -e "${RED}Erreur: Aucun client SMTP trouvé (swaks, telnet ou nc requis)${NC}"
    echo "Installation recommandée:"
    echo "  macOS: brew install swaks"
    echo "  Linux: apt-get install swaks"
    exit 1
fi

# Vérifier si le port local est déjà utilisé
if lsof -i :${LOCAL_SMTP_PORT} > /dev/null 2>&1; then
    EXISTING_PID=$(lsof -ti :${LOCAL_SMTP_PORT})
    # Vérifier si c'est un port-forward kubectl existant
    if ps -p ${EXISTING_PID} -o command= 2>/dev/null | grep -q "kubectl.*port-forward"; then
        echo -e "${YELLOW}⚠ Un port-forward kubectl existe déjà sur le port ${LOCAL_SMTP_PORT} (PID: ${EXISTING_PID})${NC}"
        echo "   Réutilisation du port-forward existant..."
        PF_PID=${EXISTING_PID}
        USE_EXISTING_PF=true
    else
        echo -e "${YELLOW}⚠ Le port ${LOCAL_SMTP_PORT} est déjà utilisé par un autre processus (PID: ${EXISTING_PID})${NC}"
        echo "   Processus: $(ps -p ${EXISTING_PID} -o command= 2>/dev/null || echo 'inconnu')"
        echo ""
        read -p "Voulez-vous tuer le processus existant et continuer ? (y/N) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            kill ${EXISTING_PID} 2>/dev/null || true
            sleep 1
            echo -e "${GREEN}✓ Ancien processus arrêté${NC}"
        else
            echo -e "${YELLOW}Test annulé. Utilisez un autre port avec: LOCAL_SMTP_PORT=<autre-port> ./test_performance_smtp.sh${NC}"
            exit 0
        fi
    fi
fi

# Démarrer le port-forward en arrière-plan (si pas déjà existant)
if [ "${USE_EXISTING_PF}" != "true" ]; then
    echo -e "${YELLOW}Démarrage du port-forward (port ${LOCAL_SMTP_PORT})...${NC}"
    kubectl port-forward -n "${NAMESPACE}" "service/${SERVICE_NAME}" "${LOCAL_SMTP_PORT}:${SMTP_PORT}" > /tmp/kubectl-port-forward-smtp-perf.log 2>&1 &
    PF_PID=$!
    
    # Attendre que le port-forward soit prêt
    sleep 3
else
    echo -e "${GREEN}✓ Utilisation du port-forward existant${NC}"
fi

# Vérifier que le port-forward fonctionne
if ! kill -0 $PF_PID 2>/dev/null; then
    echo -e "${RED}Erreur: Le port-forward a échoué${NC}"
    echo "Logs du port-forward:"
    cat /tmp/kubectl-port-forward-smtp-perf.log 2>/dev/null || echo "Aucun log disponible"
    exit 1
fi

# Vérifier que le port est bien ouvert localement
if ! lsof -i :${LOCAL_SMTP_PORT} > /dev/null 2>&1; then
    echo -e "${RED}Erreur: Le port ${LOCAL_SMTP_PORT} n'est pas accessible localement${NC}"
    kill $PF_PID 2>/dev/null || true
    exit 1
fi

# Attendre un peu plus pour que le port-forward soit vraiment prêt
sleep 2

# Test de connexion rapide pour vérifier que le port répond (optionnel)
echo -e "${YELLOW}Test de connexion au port SMTP...${NC}"
if command -v nc &> /dev/null; then
    if nc -z -w 2 localhost ${LOCAL_SMTP_PORT} 2>/dev/null; then
        echo -e "${GREEN}✓ Port SMTP accessible${NC}"
    else
        echo -e "${YELLOW}⚠ Le port ne répond pas encore, mais on continue...${NC}"
    fi
else
    echo -e "${YELLOW}⚠ nc non disponible, on continue sans test de connexion${NC}"
fi

echo -e "${GREEN}✓ Port-forward actif (PID: ${PF_PID})${NC}"
echo ""
echo -e "${BLUE}Prêt à envoyer ${NUM_MESSAGES} messages...${NC}"
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

# Fonction pour envoyer un message via SMTP avec swaks
send_message_swaks() {
    local to_email=$1
    local subject=$2
    local body=$3
    local from_email=$4
    local from_name=$5
    
    # Utiliser swaks avec gestion d'erreurs
    # --quiet supprime la sortie normale mais garde les erreurs
    # On capture tout pour vérifier les codes de retour SMTP
    swaks --to "${to_email}" \
          --from "${from_email}" \
          --server localhost \
          --port "${LOCAL_SMTP_PORT}" \
          --h-Subject "${subject}" \
          --h-From "${from_name} <${from_email}>" \
          --body "${body}" \
          --no-tls \
          --no-hints \
          --timeout 30 \
          2>&1
    
    # Retourner le code de retour de swaks
    # 0 = succès, autre = échec
    return $?
}

# Fonction pour envoyer un message via SMTP avec telnet/nc (méthode simple)
send_message_telnet() {
    local to_email=$1
    local subject=$2
    local body=$3
    local from_email=$4
    local from_name=$5
    
    # Vérifier si timeout est disponible (pas sur macOS par défaut)
    if command -v timeout &> /dev/null; then
        TIMEOUT_CMD="timeout 30"
    elif command -v gtimeout &> /dev/null; then
        TIMEOUT_CMD="gtimeout 30"
    else
        # Pas de timeout disponible, on continue sans
        TIMEOUT_CMD=""
    fi
    
    # Créer un script temporaire pour l'envoi SMTP
    local tmp_script=$(mktemp)
    {
        echo "EHLO test.local"
        sleep 0.5
        echo "MAIL FROM:<${from_email}>"
        sleep 0.5
        echo "RCPT TO:<${to_email}>"
        sleep 0.5
        echo "DATA"
        sleep 0.5
        echo "From: ${from_name} <${from_email}>"
        echo "To: ${to_email}"
        echo "Subject: ${subject}"
        echo ""
        echo "${body}"
        echo "."
        sleep 0.5
        echo "QUIT"
    } | ${TIMEOUT_CMD} "${SMTP_CLIENT}" localhost "${LOCAL_SMTP_PORT}" 2>&1
    
    return $?
}

# Boucle d'envoi des messages
echo -e "${YELLOW}Début de l'envoi des messages...${NC}"
echo ""

# Test de génération d'email pour vérifier que la fonction fonctionne
TEST_EMAIL=$(generate_random_email "${DOMAINS[@]}" 2>&1)
if [ $? -ne 0 ] || [ -z "${TEST_EMAIL}" ]; then
    echo -e "${RED}Erreur: La génération d'email a échoué${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Test de génération d'email réussi: ${TEST_EMAIL}${NC}"
echo ""

for i in $(seq 1 ${NUM_MESSAGES}); do
    # Générer une adresse destinataire aléatoire
    TO_EMAIL=$(generate_random_email "${DOMAINS[@]}")
    
    # Générer un sujet unique
    SUBJECT="Performance Test #${i} - $(date +%Y%m%d-%H%M%S)"
    
    # Générer le corps du message
    BODY="Performance test message #${i}

This is a performance test message sent via SMTP.
Timestamp: $(date '+%Y-%m-%d %H:%M:%S')
Message ID: ${i}
Recipient: ${TO_EMAIL}

This message is used to test queues, spools and generate metrics.
Mode: SINK (messages will not be delivered)"
    
    # Mesurer le temps de réponse
    START_TIME=$(date +%s%N)
    
    # Envoyer le message selon le client disponible
    OUTPUT=""
    SMTP_RESULT=1
    
    if [ "${SMTP_CLIENT}" = "swaks" ]; then
        OUTPUT=$(send_message_swaks "${TO_EMAIL}" "${SUBJECT}" "${BODY}" "${FROM_EMAIL}" "${FROM_NAME}" 2>&1) || SMTP_RESULT=$?
    else
        OUTPUT=$(send_message_telnet "${TO_EMAIL}" "${SUBJECT}" "${BODY}" "${FROM_EMAIL}" "${FROM_NAME}" 2>&1) || SMTP_RESULT=$?
    fi
    
    END_TIME=$(date +%s%N)
    ELAPSED_MS=$(( (END_TIME - START_TIME) / 1000000 ))
    
    # Vérifier le résultat
    STATUS="FAIL"
    if [ "${SMTP_CLIENT}" = "swaks" ]; then
        # swaks retourne 0 en cas de succès
        if [ ${SMTP_RESULT} -eq 0 ]; then
            # swaks retourne 0 si la connexion et l'envoi ont réussi
            # Vérifier aussi dans la sortie pour confirmer (optionnel mais recommandé)
            if echo "${OUTPUT}" | grep -qiE "250|queued|accepted|message accepted|250.*Ok"; then
                STATUS="SUCCESS"
                SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
                echo -e "${GREEN}✓${NC} Message #${i}: ${STATUS} (${ELAPSED_MS}ms) -> ${TO_EMAIL}"
            else
                # Même si on ne trouve pas le pattern, si swaks retourne 0, c'est généralement un succès
                # (swaks peut être en mode --quiet et ne pas afficher la sortie)
                STATUS="SUCCESS"
                SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
                echo -e "${GREEN}✓${NC} Message #${i}: ${STATUS} (${ELAPSED_MS}ms) -> ${TO_EMAIL}"
            fi
        else
            # swaks a retourné un code d'erreur
            FAIL_COUNT=$((FAIL_COUNT + 1))
            echo -e "${RED}✗${NC} Message #${i}: ${STATUS} (code ${SMTP_RESULT}, ${ELAPSED_MS}ms) -> ${TO_EMAIL}"
            if [ $i -le 5 ]; then
                echo "   Sortie: ${OUTPUT:0:300}"
            fi
        fi
    else
        # Pour telnet/nc, vérifier la présence de codes de succès dans la sortie
        if echo "${OUTPUT}" | grep -qiE "250.*Ok|250.*queued|250.*accepted|250.*message accepted|250.*message queued"; then
            STATUS="SUCCESS"
            SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
            echo -e "${GREEN}✓${NC} Message #${i}: ${STATUS} (${ELAPSED_MS}ms) -> ${TO_EMAIL}"
        else
            FAIL_COUNT=$((FAIL_COUNT + 1))
            echo -e "${RED}✗${NC} Message #${i}: ${STATUS} (${ELAPSED_MS}ms) -> ${TO_EMAIL}"
            if [ $i -le 5 ]; then
                echo "   Sortie: ${OUTPUT:0:300}"
            fi
        fi
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
RESULTS_CSV="performance_smtp_$(date +%Y%m%d_%H%M%S).csv"
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
