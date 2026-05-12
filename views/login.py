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
        QPushButton#btnIntra  { background: #2980b9; }
        QPushButton#btnIntra:hover  { background: #3498db; }
        QPushButton#btnIntra:disabled  { background: #bdc3c7; }
        QPushButton#btnGoogle { background: #c0392b; }
        QPushButton#btnGoogle:hover { background: #e74c3c; }
        QPushButton#btnGoogle:disabled { background: #bdc3c7; }
        QPushButton#btnPIN    { background: #8e44ad; }
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
        self._net_worker:   Optional[_Worker] = None
        self._net_mode:     Optional[NetworkMode] = None
        self._auto_connect_done: bool = False  # ← nouveau
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

        # Status bar
        sb = QStatusBar()
        self.setStatusBar(sb)
        self._net_txt = QLabel('Détection du réseau')
        self._net_txt.setStyleSheet('font-size: 12px;')
        self._net_txt.setContentsMargins(24, 0, 0, 0)  # aligné avec le titre
        self._dot_lbl = QLabel('●')
        self._dot_lbl.setStyleSheet('color: #95a5a6; font-size: 14px;')
        self._ses_txt = QLabel('')
        sb.addWidget(self._net_txt)
        sb.addWidget(self._dot_lbl)

        # Bouton Changer le mot de passe (visible uniquement après connexion Intranet)
        self._btn_change_pwd = QPushButton('Changer le mot de passe')
        self._btn_change_pwd.setObjectName('btnChangePwd')
        self._btn_change_pwd.setStyleSheet(
            'background: #7f8c8d; color: white; padding: 4px 12px; '
            'font-size: 11px; border-radius: 3px;'
        )
        self._btn_change_pwd.clicked.connect(self._on_change_password)
        self._btn_change_pwd.hide()
        sb.addPermanentWidget(self._btn_change_pwd)

        sb.addPermanentWidget(self._ses_txt)

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
        self._net_worker = _Worker(lambda: (True, detect_network(), ''))
        self._net_worker.done.connect(self._on_net_detected)
        self._net_worker.start()

    def showEvent(self, event):
        """Appelé lorsque la fenêtre devient visible."""
        super().showEvent(event)
        # Démarrer le timer de vérification réseau
        self._network_timer.start()
        # Mettre à jour les indicateurs immédiatement
        self._refresh_indicators()

    def hideEvent(self, event):
        """Appelé lorsque la fenêtre est masquée."""
        super().hideEvent(event)
        # Arrêter le timer de vérification réseau
        self._network_timer.stop()

    def _check_network(self) -> None:
        """Vérifie la connectique réseau (appelé par le timer)."""
        self._net_worker = _Worker(lambda: (True, detect_network(), ''))
        self._net_worker.done.connect(self._on_net_detected)
        self._net_worker.start()

    def _refresh_indicators(self) -> None:
        """Met à jour les feux Intranet et Cloud en fonction de l'état actuel des connexions."""
        intra_ok = db.server_conn is not None and db.mode == DBMode.INTRANET
        cloud_ok = db.server_conn is not None and db.mode == DBMode.CLOUD
        self._update_indicators(intranet=intra_ok, cloud=cloud_ok)

    def _on_net_detected(self, result) -> None:
        ok, mode, _ = result
        if not ok or mode is None:
            return
        self._net_mode = mode
        color = network_mode_color(mode)
        self._dot_lbl.setStyleSheet(f'color: {color}; font-size: 14px;')
        labels = {
            NetworkMode.INTRANET: 'Intranet',
            NetworkMode.INTERNET: 'Internet',
            NetworkMode.OFFLINE:  'Hors connexion',
        }
        self._net_txt.setText(labels.get(mode, ''))
        # Mettre à jour les indicateurs
        self._update_indicators_from_mode(mode)

        # Connexion automatique une seule fois au démarrage
        if not self._auto_connect_done:
            self._auto_connect_done = True
            self._auto_connect(mode)

    def _update_indicators_from_mode(self, mode: NetworkMode) -> None:
        """Met à jour les feux en fonction du mode réseau détecté."""
        if mode == NetworkMode.INTRANET:
            self._update_indicators(intranet=True, cloud=False)
            self._dot_lbl.setStyleSheet('color: #27ae60; font-size: 14px;')
        elif mode == NetworkMode.INTERNET:
            self._update_indicators(intranet=False, cloud=True)
            self._dot_lbl.setStyleSheet('color: #27ae60; font-size: 14px;')
        else:
            self._update_indicators(intranet=False, cloud=False)
            self._dot_lbl.setStyleSheet('color: #2c3e50; font-size: 14px;')

    def _auto_connect(self, mode: NetworkMode) -> None:
        # Priorité : Intranet > Cloud > Device
        self._set_busy(True)
        self._log('Tentative de connexion à l\'Intranet…')
        self._worker = _Worker(db.connect_intranet)
        self._worker.done.connect(
            lambda ok: self._on_auto_connect_result(ok, mode)
        )
        self._worker.start()

    def _on_auto_connect_result(self, ok: bool, mode: NetworkMode) -> None:
        if ok:
            self._set_busy(False)
            self._log('Connecté à l\'Intranet.')
            self._update_indicators(intranet=True, cloud=False)
            return
        # Intranet échoué, essayer le Cloud
        self._log('Intranet indisponible, tentative de connexion au Cloud…')
        self._update_indicators(intranet=False, cloud=False)
        self._worker = _Worker(db.connect_cloud)
        self._worker.done.connect(
            lambda ok2: self._on_cloud_connect_result(ok2, mode)
        )
        self._worker.start()

    def _on_cloud_connect_result(self, ok: bool, mode: NetworkMode) -> None:
        if ok:
            self._set_busy(False)
            self._log('Connecté au Cloud.')
            self._update_indicators(intranet=False, cloud=True)
            return
        # Cloud échoué, passer en mode device (hors connexion)
        self._set_busy(False)
        self._log('Aucune connexion serveur disponible. Passage en mode hors connexion.')
        self._update_indicators(intranet=False, cloud=False)
        sqlite_init.init()

    def _update_indicators(self, intranet: bool, cloud: bool) -> None:
        """Met à jour les feux Intranet et Cloud."""
        intra_color = '#27ae60' if intranet else '#2c3e50'
        cloud_color = '#27ae60' if cloud else '#2c3e50'
        self._intra_indicator.setStyleSheet(f'color: {intra_color}; font-size: 12px;')
        self._cloud_indicator.setStyleSheet(f'color: {cloud_color}; font-size: 12px;')
        # Afficher le bouton Changer le mot de passe uniquement si Intranet connecté
        self._btn_change_pwd.setVisible(intranet)

    def _on_change_password(self) -> None:
        """Ouvre la boîte de dialogue de changement de mot de passe."""
        from views.password import ChangePasswordDialog
        dlg = ChangePasswordDialog(self)
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
        self._worker = _Worker(AuthManager.auth_intranet, email, pwd)
        self._worker.done.connect(
            lambda r: self._on_auth_done(r, ConnMode.INTRANET)
        )
        self._worker.start()

    def _on_cloud(self) -> None:
        self._hide_error()
        self._set_busy(True)
        self._worker = _Worker(OAuth2Manager.authenticate)
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
            self._show_error('Impossible d\'ouvrir la base locale.')
            return
        self._hide_error()
        self._set_busy(True)
        self._worker = _Worker(AuthManager.auth_pin, email, pin)
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

            # Initialiser la table module_config avec les informations du professeur
            sqlite_init.init_module_config(
                annee_scolaire=infos['annee_scolaire'],
                trimestre_courant=infos['trimestre_courant'],
                nom_professeur=res.full_name,
                email_professeur=res.email
            )

            # Mode 4 : télécharger toutes les données du professeur pour le trimestre en cours
            self._show_confirmation_dialog(res, mode)
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

            # Initialiser la table module_config avec les informations du professeur
            sqlite_init.init_module_config(
                annee_scolaire=infos['annee_scolaire'],
                trimestre_courant=infos['trimestre_courant'],
                nom_professeur=res.full_name,
                email_professeur=res.email
            )

            # Mode 4 : télécharger toutes les données du professeur pour le trimestre en cours
            self._show_confirmation_dialog(res, mode)
            return

        self._apply_session(res, mode)


    def _show_confirmation_dialog(self, res: AuthResult, mode: ConnMode) -> None:
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
        buttons.accepted.connect(lambda: self._execute_steps(res, mode, dlg))
        buttons.rejected.connect(dlg.reject)
        layout.addWidget(buttons)

        dlg.exec()

    def _execute_steps(self, res: AuthResult, mode: ConnMode, dlg) -> None:
        """Exécute les étapes une par une avec processEvents."""
        dlg.accept()  # ferme la boîte de dialogue
        self._set_busy(True)
        self._log('Début du téléchargement des données du professeur…')
        QApplication.processEvents()

        # Initialiser la base SQLite (créer les tables si nécessaire)
        if not sqlite_init.init():
            self._show_error('Impossible d\'initialiser la base locale.')
            self._set_busy(False)
            return

        # Créer une connexion SQLite dédiée pour ce thread
        import sqlite3
        import os
        db_path = os.path.normpath(os.path.join(
            os.path.dirname(os.path.abspath(__file__)), '..', 'elarc.db'
        ))
        self._temp_conn = sqlite3.connect(db_path, check_same_thread=False)
        self._temp_conn.row_factory = sqlite3.Row
        self._temp_conn.execute('PRAGMA journal_mode=WAL')

        # Lancer le téléchargement dans un thread séparé
        self._data_thread = _Worker(
            sqlite_init.take_teacher_data,
            res.user_id, res.term_id,
            None,  # log_fn sera géré par le thread via QMetaObject
            self._temp_conn,
            parent=self
        )
        self._data_thread.done.connect(
            lambda result: self._on_data_finished(result, res, mode)
        )
        self._data_thread.start()

    def _on_data_finished(self, result, res: AuthResult, mode: ConnMode) -> None:
        """Appelé lorsque le thread de téléchargement est terminé."""
        self._set_busy(False)
        # Fermer la connexion temporaire
        if hasattr(self, '_temp_conn') and self._temp_conn:
            try:
                self._temp_conn.close()
            except Exception:
                pass
            self._temp_conn = None
        if not result:
            self._show_error('Échec du téléchargement des données du professeur.')
            return
        self._log('Téléchargement terminé avec succès.')
        # Appliquer la session maintenant que les données sont prêtes
        self._apply_session(res, mode)

    def _apply_session(self, res: AuthResult, mode: ConnMode) -> None:
        session.user_id           = res.user_id
        session.email             = res.email
        session.full_name         = res.full_name
        session.role              = res.role
        session.active_term_id    = res.term_id
        session.active_term_label = res.term_label
        session.conn_mode         = mode
        session.is_authenticated  = True

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
                if item in ('elarc.db', '__pycache__', '.git', '.venv'):
                    continue
                s = os.path.join(src, item)
                d = os.path.join(dest, item)
                if os.path.isdir(s):
                    shutil.copytree(s, d, dirs_exist_ok=True)
                else:
                    shutil.copy2(s, d)
            self._log("Copie terminée.")

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

    def _hide_error(self) -> None:
        self._err_lbl.hide()

    def _update_status_bar(self, res: AuthResult, mode: ConnMode) -> None:
        term = f' · {res.term_label}' if res.term_label else ''
        self._ses_txt.setText(
            f'{res.full_name}  |  {res.role.value}{term}  |  {mode.value}'
        )

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
