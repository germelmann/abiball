class Main < Sinatra::Base
    # Manual Email Templates
    # Each template has a key, default subject, default body with placeholders
    MANUAL_MAIL_TEMPLATES = {
        # Order-related templates (for order_detail.html)
        'order_accepted_cash' => {
            key: 'order_accepted_cash',
            subject: 'Bestellung angenommen - Barzahlung vor Ort',
            body: <<~BODY,
                <p>Hallo [NAME],</p>
                <p>deine Bestellung #[ORDER_ID] ([REFERENCE]) wurde angenommen.</p>
                <p>Du hast die Zahlungsoption <strong>Barzahlung vor Ort</strong> gewählt.</p>
                <p>Bitte bringe den Betrag von <strong>[TOTAL_PRICE] €</strong> zum Event mit.</p>
                <p>Bei Fragen stehen wir dir gerne zur Verfügung.</p>
            BODY
            category: 'order',
            label: 'Bestellung angenommen (Barzahlung)'
        },
        'payment_received' => {
            key: 'payment_received',
            subject: 'Zahlung eingegangen',
            body: <<~BODY,
                <p>Hallo [NAME],</p>
                <p>wir haben deine Zahlung für die Bestellung #[ORDER_ID] ([REFERENCE]) erhalten.</p>
                <p>Der Betrag von <strong>[TOTAL_PRICE] €</strong> wurde erfolgreich verbucht.</p>
                <p>Sobald deine Tickets freigeschaltet sind, kannst du sie unter [TICKET_LINK] herunterladen.</p>
                <p>Vielen Dank!</p>
            BODY
            category: 'order',
            label: 'Zahlung eingegangen'
        },
        'order_cancelled' => {
            key: 'order_cancelled',
            subject: 'Bestellung storniert',
            body: <<~BODY,
                <p>Hallo [NAME],</p>
                <p>deine Bestellung #[ORDER_ID] ([REFERENCE]) wurde storniert.</p>
                <p>Falls du Fragen dazu hast, kontaktiere uns bitte.</p>
            BODY
            category: 'order',
            label: 'Bestellung storniert'
        },
        'order_cancelled_user_request' => {
            key: 'order_cancelled_user_request',
            subject: 'Bestellung auf deinen Wunsch storniert',
            body: <<~BODY,
                <p>Hallo [NAME],</p>
                <p>wie von dir gewünscht, haben wir deine Bestellung #[ORDER_ID] ([REFERENCE]) storniert.</p>
                <p>Falls dies ein Versehen war oder du Fragen hast, kontaktiere uns bitte.</p>
            BODY
            category: 'order',
            label: 'Bestellung storniert (auf Wunsch)'
        },
        'order_reminder_1' => {
            key: 'order_reminder_1',
            subject: 'Erinnerung: Zahlung ausstehend',
            body: <<~BODY,
                <p>Hallo [NAME],</p>
                <p>wir möchten dich freundlich daran erinnern, dass die Zahlung für deine Bestellung #[ORDER_ID] ([REFERENCE]) noch aussteht.</p>
                <p>Offener Betrag: <strong>[TOTAL_PRICE] €</strong></p>
                <p>Bitte überweise den Betrag zeitnah, damit wir deine Bestellung abschließen können.</p>
            BODY
            category: 'order',
            label: 'Zahlungserinnerung 1'
        },
        'order_reminder_2' => {
            key: 'order_reminder_2',
            subject: 'Letzte Erinnerung: Zahlung ausstehend',
            body: <<~BODY,
                <p>Hallo [NAME],</p>
                <p>dies ist unsere letzte Erinnerung bezüglich der ausstehenden Zahlung für deine Bestellung #[ORDER_ID] ([REFERENCE]).</p>
                <p>Offener Betrag: <strong>[TOTAL_PRICE] €</strong></p>
                <p>Sollte die Zahlung nicht innerhalb von [X] Tagen eingehen, wird die Bestellung automatisch storniert.</p>
            BODY
            category: 'order',
            label: 'Zahlungserinnerung 2'
        },
        'order_adjusted' => {
            key: 'order_adjusted',
            subject: 'Bestellung angepasst',
            body: <<~BODY,
                <p>Hallo [NAME],</p>
                <p>deine Bestellung #[ORDER_ID] ([REFERENCE]) wurde angepasst.</p>
                <p>[REASON]</p>
                <p>Bei Fragen stehen wir dir gerne zur Verfügung.</p>
            BODY
            category: 'order',
            label: 'Bestellung angepasst'
        },
        'order_adjusted_user_request' => {
            key: 'order_adjusted_user_request',
            subject: 'Bestellung auf deinen Wunsch angepasst',
            body: <<~BODY,
                <p>Hallo [NAME],</p>
                <p>wie von dir gewünscht, haben wir deine Bestellung #[ORDER_ID] ([REFERENCE]) angepasst.</p>
                <p>[REASON]</p>
                <p>Falls du weitere Fragen hast, kontaktiere uns bitte.</p>
            BODY
            category: 'order',
            label: 'Bestellung angepasst (auf Wunsch)'
        },
        'order_issue' => {
            key: 'order_issue',
            subject: 'Problem mit deiner Bestellung - Bitte kontaktiere uns',
            body: <<~BODY,
                <p>Hallo [NAME],</p>
                <p>leider gibt es ein Problem mit deiner Bestellung #[ORDER_ID] ([REFERENCE]).</p>
                <p>[REASON]</p>
                <p>Bitte kontaktiere uns unter #{SUPPORT_EMAIL}, damit wir das Problem gemeinsam lösen können.</p>
            BODY
            category: 'order',
            label: 'Problem mit Bestellung'
        },

        # User-related templates (for user.html)
        'user_issue' => {
            key: 'user_issue',
            subject: 'Problem mit deinem Benutzerkonto - Bitte kontaktiere uns',
            body: <<~BODY,
                <p>Hallo [NAME],</p>
                <p>leider gibt es ein Problem mit deinem Benutzerkonto ([ID]).</p>
                <p>[REASON]</p>
                <p>Bitte kontaktiere uns unter #{SUPPORT_EMAIL}, damit wir das Problem gemeinsam lösen können.</p>
            BODY
            category: 'user',
            label: 'Problem mit Benutzerkonto'
        },
        'account_deletion_notice' => {
            key: 'account_deletion_notice',
            subject: 'Dein Konto wird in [X] Tagen gelöscht',
            body: <<~BODY,
                <p>Hallo [NAME],</p>
                <p>wir möchten dich darüber informieren, dass dein Konto in <strong>[X] Tagen</strong> gelöscht wird.</p>
                <p>Falls du dein Konto behalten möchtest, melde dich bitte bei uns unter #{SUPPORT_EMAIL}.</p>
            BODY
            category: 'user',
            label: 'Konto wird gelöscht in [X] Tagen'
        },
        'account_deleted' => {
            key: 'account_deleted',
            subject: 'Dein Konto wurde gelöscht',
            body: <<~BODY,
                <p>Hallo [NAME],</p>
                <p>dein Konto wurde gelöscht.</p>
                <p>Alle mit deinem Konto verbundenen Daten wurden entfernt.</p>
                <p>Falls dies ein Fehler war, kontaktiere uns bitte umgehend unter #{SUPPORT_EMAIL}.</p>
            BODY
            category: 'user',
            label: 'Konto gelöscht'
        },
        'address_viewed' => {
            key: 'address_viewed',
            subject: 'Deine Adresse wurde eingesehen',
            body: <<~BODY,
                <p>Hallo [NAME],</p>
                <p>wir möchten dich darüber informieren, dass deine Adresse durch ein Mitglied des Abikomitees eingesehen wurde.</p>
                <p>Grund: <strong>[REASON]</strong></p>
                <p>Falls du Fragen dazu hast, kontaktiere uns bitte.</p>
            BODY
            category: 'user',
            label: 'Adresse eingesehen'
        },
        'user_updated' => {
            key: 'user_updated',
            subject: 'Dein Benutzerkonto wurde aktualisiert',
            body: <<~BODY,
                <p>Hallo [NAME],</p>
                <p>dein Benutzerkonto wurde aktualisiert.</p>
                <p>[REASON]</p>
                <p>Falls du diese Änderung nicht angefordert hast, kontaktiere uns bitte umgehend.</p>
            BODY
            category: 'user',
            label: 'Benutzerkonto aktualisiert'
        },
        'user_updated_user_request' => {
            key: 'user_updated_user_request',
            subject: 'Dein Benutzerkonto wurde auf deinen Wunsch aktualisiert',
            body: <<~BODY,
                <p>Hallo [NAME],</p>
                <p>wie von dir gewünscht, haben wir dein Benutzerkonto aktualisiert.</p>
                <p>[REASON]</p>
                <p>Falls du Fragen hast, kontaktiere uns bitte.</p>
            BODY
            category: 'user',
            label: 'Benutzerkonto aktualisiert (auf Wunsch)'
        },
        'user_deleted_user_request' => {
            key: 'user_deleted_user_request',
            subject: 'Dein Benutzerkonto wurde auf deinen Wunsch gelöscht',
            body: <<~BODY,
                <p>Hallo [NAME],</p>
                <p>wie von dir gewünscht, haben wir dein Benutzerkonto gelöscht.</p>
                <p>Alle mit deinem Konto verbundenen Daten wurden entfernt.</p>
                <p>Wir bedanken uns für dein Vertrauen und wünschen dir alles Gute.</p>
            BODY
            category: 'user',
            label: 'Benutzerkonto gelöscht (auf Wunsch)'
        }
    }

    # Get template by key
    def get_manual_mail_template(template_key)
        MANUAL_MAIL_TEMPLATES[template_key]
    end

    # Get all templates for a category ('order' or 'user')
    def get_manual_mail_templates_by_category(category)
        MANUAL_MAIL_TEMPLATES.select { |key, template| template[:category] == category }
    end

    # Render template with placeholder replacements
    def render_manual_mail_template(template_key, replacements = {})
        template = get_manual_mail_template(template_key)
        return nil unless template

        subject = template[:subject].dup
        body = template[:body].dup

        # Apply replacements
        replacements.each do |placeholder, value|
            subject.gsub!("[#{placeholder}]", value.to_s)
            body.gsub!("[#{placeholder}]", value.to_s)
        end

        { subject: subject, body: body, key: template_key, label: template[:label] }
    end

    # Send manual email and log it
    def send_manual_mail(to_email:, subject:, body:, template_key:, sender_username:, recipient_username:, order_id: nil)
        # Format the email with the standard template
        formatted_body = format_email_with_template(subject, body)
        mail_subject = subject

        # Send the email
        deliver_mail do
            to to_email
            from SMTP_FROM
            subject mail_subject
            formatted_body
        end

        # Log the email to the database
        log_manual_mail(
            template_key: template_key,
            subject: subject,
            body: body,
            sender_username: sender_username,
            recipient_email: to_email,
            recipient_username: recipient_username,
            order_id: order_id
        )

        log("Manuelle E-Mail gesendet: Template '#{template_key}' an #{to_email}" + (order_id ? " (Bestellung: #{order_id})" : ""))
        
        true
    end

    # Log manual mail to database
    def log_manual_mail(template_key:, subject:, body:, sender_username:, recipient_email:, recipient_username:, order_id: nil)
        mail_log_id = RandomTag.generate(12)
        timestamp = Time.now.iso8601

        if order_id
            # Log with order relationship
            params = {
                id: mail_log_id,
                template_key: template_key,
                subject: subject,
                body: body,
                sender_username: sender_username,
                recipient_email: recipient_email,
                recipient_username: recipient_username,
                order_id: order_id,
                timestamp: timestamp
            }
            neo4j_query(<<~END_OF_QUERY, params)
                MATCH (u:User {username: $recipient_username})
                MATCH (o:TicketOrder {id: $order_id})
                CREATE (m:ManualMailLog {
                    id: $id,
                    template_key: $template_key,
                    subject: $subject,
                    body: $body,
                    sender_username: $sender_username,
                    recipient_email: $recipient_email,
                    timestamp: $timestamp
                })
                CREATE (m)-[:SENT_TO]->(u)
                CREATE (m)-[:FOR_ORDER]->(o)
            END_OF_QUERY
        else
            # Log without order relationship (user-only emails)
            params = {
                id: mail_log_id,
                template_key: template_key,
                subject: subject,
                body: body,
                sender_username: sender_username,
                recipient_email: recipient_email,
                recipient_username: recipient_username,
                timestamp: timestamp
            }
            neo4j_query(<<~END_OF_QUERY, params)
                MATCH (u:User {username: $recipient_username})
                CREATE (m:ManualMailLog {
                    id: $id,
                    template_key: $template_key,
                    subject: $subject,
                    body: $body,
                    sender_username: $sender_username,
                    recipient_email: $recipient_email,
                    timestamp: $timestamp
                })
                CREATE (m)-[:SENT_TO]->(u)
            END_OF_QUERY
        end

        mail_log_id
    end

    # Get mail logs for a user
    def get_manual_mail_logs_for_user(username)
        neo4j_query(<<~END_OF_QUERY, { username: username })
            MATCH (m:ManualMailLog)-[:SENT_TO]->(u:User {username: $username})
            OPTIONAL MATCH (m)-[:FOR_ORDER]->(o:TicketOrder)
            RETURN m.id AS id,
                   m.template_key AS template_key,
                   m.subject AS subject,
                   m.body AS body,
                   m.sender_username AS sender_username,
                   m.recipient_email AS recipient_email,
                   m.timestamp AS timestamp,
                   o.id AS order_id
            ORDER BY m.timestamp DESC
        END_OF_QUERY
    end

    # Get mail logs for an order
    def get_manual_mail_logs_for_order(order_id)
        neo4j_query(<<~END_OF_QUERY, { order_id: order_id })
            MATCH (m:ManualMailLog)-[:FOR_ORDER]->(o:TicketOrder {id: $order_id})
            MATCH (m)-[:SENT_TO]->(u:User)
            RETURN m.id AS id,
                   m.template_key AS template_key,
                   m.subject AS subject,
                   m.body AS body,
                   m.sender_username AS sender_username,
                   m.recipient_email AS recipient_email,
                   m.timestamp AS timestamp,
                   u.username AS recipient_username
            ORDER BY m.timestamp DESC
        END_OF_QUERY
    end

    # Get mail log entry by ID
    def get_manual_mail_log_by_id(log_id)
        neo4j_query(<<~END_OF_QUERY, { id: log_id }).first
            MATCH (m:ManualMailLog {id: $id})
            OPTIONAL MATCH (m)-[:SENT_TO]->(u:User)
            OPTIONAL MATCH (m)-[:FOR_ORDER]->(o:TicketOrder)
            RETURN m.id AS id,
                   m.template_key AS template_key,
                   m.subject AS subject,
                   m.body AS body,
                   m.sender_username AS sender_username,
                   m.recipient_email AS recipient_email,
                   m.timestamp AS timestamp,
                   u.username AS recipient_username,
                   o.id AS order_id
        END_OF_QUERY
    end

    # Get per-template counters for a user
    def get_manual_mail_counters_for_user(username)
        result = neo4j_query(<<~END_OF_QUERY, { username: username })
            MATCH (m:ManualMailLog)-[:SENT_TO]->(u:User {username: $username})
            RETURN m.template_key AS template_key, COUNT(m) AS count
        END_OF_QUERY
        
        counters = {}
        result.each do |row|
            counters[row['template_key']] = row['count']
        end
        counters
    end

    # Get per-template counters for an order
    def get_manual_mail_counters_for_order(order_id)
        result = neo4j_query(<<~END_OF_QUERY, { order_id: order_id })
            MATCH (m:ManualMailLog)-[:FOR_ORDER]->(o:TicketOrder {id: $order_id})
            RETURN m.template_key AS template_key, COUNT(m) AS count
        END_OF_QUERY
        
        counters = {}
        result.each do |row|
            counters[row['template_key']] = row['count']
        end
        counters
    end

    # API Endpoints

    # Get template draft with pre-filled placeholders
    post '/api/manual_mail/get_template' do
        require_user_with_permission!("manual_mail_send")
        data = parse_request_data(required_keys: [:template_key], optional_keys: [:username, :order_id])

        template_key = data[:template_key]
        username = data[:username]
        order_id = data[:order_id]

        template = get_manual_mail_template(template_key)
        unless template
            respond(success: false, error: "Template nicht gefunden")
            return
        end

        # Build replacements based on context
        replacements = {}

        if username
            user = neo4j_query(<<~END_OF_QUERY, { username: username }).first
                MATCH (u:User {username: $username})
                RETURN u.name AS name, u.email AS email, u.username AS username
            END_OF_QUERY
            
            if user
                replacements['NAME'] = user['name'] || 'Nutzer'
                replacements['EMAIL'] = user['email'] || 'N/A'
                replacements['ID'] = user['username'] || 'N/A'
            end
        end

        if order_id
            order = neo4j_query(<<~END_OF_QUERY, { order_id: order_id }).first
                MATCH (o:TicketOrder {id: $order_id})<-[:PLACED]-(u:User)
                RETURN o.id AS order_id, o.total_price AS total_price, u.name AS name, u.email AS email, u.username AS username, o.payment_reference AS payment_reference
            END_OF_QUERY

            if order
                replacements['ORDER_ID'] = order['order_id']
                replacements['TOTAL_PRICE'] = sprintf("%.2f", order['total_price'] || 0)
                replacements['NAME'] = order['name'] || 'Nutzer' unless replacements.key?('NAME')
                replacements['REFERENCE'] = order['payment_reference'] || 'N/A'
                replacements['ID'] = order['username'] || 'N/A'
                replacements['TICKET_LINK'] = "<a href=\"#{WEB_ROOT}/ticket_download\">#{WEB_ROOT}/ticket_download</a>"
            end
        end

        rendered = render_manual_mail_template(template_key, replacements)
        
        respond(
            success: true, 
            template: {
                key: template_key,
                subject: rendered[:subject],
                body: rendered[:body],
                label: rendered[:label],
                category: template[:category]
            }
        )
    end

    # Get all templates for a category
    post '/api/manual_mail/get_templates' do
        require_user_with_permission!("manual_mail_send")
        data = parse_request_data(required_keys: [:category])

        category = data[:category]
        templates = get_manual_mail_templates_by_category(category)

        template_list = templates.map do |key, template|
            {
                key: key,
                label: template[:label],
                subject: template[:subject]
            }
        end

        respond(success: true, templates: template_list)
    end

    # Send manual email
    post '/api/manual_mail/send' do
        require_user_with_permission!("manual_mail_send")
        data = parse_request_data(
            required_keys: [:template_key, :recipient_username, :subject, :body],
            optional_keys: [:order_id],
            max_body_length: 65536,
            max_string_length: 65536
        )

        template_key = data[:template_key]
        recipient_username = data[:recipient_username]
        subject = data[:subject]
        body = data[:body]
        order_id = data[:order_id]

        # Validate template exists
        template = get_manual_mail_template(template_key)
        unless template
            respond(success: false, error: "Template nicht gefunden")
            return
        end

        # Get recipient email
        recipient = neo4j_query(<<~END_OF_QUERY, { username: recipient_username }).first
            MATCH (u:User {username: $username})
            RETURN u.email AS email, u.name AS name
        END_OF_QUERY

        unless recipient
            respond(success: false, error: "Empfänger nicht gefunden")
            return
        end

        # If order_id is provided, validate it exists and belongs to the user
        if order_id
            order = neo4j_query(<<~END_OF_QUERY, { order_id: order_id, username: recipient_username }).first
                MATCH (o:TicketOrder {id: $order_id})<-[:PLACED]-(u:User {username: $username})
                RETURN o.id AS id
            END_OF_QUERY

            unless order
                respond(success: false, error: "Bestellung nicht gefunden oder gehört nicht zum angegebenen Benutzer")
                return
            end
        end

        begin
            send_manual_mail(
                to_email: recipient['email'],
                subject: subject,
                body: body,
                template_key: template_key,
                sender_username: @session_user[:username],
                recipient_username: recipient_username,
                order_id: order_id
            )

            respond(success: true, message: "E-Mail erfolgreich gesendet")
        rescue => e
            STDERR.puts "Error sending manual mail: #{e.message}"
            respond(success: false, error: "Fehler beim Senden der E-Mail: #{e.message}")
        end
    end

    # Get mail logs for a user
    post '/api/manual_mail/user_logs' do
        require_user_with_permission!("manual_mail_send")
        data = parse_request_data(required_keys: [:username])

        username = data[:username]
        logs = get_manual_mail_logs_for_user(username)

        log_list = logs.map do |log|
            {
                id: log['id'],
                template_key: log['template_key'],
                subject: log['subject'],
                sender_username: log['sender_username'],
                timestamp: log['timestamp'],
                order_id: log['order_id']
            }
        end

        respond(success: true, logs: log_list)
    end

    # Get mail logs for an order
    post '/api/manual_mail/order_logs' do
        require_user_with_permission!("manual_mail_send")
        data = parse_request_data(required_keys: [:order_id])

        order_id = data[:order_id]
        logs = get_manual_mail_logs_for_order(order_id)

        log_list = logs.map do |log|
            {
                id: log['id'],
                template_key: log['template_key'],
                subject: log['subject'],
                sender_username: log['sender_username'],
                timestamp: log['timestamp'],
                recipient_username: log['recipient_username']
            }
        end

        respond(success: true, logs: log_list)
    end

    # Get mail log details
    post '/api/manual_mail/log_details' do
        require_user_with_permission!("manual_mail_send")
        data = parse_request_data(required_keys: [:log_id])

        log_id = data[:log_id]
        log = get_manual_mail_log_by_id(log_id)

        unless log
            respond(success: false, error: "Log-Eintrag nicht gefunden")
            return
        end

        respond(success: true, log: {
            id: log['id'],
            template_key: log['template_key'],
            subject: log['subject'],
            body: log['body'],
            sender_username: log['sender_username'],
            recipient_email: log['recipient_email'],
            recipient_username: log['recipient_username'],
            timestamp: log['timestamp'],
            order_id: log['order_id']
        })
    end

    # Get counters for user
    post '/api/manual_mail/user_counters' do
        require_user_with_permission!("manual_mail_send")
        data = parse_request_data(required_keys: [:username])

        username = data[:username]
        counters = get_manual_mail_counters_for_user(username)

        respond(success: true, counters: counters)
    end

    # Get counters for order
    post '/api/manual_mail/order_counters' do
        require_user_with_permission!("manual_mail_send")
        data = parse_request_data(required_keys: [:order_id])

        order_id = data[:order_id]
        counters = get_manual_mail_counters_for_order(order_id)

        respond(success: true, counters: counters)
    end

    # Check if user has manual_mail_send permission (for frontend)
    def can_send_manual_mail?
        user_has_permission?("manual_mail_send")
    end

    # Print manual mail templates as JSON for frontend
    def print_manual_mail_templates_json
        MANUAL_MAIL_TEMPLATES.to_json
    end
end
