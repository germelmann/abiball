require './include/helper.rb'
require './include/users.rb'
require './include/tags.rb'
require './include/tickets.rb'
require './include/events.rb'
require './include/log.rb'
require 'base64'
require 'cgi'
require 'digest'
require 'mail'
require 'neo4j_bolt'
require './credentials.rb'
require './include/mail.rb'
require 'securerandom'
require 'sinatra/base'
require 'sinatra/cookies'
require 'sinatra/reloader' if DEVELOPMENT
require 'json'

Neo4jBolt.bolt_host = 'neo4j'
Neo4jBolt.bolt_port = 7687

class Neo4jGlobal
    include Neo4jBolt
end

$neo4j = Neo4jGlobal.new

def assert(condition, message = 'assertion failed')
    raise message unless condition
end

def debug(message, index = 0)
    index = 0
    begin
        while index < caller_locations.size - 1 && ['transaction', 'neo4j_query', 'neo4j_query_expect_one'].include?(caller_locations[index].base_label)
            index += 1
        end
    rescue
        index = 0
    end
    # STDERR.puts caller_locations.to_yaml
    l = caller_locations[index]
    ls = ''
    begin
        ls = "#{l.path.sub('/app/', '')}:#{l.lineno} @ #{l.base_label}"
    rescue
        ls = "#{l[0].sub('/app/', '')}:#{l[1]}"
    end
    STDERR.puts "#{DateTime.now.strftime('%H:%M:%S')} [#{ls}] #{message}"
end

def debug_error(message)
    l = caller_locations.first
    ls = ""
    begin
        ls = "#{l.path.sub("/app/", "")}:#{l.lineno} @ #{l.base_label}"
    rescue
        ls = "#{l[0].sub("/app/", "")}:#{l[1]}"
    end
    STDERR.puts "#{DateTime.now.strftime("%H:%M:%S")} [ERROR] [#{ls}] #{message}"
end

class RandomTag
    BASE_31_ALPHABET = '0123456789bcdfghjklmnpqrstvwxyz'
    def self.to_base31(i)
        result = ''
        while i > 0
            result += BASE_31_ALPHABET[i % 31]
            i /= 31
        end
        result
    end

    def self.generate(length = 12)
        self.to_base31(SecureRandom.hex(length).to_i(16))[0, length]
    end
end

def mail_html_to_plain_text(s)
    s.gsub('<p>', "\n\n").gsub(/<br\s*\/?>/, "\n").gsub(/<\/?[^>]*>/, '').strip
end

# Global email template helper function
# Parameters:
#   title: Email title shown in header (e.g., "Bestellbestätigung")
#   content: HTML content to insert in the email body
def format_email_with_template(title, content)
    StringIO.open do |io|
        io.puts "<!DOCTYPE html>"
        io.puts "<html>"
        io.puts "<head>"
        io.puts "    <meta charset=\"UTF-8\">"
        io.puts "    <title>#{title}</title>"
        io.puts "    <style>"
        io.puts "        .container { max-width: 600px; margin: 0 auto; font-family: Arial, sans-serif; }"
        io.puts "        .header { background-color: ##{THEME_COLOR}; color: white; padding: 20px; text-align: center; }"
        io.puts "        .content { padding: 20px; }"
        io.puts "        .order-details { background-color: #f8f9fa; padding: 15px; border-radius: 5px; margin: 15px 0; }"
        io.puts "        .success-badge { background-color: #d4edda; color: #155724; padding: 10px; border-radius: 5px; margin-bottom: 15px; }"
        io.puts "        .info-badge { background-color: #d1ecf1; color: #0c5460; padding: 10px; border-radius: 5px; margin-bottom: 15px; }"
        io.puts "        .participants { margin-top: 15px; }"
        io.puts "        .participant { padding: 5px; border-bottom: 1px solid #eee; }"
        io.puts "        .footer { background-color: #f8f9fa; padding: 20px; text-align: center; font-size: 12px; color: #666; }"
        io.puts "        .btn { background-color: ##{THEME_COLOR}; color: white; padding: 10px 20px; text-decoration: none; border-radius: 5px; display: inline-block; margin: 10px 0; }"
        io.puts "        .code { font-size: 200%; font-weight: bold; letter-spacing: 5px; }"
        io.puts "    </style>"
        io.puts "</head>"
        io.puts "<body>"
        io.puts "    <div class=\"container\">"
        io.puts "        <div class=\"header\">"
        io.puts "            <h1>#{EVENT_NAME}</h1>"
        io.puts "            <h2>#{title}</h2>"
        io.puts "        </div>"
        io.puts "        <div class=\"content\">"
        io.puts content
        io.puts "            <p>Viele Grüße<br>Das #{EVENT_NAME} Team</p>"
        io.puts "        </div>"
        io.puts "        <div class=\"footer\">"
        io.puts "            <p>Diese E-Mail wurde automatisch generiert. Antworte bei Fragen auf diese E-Mail.</p>"
        io.puts "        </div>"
        io.puts "    </div>"
        io.puts "</body>"
        io.puts "</html>"
        io.string
    end
