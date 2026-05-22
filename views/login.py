import os
import shutil
from typing import Optional

from PySide6.QtWidgets import (
    QMainWindow, QWidget, QVBoxLayout, QHBoxLayout, QFormLayout,
    QTabWidget, QLabel, QLineEdit, QPushButton, QStatusBar,
    QMessageBox, QFileDialog, QPlainTextEdit, QApplication,
)
from PySide6.QtCore import Qt, QThread, Signal, QMetaObject, Q_ARG, QTimer

from common.session import AuthResult, ConnMode, UserRole, session
from common.network import NetworkMode, detect_network, network_mode_color
from common.database import db, DBMode
from common.auth import AuthManager, OAuth2Manager
from common.sqlite_init import sqlite_init


# ---------------------------------------------------------------------------
# Generic background worker
# ---------------------------------------------------------------------------
class _Worker(QThread):
    done = Signal(object)   # emits whatever the function returns

    def __init__(self, fn, *args, parent=None):
        super().__init__(parent)
        self._fn   = fn
        self._args = args
        self.finished.connect(self.deleteLater)

    def run(self):
        try:
            self.done.emit(self._fn(*self._args))
        except Exception as exc:
            self.done.emit((False, None, str(exc)))



# ---------------------------------------------------------------------------
# Login window
# ---------------------------------------------------------------------------
class LoginWindow(QMainWindow):

    _STYLE = """
        QMainWindow  { background: #f5f6fa; }
        QWidget#root { background: #f5f6fa; }
        QTabWidget::pane {
            border: 1px solid #dcdde1; background: white; border-radius: 4px;
        }
        QTabBar::tab          { padding: 8px 20px; font-size: 11px; }
        QTabBar::tab:selected {
            background: white; border-bottom: 2px solid #3498db;
            color: #2c3e50; font-weight: bold;
        }
        QTabBar::tab:!selected { background: #ecf0f1; color: #7f8c8d; }
        QLineEdit {
            padding: 7px 10px; border: 1px solid #bdc3c7;
            border-radius: 4px; font-size: 12px; background: white;
        }
        QLineEdit:focus { border-color: #3498db; }
        QPushButton {
            padding: 9px 20px; border: none; border-radius: 4px;
            font-size: 12px; font-weight: bold; color: white;
        }
        QPushButton#btnIntra  { background: #2980b9; padding: 9px 20px; }
        QPushButton#btnIntra:hover  { background: #3498db; }
        QPushButton#btnIntra:disabled  { background: #bdc3c7; }
        QPushButton#btnGoogle { background: #c0392b; }
        QPushButton#btnGoogle:hover { background: #e74c3c; }
        QPushButton#btnGoogle:disabled { background: #bdc3c7; }
        QPushButton#btnPIN    { background: #8e44ad; padding: 9px 20px; }
        QPushButton#btnPIN:hover    { background: #9b59b6; }
        QPushButton#btnPIN:disabled { background: #bdc3c7; }
        QPushButton#btnCreate { background: #27ae60; }
        QPushButton#btnCreate:hover { background: #2ecc71; }
        QPushButton#btnCreate:disabled { background: #bdc3c7; }
        QPushButton#btnBrowse {
            background: #7f8c8d; padding: 9px 10px; min-width: 32px;
        }
        QPushButton#btnBrowse:hover { background: #95a5a6; }
        QLabel#errLabel { color: #c0392b; font-size: 11px; }
        QLabel#hdrTitle { color: #2c3e50; font-size: 22px; font-weight: bold; }
        QLabel#hdrSub   { color: #7f8c8d; font-size: 11px; }
        QLabel#infoLbl  { color: #555; font-size: 11px; }
    """

    def __init__(self):
        super().__init__()
        self._worker:       Optional[_Worker] = None
        self._net_mode:     Optional[NetworkMode] = None
        self._setup_ui()
        self._start_net_detection()

        # Timer pour vérifier la connectique toutes les 30 secondes
        self._network_timer = QTimer(self)
        self._network_timer.setInterval(30000)  # 30 secondes
        self._network_timer.timeout.connect(self._check_network)

    # ------------------------------------------------------------------
    # UI
    # ------------------------------------------------------------------
    def _setup_ui(self) -> None:
        self.setWindowTitle('eLarcProf — Connexion')
        self.setMinimumSize(460, 560)
        self.resize(460, 600)
        self.setStyleSheet(self._STYLE)

        root = QWidget()
        root.setObjectName('root')
        self.setCentralWidget(root)
        vbox = QVBoxLayout(root)
        vbox.setContentsMargins(24, 20, 24, 12)
        vbox.setSpacing(12)

        # Header
        title = QLabel('eLarcProf')
        title.setObjectName('hdrTitle')
        sub = QLabel('École Arc-en-Ciel  ·  IB School Management')
        sub.setObjectName('hdrSub')

        # Indicateurs en haut à droite
        self._intra_indicator = QLabel('Présence intranet ●')
        self._intra_indicator.setStyleSheet('color: #2c3e50; font-size: 12px;')
        self._cloud_indicator = QLabel('Présence cloud ●')
        self._cloud_indicator.setStyleSheet('color: #2c3e50; font-size: 12px;')

        header_layout = QHBoxLayout()
        header_layout.addWidget(title)
        header_layout.addStretch()
        header_layout.addWidget(self._intra_indicator)
        header_layout.addSpacing(16)
        header_layout.addWidget(self._cloud_indicator)

        vbox.addLayout(header_layout)
        vbox.addWidget(sub)

        # Tabs
        self._tabs = QTabWidget()
        vbox.addWidget(self._tabs, 1)
        self._build_intranet_tab()
        self._build_cloud_tab()
        self._build_pin_tab()
        self._build_new_tab()

        # Error label
        self._err_lbl = QLabel()
        self._err_lbl.setObjectName('errLabel')
        self._err_lbl.setWordWrap(True)
        self._err_lbl.hide()
        vbox.addWidget(self._err_lbl)

        # Log area
        self._log_area = QPlainTextEdit()
        self._log_area.setReadOnly(True)
        self._log_area.setMaximumHeight(120)
        self._log_area.setPlaceholderText('Messages de progression…')
        self._log_area.hide()
        vbox.addWidget(self._log_area)

        # Indicateur en bas (centré)
        self._bottom_indicator = QLabel('')
        self._bottom_indicator.setObjectName('bottomIndicator')
        self._bottom_indicator.setAlignment(Qt.AlignCenter)
        self._bottom_indicator.setStyleSheet(
            'color: #2c3e50; font-size: 16px; font-weight: bold;'
        )
        vbox.addWidget(self._bottom_indicator)

        # Status bar
        sb = QStatusBar()
        self.setStatusBar(sb)
        self._net_txt = QLabel('Détection du réseau')
        self._net_txt.setStyleSheet('font-size: 12px;')
        self._net_txt.setContentsMargins(24, 0, 0, 0)  # aligné avec le titre
        self._dot_lbl = QLabel('●')
        self._dot_lbl.setStyleSheet('color: #95a5a6; font-size: 14px;')
        sb.addWidget(self._net_txt)
        sb.addWidget(self._dot_lbl)


    def _tab_widget(self) -> tuple:
        """Returns (QWidget tab, QFormLayout, outer QVBoxLayout)"""
        tab  = QWidget()
        vbox = QVBoxLayout(tab)
        vbox.setContentsMargins(20, 20, 20, 20)
        vbox.setSpacing(10)
        form = QFormLayout()
        form.setSpacing(10)
        form.setLabelAlignment(Qt.AlignRight)
        return tab, form, vbox

    def _build_intranet_tab(self) -> None:
        tab, form, vbox = self._tab_widget()

        self._edt_i_email = QLineEdit()
        self._edt_i_email.setPlaceholderText('prenom.nom@arc-en-ciel.org')
        self._edt_i_pass  = QLineEdit()
        self._edt_i_pass.setEchoMode(QLineEdit.Password)
        self._edt_i_pass.setPlaceholderText('Mot de passe')
        form.addRow('Email :', self._edt_i_email)
        form.addRow('Mot de passe :', self._edt_i_pass)
        vbox.addLayout(form)

        self._btn_intra = QPushButton('Connexion Intranet')
        self._btn_intra.setObjectName('btnIntra')
        self._btn_intra.clicked.connect(self._on_intranet)
        self._edt_i_pass.returnPressed.connect(self._btn_intra.click)
        vbox.addWidget(self._btn_intra, alignment=Qt.AlignRight)

        self._btn_change_pwd_intra = QPushButton('Changer le mot de passe')
        self._btn_change_pwd_intra.setObjectName('btnChangePwdIntra')
        self._btn_change_pwd_intra.setStyleSheet(
            'background: #7f8c8d; color: white; padding: 9px 20px; '
            'font-size: 11px; border-radius: 3px;'
        )
        self._btn_change_pwd_intra.clicked.connect(self._on_change_password)
        vbox.addWidget(self._btn_change_pwd_intra, alignment=Qt.AlignRight)

        vbox.addStretch()

        self._tabs.addTab(tab, 'Intranet')

    def _build_cloud_tab(self) -> None:
        tab, _, vbox = self._tab_widget()

        info = QLabel(
            'Connectez-vous avec votre compte Google @arc-en-ciel.org\n'
            'via le protocole OAuth2 sécurisé (PKCE).\n\n'
            'Votre navigateur s\'ouvrira automatiquement.'
        )
        info.setObjectName('infoLbl')
        info.setAlignment(Qt.AlignCenter)
        info.setWordWrap(True)
        vbox.addStretch()
        vbox.addWidget(info)
        vbox.addSpacing(16)

        self._btn_google = QPushButton('  Connexion avec Google')
        self._btn_google.setObjectName('btnGoogle')
        self._btn_google.clicked.connect(self._on_cloud)
        vbox.addWidget(self._btn_google, alignment=Qt.AlignCenter)
        vbox.addStretch()

        self._tabs.addTab(tab, 'Cloud')

    def _build_pin_tab(self) -> None:
        tab, form, vbox = self._tab_widget()

        self._edt_p_email = QLineEdit()
        self._edt_p_email.setPlaceholderText('prenom.nom@arc-en-ciel.org')
        self._edt_p_pin   = QLineEdit()
        self._edt_p_pin.setEchoMode(QLineEdit.Password)
        self._edt_p_pin.setPlaceholderText('Code PIN (4-8 chiffres)')
        self._edt_p_pin.setMaxLength(8)
        form.addRow('Email :', self._edt_p_email)
        form.addRow('PIN :', self._edt_p_pin)
        vbox.addLayout(form)

        note = QLabel('Mode hors connexion — base locale SQLite uniquement.')
        note.setStyleSheet('color: #7f8c8d; font-size: 10px;')
        vbox.addWidget(note)

        self._btn_pin = QPushButton('Connexion PIN')
        self._btn_pin.setObjectName('btnPIN')
        self._btn_pin.clicked.connect(self._on_pin)
        self._edt_p_pin.returnPressed.connect(self._btn_pin.click)
        vbox.addWidget(self._btn_pin, alignment=Qt.AlignRight)

        self._btn_change_pin = QPushButton('Changer le code PIN')
        self._btn_change_pin.setObjectName('btnChangePin')
        self._btn_change_pin.setStyleSheet(
            'background: #7f8c8d; color: white; padding: 9px 20px; '
            'font-size: 11px; border-radius: 3px;'
        )
        self._btn_change_pin.clicked.connect(self._on_change_pin)
        vbox.addWidget(self._btn_change_pin, alignment=Qt.AlignRight)

        vbox.addStretch()

        self._tabs.addTab(tab, 'Hors connexion')

    def _build_new_tab(self) -> None:
        tab, form, vbox = self._tab_widget()

        info = QLabel(
            'Crée une nouvelle instance personnelle pour un enseignant.\n'
            'Un dossier dédié avec sa propre configuration sera généré.'
        )
        info.setObjectName('infoLbl')
        info.setWordWrap(True)
        vbox.addWidget(info)
        vbox.addSpacing(8)

        self._edt_n_email = QLineEdit()
        self._edt_n_email.setPlaceholderText('enseignant@arc-en-ciel.org')

        self._edt_n_dest = QLineEdit()
        self._edt_n_dest.setPlaceholderText('Dossier parent de destination…')
        self._edt_n_dest.setReadOnly(True)
        btn_browse = QPushButton('…')
        btn_browse.setObjectName('btnBrowse')
        btn_browse.setFixedWidth(36)
        btn_browse.clicked.connect(self._browse_dest)

        dest_row = QHBoxLayout()
        dest_row.addWidget(self._edt_n_dest)
        dest_row.addWidget(btn_browse)

        form.addRow('Email :', self._edt_n_email)
        form.addRow('Destination :', dest_row)
        vbox.addLayout(form)

        self._btn_create = QPushButton("Créer l'instance")
        self._btn_create.setObjectName('btnCreate')
        self._btn_create.clicked.connect(self._on_create)
        vbox.addWidget(self._btn_create, alignment=Qt.AlignRight)
        vbox.addStretch()

        self._tabs.addTab(tab, 'Nouvelle instance')

    # ------------------------------------------------------------------
    # Network detection
    # ------------------------------------------------------------------
    def _start_net_detection(self) -> None:
        worker = _Worker(lambda: (True, *detect_network(), ''), parent=self)
        worker.done.connect(self._on_net_detected)
        worker.start()

    def showEvent(self, event):
        """Appelé lorsque la fenêtre devient visible."""
        super().showEvent(event)
        # Démarrer le timer de vérification réseau
        self._network_timer.start()
        # Vérification réseau synchrone immédiate
        intra_ok, internet_ok = detect_network()
        self._on_net_detected((True, intra_ok, internet_ok, ''))
        # Lancer une vérification réseau asynchrone (pour le timer)
        self._check_network()
        # Mettre à jour les indicateurs immédiatement
        self._update_indicators(intra_ok, internet_ok)
        # Forcer la reconnexion à la base locale (même si déjà connectée)
        try:
            sqlite_init.init()
        except Exception as e:
            self._log(f"Erreur d'initialisation de la base locale : {e}")
        # Mettre à jour l'indicateur en bas selon l'état du module
        try:
            self._update_status_bar_from_module_config()
        except Exception as e:
            self._log(f"Erreur lors de la mise à jour de la barre d'état : {e}")

    def hideEvent(self, event):
        """Appelé lorsque la fenêtre est masquée."""
        super().hideEvent(event)
        # Arrêter le timer de vérification réseau
        self._network_timer.stop()

    def _check_network(self) -> None:
        """Vérifie la connectique réseau (appelé par le timer)."""
        worker = _Worker(lambda: (True, *detect_network(), ''), parent=self)
        worker.done.connect(self._on_net_detected)
        worker.start()


    def _on_net_detected(self, result) -> None:
        ok, intra_ok, internet_ok, _ = result
        if not ok:
            return
        self._intranet_ok = intra_ok
        self._internet_ok = internet_ok
        # Déterminer le mode principal pour la barre d'état
        if intra_ok:
            mode = NetworkMode.INTRANET
        elif internet_ok:
            mode = NetworkMode.INTERNET
        else:
            mode = NetworkMode.OFFLINE
        self._net_mode = mode
        color = network_mode_color(mode)
        self._dot_lbl.setStyleSheet(f'color: {color}; font-size: 14px;')
        labels = {
            NetworkMode.INTRANET: 'Intranet',
            NetworkMode.INTERNET: 'Internet',
            NetworkMode.OFFLINE:  'Hors connexion',
        }
        self._net_txt.setText(labels.get(mode, ''))
        # Mettre à jour les indicateurs en fonction de la détection réseau
        self._update_indicators(intra_ok, internet_ok)
        # Mettre à jour l'indicateur en bas (état 0 ou 1 selon si session existe)
        from common.session import session
        if session.is_authenticated:
            self._update_status_bar(
                AuthResult(
                    user_id=session.user_id,
                    email=session.email,
                    full_name=session.full_name,
                    role=session.role,
                    term_id=session.active_term_id,
                    term_label=session.active_term_label
                ),
                session.conn_mode
            )
        else:
            self._update_status_bar(
                AuthResult(
                    user_id=0,
                    email='',
                    full_name='',
                    role=UserRole.PROF,
                    term_id=0,
                    term_label=''
                ),
                ConnMode.OFFLINE
            )

        # Pas de connexion automatique au démarrage : on se contente de tester
        # la présence réseau (intranet/cloud) pour mettre à jour les indicateurs.
        # La connexion est déclenchée explicitement par l'utilisateur (clic Intranet,
        # Cloud, ou Nouvelle instance / mode 4). Cf. CONTEXT.md, section
        # "Architecture de synchronisation" → "Déclencheurs de la synchro".


    def _update_indicators(self, intranet: bool, cloud: bool) -> None:
        """Met à jour les feux Intranet et Cloud."""
        intra_color = '#27ae60' if intranet else '#2c3e50'
        cloud_color = '#27ae60' if cloud else '#2c3e50'
        self._intra_indicator.setStyleSheet(f'color: {intra_color}; font-size: 12px;')
        self._cloud_indicator.setStyleSheet(f'color: {cloud_color}; font-size: 12px;')

    def _on_change_password(self) -> None:
        """Ouvre la boîte de dialogue de changement de mot de passe."""
        from views.password import ChangePasswordDialog
        dlg = ChangePasswordDialog(self)
        dlg.exec()

    def _on_change_pin(self) -> None:
        """Ouvre la boîte de dialogue de changement de PIN."""
        from views.password import ChangePinDialog
        dlg = ChangePinDialog(self)
        dlg.exec()

    # ------------------------------------------------------------------
    # Auth handlers
    # ------------------------------------------------------------------
    def _on_intranet(self) -> None:
        email = self._edt_i_email.text().strip()
        pwd   = self._edt_i_pass.text()
        if not email or not pwd:
            self._show_error('Veuillez saisir votre email et mot de passe.')
            return
        self._hide_error()
        self._set_busy(True)
        self._worker = _Worker(AuthManager.auth_intranet, email, pwd, parent=self)
        self._worker.done.connect(
            lambda r: self._on_auth_done(r, ConnMode.INTRANET)
        )
        self._worker.start()

    def _on_cloud(self) -> None:
        self._hide_error()
        self._set_busy(True)
        self._worker = _Worker(OAuth2Manager.authenticate, parent=self)
        self._worker.done.connect(
            lambda r: self._on_auth_done(r, ConnMode.CLOUD)
        )
        self._worker.start()

    def _on_pin(self) -> None:
        email = self._edt_p_email.text().strip()
        pin   = self._edt_p_pin.text()
        if not email or not pin:
            self._show_error('Veuillez saisir votre email et votre PIN.')
            return
        if not sqlite_init.init():
            self._show_error('Impossible d\'initialiser la base locale.')
            return
        self._hide_error()
        self._set_busy(True)
        self._worker = _Worker(AuthManager.auth_pin, email, pin, parent=self)
        self._worker.done.connect(
            lambda r: self._on_auth_done(r, ConnMode.OFFLINE)
        )
        self._worker.start()

    def _on_auth_done(self, result, mode: ConnMode) -> None:
        self._set_busy(False)
        ok, res, err = result
        if not ok:
            self._show_error(err or 'Authentification échouée.')
            return

        # Vérifier que le professeur existe et est actif
        if mode in (ConnMode.INTRANET, ConnMode.CLOUD):
            exists, infos = AuthManager.check_teacher_exists(res.email)
            if not exists:
                self._show_error('Ce compte n\'est pas un professeur actif.')
                return
            # Mettre à jour les informations de session avec les données du serveur
            res.user_id = infos['user_id']
            res.full_name = f"{infos['first_name']} {infos['last_name']}"
            res.term_id = infos['trimestre_courant']
            res.term_label = infos['trimestre_label']

            # Initialiser la base locale avant d'écrire dans module_config
            if not sqlite_init.init():
                self._show_error('Impossible d\'initialiser la base locale.')
                return
            # Initialiser la table module_config avec les informations du professeur
            sqlite_init.init_module_config(
                annee_scolaire=infos['annee_scolaire'],
                trimestre_courant=infos['trimestre_courant'],
                nom_professeur=res.full_name,
                email_professeur=res.email
            )

            # Mode 4 : télécharger toutes les données du professeur pour le trimestre en cours
            # Appeler directement _execute_steps sans boîte de dialogue
            self._execute_steps(res, mode, None, infos)
            return

        # Pour le mode PIN, vérifier si la connexion serveur est disponible
        if mode == ConnMode.OFFLINE and db.server_conn is not None:
            exists, infos = AuthManager.check_teacher_exists(res.email)
            if not exists:
                self._show_error('Ce compte n\'est pas un professeur actif.')
                return
            # Mettre à jour les informations de session avec les données du serveur
            res.user_id = infos['user_id']
            res.full_name = f"{infos['first_name']} {infos['last_name']}"
            res.term_id = infos['trimestre_courant']
            res.term_label = infos['trimestre_label']

            # Initialiser la base locale avant d'écrire dans module_config
            if not sqlite_init.init():
                self._show_error('Impossible d\'initialiser la base locale.')
                return
            # Initialiser la table module_config avec les informations du professeur
            sqlite_init.init_module_config(
                annee_scolaire=infos['annee_scolaire'],
                trimestre_courant=infos['trimestre_courant'],
                nom_professeur=res.full_name,
                email_professeur=res.email
            )

            # Mode 4 : télécharger toutes les données du professeur pour le trimestre en cours
            self._show_confirmation_dialog(res, mode, infos)
            return

        # Pour le mode PIN sans connexion serveur, initialiser module_config avec les informations de la session
        if mode == ConnMode.OFFLINE and db.server_conn is None:
            # Initialiser la base locale avant d'écrire dans module_config
            if not sqlite_init.init():
                self._show_error('Impossible d\'initialiser la base locale.')
                return
            # Utiliser les informations de res (qui viennent de la session locale)
            sqlite_init.init_module_config(
                annee_scolaire='',
                trimestre_courant=res.term_id,
                nom_professeur=res.full_name,
                email_professeur=res.email
            )

        # Pour le mode PIN avec connexion serveur, télécharger les données
        if mode == ConnMode.OFFLINE and db.server_conn is not None:
            # Initialiser la base locale avant d'écrire dans module_config
            if not sqlite_init.init():
                self._show_error('Impossible d\'initialiser la base locale.')
                return
            # Initialiser la table module_config avec les informations du professeur
            sqlite_init.init_module_config(
                annee_scolaire=infos['annee_scolaire'],
                trimestre_courant=infos['trimestre_courant'],
                nom_professeur=res.full_name,
                email_professeur=res.email
            )

            # Mode 4 : télécharger toutes les données du professeur pour le trimestre en cours
            self._show_confirmation_dialog(res, mode, infos)
            return

        self._apply_session(res, mode)


    def _show_confirmation_dialog(self, res: AuthResult, mode: ConnMode, infos: dict) -> None:
        """Affiche une boîte de dialogue listant les étapes à effectuer."""
        from PySide6.QtWidgets import QDialog, QDialogButtonBox, QVBoxLayout, QLabel

        dlg = QDialog(self)
        dlg.setWindowTitle('Confirmation')
        dlg.setMinimumWidth(400)
        layout = QVBoxLayout(dlg)

        msg = QLabel(
            "Les étapes suivantes vont être exécutées :\n\n"
            "1. Initialisation de la base locale SQLite\n"
            "2. Téléchargement des données du professeur\n"
            "3. Sauvegarde de la session\n\n"
            "Veuillez patienter quelques minutes.\n"
            "L'interface peut sembler figée pendant l'opération."
        )
        msg.setWordWrap(True)
        layout.addWidget(msg)

        buttons = QDialogButtonBox(QDialogButtonBox.Ok | QDialogButtonBox.Cancel)
        buttons.accepted.connect(lambda: self._execute_steps(res, mode, dlg, infos))
        buttons.rejected.connect(dlg.reject)
        layout.addWidget(buttons)

        dlg.exec()

    def _execute_steps(self, res: AuthResult, mode: ConnMode, dlg, infos: dict) -> None:
        """Exécute les étapes une par une avec processEvents."""
        if dlg is not None:
            dlg.accept()  # ferme la boîte de dialogue
        self._set_busy(True)
        self._log('Début du téléchargement des données du professeur…')
        self._log(f"Infos reçues : user_id={infos.get('user_id')}, trimestre={infos.get('trimestre_courant')}")
        QApplication.processEvents()

        # Initialiser la base SQLite (créer les tables si nécessaire)
        if not sqlite_init.init():
            self._show_error('Impossible d\'initialiser la base locale.')
            self._set_busy(False)
            return

        # Utiliser la connexion SQLite déjà établie par init()
        self._temp_conn = db.local_conn

        # Afficher un spinner (barre de progression indéterminée)
        self._show_spinner(True)
        QApplication.processEvents()

        # Exécuter le téléchargement de manière synchrone
        try:
            ok, err_msg = sqlite_init.take_teacher_data(
                infos,
                self._log,
                self._temp_conn,
                None  # conn_pg (None pour utiliser db.server_conn)
            )
        except Exception as e:
            self._log(f"Exception dans take_teacher_data : {e}")
            self._show_spinner(False)
            self._set_busy(False)
            self._temp_conn = None
            self._show_error(f'Erreur lors du téléchargement : {e}')
            return

        # Masquer le spinner
        self._show_spinner(False)

        self._set_busy(False)
        self._temp_conn = None

        self._log(f"Résultat du téléchargement : ok={ok}, msg={err_msg}")
        if not ok:
            self._show_error(f'Échec du téléchargement des données du professeur : {err_msg}')
            return
        self._log('Téléchargement terminé avec succès.')
        # Vérifier les comptes dans la base locale
        try:
            conn = db.local_conn
            if conn:
                cur = conn.cursor()
                cur.execute("SELECT COUNT(*) FROM larcauth_evaluation")
                count_eval = cur.fetchone()[0]
                cur.execute("SELECT COUNT(*) FROM larcauth_learnerpei_has_termsubjectpei")
                count_pei = cur.fetchone()[0]
                cur.execute("SELECT COUNT(*) FROM larcauth_learnerdp_has_termsubjectdp")
                count_dp = cur.fetchone()[0]
                self._log(f"Comptes après téléchargement : eval={count_eval}, pei={count_pei}, dp={count_dp}")
        except Exception as e:
            self._log(f"Erreur lors de la vérification des comptes : {e}")
        # Appliquer la session maintenant que les données sont prêtes
        self._apply_session(res, mode)

    # Supprimer _on_data_finished car le traitement est maintenant synchrone dans _execute_steps

    def _apply_session(self, res: AuthResult, mode: ConnMode) -> None:
        session.user_id           = res.user_id
        session.email             = res.email
        session.full_name         = res.full_name
        session.role              = res.role
        session.active_term_id    = res.term_id
        session.active_term_label = res.term_label
        session.conn_mode         = mode
        session.is_authenticated  = True

        # Mettre à jour les indicateurs
        if mode == ConnMode.INTRANET:
            self._update_indicators(True, False)
        elif mode == ConnMode.CLOUD:
            self._update_indicators(False, True)
        else:
            self._update_indicators(False, False)

        # Persist session + offer to set PIN if online auth
        sqlite_init.init()
        if mode in (ConnMode.INTRANET, ConnMode.CLOUD):
            pin, ok = self._ask_pin_setup(res.full_name)
            sqlite_init.save_session(res, pin if ok else '')
        else:
            sqlite_init.save_session(res)

        self._update_status_bar(res, mode)
        self._open_main_window(res)

    def _ask_pin_setup(self, name: str):
        from PySide6.QtWidgets import QInputDialog
        return QInputDialog.getText(
            self, 'PIN hors connexion',
            f'Définissez un PIN pour {name} (laisser vide pour ignorer) :',
            QLineEdit.Password
        )

    # ------------------------------------------------------------------
    # New instance
    # ------------------------------------------------------------------
    def _browse_dest(self) -> None:
        folder = QFileDialog.getExistingDirectory(self, 'Choisir le dossier parent')
        if folder:
            self._edt_n_dest.setText(folder)

    def _on_create(self) -> None:
        self._hide_error()
        email  = self._edt_n_email.text().strip()
        parent = self._edt_n_dest.text().strip()
        if not email or not parent:
            self._show_error('Email et dossier de destination requis.')
            return

        # Vérifier que l'email correspond à un professeur actif
        # Priorité : Intranet > Cloud
        if db.server_conn is not None and db.mode == DBMode.INTRANET:
            # Connexion Intranet déjà établie
            exists, infos = AuthManager.check_teacher_exists(email)
            if not exists:
                self._show_error('Cet email ne correspond à aucun professeur actif.')
                return
        elif db.server_conn is not None and db.mode == DBMode.CLOUD:
            # Connexion Cloud déjà établie
            exists, infos = AuthManager.check_teacher_exists(email)
            if not exists:
                self._show_error('Cet email ne correspond à aucun professeur actif.')
                return
        else:
            # Aucune connexion serveur active, essayer l'Intranet d'abord
            self._log('Tentative de connexion à l\'Intranet…')
            if db.connect_intranet():
                exists, infos = AuthManager.check_teacher_exists(email)
                if not exists:
                    self._show_error('Cet email ne correspond à aucun professeur actif.')
                    return
            else:
                # Intranet échoué, essayer le Cloud
                self._log('Intranet indisponible, tentative de connexion au Cloud…')
                if db.connect_cloud():
                    exists, infos = AuthManager.check_teacher_exists(email)
                    if not exists:
                        self._show_error('Cet email ne correspond à aucun professeur actif.')
                        return
                else:
                    self._show_error('Aucune connexion serveur disponible (Intranet ni Cloud). '
                                     'La création d\'instance est impossible.')
                    return

        # Vérifier l'identité selon le mode
        if db.mode == DBMode.INTRANET:
            # Mode Intranet : demander le mot de passe
            from PySide6.QtWidgets import QInputDialog, QLineEdit
            pwd, ok = QInputDialog.getText(
                self, 'Mot de passe',
                f'Veuillez saisir le mot de passe pour {email} :',
                QLineEdit.Password
            )
            if not ok or not pwd:
                self._show_error('Mot de passe requis pour créer l\'instance.')
                return

            auth_ok, _, err = AuthManager.auth_intranet(email, pwd)
            if not auth_ok:
                self._show_error(f'Mot de passe incorrect : {err}')
                return

        elif db.mode == DBMode.CLOUD:
            # Mode Cloud : lancer OAuth2
            self._log('Lancement de l\'authentification OAuth2 Google…')
            auth_ok, res, err = OAuth2Manager.authenticate()
            if not auth_ok:
                self._show_error(f'Authentification Cloud échouée : {err}')
                return
            # Vérifier que l'email correspond
            if res.email.lower() != email.lower():
                self._show_error('L\'email du compte Google ne correspond pas à l\'email saisi.')
                return
        else:
            self._show_error('Mode de connexion inconnu.')
            return

        slug = email.split('@')[0].replace('.', '_')
        dest = os.path.normpath(os.path.join(parent, f'eLarcProf_{slug}'))
        try:
            self._show_progress('Création du dossier de destination…')
            os.makedirs(dest, exist_ok=True)
            self._log(f"Dossier créé : {dest}")

            # Copy entire project
            src = os.path.normpath(
                os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
            )
            self._show_progress('Copie des fichiers du projet…')
            for item in os.listdir(src):
                if item in ('__pycache__', '.git', '.venv'):
                    continue
                s = os.path.join(src, item)
                d = os.path.join(dest, item)
                if os.path.isdir(s):
                    shutil.copytree(s, d, dirs_exist_ok=True)
                else:
                    shutil.copy2(s, d)
            # Vérifier que config.ini a été copié
            dest_cfg = os.path.join(dest, 'config.ini')
            if not os.path.exists(dest_cfg):
                # Créer un fichier config.ini par défaut
                self._log("config.ini introuvable dans la source, création d'un fichier par défaut.")
                with open(dest_cfg, 'w', encoding='utf-8') as f:
                    f.write("""[IntranetDatabase]
Host = 127.0.0.1
Port = 5432
DB = NewLarcDB
User = postgres
Pass = postgres

[SupabaseDatabase]
Host = db.xxxxxxxxxxxx.supabase.co
Port = 5432
DB = postgres
User = postgres
Pass = votre_mot_de_passe_supabase
""")
                self._log(f"config.ini par défaut créé : {dest_cfg}")
            # Copier elarc.db s'il existe
            src_db = os.path.normpath(os.path.join(src, 'elarc.db'))
            if os.path.exists(src_db):
                shutil.copy2(src_db, os.path.join(dest, 'elarc.db'))
                self._log("elarc.db copié.")
            else:
                self._log("elarc.db introuvable dans la source.")
            self._log("Copie terminée.")

            # Initialiser la base locale dans le dossier de destination
            dest_db = os.path.join(dest, 'elarc.db')
            if not sqlite_init.init(dest_db):
                self._show_error('Impossible d\'initialiser la base locale dans le dossier de destination.')
                return

            # Vérifier que toutes les tables nécessaires existent
            ok, missing = sqlite_init.verify_tables()
            if not ok:
                self._log(f"ATTENTION : Tables manquantes dans la base locale : {missing}")
                # On continue quand même, mais on log l'avertissement

            # Initialiser module_config avec les informations du professeur
            sqlite_init.init_module_config(
                annee_scolaire=infos['annee_scolaire'],
                trimestre_courant=infos['trimestre_courant'],
                nom_professeur=f"{infos['first_name']} {infos['last_name']}",
                email_professeur=email
            )

            # Sauvegarder la session
            from common.session import AuthResult, UserRole
            res = AuthResult(
                user_id=infos['user_id'],
                email=email,
                full_name=f"{infos['first_name']} {infos['last_name']}",
                role=UserRole.PROF,
                term_id=infos['trimestre_courant'],
                term_label=infos['trimestre_label']
            )
            sqlite_init.save_session(res)

            # Write instance-specific config stub
            self._show_progress('Écriture du fichier instance.ini…')
            cfg_dest = os.path.join(dest, 'instance.ini')
            with open(cfg_dest, 'w', encoding='utf-8') as f:
                f.write(f'[Instance]\nEmail={email}\nCreated=auto\n')
            self._log(f"instance.ini créé : {cfg_dest}")

            # Launcher batch
            self._show_progress('Création du lanceur lancer.bat…')
            bat = os.path.join(dest, 'lancer.bat')
            with open(bat, 'w', encoding='utf-8') as f:
                f.write(f'@echo off\ncd /d "%~dp0"\npython main.py\npause\n')
            self._log(f"lancer.bat créé : {bat}")

            self._show_progress('Instance créée avec succès.')
            QMessageBox.information(
                self, 'Instance créée',
                f'Instance créée dans :\n{dest}\n\nLancez lancer.bat pour démarrer.'
            )
            self._hide_error()
        except Exception as e:
            self._show_error(f'Erreur de création : {e}')

    # ------------------------------------------------------------------
    # Helpers
    # ------------------------------------------------------------------
    def _set_busy(self, busy: bool) -> None:
        # Thread-safe via QMetaObject.invokeMethod
        for btn in (self._btn_intra, self._btn_google, self._btn_pin, self._btn_create):
            QMetaObject.invokeMethod(
                btn, "setEnabled",
                Qt.QueuedConnection,
                Q_ARG(bool, not busy)
            )
        text = 'Connexion en cours' if busy else self._net_txt.text()
        QMetaObject.invokeMethod(
            self._net_txt, "setText",
            Qt.QueuedConnection,
            Q_ARG(str, text)
        )

    def _show_error(self, msg: str) -> None:
        # Thread-safe via QMetaObject.invokeMethod
        QMetaObject.invokeMethod(
            self._err_lbl, "setText",
            Qt.QueuedConnection,
            Q_ARG(str, msg)
        )
        QMetaObject.invokeMethod(
            self._err_lbl, "setStyleSheet",
            Qt.QueuedConnection,
            Q_ARG(str, 'color: #c0392b; font-size: 11px;')
        )
        QMetaObject.invokeMethod(
            self._err_lbl, "show",
            Qt.QueuedConnection
        )

    def _log(self, msg: str) -> None:
        # Cette méthode peut être appelée depuis n'importe quel thread
        # Utiliser QMetaObject.invokeMethod pour être thread-safe
        QMetaObject.invokeMethod(
            self._log_area, "appendPlainText",
            Qt.QueuedConnection,
            Q_ARG(str, msg)
        )
        QMetaObject.invokeMethod(
            self._log_area, "show",
            Qt.QueuedConnection
        )
        # Scroll to bottom
        sb = self._log_area.verticalScrollBar()
        QMetaObject.invokeMethod(
            sb, "setValue",
            Qt.QueuedConnection,
            Q_ARG(int, sb.maximum())
        )

    def _show_progress(self, msg: str) -> None:
        self._err_lbl.setText(msg)
        self._err_lbl.setStyleSheet('color: #2c3e50; font-size: 11px;')
        self._err_lbl.show()
        self._log(msg)

    def _show_spinner(self, visible: bool) -> None:
        """Affiche ou masque une barre de progression indéterminée."""
        if not hasattr(self, '_spinner'):
            from PySide6.QtWidgets import QProgressBar
            self._spinner = QProgressBar()
            self._spinner.setRange(0, 0)  # indéterminé
            self._spinner.setFixedHeight(20)
            self._spinner.setStyleSheet(
                'QProgressBar { border: 1px solid #bdc3c7; border-radius: 4px; '
                'background: #ecf0f1; text-align: center; }'
                'QProgressBar::chunk { background: #3498db; }'
            )
            # Insérer après l'indicateur principal
            layout = self.centralWidget().layout()
            layout.insertWidget(layout.indexOf(self._bottom_indicator), self._spinner)
        self._spinner.setVisible(visible)

    def _hide_error(self) -> None:
        self._err_lbl.hide()

    def _get_module_config(self) -> Optional[dict]:
        """Lit la configuration du module depuis la base locale.
        Retourne un dict avec 'nom_professeur', 'annee_scolaire', 'trimestre_courant'
        ou None si la table n'existe pas ou est vide."""
        try:
            conn = db.local_conn
            if conn is None:
                return None
            cur = conn.cursor()
            # Vérifier que la table existe
            cur.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='module_config'")
            if not cur.fetchone():
                return None
            cur.execute("SELECT nom_professeur, annee_scolaire, trimestre_courant FROM module_config LIMIT 1")
            row = cur.fetchone()
            if row and row[0]:
                return {
                    'nom_professeur': row[0],
                    'annee_scolaire': row[1],
                    'trimestre_courant': row[2]
                }
        except Exception as e:
            self._log(f"Erreur dans _get_module_config : {e}")
        return None

    def _get_module_config_dates(self) -> dict:
        """Lit les dates de création et de dernière synchronisation depuis module_config.
        Retourne un dict avec 'date_creation_module' et 'derniere_synchronisation'."""
        try:
            conn = db.local_conn
            if conn is None:
                return {'date_creation_module': '', 'derniere_synchronisation': ''}
            cur = conn.cursor()
            # Vérifier que la table existe
            cur.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='module_config'")
            if not cur.fetchone():
                return {'date_creation_module': '', 'derniere_synchronisation': ''}
            cur.execute("SELECT date_creation_module, derniere_synchronisation FROM module_config LIMIT 1")
            row = cur.fetchone()
            if row:
                return {
                    'date_creation_module': row[0] or '',
                    'derniere_synchronisation': row[1] or ''
                }
        except Exception as e:
            self._log(f"Erreur dans _get_module_config_dates : {e}")
        return {'date_creation_module': '', 'derniere_synchronisation': ''}

    def _update_status_bar_from_module_config(self) -> None:
        """Met à jour l'indicateur en bas en lisant la configuration du module."""
        try:
            # Vérifier que la base locale est connectée
            if db.local_conn is None:
                self._bottom_indicator.setText("Module eLarcProf non instanciée")
                self._bottom_indicator.setStyleSheet(
                    'color: #2c3e50; font-size: 16px; font-weight: bold;'
                )
                if hasattr(self, '_bottom_dates_label'):
                    self._bottom_dates_label.setText('')
                return

            config = self._get_module_config()
            if config:
                prof_name = config['nom_professeur']
                # Déterminer le mode de connexion actuel
                from common.session import session
                if session.is_authenticated:
                    mode = session.conn_mode
                else:
                    mode = ConnMode.OFFLINE
                self._update_status_bar(
                    AuthResult(
                        user_id=0,
                        email='',
                        full_name=prof_name,
                        role=UserRole.PROF,
                        term_id=config['trimestre_courant'],
                        term_label=''
                    ),
                    mode
                )
            else:
                # Module non instancié
                self._bottom_indicator.setText("Module eLarcProf non instanciée")
                self._bottom_indicator.setStyleSheet(
                    'color: #2c3e50; font-size: 16px; font-weight: bold;'
                )
                # Supprimer le label des dates s'il existe
                if hasattr(self, '_bottom_dates_label'):
                    self._bottom_dates_label.setText('')
        except Exception as e:
            self._log(f"Erreur dans _update_status_bar_from_module_config : {e}")
            self._bottom_indicator.setText("Module eLarcProf non instanciée")
            self._bottom_indicator.setStyleSheet(
                'color: #2c3e50; font-size: 16px; font-weight: bold;'
            )

    def _update_status_bar(self, res: AuthResult, mode: ConnMode) -> None:
        """Met à jour l'indicateur en bas avec l'état de la connexion."""
        # Déterminer le nom du professeur
        prof_name = res.full_name if res.full_name else self._get_module_config()['nom_professeur'] if self._get_module_config() else ''

        # Récupérer les dates depuis module_config
        dates = self._get_module_config_dates()
        creation_date = dates.get('date_creation_module', '')
        sync_date = dates.get('derniere_synchronisation', '')

        if mode == ConnMode.INTRANET:
            title = f"Module de {prof_name} : Connecté à l'Intranet"
            color = "#27ae60"  # vert
        elif mode == ConnMode.CLOUD:
            title = f"Module de {prof_name} : connecté au Cloud"
            color = "#27ae60"  # vert
        else:
            # mode == ConnMode.OFFLINE
            if prof_name:
                title = f"Module de {prof_name} : Non connecté"
            else:
                title = "Module eLarcProf non instanciée"
            color = "#2c3e50"  # noir

        # Mettre à jour le label principal
        self._bottom_indicator.setText(title)
        self._bottom_indicator.setStyleSheet(
            f'color: {color}; font-size: 16px; font-weight: bold;'
        )

        # Mettre à jour le label des dates (créer s'il n'existe pas)
        if not hasattr(self, '_bottom_dates_label'):
            self._bottom_dates_label = QLabel()
            self._bottom_dates_label.setAlignment(Qt.AlignCenter)
            self._bottom_dates_label.setStyleSheet(
                'color: #7f8c8d; font-size: 11px;'
            )
            # Insérer après l'indicateur principal
            layout = self.centralWidget().layout()
            layout.insertWidget(layout.indexOf(self._bottom_indicator) + 1, self._bottom_dates_label)

        if creation_date or sync_date:
            dates_text = f"Création : {creation_date}  |  Dernière synchro : {sync_date}"
        else:
            dates_text = ""
        self._bottom_dates_label.setText(dates_text)

    def _open_main_window(self, res: AuthResult) -> None:
        from PySide6.QtWidgets import QDialog, QDialogButtonBox
        dlg = QDialog(self)
        dlg.setWindowTitle('eLarcProf')
        dlg.resize(360, 180)
        v = QVBoxLayout(dlg)
        v.addWidget(QLabel(
            f'<b>Bienvenue, {res.full_name}</b><br>'
            f'Rôle : {res.role.value}<br>'
            f'Trimestre : {res.term_label or "—"}<br><br>'
            f'<i>(Phase 2 — tableau de bord à implémenter)</i>'
        ))
        bb = QDialogButtonBox(QDialogButtonBox.Ok)
        bb.accepted.connect(dlg.accept)
        v.addWidget(bb)
        dlg.exec()
