# ------------------------------------------------------------
# Achtung: Speichere diese Datei als credentials.rb
# und trage dann die Daten ein, so werden die Zugangs-
# daten nicht unbeabsichtigt ins Git geschrieben, solange
# der Eintrag src/ruby/credentials.rb in der .gitignore steht.
# ------------------------------------------------------------
DEVELOPMENT = (ENV['DEVELOPMENT'] == '1')
WEBSITE_HOST = ENV['WEBSITE_HOST']
WEB_ROOT = DEVELOPMENT ? 'http://localhost:8025' : "https://#{WEBSITE_HOST}"
QR_BASE_URL = DEVELOPMENT ? 'https://localhost:8025' : "https://#{WEBSITE_HOST}"

SEND_MAILS_IN_DEVELOPMENT = false

# Event Configuration
EVENT_NAME = 'Abiball 2024'
EVENT_YEAR = 2024
EVENT_LOCATION = 'Große Halle Berlin'

# Text printed on the vertical gold stub of the Abiball ticket (e.g. the school name).
# Falls auskommentiert/nicht gesetzt, wird EVENT_NAME verwendet.
# Optional: Wird eine Bilddatei unter src/static/images/ticket_background.png
# (oder .jpg) abgelegt, nutzt der Ticketdruck diese Grafik als Hintergrund eines
# einzelnen Tickets; andernfalls wird das Bordeaux/Gold-Design vektorbasiert gezeichnet.
TICKET_VERTICAL_LABEL = 'Gymnasium Steglitz'

# Ticket Configuration
MAX_TICKETS_GLOBAL = 200
TICKET_PRICE_DEFAULT = 65.0
TICKETS_PER_USER = 10
ALLOW_USER_TICKET_DOWNLOAD = true

LOGIN_CODE_SALT = 'ein_schoenes_langes_salt_bitte_hier_einfuegen'

# Maximum failed login attempts before a user gets banned
MAX_LOGIN_ATTEMPTS = 10

ADMIN_USERS = ['youremailhere@example.com']

SMTP_SERVER = 'smtp_server'
SMTP_USER = 'smtp_user'
SMTP_PASSWORD = 'smtp_password'
SMTP_DOMAIN = 'smtp_domain'
SMTP_FROM = 'Name <E-Mail-Adresse>'

ALLOWED_SENDER_DOMAINS = ['abebooks.com', 'buchfreund.de', 'booklooker.de', 'antiquariat.de']
IMAP_SERVER = 'imap_server'
IMAP_USER = 'imap_user'
IMAP_PASSWORD = 'imap_password'
IMAP_FOLDER = 'INBOX'


THEME_COLOR = '1e2460'
DARK_THEME_COLOR = '121622'

SUPPORT_EMAIL = 'support@example.com'

GLOBAL_BANNER = nil

# Yearbook Configuration
YEARBOOK_ENABLED = false
YEARBOOK_START_AT = nil  # e.g. '2026-01-01T00:00:00' or nil for no start restriction
YEARBOOK_END_AT = nil    # e.g. '2026-06-30T23:59:59' or nil for no end restriction

# Allow yearbook_manage users to delete ALL yearbook entries at once.
# Set to true to show the "Alle Einträge löschen" button in jahrbuch_manage.
YEARBOOK_ALLOW_DELETE_ALL = false

# Allow students to individualise their own yearbook page: they open the same designer,
# pre-filled with their data on top of the design they would otherwise receive, and can
# move things around or add their own elements. Set to false to keep everyone on the
# global variant design only.
YEARBOOK_USER_CUSTOMIZATION_ENABLED = true

YEARBOOK_QUESTIONS = [
    # Non-anonymous question (namentlich):
    # {
    #     id: "quote",
    #     type: "text",
    #     question: "Dein Motto:",
    #     anonymous: false
    # },
    # Anonymous question (anonym):
    # {
    #     id: "late_person",
    #     type: "single_choice",
    #     question: "Wer ist am häufigsten zu spät?",
    #     options: ["Person A", "Person B", "Person C"],
    #     anonymous: true
    # },
    # {
    #     id: "best_memory",
    #     type: "multiple_choice",
    #     question: "Beste Erinnerungen?",
    #     options: ["Klassenfahrt", "Abiball", "Projektwoche", "Sportfest"],
    #     anonymous: false
    # },
    # Upload question (namentlich):
    # {
    #     id: "fav_photo",
    #     type: "upload",
    #     question: "Dein Lieblingsfoto:",
    #     anonymous: false,
    #     max_file_size: 5_000_000,   # 5 MB per file
    #     max_uploads: 3              # max 3 files
    # }
]

# List of all students for the yearbook comment system.
# Comments are written to these student entries, not directly to user accounts.
# Admins/yearbook_manage can link a student entry to a user account.
SCHUELER = [
    # { id: "s_001", name: "Max Mustermann" },
    # { id: "s_002", name: "Erika Musterfrau" },
]

YEARBOOK_PROFILE_FIELDS = [
    { id: "nickname", label: "Spitzname", type: "text" },
    { id: "life_motto", label: "Lebensmotto", type: "text" },
    { id: "future_plans", label: "Zukunftspläne", type: "text" },
    { id: "best_memory", label: "Beste Erinnerung", type: "text" },
    { id: "message_to_class", label: "Nachricht an die Stufe", type: "textarea" },
    # Upload field example:
    # { id: "photo", label: "Foto", type: "upload", max_file_size: 5_000_000, max_uploads: 1 }
]

if defined? Mail
    Mail.defaults do
    delivery_method :smtp, {
        :address => SMTP_SERVER,
        :port => 587,
        :domain => SMTP_DOMAIN,
        :user_name => SMTP_USER,
        :password => SMTP_PASSWORD,
        :authentication => 'login',
        :enable_starttls_auto => true
    } 
    end
end
