# Scripts de test pour KumoMTA

Ce répertoire contient les scripts de test pour vérifier le fonctionnement des listeners HTTP et SMTP de KumoMTA.

## 📋 Prérequis

### Pour tous les scripts
- `kubectl` configuré et connecté au cluster Kubernetes
- Accès au namespace où KumoMTA est déployé

### Pour les scripts Bash
- `jq` installé (pour parser le fichier JSON de configuration)
- Pour le test SMTP : `swaks`, `telnet`, ou `nc` (netcat) installé
- Pour le test HTTP : `curl` installé

### Pour les scripts Python (recommandés)
- Python 3.6 ou supérieur
- Bibliothèque `requests` (pour HTTP)

### Installation des outils manquants

**macOS:**
```bash
# Outils pour scripts Bash
brew install jq swaks telnet curl

# Python et dépendances
brew install python3
pip3 install -r requirements.txt
```

**Linux (Debian/Ubuntu):**
```bash
# Outils pour scripts Bash
sudo apt-get install jq swaks telnet netcat-openbsd curl

# Python et dépendances
sudo apt-get install python3 python3-pip
pip3 install -r requirements.txt
```

## 📁 Structure des fichiers

```
tests/
├── README.md                    # Ce fichier
├── requirements.txt             # Dépendances Python
├── test_payload_generic.json    # Fichier de configuration des données de test (modifiable)
├── test_http_listener.sh        # Script de test pour le listener HTTP (Bash)
├── test_smtp_listener.sh        # Script de test pour le listener SMTP (Bash)
├── test_performance_http.sh     # Script de test de performance HTTP (Bash)
├── test_performance_smtp.sh     # Script de test de performance SMTP (Bash)
├── test_performance_http.py     # Script de test de performance HTTP (Python - recommandé)
└── test_performance_smtp.py      # Script de test de performance SMTP (Python - recommandé)
```

## 🚀 Scripts Python (Recommandés)

Les scripts Python offrent une meilleure gestion des erreurs et une détection plus fiable des succès/échecs.

### Test de performance HTTP
```bash
# Avec 50 messages et 5 threads (par défaut)
python3 test_performance_http.py

# Avec un nombre spécifique de messages
python3 test_performance_http.py 100

# Avec nombre de messages et nombre de threads
python3 test_performance_http.py 100 10

# Avec variables d'environnement
NUM_MESSAGES=100 MAX_THREADS=10 python3 test_performance_http.py
```

### Test de performance SMTP
```bash
# Avec 50 messages et 5 threads (par défaut)
python3 test_performance_smtp.py

# Avec un nombre spécifique de messages
python3 test_performance_smtp.py 100

# Avec nombre de messages et nombre de threads
python3 test_performance_smtp.py 100 10

# Avec variables d'environnement
NUM_MESSAGES=100 MAX_THREADS=10 python3 test_performance_smtp.py
```

### Paramètres des scripts Python

- **nombre_de_messages** (premier paramètre) : Nombre de messages à envoyer (défaut: 50)
- **nombre_de_threads** (deuxième paramètre) : Nombre de threads pour la parallélisation (défaut: 5)

Les paramètres peuvent être passés :
- En arguments de ligne de commande : `python3 script.py 100 10`
- Via variables d'environnement : `NUM_MESSAGES=100 MAX_THREADS=10 python3 script.py`

### Avantages des scripts Python
- ✅ Meilleure détection des succès/échecs (utilise les codes de retour HTTP et SMTP)
- ✅ Gestion d'erreurs plus robuste
- ✅ Parsing des réponses plus fiable
- ✅ Statistiques détaillées (moyenne, médiane, percentiles)
- ✅ Export CSV des résultats
- ✅ Gestion automatique du port-forward Kubernetes
- ✅ Parallélisation avec threads (configurable, défaut: 5 threads)
- ✅ Gestion automatique de l'environnement virtuel et des dépendances

## ⚙️ Configuration

### Fichier `test_payload_generic.json`

Ce fichier contient toutes les données de test utilisées par les deux scripts. **Modifiez ce fichier une seule fois** pour changer les paramètres des deux tests.

```json
{
  "from_email": "test@talk.stir.com",
  "to_email": "test@example.com",
  "from_name": "KumoMTA Test",
  "subject": "Test KumoMTA - {{TIMESTAMP}}",
  "text_body": "...",
  "html_body": "...",
  "reply_to_email": "test@talk.stir.com",
  "reply_to_name": "KumoMTA Test"
}
```

**Variables disponibles:**
- `{{TIMESTAMP}}` : Sera remplacé par la date/heure actuelle au format `YYYY-MM-DD HH:MM:SS`

**Champs:**
- `from_email` : Adresse email de l'expéditeur (domaine du binding group)
- `to_email` : Adresse email du destinataire
- `from_name` : Nom d'affichage de l'expéditeur
- `subject` : Sujet du message (peut contenir `{{TIMESTAMP}}`)
- `text_body` : Corps du message en texte brut (peut contenir `{{TIMESTAMP}}`)
- `html_body` : Corps du message en HTML (peut contenir `{{TIMESTAMP}}`)
- `reply_to_email` : Adresse de réponse
- `reply_to_name` : Nom d'affichage pour la réponse

## 🚀 Utilisation

### Test du listener HTTP

