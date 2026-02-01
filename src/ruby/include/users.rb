class Main < Sinatra::Base

    PERMISSIONS = [
        { key: 'view_users', icon: 'bi-people', label: 'Benutzer ansehen', group: 'Benutzer verwalten', edit: false },
        { key: 'manage_users', icon: 'bi-people', label: 'Benutzer verwalten', group: 'Benutzer verwalten', edit: true },
        { key: 'edit_users', icon: 'bi-pencil-square', label: 'Benutzer bearbeiten', group: 'Benutzer verwalten', edit: true },
        { key: 'buy_tickets', icon: 'bi-ticket', label: 'Tickets kaufen', group: 'Tickets', edit: false },
        { key: 'manage_orders', icon: 'bi-cart', label: 'Bestellungen verwalten', group: 'Tickets', edit: true },
        { key: 'manual_mail_send', icon: 'bi-envelope', label: 'Manuelle E-Mails senden', group: 'Kommunikation', edit: false },
        { key: 'create_invites', icon: 'bi-person-plus', label: 'Einladungen erstellen', group: 'Benutzer verwalten', edit: false },
        { key: 'create_events', icon: 'bi-calendar-plus', label: 'Events erstellen', group: 'Events', edit: false },
        { key: 'view_logs', icon: 'bi-file-text', label: 'Logs ansehen', group: 'Admin', edit: false },
        { key: 'admin', icon: 'bi-gear', label: 'Admin', group: 'Admin', edit: nil }
    ];

    def print_permissions_table()
        PERMISSIONS.to_json
    end
    
    # Toggle a single permission for a user with authorization and audit logging
    post "/api/toggle_user_permission" do
        require_user_with_permission!("edit_users")
        data = parse_request_data(required_keys: [:target_username, :permission, :enabled])
        
        target_username = data[:target_username]
        permission = data[:permission]
        enabled = data[:enabled]
        current_username = @session_user[:username]
        is_admin = @session_user[:admin]
        
        # Validate permission key
        unless VALID_PERMISSION_KEYS.include?(permission)
            respond(success: false, error: "Ungültige Berechtigung: #{permission}")
            return
        end
        
        # Authorization checks:
        # 1. User cannot grant permissions to themselves unless they are admin
        if target_username == current_username && !is_admin
            respond(success: false, error: "Sie können sich selbst keine Berechtigungen erteilen")
            return
        end
        
        # 2. User can only grant permissions they possess (unless admin)
        unless is_admin
            current_user_perms = neo4j_query(<<~END_OF_QUERY, {username: current_username})
                MATCH (u:User {username: $username})-[:HAS_PERMISSION]->(p:Permission)
                RETURN COLLECT(p.name) AS permissions
            END_OF_QUERY
            
            user_permissions = current_user_perms.first&.dig('permissions') || []
            
            if enabled && !user_permissions.include?(permission)
                respond(success: false, error: "Sie können eine Berechtigung nicht erteilen, die Sie selbst nicht besitzen")
                return
            end
        end
        
        # Perform the atomic permission toggle
        if enabled
            # Grant permission
            neo4j_query(<<~END_OF_QUERY, {username: target_username, permission: permission})
                MERGE (p:Permission {name: $permission})
                WITH p
                MATCH (u:User {username: $username})
                MERGE (u)-[:HAS_PERMISSION]->(p)
            END_OF_QUERY
            
            action = "erteilt"
        else
            # Revoke permission
            neo4j_query(<<~END_OF_QUERY, {username: target_username, permission: permission})
                MATCH (u:User {username: $username})-[r:HAS_PERMISSION]->(p:Permission {name: $permission})
                DELETE r
            END_OF_QUERY
            
            action = "entzogen"
        end
        
        # Audit logging
        log("Berechtigungsänderung: '#{permission}' für #{target_username} wurde #{action}")
        
        respond(success: true, message: "Berechtigung erfolgreich aktualisiert")
    end
    
    # Get navbar menu items based on current user's permissions
    def print_navbar()
        StringIO.open do |io|
            io.puts '<ul class="navbar-nav">'
            
            # Public/User menu items (shown when logged in)
            if user_logged_in?
                io.puts '<li class="nav-item">'
                io.puts '    <a class="nav-link" href="/tickets">'
                io.puts '        <i class="bi bi-ticket"></i>&nbsp;Tickets bestellen'
                io.puts '    </a>'
                io.puts '</li>'
                
                io.puts '<li class="nav-item" id="ticket_download_nav">'
                io.puts '    <a class="nav-link" href="/ticket_download">'
                io.puts '        <i class="bi bi-download"></i>&nbsp;Meine Tickets'
                io.puts '    </a>'
                io.puts '</li>'
                
            end
            
            # Administration dropdown
            admin_items = []
            
            if user_has_permission?("view_users")
                admin_items << {label: 'Benutzer verwalten', icon: 'bi-people', url: '/users'}
            end
            
            if user_has_permission?("edit_users")
                admin_items << {label: 'Tags verwalten', icon: 'bi-tags', url: '/tags'}
            end
            
            if user_has_permission?("view_users")
                admin_items << {label: 'Ticket-Bestellungen', icon: 'bi-ticket-detailed', url: '/order_management'}
            end
            
            if user_has_permission?("manage_orders")
                admin_items << {label: 'Quick Payment', icon: 'bi-credit-card', url: '/quick_payment'}
            end
            
            if user_has_permission?("manage_orders")
                admin_items << {label: 'Ticket Scanner', icon: 'bi-qr-code-scan', url: '/ticket_scanner'}
            end
            
            if user_has_permission?("create_invites")
                admin_items << {label: 'Einladungslinks', icon: 'bi-person-plus', url: '/invitations'}
            end
            
            if user_has_permission?("create_events")
                admin_items << {label: 'Events verwalten', icon: 'bi-calendar-plus', url: '/events'}
            end
            
            if user_has_permission?("view_logs")
                admin_items << {label: 'Log', icon: 'bi-file-text', url: '/log'}
            end

            if user_has_permission?("admin")
                admin_items << {label: 'Administration', icon: 'bi-gear', url: '/admin'}
            end
            
            # Add dropdown if there are admin items
            if admin_items.length > 0
                io.puts '<li class="nav-item dropdown">'
                io.puts '    <a class="nav-link dropdown-toggle" href="#" role="button" data-bs-toggle="dropdown" aria-expanded="false">'
                io.puts '        <i class="bi bi-tools"></i>&nbsp;Administration'
                io.puts '    </a>'
                io.puts '    <ul class="dropdown-menu">'
                admin_items.each do |item|
                    io.puts '        <li>'
                    io.puts "            <a class=\"dropdown-item\" href=\"#{item[:url]}\">"
                    io.puts "                <i class=\"#{item[:icon]}\"></i>&nbsp;#{item[:label]}"
                    io.puts '            </a>'
                    io.puts '        </li>'
                end
                io.puts '    </ul>'
                io.puts '</li>'
            end
            
            # Profile and logout items
            if user_logged_in?
                io.puts '<li class="nav-item dropdown">'
                io.puts '    <a class="nav-link dropdown-toggle" href="#" role="button" data-bs-toggle="dropdown" aria-expanded="false">'
                io.puts "        <i class=\"bi bi-person-circle\"></i>&nbsp;#{@session_user[:name]}"
                io.puts '    </a>'
                io.puts '    <ul class="dropdown-menu">'
                io.puts '        <li>'
                io.puts "            <a class='dropdown-item' href='#{get_support_mailto("general")}'>"
                io.puts '                <i class="bi bi-headset"></i>&nbsp;Support kontaktieren'
                io.puts '            </a>'
                io.puts '        </li>'
                io.puts '        <li><hr class="dropdown-divider"></li>'
                io.puts '        <li>'
                io.puts '            <a class="dropdown-item" href="/profile">'
                io.puts '                <i class="bi bi-person"></i>&nbsp;Mein Profil'
                io.puts '            </a>'
                io.puts '        </li>'
                io.puts '        <li>'
                io.puts '            <a class="dropdown-item" href="/logout">'
                io.puts '                <i class="bi bi-box-arrow-right"></i>&nbsp;Abmelden'
                io.puts '            </a>'
                io.puts '        </li>'
                io.puts '    </ul>'
                io.puts '</li>'
            else
                io.puts '<li class="nav-item">'
                io.puts '    <a class="nav-link" href="/login">'
                io.puts '        <i class="bi bi-box-arrow-in-right"></i>&nbsp;Anmelden'
                io.puts '    </a>'
                io.puts '</li>'
            end
            
            io.puts '</ul>'
            io.string
        end
    end

    post "/api/get_user_permissions" do
        require_user_with_permission!("view_users")
        permissions = neo4j_query(<<~END_OF_QUERY)
            MATCH (u:User)
            OPTIONAL MATCH (u)-[:HAS_PERMISSION]->(p:Permission)
            OPTIONAL MATCH (u)-[:PLACED]->(o:TicketOrder)
            WITH u, 
                 COLLECT(DISTINCT p.name) AS permissions,
                 COUNT(DISTINCT o) AS order_count
            RETURN u.email AS email, 
                   u.name AS name, 
                   u.username AS username, 
                   u.admin AS admin,
                   u.phone AS phone,
                   COALESCE(u.email_verified, false) AS email_verified,
                   COALESCE(u.scanner_only, false) AS scanner_only,
                   permissions,
                   order_count
        END_OF_QUERY

        respond(success: true, permissions: permissions)
    end

    post "/api/delete_user" do
        require_user_with_permission!("manage_users")
        data = parse_request_data(required_keys: [:username])
        username = data[:username]
        # Delete the user and their permissions
        neo4j_query(<<~END_OF_QUERY, {username: username})
            MATCH (u:User {username: $username})
            OPTIONAL MATCH (u)-[r:HAS_PERMISSION]->(p:Permission)
            DETACH DELETE u
        END_OF_QUERY
        log("Benutzer #{username} gelöscht")
        respond(success: true)
    end

    post "/api/impersonate_user" do
        require_admin!
        data = parse_request_data(required_keys: [:username])
        target_username = data[:username]
        
        # Check if target user exists
        user_exists = neo4j_query(<<~END_OF_QUERY, {username: target_username})
            MATCH (u:User {username: $username})
            RETURN u.username AS username
        END_OF_QUERY
        
        if user_exists.empty?
            respond(success: false, error: "Benutzer nicht gefunden")
            return
        end
        
        # Create a new session for the target user
        sid = RandomTag.generate(24)
        neo4j_query(<<~END_OF_QUERY, {sid: sid, username: target_username, expires: (DateTime.now + 365).to_s})
            MATCH (u:User {username: $username})
            WITH u
            CREATE (s:Session {sid: $sid, expires: $expires})-[:FOR]->(u)
            RETURN s.sid AS sid
        END_OF_QUERY
        
        # Set the session cookie
        response.set_cookie('sid',
            :value => sid,
            :expires => Time.new + 3600 * 24 * 365,
            :path => '/',
            :httponly => true,
            :secure => DEVELOPMENT ? false : true)
        
        log("Als #{target_username} angemeldet")
        respond(success: true)
    end

    # Get current user's profile data
    post "/api/get_profile_data" do
        require_user!
        user_email = @session_user[:email]
        
        profile = neo4j_query(<<~END_OF_QUERY, {email: user_email})
            MATCH (u:User {email: $email})
            OPTIONAL MATCH (u)-[:HAS_TAG]->(t:Tag)
            RETURN u.email AS email, 
                   u.name AS name, 
                   u.username AS username, 
                   u.address AS address,
                   u.phone AS phone,
                   COALESCE(u.email_verified, false) AS email_verified,
                   COALESCE(u.scanner_only, false) AS scanner_only,
                   COLLECT({name: t.name, color: t.color}) AS tags
        END_OF_QUERY
        
        if profile.empty?
            respond(success: false, error: "Benutzerdaten nicht gefunden")
        else
            respond(success: true, profile: profile.first)
        end
    end

    VALID_PERMISSION_KEYS = PERMISSIONS.map { |p| p[:key] }

    # Hilfsfunktion für Abhängigkeiten
    def normalize_permissions(perms)
        perms = perms & VALID_PERMISSION_KEYS # nur bekannte behalten

        # falls edit gesetzt ist, aber view fehlt, automatisch ergänzen
        PERMISSIONS.each do |p|
            next unless p[:edit] == true
            view_perm = PERMISSIONS.find { |vp| vp[:group] == p[:group] && vp[:edit] == false }
            if perms.include?(p[:key]) && view_perm && !perms.include?(view_perm[:key])
                perms << view_perm[:key]
            end
        end

        perms.uniq
    end

    def user_has_permission?(permission)
        return unless @session_user
        
        username = @session_user[:username]

        has_permission = neo4j_query(<<~END_OF_QUERY, {username: username, permission: permission})
            MATCH (u:User {username: $username})-[:HAS_PERMISSION]->(p:Permission {name: $permission})
            RETURN COUNT(p) > 0 AS has_permission
        END_OF_QUERY
        .first["has_permission"]
        return user_logged_in? && (@session_user[:admin] || has_permission)
    end

    def require_user_with_permission!(permission)
        assert(user_has_permission?(permission))
    end

    def site_for_user_with_permission!(permission)
        unless user_has_permission?(permission)
            redirect "#{WEB_ROOT}/no_permission"
            log("Zugriffsversuch auf #{permission} fehlgeschlagen.")
        end
    end

    def site_for_users!
        unless user_logged_in?
            redirect "#{WEB_ROOT}/no_permission"
            log("Zugriffsversuch auf geschützte Seite fehlgeschlagen.")
        end
    end
    
    def user_is_scanner_only?
        return false unless @session_user
        
        username = @session_user[:username]
        result = neo4j_query(<<~END_OF_QUERY, {username: username})
            MATCH (u:User {username: $username})
            RETURN COALESCE(u.scanner_only, false) AS scanner_only
        END_OF_QUERY
        
        return false if result.empty?
        result.first['scanner_only']
    end
    
    def site_for_scanner_or_permission!(permission)
        # Allow access if user is scanner-only OR has the required permission
        unless user_logged_in? && (user_is_scanner_only? || user_has_permission?(permission))
            redirect "#{WEB_ROOT}/no_permission"
            log("Zugriffsversuch auf #{permission} fehlgeschlagen.")
        end
    end
    
    def redirect_scanner_only_users!
        if user_is_scanner_only? && request.path_info != "#{WEB_ROOT}/ticket_scanner" && request.path_info != "/ticket_scanner"
            redirect "#{WEB_ROOT}/ticket_scanner"
        end
    end

    # Invitation system endpoints
    post "/api/create_invite" do
        require_user_with_permission!("create_invites")
        data = parse_request_data(optional_keys: [:expires_hours, :max_uses, :custom_name, :permissions, :tags], types: {expires_hours: Integer, max_uses: Integer})
        
        expires_hours = data[:expires_hours] # If nil, invitation is unlimited
        max_uses = data[:max_uses] # If nil, unlimited uses
        custom_name = data[:custom_name] || "Einladung"
        permissions = data[:permissions] || []
        tags = data[:tags] || []
        
        # Validate permissions: user can only grant permissions they have (unless admin)
        if permissions.any?
            unless @session_user[:admin]
                current_user_perms = neo4j_query(<<~END_OF_QUERY, {username: @session_user[:username]})
                    MATCH (u:User {username: $username})-[:HAS_PERMISSION]->(p:Permission)
                    RETURN COLLECT(p.name) AS permissions
                END_OF_QUERY
                
                user_permissions = current_user_perms.first&.dig('permissions') || []
                
                invalid_perms = permissions - user_permissions
                if invalid_perms.any?
                    respond(success: false, error: "Sie können folgende Berechtigungen nicht erteilen: #{invalid_perms.join(', ')}")
                    return
                end
            end
            
            # Validate all permissions are valid
            invalid_perms = permissions - VALID_PERMISSION_KEYS
            if invalid_perms.any?
                respond(success: false, error: "Ungültige Berechtigungen: #{invalid_perms.join(', ')}")
                return
            end
        end
        
        invite_token = RandomTag::generate(32)
        expires_at = expires_hours ? (DateTime.now + Rational(expires_hours, 24)).to_s : nil
        
        invite_params = {
            token: invite_token,
            created_by: @session_user[:username],
            expires_at: expires_at,
            max_uses: max_uses,
            custom_name: custom_name,
            uses_count: 0,
            created_at: DateTime.now.to_s,
            permissions: permissions.to_json,
            tags: tags.to_json
        }
        
        neo4j_query(<<~END_OF_QUERY, invite_params)
            CREATE (i:Invitation {
                token: $token,
                created_by: $created_by,
                expires_at: $expires_at,
                max_uses: $max_uses,
                custom_name: $custom_name,
                uses_count: $uses_count,
                created_at: $created_at,
                used: false,
                revoked: false,
                active: true,
                permissions: $permissions,
                tags: $tags
            })
        END_OF_QUERY
        
        invite_url = "#{WEB_ROOT}/register/#{invite_token}"
        respond(success: true, invite_url: invite_url, expires_at: expires_at, max_uses: max_uses, custom_name: custom_name, permissions: permissions, tags: tags)
        log("Einladungslink '#{custom_name}' erstellt: #{invite_url}")
    end

    # Validate registration token
    post "/api/validate_invite/:token" do |token|
        invitation = neo4j_query(<<~END_OF_QUERY, {token: token})
            MATCH (i:Invitation {token: $token})
            WHERE i.revoked = false 
              AND (i.expires_at IS NULL OR datetime(i.expires_at) > datetime())
              AND (i.max_uses IS NULL OR i.uses_count < i.max_uses)
            RETURN i.created_by AS created_by, 
                   i.expires_at AS expires_at, 
                   i.custom_name AS custom_name,
                   i.max_uses AS max_uses,
                   i.uses_count AS uses_count,
                   i.active AS active
        END_OF_QUERY
        
        if invitation.empty?
            respond(success: true, valid: false, error: "Einladungslink ist ungültig, abgelaufen oder widerrufen")
        else
            invitation_data = invitation.first
            if !invitation_data['active']
                respond(success: true, valid: false, error: "Einladungslink wurde deaktiviert")
            else
                respond(success: true,
                        valid: true,
                        expires_at: invitation_data['expires_at'],
                        custom_name: invitation_data['custom_name'])
            end
        end
    end

    post "/api/register" do
        data = parse_request_data(required_keys: [:invite_token, :name, :username, :email, :address], optional_keys: [:phone])
        
        invite_token = data[:invite_token]
        name = data[:name]
        username = validate_username(data[:username])
        email = data[:email].downcase
        address = data[:address]
        phone = data[:phone] || ''
        
        # Validate required fields (phone is now optional)
        if name.strip.empty? || address.strip.empty?
            respond(success: false, error: "Name und Adresse sind Pflichtfelder")
            return
        end
        
        # Validate username format
        if username.nil?
            respond(success: false, error: "Nutzer-ID ist ungültig. Nur Kleinbuchstaben, Zahlen, Bindestriche und Unterstriche sind erlaubt.")
            return
        end
        
        # Validate invitation
        invitation = neo4j_query(<<~END_OF_QUERY, {token: invite_token})
            MATCH (i:Invitation {token: $token})
            WHERE i.revoked = false 
              AND i.active = true
              AND (i.expires_at IS NULL OR datetime(i.expires_at) > datetime())
              AND (i.max_uses IS NULL OR i.uses_count < i.max_uses)
            RETURN i, i.permissions AS permissions, i.tags AS tags
        END_OF_QUERY
        
        if invitation.empty?
            respond(success: false, error: "Einladungslink ist ungültig, abgelaufen, widerrufen oder deaktiviert")
            return
        end
        
        invitation_data = invitation.first
        invite_permissions = []
        if invitation_data['permissions']
            begin
                invite_permissions = JSON.parse(invitation_data['permissions'])
            rescue
                invite_permissions = []
            end
        end
        
        invite_tags = []
        if invitation_data['tags']
            begin
                invite_tags = JSON.parse(invitation_data['tags'])
            rescue
                invite_tags = []
            end
        end
        
        # Check if username or email already exists
        existing_user = neo4j_query(<<~END_OF_QUERY, {username: username, email: email})
            MATCH (u:User)
            WHERE u.username = $username OR u.email = $email
            RETURN u.username AS username, u.email AS email
        END_OF_QUERY
        
        unless existing_user.empty?
            existing = existing_user.first
            if existing['username'] == username
                respond(success: false, error: "Nutzer-ID bereits vergeben")
            else
                respond(success: false, error: "E-Mail-Adresse bereits registriert")
            end
            return
        end
        
        # Create new user
        user_params = {
            username: username,
            email: email,
            name: name,
            address: address,
            phone: phone,
            created_at: DateTime.now.to_s
        }
        
        # Generate email verification token
        email_verification_token = RandomTag::generate(32)
        user_params[:email_verification_token] = email_verification_token
        
        neo4j_query(<<~END_OF_QUERY, user_params)
            CREATE (u:User {
                username: $username,
                email: $email,
                name: $name,
                address: $address,
                phone: $phone,
                admin: false,
                email_verified: false,
                email_verification_token: $email_verification_token,
                created_at: $created_at
            })
        END_OF_QUERY
        
        # Give buy_tickets permission by default
        neo4j_query(<<~END_OF_QUERY, {email: email})
            MERGE (p:Permission {name: 'buy_tickets'})
            WITH p
            MATCH (u:User {email: $email})
            MERGE (u)-[:HAS_PERMISSION]->(p)
        END_OF_QUERY
        
        # Apply permissions from invitation
        invite_permissions.each do |permission|
            next unless VALID_PERMISSION_KEYS.include?(permission)
            neo4j_query(<<~END_OF_QUERY, {email: email, permission: permission})
                MERGE (p:Permission {name: $permission})
                WITH p
                MATCH (u:User {email: $email})
                MERGE (u)-[:HAS_PERMISSION]->(p)
            END_OF_QUERY
        end
        
        # Apply tags from invitation
        invite_tags.each do |tag|
            next if tag.strip.empty?
            neo4j_query(<<~END_OF_QUERY, {email: email, tag: tag})
                MERGE (t:Tag {name: $tag})
                WITH t
                MATCH (u:User {email: $email})
                MERGE (u)-[:HAS_TAG]->(t)
            END_OF_QUERY
        end
        
        # Increment invitation uses count
        neo4j_query(<<~END_OF_QUERY, {token: invite_token, used_at: DateTime.now.to_s})
            MATCH (i:Invitation {token: $token})
            SET i.uses_count = i.uses_count + 1, i.last_used_at = $used_at
        END_OF_QUERY
        
        # Send email verification email
        verification_url = "#{WEB_ROOT}/verify_email/#{email_verification_token}"
        deliver_mail do
            to email
            from SMTP_FROM
            subject "Bitte bestätige deine E-Mail-Adresse für #{EVENT_NAME}"
            
            content = StringIO.open do |io|
                io.puts "<p>Hallo #{name}!</p>"
                io.puts "<p>Willkommen beim #{EVENT_NAME}!</p>"
                io.puts "<p>Bitte klicke auf den folgenden Link, um deine E-Mail-Adresse zu bestätigen:</p>"
                io.puts "<p><a href='#{verification_url}' class='btn'>E-Mail-Adresse bestätigen</a></p>"
                io.puts "<p>Ohne E-Mail-Bestätigung kannst du keine Tickets kaufen.</p>"
                io.puts "<p>Falls du diese E-Mail nicht angefordert hast, kannst du sie ignorieren.</p>"
                io.string
            end
            
            format_email_with_template("E-Mail-Bestätigung", content)
        end
        
        respond(success: true, message: "Registrierung erfolgreich! Bitte bestätige deine E-Mail-Adresse.")
        log("Neuer Benutzer registriert: #{username} (#{email}) via Einladung #{invite_token}")
    end

    # Email verification endpoint
    post "/api/verify_email" do
        data = parse_request_data(required_keys: [:token])
        token = data[:token]
        
        # Find user with this verification token
        user = neo4j_query(<<~END_OF_QUERY, {token: token})
            MATCH (u:User {email_verification_token: $token})
            WHERE u.email_verified = false
            RETURN u.email AS email, u.name AS name
        END_OF_QUERY
        
        if user.empty?
            respond(success: false, error: "Ungültiger Verifizierungstoken")
            return
        end
        
        user_data = user.first
        
        # Mark user as verified
        neo4j_query(<<~END_OF_QUERY, {token: token})
            MATCH (u:User {email_verification_token: $token})
            SET u.email_verified = true
            REMOVE u.email_verification_token
        END_OF_QUERY
        
        respond(success: true, message: "E-Mail-Adresse erfolgreich bestätigt!")
        log("E-Mail bestätigt für: #{user_data['email']}")
    end

    # Admin: Manually verify user email
    post "/api/admin_verify_email" do
        require_user_with_permission!("manage_users")
        data = parse_request_data(required_keys: [:email])
        
        target_email = data[:email].downcase
        
        # Check if user exists
        user_data = neo4j_query(<<~END_OF_QUERY, {email: target_email})
            MATCH (u:User {email: $email})
            RETURN u.email AS email, u.name AS name, u.email_verified AS verified
        END_OF_QUERY
        
        if user_data.empty?
            respond(success: false, error: "Benutzer nicht gefunden")
            return
        end
        
        user_info = user_data.first
        if user_info['verified']
            respond(success: false, error: "E-Mail-Adresse ist bereits bestätigt")
            return
        end
        
        # Mark user as verified and remove verification token
        neo4j_query(<<~END_OF_QUERY, {email: target_email})
            MATCH (u:User {email: $email})
            SET u.email_verified = true
            REMOVE u.email_verification_token
        END_OF_QUERY
        
        respond(success: true, message: "E-Mail-Adresse wurde erfolgreich als bestätigt markiert!")
        log("E-Mail-Adresse manuell bestätigt für: #{target_email}")
    end

    # Get all invitations (admin function)
    post "/api/get_invitations" do
        require_user_with_permission!("create_invites")
        
        invitations = neo4j_query(<<~END_OF_QUERY)
            MATCH (i:Invitation)
            RETURN i.token AS token,
                   i.created_by AS created_by,
                   i.expires_at AS expires_at,
                   i.max_uses AS max_uses,
                   i.custom_name AS custom_name,
                   i.uses_count AS uses_count,
                   i.created_at AS created_at,
                   i.last_used_at AS last_used_at,
                   i.revoked AS revoked,
                   COALESCE(i.active, true) AS active
            ORDER BY i.created_at DESC
        END_OF_QUERY
        
        respond(success: true, invitations: invitations)
    end

    # Revoke invitation
    post "/api/revoke_invitation" do
        require_user_with_permission!("create_invites")
        data = parse_request_data(required_keys: [:token])
        
        neo4j_query(<<~END_OF_QUERY, {token: data[:token]})
            MATCH (i:Invitation {token: $token})
            SET i.revoked = true
        END_OF_QUERY
        
        log("Einladungslink widerrufen: #{data[:token]}")
        respond(success: true)
    end

    # Toggle invitation activation
    post "/api/toggle_invitation_active" do
        require_user_with_permission!("create_invites")
        data = parse_request_data(required_keys: [:token, :active])
        
        active = data[:active]
        
        neo4j_query(<<~END_OF_QUERY, {token: data[:token], active: active})
            MATCH (i:Invitation {token: $token})
            SET i.active = $active
        END_OF_QUERY
        
        action = active ? "aktiviert" : "deaktiviert"
        log("Einladungslink #{action}: #{data[:token]}")
        respond(success: true)
    end
    
    # Get user address with access logging (admin/support only)
    post "/api/get_user_address" do
        require_user_with_permission!("view_users")
        data = parse_request_data(required_keys: [:username])
        
        target_username = data[:username]
        viewer_username = @session_user[:username]
        
        # Get user's address
        user_data = neo4j_query(<<~END_OF_QUERY, {username: target_username})
            MATCH (u:User {username: $username})
            RETURN u.email AS email, u.name AS name, u.address AS address
        END_OF_QUERY
        
        if user_data.empty?
            respond(success: false, error: "Benutzer nicht gefunden")
            return
        end
        
        user_info = user_data.first
        
        # Log the address access
        log_id = RandomTag.generate(16)
        params = {
            log_id: log_id,
            viewer_username: viewer_username,
            target_username: target_username,
            event_context: "N/A",
            timestamp: DateTime.now.to_s
        }
        neo4j_query(<<~END_OF_QUERY, params)
            MATCH (viewer:User {username: $viewer_username})
            MATCH (target:User {username: $target_username})
            CREATE (log:AddressAccessLog {
                id: $log_id,
                event_context: $event_context,
                timestamp: $timestamp
            })
            CREATE (viewer)-[:ACCESSED_ADDRESS]->(log)
            CREATE (log)-[:ADDRESS_OF]->(target)
        END_OF_QUERY
        
        log("Adresse von #{target_username} abgerufen")
        
        respond(success: true, address: user_info['address'], name: user_info['name'])
    end

    # Get comprehensive user details for user.html page
    post "/api/get_user_details" do
        require_user_with_permission!("view_users")
        data = parse_request_data(required_keys: [:username])
        username = data[:username]
        
        # Get user basic info, settings, permissions, and tags
        user_data = neo4j_query(<<~END_OF_QUERY, {username: username})
            MATCH (u:User {username: $username})
            OPTIONAL MATCH (u)-[:HAS_PERMISSION]->(p:Permission)
            WITH u, COLLECT(DISTINCT p.name) AS permissions
            OPTIONAL MATCH (u)-[:HAS_TAG]->(t:Tag)
            RETURN u.email AS email,
                   u.name AS name,
                   u.username AS username,
                   u.phone AS phone,
                   COALESCE(u.email_verified, false) AS email_verified,
                   COALESCE(u.scanner_only, false) AS scanner_only,
                   COALESCE(u.admin, false) AS admin,
                   permissions,
                   COLLECT(DISTINCT {name: t.name, color: t.color}) AS tags
        END_OF_QUERY
        
        if user_data.empty?
            respond(success: false, error: "Benutzer nicht gefunden")
            return
        end
        
        user_info = user_data.first
        
        respond(success: true, user: user_info)
    end

    # Get user order history for user.html page
    post "/api/get_user_orders" do
        require_user_with_permission!("view_users")
        data = parse_request_data(required_keys: [:username])
        username = data[:username]
        
        # Get user email first
        user_email_result = neo4j_query(<<~END_OF_QUERY, {username: username})
            MATCH (u:User {username: $username})
            RETURN u.email AS email
        END_OF_QUERY
        
        if user_email_result.empty?
            respond(success: false, error: "Benutzer nicht gefunden")
            return
        end
        
        user_email = user_email_result.first['email']
        
        # Get user's orders
        orders = neo4j_query(<<~END_OF_QUERY, {email: user_email})
            MATCH (u:User {email: $email})-[:PLACED]->(o:TicketOrder)
            OPTIONAL MATCH (o)-[:FOR]->(e:Event)
            RETURN o.id AS order_id,
                   o.ticket_count AS ticket_count,
                   o.total_price AS total_price,
                   o.individual_ticket_price AS individual_ticket_price,
                   o.status AS status,
                   o.created_at AS created_at,
                   COALESCE(e.name, 'N/A') AS event_name,
                   COALESCE(e.id, '') AS event_id
            ORDER BY o.created_at DESC
        END_OF_QUERY
        
        respond(success: true, orders: orders)
    end

    # Edit/Create user endpoint
    # NOTE: Permissions are managed separately via /api/toggle_user_permission
    post "/api/edit_user" do
        require_user_with_permission!("edit_users")
        data = parse_request_data(required_keys: [:name, :email, :username], optional_keys: [:address, :phone, :scanner_only])
        
        username = data[:username]
        name = data[:name]
        email = data[:email].downcase
        address = data[:address] || ""
        phone = data[:phone] || ""
        scanner_only = data[:scanner_only] == 1 ? true : false
        
        # Validate username format
        if username.nil?
            respond(success: false, error: "Nutzer-ID ist ungültig. Nur Kleinbuchstaben, Zahlen, Bindestriche und Unterstriche sind erlaubt.")
            return
        end
        
        # Check if user exists
        existing_user = neo4j_query(<<~END_OF_QUERY, {username: username})
            MATCH (u:User {username: $username})
            RETURN u.username AS username
        END_OF_QUERY
        
        if existing_user.empty?
            # Create new user (without permissions - they're managed separately)
            neo4j_query(<<~END_OF_QUERY, {username: username, name: name, email: email, address: address, phone: phone, scanner_only: scanner_only})
                CREATE (u:User {
                    username: $username,
                    name: $name,
                    email: $email,
                    address: $address,
                    phone: $phone,
                    scanner_only: $scanner_only,
                    email_verified: false,
                    admin: false
                })
            END_OF_QUERY
            log("Benutzer #{username} erstellt")
        else
            # Update existing user (permissions are NOT modified here)
            neo4j_query(<<~END_OF_QUERY, {username: username, name: name, email: email, address: address, phone: phone, scanner_only: scanner_only})
                MATCH (u:User {username: $username})
                SET u.name = $name,
                    u.email = $email,
                    u.address = $address,
                    u.phone = $phone,
                    u.scanner_only = $scanner_only
            END_OF_QUERY
            log("Benutzer #{username} aktualisiert")
        end
        
        respond(success: true, message: "Benutzer erfolgreich gespeichert")
    end
end
