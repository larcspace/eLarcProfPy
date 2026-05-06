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

    win = LoginWindow()
    win.show()

    sys.exit(app.exec())


if __name__ == '__main__':
    main()