end

def deliver_mail(plain_text = nil, &block)
    mail = Mail.new do
        charset = 'UTF-8'
        message = self.instance_eval(&block)
        if plain_text.nil?
            html_part do
                content_type 'text/html; charset=UTF-8'
                body message
            end

            text_part do
                content_type 'text/plain; charset=UTF-8'
                body mail_html_to_plain_text(message)
            end
        else
            text_part do
                content_type 'text/plain; charset=UTF-8'
                body plain_text
            end
        end
    end
    if DEVELOPMENT && !SEND_MAILS_IN_DEVELOPMENT
        STDERR.puts "Not sending mail in development mode!"
        STDERR.puts '-' * 40
        STDERR.puts "From:    #{mail.from.join('; ')}"
        STDERR.puts "To:      #{mail.to.join('; ')}"
        STDERR.puts "Subject: #{mail.subject}"
        STDERR.puts mail.text_part
        STDERR.puts '-' * 40
    else
        mail.deliver!
    end
end


class SetupDatabase
    include Neo4jBolt

    def setup(main)
        delay = 1
        10.times do
            begin
                neo4j_query("MATCH (n) RETURN n LIMIT 1;")
                break
            rescue
                debug $!
                debug "Retrying setup after #{delay} seconds..."
                sleep delay
                delay += 1
            end
        end
    end
end

