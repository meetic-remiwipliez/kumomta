#!/usr/bin/env python3
"""
Script de test de performance pour le listener SMTP de KumoMTA
Ce script envoie plusieurs messages via SMTP pour tester les queues, spools et générer des métriques

Usage:
    python3 test_performance_smtp.py [nombre_de_messages] [nombre_de_threads]
    ou
    NUM_MESSAGES=100 MAX_THREADS=10 python3 test_performance_smtp.py

Paramètres:
    nombre_de_messages: Nombre de messages à envoyer (défaut: 50)
    nombre_de_threads: Nombre de threads pour la parallélisation (défaut: 5)
"""

import os
import sys
import time
import random
import subprocess
import signal
import statistics
import threading
import smtplib
from datetime import datetime
from typing import List, Tuple, Optional
from email.mime.text import MIMEText
from email.mime.multipart import MIMEMultipart
from concurrent.futures import ThreadPoolExecutor, as_completed

# Vérifier et installer les dépendances
def setup_environment():
    """Configure l'environnement virtuel et installe les dépendances"""
    script_dir = os.path.dirname(os.path.abspath(__file__))
    venv_dir = os.path.join(script_dir, '.venv')
    
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
    
    # Pour SMTP, on n'a pas besoin de dépendances externes (utilise la bibliothèque standard)
    print("✓ Environnement prêt (SMTP utilise uniquement la bibliothèque standard)")

# Appeler setup_environment avant les imports
setup_environment()

# ============================================================================
# CONFIGURATION
# ============================================================================

# Nombre de messages à envoyer (par défaut: 50)
# Usage: python3 test_performance_smtp.py [nombre_de_messages] [nombre_de_threads]
NUM_MESSAGES = int(os.getenv('NUM_MESSAGES', sys.argv[1] if len(sys.argv) > 1 else 50))
MAX_THREADS = int(os.getenv('MAX_THREADS', sys.argv[2] if len(sys.argv) > 2 else 5))

# Configuration Kubernetes par défaut
NAMESPACE = os.getenv('NAMESPACE', 'kumomta')
RELEASE_NAME = os.getenv('RELEASE_NAME', 'kumomta')
SERVICE_NAME = os.getenv('SERVICE_NAME', RELEASE_NAME)
SMTP_PORT = int(os.getenv('SMTP_PORT', 2500))
LOCAL_SMTP_PORT = int(os.getenv('LOCAL_SMTP_PORT', 2500))

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
            print("Test annulé. Utilisez un autre port avec: LOCAL_SMTP_PORT=<autre-port>")
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

def send_smtp_message(message_num: int, to_email: str) -> Tuple[bool, float, Optional[str]]:
    """Envoie un message via SMTP et retourne (succès, temps_ms, erreur)"""
    from_email = "perf-test@talk.stir.com"
    from_name = "Performance Test"
    subject = f"Performance Test #{message_num} - {datetime.now().strftime('%Y%m%d-%H%M%S')}"
    
    body = f"""Performance test message #{message_num}

This is a performance test message sent via SMTP.
Timestamp: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}
Message ID: {message_num}
Recipient: {to_email}

This message is used to test queues, spools and generate metrics.
Mode: SINK (messages will not be delivered)"""
    
    # Créer le message
    msg = MIMEText(body)
    msg['From'] = f"{from_name} <{from_email}>"
    msg['To'] = to_email
    msg['Subject'] = subject
    
    start_time = time.time()
    server = None
    try:
        # Se connecter au serveur SMTP
        server = smtplib.SMTP('localhost', LOCAL_SMTP_PORT, timeout=30)
        
        # Activer le mode debug pour voir les réponses (optionnel, peut être désactivé)
        # server.set_debuglevel(0)
        
        # Envoyer le message
        # sendmail retourne un dictionnaire vide en cas de succès
        # ou un dictionnaire avec les adresses refusées en cas d'échec
        refused = server.sendmail(from_email, [to_email], msg.as_string())
        
        elapsed_ms = (time.time() - start_time) * 1000
        
        # Si refused est vide, tous les destinataires ont été acceptés
        if not refused:
            return True, elapsed_ms, None
        else:
            # Certains destinataires ont été refusés
            return False, elapsed_ms, f"Recipients refused: {refused}"
        
    except smtplib.SMTPRecipientsRefused as e:
        elapsed_ms = (time.time() - start_time) * 1000
        return False, elapsed_ms, f"Recipients refused: {e}"
    except smtplib.SMTPDataError as e:
        elapsed_ms = (time.time() - start_time) * 1000
        # Les erreurs SMTPDataError peuvent parfois indiquer un succès partiel
        # Vérifier le code de réponse
        if hasattr(e, 'smtp_code') and e.smtp_code in [250, 251]:
            return True, elapsed_ms, None
        return False, elapsed_ms, f"Data error: {e}"
    except smtplib.SMTPException as e:
        elapsed_ms = (time.time() - start_time) * 1000
        return False, elapsed_ms, f"SMTP error: {e}"
    except (ConnectionRefusedError, OSError) as e:
        elapsed_ms = (time.time() - start_time) * 1000
        return False, elapsed_ms, f"Connection error: {e}"
    except Exception as e:
        elapsed_ms = (time.time() - start_time) * 1000
        return False, elapsed_ms, f"Unexpected error: {e}"
    finally:
        # S'assurer de fermer la connexion
        if server:
            try:
                server.quit()
            except Exception:
                try:
                    server.close()
                except Exception:
                    pass