Le script `test_http_listener.sh` teste l'injection de messages via l'API HTTP de KumoMTA.

```bash
cd tests
./test_http_listener.sh
```

**Configuration par défaut:**
- Namespace: `kumomta`
- Service: `kumomta` (détection automatique si différent)
- Port local: `8000`
- Authentification: `user1` / `default-password`

**Personnalisation via variables d'environnement:**
```bash
NAMESPACE=production \
RELEASE_NAME=kumomta-prod \
LOCAL_HTTP_PORT=8080 \
HTTP_USER=admin \
HTTP_PASSWORD=my-secure-password \
PAYLOAD_FILE=./custom_payload.json \
./test_http_listener.sh
```

### Test du listener SMTP

Le script `test_smtp_listener.sh` teste l'envoi de messages via le protocole SMTP.

```bash
cd tests
./test_smtp_listener.sh
```

**Configuration par défaut:**
- Namespace: `kumomta`
- Service: `kumomta` (détection automatique si différent)
- Port local: `2500`

**Personnalisation via variables d'environnement:**
```bash
NAMESPACE=production \
RELEASE_NAME=kumomta-prod \
LOCAL_SMTP_PORT=2525 \
PAYLOAD_FILE=./custom_payload.json \
./test_smtp_listener.sh
```

## 🔧 Fonctionnement

Les deux scripts fonctionnent de la même manière:

1. **Chargement du fichier JSON** - Lit les données depuis `test_payload_generic.json` (ou un fichier personnalisé passé en argument)
2. **Vérification du service Kubernetes** - Vérifie que le service KumoMTA existe
3. **Configuration du port-forward** - Crée un tunnel local vers le service dans le cluster
4. **Test de connexion** - Vérifie que le listener répond
5. **Envoi du message** - Envoie un message de test avec les données du fichier JSON
6. **Vérification du résultat** - Affiche le résultat et les codes de retour

Le port-forward est automatiquement nettoyé à la fin du script (ou en cas d'interruption).

## 📊 Résultats attendus

### Test HTTP réussi

```
=== Test du listener HTTP KumoMTA ===
Service: kumomta
Namespace: kumomta
Port local: 8000
Payload file: ./test_payload_generic.json
From: test@talk.stir.com
To: test@example.com

✓ Service trouvé
✓ Port-forward actif (PID: 12345)
✓ Connexion HTTP réussie
✓ Message envoyé avec succès (HTTP 200)

=== Test HTTP réussi ===
```

### Test SMTP réussi

```
=== Test du listener SMTP KumoMTA ===
Service: kumomta
Namespace: kumomta
Port local: 2500
Payload file: ./test_payload_generic.json
From: test@talk.stir.com
To: test@example.com

✓ Service trouvé
✓ Pod trouvé: kumomta-kumomta-0
✓ Listener SMTP semble être configuré
✓ Port-forward actif (PID: 12345)
✓ Message envoyé avec succès via SMTP

=== Test SMTP réussi ===
```

## 🐛 Dépannage

### Le fichier JSON n'est pas trouvé

- Vérifiez que `test_payload_generic.json` existe dans le même répertoire que les scripts
- Ou spécifiez le chemin complet avec `PAYLOAD_FILE=/chemin/vers/fichier.json`

### jq n'est pas installé

```bash
# macOS
brew install jq

# Linux
sudo apt-get install jq
```

### Le port-forward échoue

- Vérifiez que le port local n'est pas déjà utilisé
- Changez `LOCAL_HTTP_PORT` ou `LOCAL_SMTP_PORT` si nécessaire
- Vérifiez que vous avez les permissions nécessaires dans le cluster

### Le test HTTP échoue avec une erreur 401

- Vérifiez les credentials HTTP dans le secret `http-listener-keys`
- Utilisez les variables `HTTP_USER` et `HTTP_PASSWORD` pour spécifier les bonnes valeurs

### Le test SMTP échoue

- Vérifiez que le listener SMTP est activé dans `init.lua`
- Vérifiez les logs du pod: `kubectl logs -n <namespace> <pod-name> --tail=50`
- Assurez-vous que le port SMTP est correct (2500 par défaut)

### Le service n'est pas trouvé

- Vérifiez le nom du service: `kubectl get services -n <namespace>`
- Ajustez `SERVICE_NAME` ou `RELEASE_NAME` selon votre déploiement

## 📝 Notes

- Les scripts utilisent le domaine `talk.stir.com` du binding group **StirTalk** comme domaine d'origine par défaut
- Les messages sont envoyés à `test@example.com` (domaine de test standard)
- En mode sink (activé par défaut), les messages sont redirigés vers le service sink au lieu d'être envoyés réellement
- Les scripts nettoient automatiquement le port-forward même en cas d'interruption (Ctrl+C)
- Le fichier `test_payload_generic.json` est utilisé par défaut, mais vous pouvez passer un fichier JSON personnalisé en argument : `./test_http_listener.sh mon_fichier.json`
- Les deux scripts peuvent utiliser le même fichier JSON ou des fichiers différents selon vos besoins

## 🔗 Liens utiles

- [Documentation KumoMTA HTTP API](https://docs.kumomta.com/reference/http_api/)
- [Documentation KumoMTA SMTP Listener](https://docs.kumomta.com/userguide/configuration/smtplisteners/)