class Main < Sinatra::Base
    include Neo4jBolt
    helpers Sinatra::Cookies

    configure do
        setup = SetupDatabase.new()
        setup.setup(self)
        setup.wait_for_neo4j()
        debug "Server is up and running!"

        # create admin users in database if they don't exist yet
        ADMIN_USERS.each do |username|
            # check if a user with this email or username already exists (case-insensitive)
            existing = $neo4j.neo4j_query(<<~END_OF_QUERY, {:username => username}).to_a
                MATCH (u:User)
                WHERE toLower(u.email) = toLower($username) OR toLower(u.username) = toLower($username)
                RETURN u LIMIT 1;
            END_OF_QUERY

            if existing.empty?
            # create a new admin user only if neither email nor username exists
            $neo4j.neo4j_query(<<~END_OF_QUERY, {:username => username})
                CREATE (u:User {
                email: $username,
                username: $username,
                name: "Admin",
                admin: true,
                email_verified: true,
                address: "",
                phone: ""
                });
            END_OF_QUERY
            else
            # If a matching user exists, ensure they have admin privileges and email verified
            $neo4j.neo4j_query(<<~END_OF_QUERY, {:username => username})
                MATCH (u:User)
                WHERE toLower(u.email) = toLower($username) OR toLower(u.username) = toLower($username)
                SET u.admin = true, u.email_verified = true;
            END_OF_QUERY
            end
        end

        $neo4j.neo4j_query(<<~END_OF_QUERY, {usernames: ADMIN_USERS})
            MATCH (u:User)
            WHERE u.admin = true AND NOT u.username IN $usernames AND NOT u.email IN $usernames
            REMOVE u.admin
        END_OF_QUERY

        # Ensure admin users have all permissions
        ADMIN_USERS.each do |username|
            # First, clear existing permissions for this admin
            $neo4j.neo4j_query(<<~END_OF_QUERY, {:username => username})
                MATCH (u:User {username: $username})-[r:HAS_PERMISSION]->(p:Permission)
                DELETE r
            END_OF_QUERY
            
            # Then add all permissions
            Main::PERMISSIONS.each do |perm|
                $neo4j.neo4j_query(<<~END_OF_QUERY, {:username => username, :permission => perm[:key]})
                    MERGE (p:Permission {name: $permission})
                    WITH p
                    MATCH (u:User {username: $username})
                    MERGE (u)-[:HAS_PERMISSION]->(p)
                END_OF_QUERY
            end
        end

        # Scan all users, fix missing usernames
        users = $neo4j.neo4j_query("MATCH (u:User) RETURN id(u) AS id, u.email AS email, u.username AS username").map { |r| r }
        existing_usernames = users.map { |u| u["username"] }.compact.map(&:downcase).to_set

        users.each do |user|
            id = user["id"]
            email = user["email"]
            username = user["username"]

            if username.nil? || username.strip.empty?
                # Try to create a username from the email
                candidate = sanitize_to_username(email.to_s)
                if candidate && !existing_usernames.include?(candidate)
                    $neo4j.neo4j_query("MATCH (u:User) WHERE id(u) = $id SET u.username = $username", {id: id, username: candidate})
                    existing_usernames << candidate
                else
                    random_username = RandomTag.generate(12)
                    tries = 0
                    while existing_usernames.include?(random_username) && tries < 10
                        random_username = RandomTag.generate(12)
                        tries += 1
                    end
                    if !existing_usernames.include?(random_username)
                        $neo4j.neo4j_query("MATCH (u:User) WHERE id(u) = $id SET u.username = $username", {id: id, username: random_username})
                        existing_usernames << random_username
                    else
                        # Could not assign a unique username, delete user
                        $neo4j.neo4j_query("MATCH (u:User) WHERE id(u) = $id DETACH DELETE u", {id: id})
                    end
                end
            end
        end
    end

    before '*' do
        @session_user = nil
        if request.cookies.include?('sid')
            sid = request.cookies['sid']
            if (sid.is_a? String) && (sid =~ /^[0-9A-Za-z]+$/)
                first_sid = sid.split(',').first
                if first_sid =~ /^[0-9A-Za-z]+$/
                    results = neo4j_query(<<~END_OF_QUERY, :sid => first_sid).to_a
                    MATCH (s:Session {sid: $sid})-[:FOR]->(u:User)
                    RETURN s, u, properties(u), labels(u);
                  END_OF_QUERY
                    if results.size == 1
                        begin
                            session = results.first['s']
                            user = results.first['u']
                            session_expiry = session[:expires]
                            if DateTime.parse(session_expiry) > DateTime.now
                                @session_user = {
                                    :email => results.first['u'][:email].downcase,
                                    :name => results.first['u'][:name],
                                    :admin => results.first['u'][:admin],
                                    :username => results.first['u'][:username],
                                }
                            end
                        rescue
                            # something went wrong, delete the session
                            results = neo4j_query(<<~END_OF_QUERY, :sid => first_sid).to_a
                                MATCH (s:Session {sid: $sid})
                                DETACH DELETE s;
                            END_OF_QUERY
                            STDERR.puts "Deleted invalid session"
                        end
                    end
                end
            end
        end
        
        # Redirect scanner-only users to scanner page
        if user_logged_in? && !request.path_info.start_with?('/api/')
            redirect_scanner_only_users!
        end
    end

    def user_logged_in?
        return (!@session_user.nil?)
    end

    def admin_logged_in?
        return user_logged_in? && @session_user[:admin]
    end

    def chef_logged_in?
        return user_logged_in? && @session_user[:chef] || admin_logged_in?
    end


    def require_user!
        assert(user_logged_in?)
    end

    def require_admin!
        assert(admin_logged_in?)
    end

    def require_chef!
        assert(chef_logged_in?)
    end

    post '/api/request_login' do
        data = parse_request_data(:required_keys => [:username])
        email = data[:username].downcase
        STDERR.puts "Login request for #{email}"

        tag = RandomTag::generate(12)
        srand(Digest::SHA2.hexdigest(LOGIN_CODE_SALT).to_i + (Time.now.to_f * 1000000).to_i)
        random_code = (0..5).map { |x| rand(10).to_s }.join('')
        random_code = '123456' if DEVELOPMENT && !SEND_MAILS_IN_DEVELOPMENT

        log("Code #{random_code} für #{email}")

        # Verify user exists by email
        user = neo4j_query_expect_one(<<~END_OF_QUERY, {:email => email})
            MATCH (u:User {email: $email})
            RETURN u.email, u.name, u.username;
        END_OF_QUERY

        name = user['u.name'] || 'Nutzer'
        username = user['u.username'] || 'Benutzer'

        STDERR.puts "Sending code #{random_code} to #{email}"

        neo4j_query_expect_one(<<~END_OF_QUERY, {:email => email, :tag => tag, :code => random_code})
            MATCH (u:User {email: $email})
            CREATE (r:LoginRequest)-[:FOR]->(u)
            SET r.tag = $tag
            SET r.code = $code
            RETURN u.email;
        END_OF_QUERY

        deliver_mail do
            to email
            # bcc SMTP_FROM
            from SMTP_FROM

            subject "Dein Anmeldecode lautet #{random_code}"

            content = StringIO.open do |io|
                io.puts "<p>Hallo #{name},</p>"
                io.puts "<p>bitte verwende folgenden Code für die Anmeldung:</p>"
                io.puts "<p class='code'>#{random_code}</p>"
                io.puts "<p>Alternativ kannst du auch einfach auf den folgenden Link klicken, um dich anzumelden:</p>"
                io.puts "<p><a class='btn' href='#{WEB_ROOT}/l/#{tag}/#{random_code}'>Jetzt anmelden</a></p>"
                io.puts "<p>Falls du dich nicht anmelden wolltest, hat wohl jemand versucht, sich mit deiner E-Mail-Adresse anzumelden. In diesem Fall kannst du diese E-Mail einfach ignorieren.</p>"
                io.string
            end

            format_email_with_template("Anmeldecode", content)
        end
        respond(:success => true, :ok => 'yay', :tag => tag)
    end

    def logout()
        sid = request.cookies['sid']
        if sid =~ /^[0-9A-Za-z,]+$/
            current_sid = sid.split(',').first
            if current_sid =~ /^[0-9A-Za-z]+$/
                result = neo4j_query(<<~END_OF_QUERY, :sid => current_sid)
                    MATCH (s:Session {sid: $sid})
                    DETACH DELETE s;
                END_OF_QUERY
            end
        end
    end

    post '/api/logout' do
        logout()
        respond(:success => true, :ok => 'yeah')
    end

    def get_todays_smart_sentence()
        if Time.now.hour < 11
            "Guten Morgen!"
        elsif Time.now.hour < 17
            "Guten Tag!"
        else
            "Guten Abend!"
        end
    end

    def print_global_banner()
        return '' unless user_logged_in?
        return '' unless defined?(GLOBAL_BANNER) && GLOBAL_BANNER
        "<div class='alert alert-warning text-center mb-0' role='alert' style='border: 0px;'>#{GLOBAL_BANNER}</div>"
    end

    def get_support_mailto(request_type)
        types = {
            'general' => 'Allgemein',
            'data_change' => 'Datenänderung',
            'order' => 'Bestellung',
            'ticket' => 'Ticket',
            'payment' => 'Zahlung',
            'technical' => 'Technisch',
            'financial' => 'Finanziell',
            'companion' => 'Schwerbehinderung / Begleitperson benötigt (SGB IX)',
            'refund' => 'Rückerstattung',
            'datenschutz' => 'Datenschutz',
            'impressum' => 'Impressum',
            'other' => 'Sonstiges'
        }

        type_label = types[request_type.to_s] || types['general']
        subject = "[Support] #{type_label} - #{EVENT_NAME}"

        body = <<~TEXT
            Hallo,

            [Dein Anliegen bitte hier eintragen]


            ----------------------------------------
            Anfragedaten (bitte nicht entfernen):
            Thema: #{type_label}
            ----------------------------------------
        TEXT
        if @session_user
            body = <<~TEXT
                Hallo,

                [Dein Anliegen bitte hier eintragen]

                Viele Grüße
                #{@session_user[:name] ? @session_user[:name] : ''}


                ----------------------------------------
                Anfragedaten (bitte nicht entfernen):
                Name: #{@session_user[:name] ? @session_user[:name] : ''}
                E-Mail: #{@session_user[:email] ? @session_user[:email] : ''}
                ID: #{@session_user[:username] ? @session_user[:username] : ''}
                Thema: #{type_label}
                ----------------------------------------
            TEXT
        end

        escaped_subject = CGI.escape(subject).gsub('+', '%20').gsub('%0A', '%0D%0A')
        escaped_body = CGI.escape(body).gsub('+', '%20').gsub('%0A', '%0D%0A')

        mailto = "mailto:#{SUPPORT_EMAIL}?subject=#{escaped_subject}&body=#{escaped_body}"
        mailto
    end

    def print_links()
        links = "<p>#{get_todays_smart_sentence()}</p>
            <div class='row'>
                <div class='col-md-4'>
                    <h2>Ticket-Bestellung</h2>
                    <a class='btn btn-primary' href='tickets'><i class='bi bi-ticket'></i>&nbsp;&nbsp;Tickets bestellen</a>
                    <p class='mt-2 text-muted'>Bestelle deine Tickets für den Abiball 2026</p>
                </div>
                #{user_has_permission?("view_users") || user_has_permission?("admin") ? 
                "<div class='col-md-4'>
                    <h2>Administration</h2>
                    <a class='#{user_has_permission?("view_users") ? '' : 'disabled'} btn btn-primary' href='users'><i class='bi bi-people'></i>&nbsp;&nbsp;Benutzer verwalten</a>
                    <a class='#{user_has_permission?("view_users") ? '' : 'disabled'} btn btn-info' href='order_management'><i class='bi bi-list-check'></i>&nbsp;&nbsp;Bestellungsmanagement</a>
                    <a class='#{user_has_permission?("admin") ? '' : 'disabled'} btn btn-danger' href='admin'><i class='bi bi-gear'></i>&nbsp;&nbsp;Administration</a>
                </div>" : ""}
            </div>
            <br>
            <div class='alert alert-danger'>
                Wir haben festgestellt, dass Apple unsere automatischen Mails an <b>@icloud.com</b>-Adressen blockiert. Wenn Du dich bereits mit einer solchen Adresse registriert hast, schreib uns bitte eine alternative E-Mail-Adresse an <a href='#{get_support_mailto('data_change')}'>#{SUPPORT_EMAIL}</a>. Nutze dazu bitte deine @icloud.com-Adresse als Absender.
            </div>"
        login = "<p>Du bist nicht angemeldet. Bitte melde dich an, um Tickets bestellen zu können.</p>
            <div class='row'>
                <div class='col-md-6'>
                    <h2>Login</h2>
                    <a class='btn btn-primary' href='login'><i class='bi bi-person-lock'></i>&nbsp;&nbsp;Anmelden</a>
                </div>
            </div>
            <br>
            <div class='alert alert-danger'>
                Wir haben festgestellt, dass Apple unsere automatischen Mails an <b>@icloud.com</b>-Adressen blockiert. Wenn Du dich bereits mit einer solchen Adresse registriert hast, schreib uns bitte eine alternative E-Mail-Adresse an <a href='#{get_support_mailto('data_change')}'>#{SUPPORT_EMAIL}</a>. Nutze dazu bitte deine @icloud.com-Adresse als Absender.
            </div>"
        if user_logged_in?
            links
        else
            login
        end
    end

    def print_impressum()
        log("Impressum aufgerufen")
        StringIO.open do |io|
            io.puts "<h1>Impressum</h1>"
            io.puts "<p>Angaben gemäß § 5 TMG:</p>"
            io.puts "<p>#{IMPRESSUM_MAINTAINTER}</p>"
            io.puts "<h2>Kontakt</h2>"
            io.puts "<p>E-Mail: <a href='#{get_support_mailto('impressum')}'>#{SUPPORT_EMAIL}</a></p>"
            io.string
        end
    end

    def print_datenschutz()
        log("Datenschutzerklärung aufgerufen")
        StringIO.open do |io|
            io.puts "<h1>Datenschutzerklärung</h1>"
            io.puts "<p>Wir nehmen den Schutz Ihrer persönlichen Daten sehr ernst. Ihre Daten werden vertraulich und entsprechend der gesetzlichen Datenschutzvorschriften sowie dieser Datenschutzerklärung behandelt.</p>"
            io.puts "<h2>Erhebung und Verarbeitung personenbezogener Daten</h2>"
            io.puts "<p>Personenbezogene Daten werden nur erhoben, wenn Sie uns diese im Rahmen Ihrer Bestellung, bei einer Registrierung oder bei der Kontaktaufnahme freiwillig mitteilen.</p>"
            io.puts "<h2>Verwendung von Cookies</h2>"
            io.puts "<p>Unsere Website setzt einen einzigen Cookie (Session-ID), um den Benutzer während der Sitzung zu identifizieren und die Nutzung bestimmter Funktionen zu ermöglichen.</p>"
            io.puts "<h2>Ihre Rechte</h2>"
            io.puts "<p>Sie haben das Recht auf Auskunft über Ihre gespeicherten personenbezogenen Daten sowie auf Berichtigung, Löschung oder Einschränkung der Verarbeitung dieser Daten.</p>"
            io.puts "<p>Bei Fragen zur Erhebung, Verarbeitung oder Nutzung Ihrer personenbezogenen Daten, bei Auskünften, Berichtigung, Sperrung oder Löschung von Daten wenden Sie sich bitte an: <a href='#{get_support_mailto('datenschutz')}'>#{SUPPORT_EMAIL}</a>.</p>"
            io.string
        end
    end

    def search_data(data:, search_term: nil, fields: nil, start: 0, length: 10, order_field: nil, order_dir: "asc")
        results = data

        fields ||= results.first&.keys || []

        if search_term && !search_term.strip.empty?
            puts "Applying search filter: #{search_term}"
            tokens = search_term.downcase.split(/\s+/)

            results = results.select do |row|
                tokens.all? do |token|
                    fields.any? do |f|
                        value = row[f]&.to_s&.downcase
                        value && value.include?(token)
                    end
                end
            end
        end

        filtered_count = results.size

        if order_field && results.first&.key?(order_field)
            results = results.sort_by { |row| row[order_field].to_s.downcase rescue "" }
            results.reverse! if order_dir == "desc"
        end

        results = results.drop(start).first(length)

        {
            recordsTotal: data.size,
            recordsFiltered: filtered_count,
            data: results
        }
    end


    get '/*' do
        path = request.path
        if path == '/'
            path = '/index.html'
        end
        confirm_tag = nil
        confirm_message = nil
        if path[0, 3] == '/l/'
            STDERR.puts "Found login request"
            rest = path[3, path.size - 3].split('/')
            path = '/index.html'
            tag = rest[0]
            code = rest[1]
            begin
                STDERR.puts "Trying to log in with tag #{tag} and code #{code}"
                username = neo4j_query_expect_one(<<~END_OF_QUERY, {:tag => tag, :code => code})['username']
                    MATCH (r:LoginRequest {tag: $tag, code: $code})-[:FOR]->(u:User)
                    RETURN u.username AS username;
                END_OF_QUERY
                neo4j_query(<<~END_OF_QUERY, {:tag => tag, :code => code})
                    MATCH (r:LoginRequest {tag: $tag, code: $code})-[:FOR]->(u:User)
                    DETACH DELETE r;
                END_OF_QUERY
                sid = RandomTag::generate(24)
                STDERR.puts "Generated sid #{sid} for user #{username}"
                neo4j_query_expect_one(<<~END_OF_QUERY, {:sid => sid, :username => username, :expires => (DateTime.now() + 365).to_s})
                    MATCH (u:User {username: $username})
                    WITH u
                    CREATE (s:Session {sid: $sid, expires: $expires})-[:FOR]->(u)
                    RETURN s.sid AS sid;
                END_OF_QUERY
                STDERR.puts "Created session for user #{username}"
                # Automatically verify email since user proved access by entering the code
                result = neo4j_query(<<~END_OF_QUERY, {:username => username})
                    MATCH (u:User {username: $username})
                    WHERE COALESCE(u.email_verified, false) = false
                    SET u.email_verified = true
                    REMOVE u.email_verification_token
                    RETURN u.email AS email
                END_OF_QUERY
                unless result.empty?
                    log("E-Mail automatisch bestätigt für: #{result.first['email']} (Login)")
                end
                response.set_cookie('sid',
                    :value => sid,
                    :expires => Time.new + 3600 * 24 * 365,
                    :path => '/',
                    :httponly => true,
                    :secure => DEVELOPMENT ? false : true)
            # rescue StandardError => e
                # debug e
            end
            redirect "#{WEB_ROOT}/", 302
        end

        # Handle registration invitation links
        if path =~ /^\/register\/([A-Za-z0-9]+)$/
            invite_token = $1
            path = '/register.html'
            # Make invite token available to the page
            @invite_token = invite_token
        end

        # Handle email verification links
        if path =~ /^\/verify_email\/([A-Za-z0-9]+)$/
            verification_token = $1
            path = '/verify_email.html'
            @verification_token = verification_token
        end

        if path =~ /^\/user\/(.+)$/
            username = $1
            path = '/user.html'
            @username = username
        end

        if path =~ /^\/order_detail\/([A-Za-z0-9]+)$/
            order_id = $1
            path = '/order_detail.html'
            @order_id = order_id
        end

        if path =~ /^\/live_dashboard\/(.+)$/
            event_id = $1
            path = '/live_dashboard.html'
            @event_id = event_id
        end

        if path == '/site.webmanifest'
            # Serve the static webmanifest file instead of generating it dynamically
            respond_with_file(File.join('/src/static', 'site.webmanifest'))
            return
        end

        path = path + '.html' unless path.include?('.')
        respond_with_file(File.join('/src/static', path)) do |content, mime_type|
            if mime_type == 'text/html'
                template = File.read(File.join('/src/static', '_template.html'))
                template.sub!('#{CONTENT}', content)
                s = template
                while true
                    index = s.index('#{')
                    break if index.nil?
                    length = 2
                    balance = 1
                    while index + length < s.size && balance > 0
                        c = s[index + length]
                        balance -= 1 if c == '}'
                        balance += 1 if c == '{'
                        length += 1
                    end
                    code = s[index + 2, length - 3]
                    begin
                        s[index, length] = eval(code).to_s || ''
                    rescue
                        STDERR.puts "Error while evaluating:"
                        STDERR.puts code
                        raise
                    end
                end
                s
            end
        end
    end
end