# ============================================================================
# MAIN
# ============================================================================

def main():
    global port_forward_process
    
    print("=" * 60)
    print("Test de Performance - Listener SMTP KumoMTA")
    print("=" * 60)
    print(f"Service: {SERVICE_NAME}")
    print(f"Namespace: {NAMESPACE}")
    print(f"Port local: {LOCAL_SMTP_PORT}")
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
    
    # Vérifier le listener SMTP (optionnel)
    pod_name = None
    try:
        result = subprocess.run(
            ['kubectl', 'get', 'pods', '-n', NAMESPACE, '-l', 'app.kubernetes.io/name=kumomta', 
             '-o', 'jsonpath={.items[0].metadata.name}'],
            capture_output=True, text=True
        )
        if result.returncode == 0 and result.stdout.strip():
            pod_name = result.stdout.strip()
            # Vérification rapide dans les logs
            log_result = subprocess.run(
                ['kubectl', 'logs', '-n', NAMESPACE, pod_name, '--tail=500'],
                capture_output=True, text=True
            )
            if 'start_esmtp_listener' in log_result.stdout.lower() or 'listening' in log_result.stdout.lower():
                print("✓ Listener SMTP détecté")
            else:
                print("⚠ Listener SMTP non détecté dans les logs (peut être normal)")
    except Exception:
        pass
    
    # Configurer le port-forward
    port_forward_process = setup_port_forward(NAMESPACE, service, LOCAL_SMTP_PORT, SMTP_PORT)
    if port_forward_process is None and not use_existing_pf:
        print("✗ Impossible de configurer le port-forward")
        sys.exit(1)
    
    # Enregistrer le handler de nettoyage
    signal.signal(signal.SIGINT, lambda s, f: (cleanup_port_forward(), sys.exit(0)))
    signal.signal(signal.SIGTERM, lambda s, f: (cleanup_port_forward(), sys.exit(0)))
    
    try:
        # Test de connexion rapide
        print("\n⏳ Test de connexion au port SMTP...")
        try:
            server = smtplib.SMTP('localhost', LOCAL_SMTP_PORT, timeout=5)
            server.quit()
            print("✓ Port SMTP accessible")
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
            success, elapsed_ms, error = send_smtp_message(message_num, to_email)
            
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
            if pod_name:
                print(f"  kubectl logs -n {NAMESPACE} {pod_name} --tail=100")
            else:
                print(f"  kubectl logs -n {NAMESPACE} -l app.kubernetes.io/name=kumomta --tail=100")
            sys.exit(1)
    
    finally:
        cleanup_port_forward()

if __name__ == '__main__':
    main()
