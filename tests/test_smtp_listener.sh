#!/bin/bash

# Script de test pour le listener SMTP de KumoMTA
# Ce script teste l'envoi de messages via SMTP
#
# Usage:
#   ./test_smtp_listener.sh [fichier_json]
#   ou
#   PAYLOAD_FILE=fichier.json ./test_smtp_listener.sh
#
# Le fichier JSON peut contenir:
#   - from_email, to_email, from_name, subject, text_body
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
# Le nom du service suit la convention Helm: {release-name}-{chart-name}
# Si release-name contient déjà le chart-name, alors juste {release-name}
# Par défaut, on essaie d'abord {release-name}, puis {release-name}-kumomta
SERVICE_NAME="${SERVICE_NAME:-${RELEASE_NAME}}"
SMTP_PORT="${SMTP_PORT:-2500}"
LOCAL_SMTP_PORT="${LOCAL_SMTP_PORT:-2500}"

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
    TEXT_BODY_TEMPLATE=$(jq -r '.text_body' "${PAYLOAD_FILE}")
    SUBJECT_TEMPLATE=$(jq -r '.subject' "${PAYLOAD_FILE}")
    
    # Charger les headers personnalisés (si présents)
    if jq -e '.headers' "${PAYLOAD_FILE}" > /dev/null 2>&1; then
        # Extraire les headers pour traitement
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

# Préparer les headers personnalisés pour SMTP
CUSTOM_HEADERS=""
if [ "${HEADERS_JSON}" != "{}" ]; then
    # Remplacer les variables dans les headers
    HEADERS_JSON=$(echo "${HEADERS_JSON}" | sed "s/{{TIMESTAMP}}/${TIMESTAMP}/g")
    
    # Convertir le JSON des headers en format SMTP (clé: valeur)
    CUSTOM_HEADERS=$(echo "${HEADERS_JSON}" | jq -r 'to_entries | .[] | "\(.key): \(.value)"')
fi

# Couleurs pour l'output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${YELLOW}=== Test du listener SMTP KumoMTA ===${NC}"
echo "Service: ${SERVICE_NAME}"
echo "Namespace: ${NAMESPACE}"
echo "Port local: ${LOCAL_SMTP_PORT}"
echo "Payload file: ${PAYLOAD_FILE}"
echo "From: ${FROM_EMAIL}"
echo "To: ${TO_EMAIL}"
echo ""

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

# Vérifier que kubectl est disponible
if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}Erreur: kubectl n'est pas installé ou n'est pas dans le PATH${NC}"
    exit 1
fi

# Vérifier que le service existe
echo -e "${YELLOW}Vérification du service Kubernetes...${NC}"

