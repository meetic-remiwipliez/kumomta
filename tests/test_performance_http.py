#!/usr/bin/env python3
"""
Script de test de performance pour le listener HTTP de KumoMTA
Ce script envoie plusieurs messages via l'API HTTP pour tester les queues, spools et générer des métriques

Usage:
    python3 test_performance_http.py [nombre_de_messages] [nombre_de_threads]
    ou
    NUM_MESSAGES=100 MAX_THREADS=10 python3 test_performance_http.py

Paramètres:
    nombre_de_messages: Nombre de messages à envoyer (défaut: 50)
    nombre_de_threads: Nombre de threads pour la parallélisation (défaut: 5)
"""

import os
import sys
import json
import time
import random
import subprocess
import signal
import statistics
import threading
from datetime import datetime
from typing import List, Tuple, Optional
from concurrent.futures import ThreadPoolExecutor, as_completed

# Vérifier et installer les dépendances
def setup_environment():
    """Configure l'environnement virtuel et installe les dépendances"""
    script_dir = os.path.dirname(os.path.abspath(__file__))
    venv_dir = os.path.join(script_dir, '.venv')
    requirements_file = os.path.join(script_dir, 'requirements.txt')
    
    # Vérifier si on est déjà dans un venv
    in_venv = hasattr(sys, 'real_prefix') or (hasattr(sys, 'base_prefix') and sys.base_prefix != sys.prefix)
    
    if not in_venv:
        # Créer un venv si nécessaire
        if not os.path.exists(venv_dir):
            print("⏳ Création de l'environnement virtuel...")
            subprocess.run([sys.executable, '-m', 'venv', venv_dir], check=True)
            print("✓ Environnement virtuel créé")
        
        # Activer le venv
        if sys.platform == 'win32':
            python_exe = os.path.join(venv_dir, 'Scripts', 'python.exe')
        else:
            python_exe = os.path.join(venv_dir, 'bin', 'python')
        
        # Réexécuter le script avec le Python du venv
        if os.path.exists(python_exe) and sys.executable != python_exe:
            print("⏳ Activation de l'environnement virtuel...")
            os.execv(python_exe, [python_exe] + sys.argv)
            return  # Ne revient jamais ici car execv remplace le processus
        elif not os.path.exists(python_exe):
            print("⚠ Impossible de trouver le Python du venv, utilisation du Python système")
    
    # Installer les dépendances
    if os.path.exists(requirements_file):
        print("⏳ Vérification des dépendances...")
        try:
            import requests
            print("✓ Dépendances déjà installées")
        except ImportError:
            print("⏳ Installation des dépendances...")
            pip_cmd = [sys.executable, '-m', 'pip', 'install', '-q', '-r', requirements_file]
            subprocess.run(pip_cmd, check=True)
            print("✓ Dépendances installées")

# Appeler setup_environment avant les imports
setup_environment()

# Imports après vérification de l'environnement
import requests
from requests.auth import HTTPBasicAuth

# ============================================================================
# CONFIGURATION
# ============================================================================

# Nombre de messages à envoyer (par défaut: 50)
# Usage: python3 test_performance_http.py [nombre_de_messages] [nombre_de_threads]
NUM_MESSAGES = int(os.getenv('NUM_MESSAGES', sys.argv[1] if len(sys.argv) > 1 else 50))
MAX_THREADS = int(os.getenv('MAX_THREADS', sys.argv[2] if len(sys.argv) > 2 else 5))

# Configuration Kubernetes par défaut
NAMESPACE = os.getenv('NAMESPACE', 'kumomta')
RELEASE_NAME = os.getenv('RELEASE_NAME', 'kumomta')
SERVICE_NAME = os.getenv('SERVICE_NAME', RELEASE_NAME)
HTTP_PORT = int(os.getenv('HTTP_PORT', 8000))
LOCAL_HTTP_PORT = int(os.getenv('LOCAL_HTTP_PORT', 8000))

# Authentification HTTP
HTTP_USER = os.getenv('HTTP_USER', 'user1')
HTTP_PASSWORD = os.getenv('HTTP_PASSWORD', 'default-password')

# Domaines pour générer les adresses destinataires
DOMAINS = ['gmail.com', 'yahoo.com', 'hotmail.com']

