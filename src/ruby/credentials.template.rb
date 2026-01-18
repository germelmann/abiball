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

# Ticket Configuration
MAX_TICKETS_GLOBAL = 200
TICKET_PRICE_DEFAULT = 65.0
TICKETS_PER_USER = 10
ALLOW_USER_TICKET_DOWNLOAD = true

LOGIN_CODE_SALT = 'ein_schoenes_langes_salt_bitte_hier_einfuegen'

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