# Essayer de trouver le service automatiquement si SERVICE_NAME n'existe pas
if ! kubectl get service "${SERVICE_NAME}" -n "${NAMESPACE}" &> /dev/null; then
    echo -e "${YELLOW}Service ${SERVICE_NAME} non trouvé, recherche automatique...${NC}"
    
    # Chercher les services kumomta dans le namespace (essayer d'abord {release-name}, puis {release-name}-kumomta)
    FOUND_SERVICE=$(kubectl get services -n "${NAMESPACE}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -E "^${RELEASE_NAME}$|^${RELEASE_NAME}-kumomta$" | head -1)
    
    if [ -n "${FOUND_SERVICE}" ]; then
        echo -e "${GREEN}Service trouvé: ${FOUND_SERVICE}${NC}"
        SERVICE_NAME="${FOUND_SERVICE}"
    else
        echo -e "${RED}Erreur: Le service ${SERVICE_NAME} n'existe pas dans le namespace ${NAMESPACE}${NC}"
        echo ""
        echo "Services disponibles dans le namespace ${NAMESPACE}:"
        kubectl get services -n "${NAMESPACE}" 2>/dev/null || echo "Namespace ${NAMESPACE} non accessible"
        echo ""
        echo "Indiquez le nom du service avec: SERVICE_NAME=<nom-du-service> ./test_smtp_listener.sh"
        exit 1
    fi
fi

echo -e "${GREEN}✓ Service trouvé${NC}"

# Vérifier que le listener SMTP est activé
echo -e "${YELLOW}Vérification de la configuration SMTP...${NC}"
POD_NAME=$(kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/name=kumomta -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -z "${POD_NAME}" ]; then
    echo -e "${RED}Erreur: Aucun pod KumoMTA trouvé${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Pod trouvé: ${POD_NAME}${NC}"

# Vérifier si le listener SMTP est actif avec plusieurs méthodes
SMTP_ENABLED=false

# Méthode 1: Vérifier dans les logs avec des patterns plus spécifiques
if kubectl logs -n "${NAMESPACE}" "${POD_NAME}" --tail=500 2>/dev/null | grep -qiE "start_esmtp_listener|listening.*0\.0\.0\.0:2500|listening.*:2500|esmtp.*listener.*2500|SMTP.*listener.*started|listening on.*2500"; then
    echo -e "${GREEN}✓ Listener SMTP détecté dans les logs${NC}"
    SMTP_ENABLED=true
fi

# Méthode 2: Vérifier si le port 2500 est en écoute dans le pod (si netstat/ss est disponible)
if [ "${SMTP_ENABLED}" = "false" ]; then
    if kubectl exec -n "${NAMESPACE}" "${POD_NAME}" -- sh -c "command -v netstat >/dev/null 2>&1 && netstat -tln 2>/dev/null | grep -q ':2500 ' || command -v ss >/dev/null 2>&1 && ss -tln 2>/dev/null | grep -q ':2500 '" 2>/dev/null; then
        echo -e "${GREEN}✓ Port 2500 en écoute dans le pod${NC}"
        SMTP_ENABLED=true
    fi
fi

# Méthode 3: Vérifier la configuration dans init.lua (si accessible)
if [ "${SMTP_ENABLED}" = "false" ]; then
    if kubectl exec -n "${NAMESPACE}" "${POD_NAME}" -- sh -c "grep -q 'start_esmtp_listener' /opt/kumomta/etc/policy/init.lua 2>/dev/null" 2>/dev/null; then
        echo -e "${GREEN}✓ start_esmtp_listener trouvé dans la configuration${NC}"
        SMTP_ENABLED=true
    fi
fi

# Si toujours pas détecté, on continue quand même mais avec un avertissement
if [ "${SMTP_ENABLED}" = "false" ]; then
    echo -e "${YELLOW}⚠ Le listener SMTP n'a pas été détecté automatiquement${NC}"
    echo "   Cela peut être normal si les logs sont récents ou si le pod vient de démarrer"
    echo "   Le test continuera quand même pour vérifier la connectivité"
    echo ""
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
            USE_EXISTING_PF=false
        else
            echo -e "${YELLOW}Test annulé. Utilisez un autre port avec: LOCAL_SMTP_PORT=<autre-port> ./test_smtp_listener.sh${NC}"
            exit 0
        fi
    fi
else
    USE_EXISTING_PF=false
fi

# Démarrer le port-forward en arrière-plan (si pas déjà existant)
if [ "${USE_EXISTING_PF}" != "true" ]; then
    echo -e "${YELLOW}Démarrage du port-forward (port ${LOCAL_SMTP_PORT})...${NC}"
    kubectl port-forward -n "${NAMESPACE}" "service/${SERVICE_NAME}" "${LOCAL_SMTP_PORT}:${SMTP_PORT}" > /tmp/kubectl-port-forward-smtp.log 2>&1 &
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
    cat /tmp/kubectl-port-forward-smtp.log 2>/dev/null || echo "Aucun log disponible"
    echo ""
    echo "Vérifiez que:"
    echo "  1. Le service ${SERVICE_NAME} existe dans le namespace ${NAMESPACE}"
    echo "  2. Le port ${SMTP_PORT} est bien exposé par le service"
    echo "  3. Vous avez les permissions nécessaires pour faire un port-forward"
    exit 1
fi

# Vérifier que le port est bien ouvert localement
if ! lsof -i :${LOCAL_SMTP_PORT} > /dev/null 2>&1; then
    echo -e "${RED}Erreur: Le port ${LOCAL_SMTP_PORT} n'est pas accessible localement${NC}"
    kill $PF_PID 2>/dev/null || true
    exit 1
fi

echo -e "${GREEN}✓ Port-forward actif (PID: ${PF_PID})${NC}"
echo "   Port local: ${LOCAL_SMTP_PORT} -> Service ${SERVICE_NAME}:${SMTP_PORT}"

# Test de connexion SMTP
echo -e "${YELLOW}Test de connexion SMTP...${NC}"

# Vérifier si telnet ou nc (netcat) est disponible
if command -v swaks &> /dev/null; then
    SMTP_CLIENT="swaks"
elif command -v telnet &> /dev/null; then
    SMTP_CLIENT="telnet"
elif command -v nc &> /dev/null; then
    SMTP_CLIENT="nc"
else
    echo -e "${RED}Erreur: Aucun client SMTP trouvé (swaks, telnet ou nc requis)${NC}"
    echo "Installation recommandée:"
    echo "  macOS: brew install swaks ou brew install telnet"
    echo "  Linux: apt-get install swaks ou apt-get install telnet"
    exit 1
fi

echo "Utilisation de: ${SMTP_CLIENT}"

# Test avec swaks (le plus simple et robuste)
if [ "${SMTP_CLIENT}" = "swaks" ]; then
    echo -e "${YELLOW}Envoi du message de test via SMTP (swaks)...${NC}"
    
    # Construire la commande swaks de base
    SWAKS_CMD="swaks --to \"${TO_EMAIL}\" --from \"${FROM_EMAIL}\" --server localhost --port \"${LOCAL_SMTP_PORT}\" --h-Subject \"${SUBJECT}\" --body \"${TEXT_BODY}\" --no-tls --no-hints"
    
    # Ajouter les headers personnalisés s'ils existent
    if [ -n "${CUSTOM_HEADERS}" ] && [ "${HEADERS_JSON}" != "{}" ]; then
        while IFS= read -r header_line; do
            if [ -n "${header_line}" ]; then
                header_name=$(echo "${header_line}" | cut -d: -f1 | xargs)
                header_value=$(echo "${header_line}" | cut -d: -f2- | sed 's/^ *//')
                # Échapper les guillemets dans la valeur pour la commande
                header_value=$(echo "${header_value}" | sed 's/"/\\"/g')
                SWAKS_CMD="${SWAKS_CMD} --add-header \"${header_name}: ${header_value}\""
            fi
        done <<EOF
${CUSTOM_HEADERS}
EOF
    fi
    
    # Exécuter swaks avec tous les arguments et capturer la sortie
    SWAKS_OUTPUT=$(eval "${SWAKS_CMD}" 2>&1)
    SWAKS_EXIT_CODE=$?
    
    # Vérifier le résultat (swaks retourne 0 en cas de succès)
    if [ ${SWAKS_EXIT_CODE} -eq 0 ]; then
        # Vérifier aussi dans la sortie pour confirmer
        if echo "${SWAKS_OUTPUT}" | grep -qiE "250.*Ok|250.*queued|250.*accepted|message accepted|250.*message queued"; then
            echo -e "${GREEN}✓ Message envoyé avec succès via SMTP${NC}"
            echo ""
            echo -e "${GREEN}=== Test SMTP réussi ===${NC}"
            exit 0
        else
            echo -e "${YELLOW}⚠ swaks a retourné 0 mais la réponse n'est pas claire${NC}"
            echo "Sortie:"
            echo "${SWAKS_OUTPUT}" | head -20
            echo ""
            echo -e "${GREEN}✓ Test considéré comme réussi (code de retour 0)${NC}"
            exit 0
        fi
    else
        echo -e "${RED}✗ Échec de l'envoi du message via SMTP (code: ${SWAKS_EXIT_CODE})${NC}"
        echo ""
        echo "Sortie de swaks:"
        echo "${SWAKS_OUTPUT}" | head -30
        echo ""
        echo "Vérifiez les logs du pod KumoMTA:"
        echo "  kubectl logs -n ${NAMESPACE} ${POD_NAME} --tail=50"
        exit 1
    fi
fi

# Test avec telnet ou nc (méthode manuelle)
echo -e "${YELLOW}Test de connexion SMTP (méthode manuelle)...${NC}"

# Créer un script temporaire pour l'interaction SMTP
TMP_SCRIPT=$(mktemp)

# Créer le script expect avec les headers personnalisés
{
    cat <<EOF
#!/usr/bin/expect -f
set timeout 10
spawn ${SMTP_CLIENT} localhost ${LOCAL_SMTP_PORT}
expect {
    "220" {
        send "EHLO test.local\r"
        expect "250"
        send "MAIL FROM:<${FROM_EMAIL}>\r"
        expect "250"
        send "RCPT TO:<${TO_EMAIL}>\r"
        expect "250"
        send "DATA\r"
        expect "354"
        send "From: ${FROM_NAME} <${FROM_EMAIL}>\r"
        send "To: ${TO_EMAIL}\r"
        send "Subject: ${SUBJECT}\r"
EOF
    
    # Ajouter les headers personnalisés s'ils existent
    if [ -n "${CUSTOM_HEADERS}" ] && [ "${HEADERS_JSON}" != "{}" ]; then
        while IFS= read -r header_line; do
            if [ -n "${header_line}" ]; then
                # Échapper les caractères spéciaux pour expect
                header_line_escaped=$(echo "${header_line}" | sed 's/\[/\\[/g; s/\]/\\]/g; s/\$/\\$/g; s/"/\\"/g')
                echo "        send \"${header_line_escaped}\\r\""
            fi
        done <<EOF_INNER
${CUSTOM_HEADERS}
EOF_INNER
    fi
    
    cat <<EOF
        send "\r"
        send "${TEXT_BODY}\r"
        send "\r"
        send ".\r"
        expect "250"
        send "QUIT\r"
        expect "221"
    }
    timeout {
        puts "Timeout lors de la connexion"
        exit 1
    }
}
EOF
} > "${TMP_SCRIPT}"

chmod +x "${TMP_SCRIPT}"

# Vérifier si expect est disponible
if ! command -v expect &> /dev/null; then
    echo -e "${YELLOW}⚠ expect n'est pas disponible, tentative avec une méthode alternative...${NC}"
    rm "${TMP_SCRIPT}"
    
    # Méthode simple avec echo et nc/telnet
    echo -e "${YELLOW}Envoi du message via SMTP (méthode simple)...${NC}"
    
    # Créer un fichier temporaire pour construire la commande SMTP avec les headers
    SMTP_CMD_FILE=$(mktemp)
    {
        echo "EHLO test.local"
        sleep 1
        echo "MAIL FROM:<${FROM_EMAIL}>"
        sleep 1
        echo "RCPT TO:<${TO_EMAIL}>"
        sleep 1
        echo "DATA"
        sleep 1
        echo "From: ${FROM_NAME} <${FROM_EMAIL}>"
        echo "To: ${TO_EMAIL}"
        echo "Subject: ${SUBJECT}"
        # Ajouter les headers personnalisés s'ils existent
        if [ -n "${CUSTOM_HEADERS}" ] && [ "${HEADERS_JSON}" != "{}" ]; then
            echo "${CUSTOM_HEADERS}"
        fi
        echo ""
        echo "${TEXT_BODY}"
        echo ""
        echo "."
        sleep 1
        echo "QUIT"
    } | "${SMTP_CLIENT}" localhost "${LOCAL_SMTP_PORT}" 2>&1 | tee /tmp/smtp_test_output.log
    rm -f "${SMTP_CMD_FILE}"
    
    if grep -q "250.*Ok\|250.*queued\|250.*accepted" /tmp/smtp_test_output.log; then
        echo -e "${GREEN}✓ Message envoyé avec succès via SMTP${NC}"
        echo ""
        echo -e "${GREEN}=== Test SMTP réussi ===${NC}"
        rm -f /tmp/smtp_test_output.log
        exit 0
    else
        echo -e "${RED}✗ Échec de l'envoi du message via SMTP${NC}"
        echo ""
        echo "Réponse du serveur:"
        cat /tmp/smtp_test_output.log
        echo ""
        echo "Vérifiez les logs du pod KumoMTA:"
        echo "  kubectl logs -n ${NAMESPACE} ${POD_NAME} --tail=50"
        rm -f /tmp/smtp_test_output.log
        exit 1
    fi
else
    # Utiliser expect pour une interaction plus robuste
    if "${TMP_SCRIPT}"; then
        echo -e "${GREEN}✓ Message envoyé avec succès via SMTP${NC}"
        echo ""
        echo -e "${GREEN}=== Test SMTP réussi ===${NC}"
        rm -f "${TMP_SCRIPT}"
        exit 0
    else
        echo -e "${RED}✗ Échec de l'envoi du message via SMTP${NC}"
        echo ""
        echo "Vérifiez les logs du pod KumoMTA:"
        echo "  kubectl logs -n ${NAMESPACE} ${POD_NAME} --tail=50"
        rm -f "${TMP_SCRIPT}"
        exit 1
    fi
fi