# Variables globales pour le port-forward
port_forward_process = None
use_existing_pf = False

# Lock pour thread-safety des statistiques
stats_lock = threading.Lock()

# ============================================================================
# FONCTIONS UTILITAIRES
# ============================================================================

def generate_random_email() -> str:
    """Génère une adresse email aléatoire sur un des domaines spécifiés"""
    domain = random.choice(DOMAINS)
    username = f"test{int(time.time())}{random.randint(1000, 9999)}"
    return f"{username}@{domain}"

def check_kubectl() -> bool:
    """Vérifie que kubectl est disponible"""
    try:
        subprocess.run(['kubectl', 'version', '--client'], 
                      capture_output=True, check=True)
        return True
    except (subprocess.CalledProcessError, FileNotFoundError):
        return False

def find_service(namespace: str, release_name: str) -> Optional[str]:
    """Trouve le service Kubernetes"""
    try:
        # Essayer d'abord avec le nom exact
        result = subprocess.run(
            ['kubectl', 'get', 'service', SERVICE_NAME, '-n', namespace],
            capture_output=True, text=True
        )
        if result.returncode == 0:
            return SERVICE_NAME
        
        # Chercher automatiquement
        result = subprocess.run(
            ['kubectl', 'get', 'services', '-n', namespace, '-o', 'jsonpath={.items[*].metadata.name}'],
            capture_output=True, text=True
        )
        if result.returncode == 0:
            services = result.stdout.strip().split()
            for svc in services:
                if svc == release_name or svc == f"{release_name}-kumomta":
                    return svc
    except Exception:
        pass
    return None

def check_port_in_use(port: int) -> Tuple[bool, Optional[int], bool]:
    """Vérifie si le port est utilisé et si c'est un port-forward kubectl"""
    try:
        result = subprocess.run(
            ['lsof', '-ti', f':{port}'],
            capture_output=True, text=True
        )
        if result.returncode == 0:
            pid = int(result.stdout.strip().split()[0])
            # Vérifier si c'est un port-forward kubectl
            ps_result = subprocess.run(
                ['ps', '-p', str(pid), '-o', 'command='],
                capture_output=True, text=True
            )
            is_kubectl_pf = 'kubectl' in ps_result.stdout and 'port-forward' in ps_result.stdout
            return True, pid, is_kubectl_pf
    except Exception:
        pass
    return False, None, False

def setup_port_forward(namespace: str, service: str, local_port: int, remote_port: int) -> Optional[subprocess.Popen]:
    """Configure le port-forward Kubernetes"""
    global use_existing_pf, port_forward_process
    
    # Vérifier si le port est déjà utilisé
    in_use, pid, is_kubectl = check_port_in_use(local_port)
    
    if in_use and is_kubectl:
        print(f"✓ Réutilisation du port-forward existant (PID: {pid})")
        use_existing_pf = True
        port_forward_process = None  # On ne gère pas ce processus
        return None
    elif in_use:
        response = input(f"⚠ Le port {local_port} est utilisé par un autre processus (PID: {pid}). Voulez-vous le tuer? (y/N): ")
        if response.lower() == 'y':
            try:
                os.kill(pid, signal.SIGTERM)
                time.sleep(1)
                print(f"✓ Ancien processus arrêté")
            except Exception as e:
                print(f"✗ Erreur lors de l'arrêt du processus: {e}")
                return None
        else:
            print("Test annulé. Utilisez un autre port avec: LOCAL_HTTP_PORT=<autre-port>")
            sys.exit(0)
    
    # Démarrer le port-forward
    print(f"⏳ Démarrage du port-forward (port {local_port})...")
    try:
        process = subprocess.Popen(
            ['kubectl', 'port-forward', '-n', namespace, f'service/{service}', f'{local_port}:{remote_port}'],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE
        )
        time.sleep(3)  # Attendre que le port-forward soit prêt
        
        # Vérifier que le processus est toujours actif
        if process.poll() is None:
            print(f"✓ Port-forward actif (PID: {process.pid})")
            return process
        else:
            stdout, stderr = process.communicate()
            print(f"✗ Le port-forward a échoué")
            print(f"  Erreur: {stderr.decode()}")
            return None
    except Exception as e:
        print(f"✗ Erreur lors du démarrage du port-forward: {e}")
        return None

