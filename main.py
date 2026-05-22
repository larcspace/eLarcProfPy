import sys
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from PySide6.QtWidgets import QApplication
from PySide6.QtGui import QFont
from views.login import LoginWindow


def main() -> None:
    app = QApplication(sys.argv)
    app.setApplicationName('eLarcProf')
    app.setOrganizationName('Arc-en-Ciel')
    app.setStyle('Fusion')
    app.setFont(QFont('Segoe UI', 10))

    # Vérifier si le mode 4 est demandé
    if '--mode4' in sys.argv:
        # Lancer directement la création d'instance
        from common.database import db
        from common.auth import AuthManager
        from common.sqlite_init import sqlite_init
        from common.session import AuthResult, UserRole, session

        # Se connecter à l'Intranet
        if not db.connect_intranet():
            print("ERREUR : Impossible de se connecter à l'Intranet")
            sys.exit(1)
        print("Connexion Intranet établie")

        # Récupérer les informations du professeur (par défaut : premier professeur trouvé)
        # Pour l'instant, on utilise un email par défaut ou on demande à l'utilisateur
        import sys as _sys
        if len(_sys.argv) > 2:
            email = _sys.argv[2]
        else:
            email = input("Email du professeur : ").strip()

        exists, infos = AuthManager.check_teacher_exists(email)
        if not exists:
            print(f"ERREUR : Professeur {email} introuvable")
            sys.exit(1)

        print(f"Professeur trouvé : {infos['first_name']} {infos['last_name']}")

        # Initialiser la base SQLite
        if not sqlite_init.init():
            print("ERREUR : Impossible d'initialiser la base SQLite")
            sys.exit(1)

        # Initialiser module_config
        sqlite_init.init_module_config(
            annee_scolaire=infos['annee_scolaire'],
            trimestre_courant=infos['trimestre_courant'],
            nom_professeur=f"{infos['first_name']} {infos['last_name']}",
            email_professeur=email
        )

        # Télécharger les données du professeur
        print("Téléchargement des données du professeur...")
        ok, err_msg = sqlite_init.take_teacher_data(infos)
        if not ok:
            print(f"ERREUR lors du téléchargement : {err_msg}")
            sys.exit(1)

        print("Données téléchargées avec succès")

        # Vérifier les comptes
        conn = db.local_conn
        if conn:
            cur = conn.cursor()
            cur.execute("SELECT COUNT(*) FROM larcauth_evaluation")
            count_eval = cur.fetchone()[0]
            cur.execute("SELECT COUNT(*) FROM larcauth_learnerpei_has_termsubjectpei")
            count_pei = cur.fetchone()[0]
            cur.execute("SELECT COUNT(*) FROM larcauth_learnerdp_has_termsubjectdp")
            count_dp = cur.fetchone()[0]
            print(f"Comptes : eval={count_eval}, pei={count_pei}, dp={count_dp}")

        # Sauvegarder la session
        res = AuthResult(
            user_id=infos['user_id'],
            email=email,
            full_name=f"{infos['first_name']} {infos['last_name']}",
            role=UserRole.PROF,
            term_id=infos['trimestre_courant'],
            term_label=infos['trimestre_label']
        )
        sqlite_init.save_session(res)

        # Lancer l'interface graphique
        win = LoginWindow()
        win.show()
    elif '--test-create-db' in sys.argv:
        # Tester la création de la base SQLite
        from common.sqlite_init import sqlite_init
        from common.database import db

        # Créer une base temporaire
        import tempfile
        import os

        temp_dir = tempfile.mkdtemp()
        temp_db = os.path.join(temp_dir, 'test_elarc.db')

        print(f"Test de création de la base SQLite : {temp_db}")

        # Initialiser la base
        if not sqlite_init.init(temp_db):
            print("ERREUR : Impossible d'initialiser la base SQLite")
            sys.exit(1)

        # Vérifier les tables
        ok, missing = sqlite_init.verify_tables()
        if ok:
            print("SUCCÈS : Toutes les tables nécessaires existent")
        else:
            print(f"ERREUR : Tables manquantes : {missing}")
            sys.exit(1)

        # Nettoyer
        db.disconnect_all()
        os.remove(temp_db)
        os.rmdir(temp_dir)

        print("Test terminé avec succès")
        sys.exit(0)
    else:
        win = LoginWindow()
        win.show()

    sys.exit(app.exec())


if __name__ == '__main__':
    main()