def cleanup_port_forward():
    """Nettoie le port-forward"""
    global port_forward_process, use_existing_pf
    if not use_existing_pf and port_forward_process:
        print("\n⏳ Nettoyage du port-forward...")
        try:
            port_forward_process.terminate()
            port_forward_process.wait(timeout=5)
        except Exception:
            port_forward_process.kill()

def send_http_message(message_num: int, to_email: str) -> Tuple[bool, float, Optional[str]]:
    """Envoie un message via l'API HTTP et retourne (succès, temps_ms, erreur)"""
    from_email = "perf-test@talk.stir.com"
    from_name = "Performance Test"
    subject = f"Performance Test #{message_num} - {datetime.now().strftime('%Y%m%d-%H%M%S')}"
    
    text_body = f"""Performance test message #{message_num}

This is a performance test message sent via HTTP API.
Timestamp: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}
Message ID: {message_num}
Recipient: {to_email}

This message is used to test queues, spools and generate metrics.
Mode: SINK (messages will not be delivered)"""
    
    payload = {
        "envelope_sender": from_email,
        "content": {
            "text_body": text_body,
            "from": {
                "email": from_email,
                "name": from_name
            },
            "subject": subject
        },
        "recipients": [
            {
                "email": to_email
            }
        ]
    }
    
    url = f"http://localhost:{LOCAL_HTTP_PORT}/api/inject/v1"
    
    start_time = time.time()
    try:
        response = requests.post(
            url,
            json=payload,
            auth=HTTPBasicAuth(HTTP_USER, HTTP_PASSWORD),
            headers={'Content-Type': 'application/json'},
            timeout=30
        )
        elapsed_ms = (time.time() - start_time) * 1000
        
        # Vérifier le succès (codes 2xx)
        if 200 <= response.status_code < 300:
            return True, elapsed_ms, None
        else:
            error_msg = f"HTTP {response.status_code}: {response.text[:200]}"
            return False, elapsed_ms, error_msg
    except requests.exceptions.RequestException as e:
        elapsed_ms = (time.time() - start_time) * 1000
        return False, elapsed_ms, str(e)

# ============================================================================
# MAIN
# ============================================================================

def main():
    global port_forward_process
    
    print("=" * 60)
    print("Test de Performance - Listener HTTP KumoMTA")
    print("=" * 60)
    print(f"Service: {SERVICE_NAME}")
    print(f"Namespace: {NAMESPACE}")
    print(f"Port local: {LOCAL_HTTP_PORT}")
    print(f"Nombre de messages: {NUM_MESSAGES}")
    print(f"Nombre de threads: {MAX_THREADS}")
    print()
    
    # Vérifications préliminaires
    if not check_kubectl():
        print("✗ Erreur: kubectl n'est pas installé ou n'est pas dans le PATH")
        sys.exit(1)
    
    # Trouver le service
    print("⏳ Vérification du service Kubernetes...")
    service = find_service(NAMESPACE, RELEASE_NAME)
    if not service:
        print(f"✗ Erreur: Le service {SERVICE_NAME} n'existe pas dans le namespace {NAMESPACE}")
        sys.exit(1)
    print(f"✓ Service trouvé: {service}")
    
    # Configurer le port-forward
    port_forward_process = setup_port_forward(NAMESPACE, service, LOCAL_HTTP_PORT, HTTP_PORT)
    if port_forward_process is None and not use_existing_pf:
        print("✗ Impossible de configurer le port-forward")
        sys.exit(1)
    
    # Enregistrer le handler de nettoyage
    signal.signal(signal.SIGINT, lambda s, f: (cleanup_port_forward(), sys.exit(0)))
    signal.signal(signal.SIGTERM, lambda s, f: (cleanup_port_forward(), sys.exit(0)))
    
    try:
        # Test de connexion rapide
        print("\n⏳ Test de connexion au port HTTP...")
        try:
            response = requests.get(f"http://localhost:{LOCAL_HTTP_PORT}", timeout=5)
            print("✓ Port HTTP accessible")
        except Exception:
            print("⚠ Le port ne répond pas encore, mais on continue...")
        
        # Boucle d'envoi des messages avec parallélisation
        print(f"\n{'=' * 60}")
        print("Démarrage du test de performance")
        print(f"Parallélisation: {MAX_THREADS} threads maximum")
        print(f"{'=' * 60}\n")
        
        results = []
        success_count = [0]  # Utiliser une liste pour pouvoir modifier dans les threads
        fail_count = [0]
        times = []
        
        # Fonction pour envoyer un message (utilisée par les threads)
        def send_message_wrapper(message_num: int):
            to_email = generate_random_email()
            success, elapsed_ms, error = send_http_message(message_num, to_email)
            
            with stats_lock:
                times.append(elapsed_ms)
                results.append({
                    'message_num': message_num,
                    'status': 'SUCCESS' if success else 'FAIL',
                    'time_ms': elapsed_ms,
                    'to_email': to_email,
                    'error': error
                })
                
                if success:
                    success_count[0] += 1
                    print(f"✓ Message #{message_num}: SUCCESS ({elapsed_ms:.2f}ms) -> {to_email}")
                else:
                    fail_count[0] += 1
                    print(f"✗ Message #{message_num}: FAIL ({elapsed_ms:.2f}ms) -> {to_email}")
                    if message_num <= 5 and error:
                        print(f"   Erreur: {error[:150]}")
            
            return message_num, success, elapsed_ms
        
        # Utiliser ThreadPoolExecutor pour paralléliser
        max_workers = min(MAX_THREADS, NUM_MESSAGES)  # Maximum MAX_THREADS threads
        with ThreadPoolExecutor(max_workers=max_workers) as executor:
            # Soumettre toutes les tâches
            futures = {executor.submit(send_message_wrapper, i): i for i in range(1, NUM_MESSAGES + 1)}
            
            # Attendre la completion de toutes les tâches
            for future in as_completed(futures):
                try:
                    future.result()
                except Exception as e:
                    message_num = futures[future]
                    print(f"✗ Message #{message_num}: Exception -> {e}")
                    with stats_lock:
                        fail_count[0] += 1
                        results.append({
                            'message_num': message_num,
                            'status': 'FAIL',
                            'time_ms': 0,
                            'to_email': 'unknown',
                            'error': str(e)
                        })
        
        # Calcul des statistiques
        print(f"\n{'=' * 60}")
        print("Statistiques")
        print(f"{'=' * 60}\n")
        
        if times:
            print(f"Total de messages:     {NUM_MESSAGES}")
            print(f"Succès:                 {success_count[0]}")
            print(f"Échecs:                 {fail_count[0]}")
            print()
            print("Temps de réponse:")
            print(f"  Minimum:              {min(times):.2f} ms")
            print(f"  Maximum:              {max(times):.2f} ms")
            print(f"  Moyenne:              {statistics.mean(times):.2f} ms")
            print(f"  Médiane:              {statistics.median(times):.2f} ms")
            
            if len(times) > 1:
                sorted_times = sorted(times)
                p95_idx = int(len(times) * 0.95)
                p99_idx = int(len(times) * 0.99)
                if p95_idx >= len(times):
                    p95_idx = len(times) - 1
                if p99_idx >= len(times):
                    p99_idx = len(times) - 1
                print(f"  P95:                  {sorted_times[p95_idx]:.2f} ms")
                print(f"  P99:                  {sorted_times[p99_idx]:.2f} ms")
            
            print()
            success_rate = (success_count[0] * 100) / NUM_MESSAGES
            print(f"Taux de succès:         {success_rate:.1f}%")
        
        # Résumé final
        if fail_count[0] == 0:
            print(f"\n{'=' * 60}")
            print("✓ Test de performance réussi")
            print(f"{'=' * 60}")
            sys.exit(0)
        else:
            print(f"\n{'=' * 60}")
            print(f"⚠ Test de performance terminé avec {fail_count[0]} échec(s)")
            print(f"{'=' * 60}")
            print("\nVérifiez les logs du pod KumoMTA pour plus de détails:")
            print(f"  kubectl logs -n {NAMESPACE} -l app.kubernetes.io/name=kumomta --tail=100")
            sys.exit(1)
    
    finally:
        cleanup_port_forward()

if __name__ == '__main__':
    main()
