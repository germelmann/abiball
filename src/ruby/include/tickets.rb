class Main < Sinatra::Base
    require 'prawn'
    require 'prawn/table'
    require 'prawn/qrcode'
    require 'securerandom'
    require 'base64'
    
    # Order status translations
    def self.order_status_translations
        {
            'paid' => 'Bezahlt',
            'pending' => 'Ausstehend',
            'pending_payment' => 'Zahlung ausstehend',
            'cancelled' => 'Storniert',
            'cancelled_by_user' => 'Storniert durch Käufer'
        }
    end
    
    def self.get_order_status_text(status)
        order_status_translations[status] || status
    end
    
    # Payment request status translations
    def self.payment_request_status_translations
        {
            'not_sent' => 'Nicht gesendet',
            'sent' => 'Gesendet',
            'paid' => 'Bezahlt'
        }
    end
    
    def self.get_payment_request_status_text(status)
        payment_request_status_translations[status] || status
    end
    
    # Generate unique bank transfer reference
    def generate_payment_reference(user_id, order_count)
        "#{user_id}#{order_count.to_s.rjust(3, '0')}".upcase
    end
    
    # Generate EPC QR code data for SEPA payments
    # This format is compatible with most European banking apps
    def generate_epc_qr_data(account_name, iban, bic, amount, reference, recipient_info = '')
        # EPC QR Code Format (Version 002)
        # Reference: https://www.europeanpaymentscouncil.eu/document-library/guidance-documents/quick-response-code-guidelines-enable-data-capture-initiation
        data = [
            'BCD',                          # Service Tag
            '002',                          # Version
            '1',                            # Character Set (1 = UTF-8)
            'SCT',                          # Identification (SEPA Credit Transfer)
            bic || '',                      # BIC (optional for SEPA in some countries)
            account_name,                   # Beneficiary Name (max 70 chars)
            iban.gsub(/\s+/, ''),          # Beneficiary Account (IBAN without spaces)
            "EUR#{sprintf('%.2f', amount)}", # Amount (EUR with 2 decimals)
            '',                             # Purpose (optional)
            reference || '',                # Remittance Information (max 140 chars)
            recipient_info || ''            # Beneficiary to Originator Information (optional)
        ].join("\n")
        
        data
    end
    
    # Select bank account based on percentage distribution
    def select_bank_account(event_id)
        accounts = neo4j_query(<<~END_OF_QUERY, {event_id: event_id})
            MATCH (e:Event {id: $event_id})-[:HAS_BANK_ACCOUNT]->(b:BankAccount)
            RETURN b.id AS id, b.account_name AS account_name, b.bank_name AS bank_name,
                   b.iban AS iban, b.bic AS bic, b.percentage AS percentage
            ORDER BY b.percentage DESC
        END_OF_QUERY
        
        return nil if accounts.empty?
        
        # Generate a random number between 0 and 100
        random_value = rand(100.0)
        
        # Select account based on cumulative percentage
        cumulative = 0.0
        accounts.each do |account|
            cumulative += account['percentage'].to_f
            if random_value < cumulative
                return account['id']
            end
        end
        
        # Fallback to first account (should not happen if percentages sum to 100)
        accounts.first['id']
    end

    # Get or create ticket order for user
    post "/api/create_ticket_order" do
        require_user_with_permission!("buy_tickets")
        data = parse_request_data(required_keys: [:ticket_count, :participants, :event_id],
                                  optional_keys: [:tier_id],
                                  types: {ticket_count: Integer, participants: Array})
        
        user_email = @session_user[:email]
        ticket_count = data[:ticket_count]
        participants = data[:participants]
        event_id = data[:event_id]
        tier_id = data[:tier_id]
        
        # Verify event exists and is accessible
        event = neo4j_query(<<~END_OF_QUERY, {event_id: event_id}).map { |e| e['e'] }
            MATCH (e:Event {id: $event_id})
            WHERE e.active = true
            RETURN e
        END_OF_QUERY

        event = event.first

        puts event
        
        if event.empty?
            respond(success: false, error: "Event nicht gefunden.")
            return
        end
        
        # Check if ticket generation is enabled for this event
        unless event[:ticket_generation_enabled]
            respond(success: false, error: "Ticket-Verkauf für dieses Event ist derzeit deaktiviert.")
            return
        end
        
        # Check if ticket sales are within the allowed time window
        current_time = Time.now
        if event[:ticket_sale_start_datetime] && !event[:ticket_sale_start_datetime].empty?
            sale_start_time = Time.parse(event[:ticket_sale_start_datetime])
            if current_time < sale_start_time
                respond(success: false, error: "Ticket-Verkauf hat noch nicht begonnen. Verkaufsstart: #{sale_start_time.strftime('%d.%m.%Y um %H:%M Uhr')}")
                return
            end
        end

        if event[:ticket_sale_end_datetime] && !event[:ticket_sale_end_datetime].empty?
            sale_end_time = Time.parse(event[:ticket_sale_end_datetime])
            if current_time > sale_end_time
                respond(success: false, error: "Ticket-Verkauf ist bereits beendet. Verkaufsende war: #{sale_end_time.strftime('%d.%m.%Y um %H:%M Uhr')}")
                return
            end
        end
        
        # Check if user can access this event
        if event[:visibility] == 'private'
            # Only event creators and admins can access private events
            unless user_has_permission?("create_events") || user_has_permission?("admin")
                respond(success: false, error: "Zugriff verweigert.")
                return
            end
        elsif event[:visibility] == 'password_protected'
            # Check if user has provided the correct password (this should be verified earlier)
            unless session["event_access_#{event_id}"]
                respond(success: false, error: "Event-Passwort erforderlich.")
                return
            end
        end
        
        # Check if email is verified
        email_verified_result = neo4j_query(<<~END_OF_QUERY, {email: user_email})
            MATCH (u:User {email: $email})
            RETURN COALESCE(u.email_verified, false) AS verified
        END_OF_QUERY
        email_verified = email_verified_result.first&.dig('verified') || false
        
        unless email_verified
            respond(success: false, error: "Du musst deine E-Mail-Adresse bestätigen, bevor du Tickets kaufen kannst.")
            return
        end
        
        # Validate ticket count against event-specific limit (include reserved/pending tickets)
        event_sold_result = neo4j_query(<<~END_OF_QUERY, {event_id: event_id})
            MATCH (e:Event {id: $event_id})<-[:FOR]-(o:TicketOrder)
            WHERE o.status = 'paid' OR o.status = 'pending'
            RETURN SUM(o.ticket_count) AS total
        END_OF_QUERY
        event_sold = event_sold_result.first&.dig('total') || 0

        if event_sold + ticket_count > event[:max_tickets]
            respond(success: false, error: "Nicht genügend Tickets für dieses Event verfügbar.")
            return
        end
        
        # Check user's current orders for this event
        existing_orders = neo4j_query(<<~END_OF_QUERY, {email: user_email, event_id: event_id})
            MATCH (u:User {email: $email})-[:PLACED]->(o:TicketOrder)-[:FOR]->(e:Event {id: $event_id})
            RETURN o.id AS id, o.ticket_count AS ticket_count, o.status AS status
        END_OF_QUERY
        
        # Get user's ticket limit (check event-specific first, then event default, then global default)
        user_limit_result = neo4j_query(<<~END_OF_QUERY, {email: user_email, event_id: event_id, default_limit: TICKETS_PER_USER})
            MATCH (u:User {email: $email})
            MATCH (e:Event {id: $event_id})
            OPTIONAL MATCH (u)-[r:HAS_EVENT_LIMIT]->(e)
            RETURN COALESCE(r.ticket_limit, e.max_tickets_per_user, $default_limit) AS limit
        END_OF_QUERY
        user_limit = user_limit_result.first&.dig('limit') || TICKETS_PER_USER
        
        # If user-specific limit is 0, block purchases
        if user_limit == 0
            respond(success: false, error: "Du bist temporär vom Ticketkauf für dieses Event ausgeschlossen.")
            return
        end

        current_tickets = existing_orders.select { |o| o['status'] == 'paid' || o['status'] == 'pending' }
                                        .sum { |o| o['ticket_count'] }
        
        if current_tickets + ticket_count > user_limit
            respond(success: false, error: "Ticket-Limit überschritten. Du kannst maximal #{user_limit} Tickets für dieses Event bestellen.")
            return
        end
        
        # Validate participants data
        if participants.nil? || participants.empty?
            respond(success: false, error: "Teilnehmer-Daten sind erforderlich.")
            return
        end
        
        if participants.size != ticket_count
            respond(success: false, error: "Anzahl der Teilnehmer stimmt nicht mit der Ticket-Anzahl überein.")
            return
        end
        
        # Get event start datetime for age calculation reference
        event_start_datetime = event[:start_datetime]
        reference_date = nil
        if event_start_datetime && !event_start_datetime.empty?
            begin
                reference_date = DateTime.parse(event_start_datetime).to_date
            rescue ArgumentError
                # If parsing fails, use today as fallback
                reference_date = Date.today
            end
        else
            reference_date = Date.today
        end
        
        # Validate each participant
        participants.each_with_index do |participant, index|
            # Validate name
            if participant['name'].nil? || participant['name'].strip.empty?
                respond(success: false, error: "Name für Teilnehmer #{index + 1} ist erforderlich.")
                return
            end
            
            # Validate birthdate
            if participant['birthdate'].nil? || participant['birthdate'].strip.empty?
                respond(success: false, error: "Geburtsdatum für Teilnehmer #{index + 1} ist erforderlich.")
                return
            end
            
            valid, error_msg = validate_birthdate(participant['birthdate'], reference_date)
            unless valid
                respond(success: false, error: "Ungültiges Geburtsdatum für Teilnehmer #{index + 1}: #{error_msg}")
                return
            end
        end
        
        # Determine ticket price based on tier selection
        if tier_id && tier_id != 'default'
            # Get tier-specific pricing
            tier_result = neo4j_query(<<~END_OF_QUERY, {event_id: event_id, tier_id: tier_id})
                MATCH (e:Event {id: $event_id})-[:HAS_TIER]->(t:TicketTier {id: $tier_id})
                RETURN t.price AS tier_price, t.name AS tier_name, t.max_tickets AS tier_max_tickets
            END_OF_QUERY
            
            if tier_result.empty?
                respond(success: false, error: "Ausgewählte Ticket-Kategorie nicht gefunden.")
                return
            end
            
            tier = tier_result.first
            ticket_price = tier['tier_price'].to_f
            tier_name = tier['tier_name']
            tier_max_tickets = tier['tier_max_tickets']
            
            # Check tier-specific ticket availability if tier has max_tickets limit
            if tier_max_tickets
                tier_sold_result = neo4j_query(<<~END_OF_QUERY, {event_id: event_id, tier_id: tier_id})
                    MATCH (e:Event {id: $event_id})-[:HAS_TIER]->(t:TicketTier {id: $tier_id})
                    OPTIONAL MATCH (o:TicketOrder)-[:FOR_TIER]->(t)
                    WHERE o.status = 'paid' OR o.status = 'pending'
                    RETURN COALESCE(SUM(o.ticket_count), 0) AS sold
                END_OF_QUERY
                tier_sold = tier_sold_result.first&.dig('sold') || 0
                
                if tier_sold + ticket_count > tier_max_tickets
                    respond(success: false, error: "Nicht genügend Tickets in der Kategorie '#{tier_name}' verfügbar.")
                    return
                end
            end
        else
            # Use default pricing (with user-specific override if applicable)
            ticket_price_result = neo4j_query(<<~END_OF_QUERY, {email: user_email, event_id: event_id})
                MATCH (u:User {email: $email})
                MATCH (e:Event {id: $event_id})
                OPTIONAL MATCH (u)-[r:HAS_EVENT_LIMIT]->(e)
                RETURN COALESCE(r.ticket_price, e.ticket_price) AS price
            END_OF_QUERY
            user_ticket_price = ticket_price_result.first&.dig('price')
            ticket_price = (user_ticket_price || event[:ticket_price]).to_f
            tier_name = 'Standard'
        end
        
        # Get next order count for this user
        order_count = existing_orders.size + 1
        
        # Generate order ID and payment reference
        order_id = RandomTag::generate(8)
        payment_ref = generate_payment_reference(@session_user[:username] || user_email.split('@').first, order_count)
        
        # NOTE: Bank account is NOT assigned at order creation time.
        # Payment requests are now a separate step and can be sent manually or in bulk.
        # 
        # Order Status Flow:
        # - 'pending': Order created, tickets reserved, no payment request sent yet
        # - 'paid': Payment received and confirmed
        # - 'cancelled': Order cancelled by admin
        # - 'cancelled_by_user': Order cancelled by customer
        
        # Create ticket order and link to event (without bank account assignment)
        order_params = {
            order_id: order_id,
            user_email: user_email,
            event_id: event_id,
            tier_id: tier_id,
            ticket_count: ticket_count,
            total_price: ticket_price * ticket_count,
            individual_ticket_price: ticket_price,
            payment_ref: payment_ref,
            status: 'pending',
            created_at: DateTime.now.to_s,
            tier_name: tier_name
        }
        
        if tier_id && tier_id != 'default'
            # Create order with tier relationship
            neo4j_query(<<~END_OF_QUERY, order_params)
                MATCH (u:User {email: $user_email})
                MATCH (e:Event {id: $event_id})
                MATCH (t:TicketTier {id: $tier_id})
                CREATE (o:TicketOrder {
                    id: $order_id,
                    ticket_count: $ticket_count,
                    total_price: $total_price,
                    individual_ticket_price: $individual_ticket_price,
                    payment_reference: $payment_ref,
                    status: $status,
                    tier_name: $tier_name,
                    created_at: $created_at
                })
                CREATE (u)-[:PLACED]->(o)
                CREATE (o)-[:FOR]->(e)
                CREATE (o)-[:FOR_TIER]->(t)
            END_OF_QUERY
        else
            # Create order without tier relationship (default tier)
            neo4j_query(<<~END_OF_QUERY, order_params)
                MATCH (u:User {email: $user_email})
                MATCH (e:Event {id: $event_id})
                CREATE (o:TicketOrder {
                    id: $order_id,
                    ticket_count: $ticket_count,
                    total_price: $total_price,
                    individual_ticket_price: $individual_ticket_price,
                    payment_reference: $payment_ref,
                    status: $status,
                    tier_name: $tier_name,
                    created_at: $created_at
                })
                CREATE (u)-[:PLACED]->(o)
                CREATE (o)-[:FOR]->(e)
            END_OF_QUERY
        end
        
        # Add participants
        participants.each_with_index do |participant, index|
            params = {
                order_id: order_id,
                name: participant['name'],
                phone: participant['phone'] || '',
                email: participant['email'] || '',
                birthdate: participant['birthdate'],
                ticket_number: index + 1
            }
            neo4j_query(<<~END_OF_QUERY, params)
                MATCH (o:TicketOrder {id: $order_id})
                CREATE (p:Participant {
                    name: $name,
                    phone: $phone,
                    email: $email,
                    birthdate: $birthdate,
                    ticket_number: $ticket_number
                })
                CREATE (o)-[:INCLUDES]->(p)
            END_OF_QUERY
        end
        
        # NOTE: Payment request is NOT automatically sent.
        # The order is created in 'pending' status with tickets reserved.
        # A payment request will be sent separately, either manually per order or in bulk via event settings.
        # Send order received confirmation email (without payment details - those come with payment request)
        send_order_received_email(user_email, order_id, payment_ref, event, participants, ticket_price * ticket_count)
        
        log("Neue Bestellung #{order_id} erstellt für #{user_email} - #{ticket_count} Tickets, #{ticket_price * ticket_count}€")
        
        respond(success: true, order_id: order_id, payment_reference: payment_ref, total_price: ticket_price * ticket_count, ticket_count: ticket_count, payment_request_sent: false)
    end
    
    # Get payment QR code for an order
    post "/api/get_payment_qr_code" do
        require_user_with_permission!("buy_tickets")
        data = parse_request_data(required_keys: [:order_id])
        
        order_id = data[:order_id]
        user_email = @session_user[:email]
        
        # Verify order belongs to user or user is admin
        order_result = neo4j_query(<<~END_OF_QUERY, {order_id: order_id, user_email: user_email})
            MATCH (u:User {email: $user_email})-[:PLACED]->(o:TicketOrder {id: $order_id})
            OPTIONAL MATCH (o)-[:USES_ACCOUNT]->(b:BankAccount)
            RETURN o.payment_reference AS payment_ref, o.total_price AS total_price,
                   b.account_name AS account_name, b.bank_name AS bank_name,
                   b.iban AS iban, b.bic AS bic
        END_OF_QUERY
        
        if order_result.empty? && !user_has_permission?("manage_orders")
            respond(success: false, error: "Bestellung nicht gefunden oder keine Berechtigung")
            return
        end
        
        order = order_result.first
        
        if order['iban'].nil? || order['iban'].empty?
            respond(success: false, error: "Keine Bankverbindung für diese Bestellung hinterlegt")
            return
        end
        
        begin
            require 'rqrcode'
            
            # Generate EPC QR code
            epc_data = generate_epc_qr_data(
                order['account_name'],
                order['iban'],
                order['bic'],
                order['total_price'].to_f,
                order['payment_ref']
            )
            
            qr = RQRCode::QRCode.new(epc_data)
            png = qr.as_png(
                resize_gte_to: false,
                resize_exactly_to: false,
                fill: 'white',
                color: 'black',
                size: 300,
                border_modules: 4
            )
            qr_code_data_uri = "data:image/png;base64,#{Base64.strict_encode64(png.to_s)}"
            
            respond(success: true, 
                   qr_code: qr_code_data_uri,
                   bank_info: {
                       account_name: order['account_name'],
                       bank_name: order['bank_name'],
                       iban: order['iban'],
                       bic: order['bic'],
                       amount: order['total_price'].to_f,
                       reference: order['payment_ref']
                   })
        rescue => e
            debug_error("Failed to generate QR code: #{e.message}")
            respond(success: false, error: "QR-Code konnte nicht generiert werden")
        end
    end

    # Admin: Mark order as paid
    post "/api/mark_order_paid" do
        require_user_with_permission!("manage_orders")
        data = parse_request_data(required_keys: [:order_id])

        neo4j_query(<<~END_OF_QUERY, {order_id: data[:order_id], date: Date.today.to_s})
            MATCH (o:TicketOrder {id: $order_id})
            SET o.status = 'paid', o.paid_at = $date
        END_OF_QUERY
        
        respond(success: true)
    end

    # Admin: Mark order as unpaid
    post "/api/mark_order_unpaid" do
        require_user_with_permission!("manage_orders")
        data = parse_request_data(required_keys: [:order_id])
        neo4j_query(<<~END_OF_QUERY, {order_id: data[:order_id]})
            MATCH (o:TicketOrder {id: $order_id})
            SET o.status = 'pending'
            REMOVE o.paid_at
        END_OF_QUERY
        
        respond(success: true)
    end

    # ===========================================
    # Payment Request Management Endpoints
    # ===========================================
    
    # Get all payment requests for an order
    post "/api/get_payment_requests" do
        require_user_with_permission!("view_users")
        data = parse_request_data(required_keys: [:order_id])
        
        order_id = data[:order_id]
        
        payment_requests = neo4j_query(<<~END_OF_QUERY, {order_id: order_id})
            MATCH (o:TicketOrder {id: $order_id})-[:HAS_PAYMENT_REQUEST]->(pr:PaymentRequest)
            OPTIONAL MATCH (pr)-[:USES_ACCOUNT]->(b:BankAccount)
            RETURN pr.id AS id,
                   pr.status AS status,
                   pr.created_at AS created_at,
                   pr.sent_at AS sent_at,
                   pr.paid_at AS paid_at,
                   pr.created_by AS created_by,
                   b.id AS bank_account_id,
                   b.account_name AS bank_account_name,
                   b.bank_name AS bank_name,
                   b.iban AS iban,
                   b.bic AS bic
            ORDER BY pr.created_at DESC
        END_OF_QUERY
        
        respond(success: true, payment_requests: payment_requests)
    end

    # Send a payment request for a specific order (manual, with bank account selection)
    post "/api/send_payment_request" do
        require_user_with_permission!("manage_orders")
        data = parse_request_data(required_keys: [:order_id, :bank_account_id])
        
        order_id = data[:order_id]
        bank_account_id = data[:bank_account_id]
        
        # Verify order exists and is in pending status
        order_result = neo4j_query(<<~END_OF_QUERY, {order_id: order_id})
            MATCH (u:User)-[:PLACED]->(o:TicketOrder {id: $order_id})-[:FOR]->(e:Event)
            OPTIONAL MATCH (o)-[:INCLUDES]->(p:Participant)
            RETURN o.id AS order_id, 
                   o.status AS status, 
                   o.payment_reference AS payment_reference,
                   o.total_price AS total_price,
                   o.ticket_count AS ticket_count,
                   u.email AS user_email,
                   u.name AS user_name,
                   e.id AS event_id,
                   e.name AS event_name,
                   COLLECT({name: p.name, phone: p.phone, email: p.email}) AS participants
        END_OF_QUERY
        
        if order_result.empty?
            respond(success: false, error: "Bestellung nicht gefunden")
            return
        end
        
        order = order_result.first
        
        # Check if order is already paid
        if order['status'] == 'paid'
            respond(success: false, error: "Bestellung ist bereits bezahlt")
            return
        end
        
        # Verify bank account exists
        bank_result = neo4j_query(<<~END_OF_QUERY, {bank_account_id: bank_account_id})
            MATCH (b:BankAccount {id: $bank_account_id})
            RETURN b.id AS id, b.account_name AS account_name, b.bank_name AS bank_name,
                   b.iban AS iban, b.bic AS bic
        END_OF_QUERY
        
        if bank_result.empty?
            respond(success: false, error: "Bankkonto nicht gefunden")
            return
        end
        
        bank_account = bank_result.first
        
        # Create payment request
        payment_request_id = RandomTag::generate(12)
        created_at = DateTime.now.to_s
        
        pr_params = {
            order_id: order_id,
            payment_request_id: payment_request_id,
            bank_account_id: bank_account_id,
            created_at: created_at,
            created_by: @session_user[:email]
        }
        neo4j_query(<<~END_OF_QUERY, pr_params)
            MATCH (o:TicketOrder {id: $order_id})
            MATCH (b:BankAccount {id: $bank_account_id})
            CREATE (pr:PaymentRequest {
                id: $payment_request_id,
                status: 'sent',
                created_at: $created_at,
                sent_at: $created_at,
                created_by: $created_by
            })
            CREATE (o)-[:HAS_PAYMENT_REQUEST]->(pr)
            CREATE (pr)-[:USES_ACCOUNT]->(b)
        END_OF_QUERY
        
        # Get event details for email
        event_result = neo4j_query(<<~END_OF_QUERY, {event_id: order['event_id']})
            MATCH (e:Event {id: $event_id})
            RETURN e
        END_OF_QUERY
        event = event_result.first['e']
        
        # Send payment request email with bank details
        send_payment_request_email(
            order['user_email'],
            order_id,
            order['payment_reference'],
            event,
            order['participants'],
            order['total_price'].to_f,
            bank_account
        )
        
        log("Zahlungsaufforderung für Bestellung #{order_id} an #{order['user_email']} gesendet")
        
        respond(success: true, payment_request_id: payment_request_id, message: "Zahlungsaufforderung erfolgreich gesendet")
    end

    # Send bulk payment requests for all pending orders of an event
    post "/api/send_bulk_payment_requests" do
        require_user_with_permission!("manage_orders")
        data = parse_request_data(required_keys: [:event_id], optional_keys: [:order_ids])
        
        event_id = data[:event_id]
        specific_order_ids = data[:order_ids]  # Optional: specific orders to process
        
        # Verify event exists
        event_result = neo4j_query(<<~END_OF_QUERY, {event_id: event_id})
            MATCH (e:Event {id: $event_id})
            WHERE e.active = true
            RETURN e
        END_OF_QUERY
        
        if event_result.empty?
            respond(success: false, error: "Event nicht gefunden")
            return
        end
        
        event = event_result.first['e']
        
        # Get bank accounts for this event with percentages
        bank_accounts = neo4j_query(<<~END_OF_QUERY, {event_id: event_id})
            MATCH (e:Event {id: $event_id})-[:HAS_BANK_ACCOUNT]->(b:BankAccount)
            RETURN b.id AS id, b.account_name AS account_name, b.bank_name AS bank_name,
                   b.iban AS iban, b.bic AS bic, b.percentage AS percentage
            ORDER BY b.percentage DESC
        END_OF_QUERY
        
        if bank_accounts.empty?
            respond(success: false, error: "Keine Bankkonten für dieses Event konfiguriert")
            return
        end
        
        # Get pending orders without payment requests
        if specific_order_ids && !specific_order_ids.empty?
            # Filter to specific orders
            pending_orders = neo4j_query(<<~END_OF_QUERY, {event_id: event_id, order_ids: specific_order_ids})
                MATCH (u:User)-[:PLACED]->(o:TicketOrder)-[:FOR]->(e:Event {id: $event_id})
                WHERE o.status = 'pending' 
                  AND o.id IN $order_ids
                  AND NOT EXISTS((o)-[:HAS_PAYMENT_REQUEST]->(:PaymentRequest))
                OPTIONAL MATCH (o)-[:INCLUDES]->(p:Participant)
                RETURN o.id AS order_id,
                       o.payment_reference AS payment_reference,
                       o.total_price AS total_price,
                       u.email AS user_email,
                       u.name AS user_name,
                       COLLECT({name: p.name, phone: p.phone, email: p.email}) AS participants
            END_OF_QUERY
        else
            # Get all pending orders without payment requests
            pending_orders = neo4j_query(<<~END_OF_QUERY, {event_id: event_id})
                MATCH (u:User)-[:PLACED]->(o:TicketOrder)-[:FOR]->(e:Event {id: $event_id})
                WHERE o.status = 'pending' 
                  AND NOT EXISTS((o)-[:HAS_PAYMENT_REQUEST]->(:PaymentRequest))
                OPTIONAL MATCH (o)-[:INCLUDES]->(p:Participant)
                RETURN o.id AS order_id,
                       o.payment_reference AS payment_reference,
                       o.total_price AS total_price,
                       u.email AS user_email,
                       u.name AS user_name,
                       COLLECT({name: p.name, phone: p.phone, email: p.email}) AS participants
            END_OF_QUERY
        end
        
        if pending_orders.empty?
            respond(success: true, sent_count: 0, message: "Keine ausstehenden Bestellungen ohne Zahlungsaufforderung")
            return
        end
        
        sent_count = 0
        errors = []
        
        pending_orders.each do |order|
            begin
                # Select bank account based on percentage distribution
                selected_bank_account = select_bank_account_from_list(bank_accounts)
                
                # Create payment request
                payment_request_id = RandomTag::generate(12)
                created_at = DateTime.now.to_s
                
                pr_params = {
                    order_id: order['order_id'],
                    payment_request_id: payment_request_id,
                    bank_account_id: selected_bank_account['id'],
                    created_at: created_at,
                    created_by: @session_user[:email]
                }
                neo4j_query(<<~END_OF_QUERY, pr_params)
                    MATCH (o:TicketOrder {id: $order_id})
                    MATCH (b:BankAccount {id: $bank_account_id})
                    CREATE (pr:PaymentRequest {
                        id: $payment_request_id,
                        status: 'sent',
                        created_at: $created_at,
                        sent_at: $created_at,
                        created_by: $created_by
                    })
                    CREATE (o)-[:HAS_PAYMENT_REQUEST]->(pr)
                    CREATE (pr)-[:USES_ACCOUNT]->(b)
                END_OF_QUERY
                
                # Send payment request email
                send_payment_request_email(
                    order['user_email'],
                    order['order_id'],
                    order['payment_reference'],
                    event,
                    order['participants'],
                    order['total_price'].to_f,
                    selected_bank_account
                )
                
                sent_count += 1
            rescue => e
                errors << {order_id: order['order_id'], error: e.message}
                debug_error("Failed to send payment request for order #{order['order_id']}: #{e.message}")
            end
        end
        
        log("Bulk-Zahlungsaufforderung für Event #{event_id}: #{sent_count} gesendet, #{errors.size} fehlgeschlagen")
        
        respond(success: true, sent_count: sent_count, errors: errors, message: "#{sent_count} Zahlungsaufforderungen gesendet")
    end

    # Mark payment request as paid
    post "/api/mark_payment_request_paid" do
        require_user_with_permission!("manage_orders")
        data = parse_request_data(required_keys: [:payment_request_id])
        
        payment_request_id = data[:payment_request_id]
        
        # Update payment request status and mark order as paid
        neo4j_query(<<~END_OF_QUERY, {payment_request_id: payment_request_id, paid_at: Date.today.to_s})
            MATCH (o:TicketOrder)-[:HAS_PAYMENT_REQUEST]->(pr:PaymentRequest {id: $payment_request_id})
            SET pr.status = 'paid', pr.paid_at = $paid_at,
                o.status = 'paid', o.paid_at = $paid_at
        END_OF_QUERY
        
        respond(success: true)
    end

    # Get orders with payment request status for an event
    post "/api/get_orders_by_payment_status" do
        require_user_with_permission!("view_users")
        data = parse_request_data(required_keys: [:event_id], optional_keys: [:payment_status])
        
        event_id = data[:event_id]
        payment_status = data[:payment_status]  # 'no_request', 'sent', 'paid', or nil for all
        
        base_query = <<~END_OF_QUERY
            MATCH (u:User)-[:PLACED]->(o:TicketOrder)-[:FOR]->(e:Event {id: $event_id})
            OPTIONAL MATCH (o)-[:HAS_PAYMENT_REQUEST]->(pr:PaymentRequest)
            OPTIONAL MATCH (pr)-[:USES_ACCOUNT]->(b:BankAccount)
        END_OF_QUERY
        
        filter_clause = case payment_status
        when 'no_request'
            "WHERE pr IS NULL"
        when 'sent'
            "WHERE pr.status = 'sent'"
        when 'paid'
            "WHERE o.status = 'paid'"
        else
            ""
        end
        
        return_clause = <<~END_OF_QUERY
            RETURN u.name AS user_name,
                   u.email AS user_email,
                   o.id AS order_id,
                   o.ticket_count AS ticket_count,
                   o.total_price AS total_price,
                   o.payment_reference AS payment_reference,
                   o.status AS order_status,
                   o.created_at AS created_at,
                   pr.id AS payment_request_id,
                   pr.status AS payment_request_status,
                   pr.sent_at AS payment_request_sent_at,
                   b.account_name AS bank_account_name
            ORDER BY o.created_at DESC
        END_OF_QUERY
        
        full_query = "#{base_query}\n#{filter_clause}\n#{return_clause}"
        
        orders = neo4j_query(full_query, {event_id: event_id})
        
        respond(success: true, orders: orders)
    end

    # Helper: Select bank account from list based on percentage distribution
    def select_bank_account_from_list(accounts)
        return accounts.first if accounts.size == 1
        
        # Generate a random number between 0 and 100
        random_value = rand(100.0)
        
        # Select account based on cumulative percentage
        cumulative = 0.0
        accounts.each do |account|
            cumulative += account['percentage'].to_f
            if random_value < cumulative
                return account
            end
        end
        
        # Fallback to first account
        accounts.first
    end

    # Send payment request email
    def send_payment_request_email(user_email, order_id, payment_ref, event, participants, total_price, bank_account)
        # Get user name
        user_result = neo4j_query(<<~END_OF_QUERY, {email: user_email})
            MATCH (u:User {email: $email})
            RETURN u.name AS name
        END_OF_QUERY
        
        user_name = user_result.first&.dig('name') || 'Liebe/r Nutzer/in'
        
        # Generate QR code for payment
        qr_code_data_uri = nil
        begin
            require 'rqrcode'
            epc_data = generate_epc_qr_data(
                bank_account['account_name'],
                bank_account['iban'],
                bank_account['bic'],
                total_price,
                payment_ref
            )
            qr = RQRCode::QRCode.new(epc_data)
            png = qr.as_png(
                resize_gte_to: false,
                resize_exactly_to: false,
                fill: 'white',
                color: 'black',
                size: 300,
                border_modules: 4
            )
            qr_code_data_uri = "data:image/png;base64,#{Base64.strict_encode64(png.to_s)}"
        rescue => e
            debug_error("Failed to generate QR code for email: #{e.message}")
        end
        
        deliver_mail do
            to user_email
            from SMTP_FROM
            subject "Zahlungsaufforderung - #{event[:name]}"
            
            content = StringIO.open do |io|
                io.puts "            <div class=\"info-badge\">"
                io.puts "                <strong>Zahlungsaufforderung für deine Bestellung</strong>"
                io.puts "            </div>"
                io.puts "            <p>Hallo #{user_name},</p>"
                io.puts "            <p>hier sind die Zahlungsinformationen für deine Ticket-Bestellung:</p>"
                io.puts "            <div class=\"order-details\">"
                io.puts "                <h3>Bestelldetails</h3>"
                io.puts "                <p><strong>Bestellnummer:</strong> #{payment_ref}</p>"
                io.puts "                <p><strong>Event:</strong> #{event[:name]}</p>"
                io.puts "                <p><strong>Anzahl Tickets:</strong> #{participants.length}</p>"
                io.puts "                <p><strong>Gesamtpreis:</strong> #{total_price.round(2)}€</p>"
                io.puts "            </div>"
                io.puts "            <h4>Bitte überweise auf folgendes Konto:</h4>"
                io.puts "            <ul>"
                io.puts "                <li><strong>Empfänger:</strong> #{bank_account['account_name']}</li>"
                io.puts "                <li><strong>Bank:</strong> #{bank_account['bank_name']}</li>"
                io.puts "                <li><strong>IBAN:</strong> #{bank_account['iban']}</li>"
                io.puts "                <li><strong>BIC:</strong> #{bank_account['bic']}</li>"
                io.puts "                <li><strong>Betrag:</strong> #{total_price.round(2)}€</li>"
                io.puts "                <li><strong>Verwendungszweck:</strong> #{payment_ref}</li>"
                io.puts "            </ul>"
                
                if qr_code_data_uri
                    io.puts "            <div style='margin: 20px 0; padding: 15px; background-color: #f8f9fa; border-radius: 5px;'>"
                    io.puts "                <h4 style='margin-top: 0;'>Schnelle Zahlung mit QR-Code</h4>"
                    io.puts "                <p>Scanne diesen QR-Code mit deiner Banking-App, um die Überweisung automatisch auszufüllen:</p>"
                    io.puts "                <div style='text-align: center; margin: 15px 0;'>"
                    io.puts "                    <img src='#{qr_code_data_uri}' alt='Payment QR Code' style='max-width: 300px; width: 100%; height: auto;' />"
                    io.puts "                </div>"
                    io.puts "            </div>"
                end
                
                io.puts "            <p><strong>Wichtig:</strong> Bitte verwende unbedingt die Bestellnummer <code>#{payment_ref}</code> als Verwendungszweck!</p>"
                io.puts "            <p>Nach Zahlungseingang werden deine Tickets freigeschaltet.</p>"
                io.puts "            <p><a href=\"#{WEB_ROOT}/tickets\" class=\"btn\">Meine Bestellungen ansehen</a></p>"
                io.puts "            <p>Bei Fragen wende dich gerne an unseren Support.</p>"
                io.string
            end
            
            format_email_with_template("Zahlungsaufforderung", content)
        end
        log("Zahlungsaufforderung für Bestellung #{order_id} versendet")
    rescue => e
        log("Zahlungsaufforderung für Bestellung #{order_id} fehlgeschlagen: #{e.message}")
        raise e
    end

    post "/api/all_ticket_orders" do
        require_user_with_permission!("view_users")
        
        orders = neo4j_query(<<~END_OF_QUERY)
            MATCH (u:User)-[:PLACED]->(o:TicketOrder)-[:FOR]->(e:Event)
            OPTIONAL MATCH (o)-[:INCLUDES]->(p:Participant)
            OPTIONAL MATCH (o)-[:HAS_PAYMENT_REQUEST]->(pr:PaymentRequest)
            OPTIONAL MATCH (pr)-[:USES_ACCOUNT]->(b:BankAccount)
            WITH u, o, e, p, pr, b
            ORDER BY pr.created_at DESC
            WITH u, o, e, 
                 COLLECT(DISTINCT {name: p.name, phone: p.phone, email: p.email, birthdate: p.birthdate, ticket_number: p.ticket_number}) AS participants,
                 COLLECT(DISTINCT {
                    id: pr.id, 
                    status: pr.status, 
                    sent_at: pr.sent_at, 
                    paid_at: pr.paid_at,
                    bank_account_id: b.id,
                    bank_account_name: b.account_name
                 })[0] AS latest_payment_request
            RETURN u.name AS user_name,
                   u.email AS user_email,
                   u.username AS user_username,
                   u.phone AS user_phone,
                   o.id AS order_id,
                   o.ticket_count AS ticket_count,
                   o.total_price AS total_price,
                   o.individual_ticket_price AS individual_ticket_price,
                   o.payment_reference AS payment_reference,
                   o.created_at AS created_at,
                   COALESCE(o.paid_at, '') AS paid_at,
                   COALESCE(o.status, '') AS status,
                   e.id AS event_id,
                   COALESCE(e.name, '') AS event_name,
                   COALESCE(e.year, '') AS event_year,
                   participants,
                   latest_payment_request
        END_OF_QUERY
        
        respond(success: true, orders: orders)
    end

    # Get a specific ticket order by ID
    post "/api/get_ticket_order" do
        require_user_with_permission!("view_users")
        data = parse_request_data(required_keys: [:order_id])
        
        order_id = data[:order_id]
        
        # Query for the specific order with payment request info
        order_result = neo4j_query(<<~END_OF_QUERY, {order_id: order_id})
            MATCH (u:User)-[:PLACED]->(o:TicketOrder {id: $order_id})-[:FOR]->(e:Event)
            OPTIONAL MATCH (o)-[:INCLUDES]->(p:Participant)
            OPTIONAL MATCH (o)-[:HAS_PAYMENT_REQUEST]->(pr:PaymentRequest)
            OPTIONAL MATCH (pr)-[:USES_ACCOUNT]->(b:BankAccount)
            WITH u, o, e, p, pr, b
            ORDER BY pr.created_at DESC
            WITH u, o, e, 
                 COLLECT(DISTINCT {name: p.name, phone: p.phone, email: p.email, birthdate: p.birthdate, ticket_number: p.ticket_number}) AS participants,
                 COLLECT(DISTINCT CASE WHEN pr IS NOT NULL THEN {
                    id: pr.id, 
                    status: pr.status, 
                    created_at: pr.created_at,
                    sent_at: pr.sent_at, 
                    paid_at: pr.paid_at,
                    bank_account_id: b.id,
                    bank_account_name: b.account_name,
                    bank_name: b.bank_name,
                    iban: b.iban,
                    bic: b.bic
                 } ELSE null END) AS payment_requests
            RETURN u.name AS user_name,
                   u.email AS user_email,
                   u.username AS user_username,
                   u.phone AS user_phone,
                   o.id AS order_id,
                   o.ticket_count AS ticket_count,
                   o.total_price AS total_price,
                   o.individual_ticket_price AS individual_ticket_price,
                   o.payment_reference AS payment_reference,
                   o.created_at AS created_at,
                   COALESCE(o.paid_at, '') AS paid_at,
                   COALESCE(o.status, '') AS status,
                   e.id AS event_id,
                   COALESCE(e.name, '') AS event_name,
                   COALESCE(e.year, '') AS event_year,
                   participants,
                   [x IN payment_requests WHERE x IS NOT NULL] AS payment_requests
        END_OF_QUERY
        
        if order_result.empty?
            respond(success: false, error: "Bestellung nicht gefunden")
            return
        end
        
        # Since we're getting a single order, extract the first result
        order = order_result.first
        
        respond(success: true, order: order)
    end

    # Get ticket limits and availability for current user for a specific event
    post "/api/ticket_limits" do
        require_user_with_permission!("buy_tickets")
        data = parse_request_data(required_keys: [:event_id])
        
        user_email = @session_user[:email]
        event_id = data[:event_id]
        
        # Get event details
        event_result = neo4j_query(<<~END_OF_QUERY, {event_id: event_id})
            MATCH (e:Event {id: $event_id})
            WHERE e.active = true
            RETURN e.max_tickets AS max_tickets, e.ticket_price AS ticket_price, e.visibility AS visibility
        END_OF_QUERY
        
        if event_result.empty?
            respond(success: false, error: "Event nicht gefunden.")
            return
        end
        
        event = event_result.first
        
        # Check event access
        if event['visibility'] == 'private'
            unless user_has_permission?("create_events") || user_has_permission?("admin")
                respond(success: false, error: "Zugriff verweigert.")
                return
            end
        elsif event['visibility'] == 'password_protected'
            unless session["event_access_#{event_id}"]
                respond(success: false, error: "Event-Passwort erforderlich.")
                return
            end
        end
        
        # Get user's ticket limit and price (check event-specific first, then event default, then global)
        user_limit_result = neo4j_query(<<~END_OF_QUERY, {email: user_email, event_id: event_id, default_limit: TICKETS_PER_USER})
            MATCH (u:User {email: $email})
            MATCH (e:Event {id: $event_id})
            OPTIONAL MATCH (u)-[r:HAS_EVENT_LIMIT]->(e)
            RETURN COALESCE(r.ticket_limit, e.max_tickets_per_user, $default_limit) AS limit, 
                   COALESCE(r.ticket_price, e.ticket_price) AS price
        END_OF_QUERY
        user_limit = user_limit_result.first&.dig('limit') || TICKETS_PER_USER
        ticket_price = user_limit_result.first&.dig('price')&.to_f || event['ticket_price'].to_f
        
        # Check if user is blocked (limit = 0)
        if user_limit == 0
            respond(success: false, error: "Du bist temporär vom Ticketkauf für dieses Event ausgeschlossen.")
            return
        end
        
        # Get event tickets sold (include reserved/pending tickets)
        event_sold_result = neo4j_query(<<~END_OF_QUERY, {event_id: event_id})
            MATCH (e:Event {id: $event_id})<-[:FOR]-(o:TicketOrder)
            WHERE o.status = 'paid' OR o.status = 'pending'
            RETURN SUM(o.ticket_count) AS total
        END_OF_QUERY
        event_sold = event_sold_result.first&.dig('total') || 0
        
        # Get user's current tickets for this event
        user_orders = neo4j_query(<<~END_OF_QUERY, {email: user_email, event_id: event_id})
            MATCH (u:User {email: $email})-[:PLACED]->(o:TicketOrder)-[:FOR]->(e:Event {id: $event_id})
            WHERE o.status = 'paid' OR o.status = 'pending'
            RETURN o.ticket_count AS ticket_count
        END_OF_QUERY
        current_tickets = user_orders.sum { |o| o['ticket_count'] }
        
        available_event = event['max_tickets'] - event_sold
        available_user = user_limit - current_tickets
        max_order = [available_event, available_user].min
        
        respond(success: true, 
                user_limit: user_limit, 
                ticket_price: ticket_price,
                current_tickets: current_tickets,
                available_user: available_user,
                available_event: available_event,
                max_tickets_event: event['max_tickets'],
                event_sold: event_sold,
                max_order: max_order > 0 ? max_order : 0)
    end

    # Get current user's ticket orders
    post "/api/my_tickets" do
        require_user_with_permission!("buy_tickets")
        user_email = @session_user[:email]
        
        orders = neo4j_query(<<~END_OF_QUERY, {email: user_email})
            MATCH (u:User {email: $email})-[:PLACED]->(o:TicketOrder)-[:FOR]->(e:Event)
            OPTIONAL MATCH (o)-[:INCLUDES]->(p:Participant)
            OPTIONAL MATCH (o)-[:FOR_TIER]->(t:TicketTier)
            OPTIONAL MATCH (o)-[:HAS_PAYMENT_REQUEST]->(pr:PaymentRequest)
            OPTIONAL MATCH (pr)-[:USES_ACCOUNT]->(b:BankAccount)
            WITH o, e, t, 
                 COLLECT(DISTINCT {name: p.name, phone: p.phone, email: p.email, birthdate: p.birthdate, ticket_number: p.ticket_number}) AS participants,
                 pr, b
            ORDER BY pr.created_at DESC
            WITH o, e, t, participants,
                 COLLECT(DISTINCT CASE WHEN pr IS NOT NULL THEN {
                    id: pr.id,
                    status: pr.status,
                    sent_at: pr.sent_at,
                    bank_account_name: b.account_name,
                    bank_name: b.bank_name,
                    iban: b.iban,
                    bic: b.bic
                 } ELSE null END)[0] AS latest_payment_request
            RETURN o.id AS order_id,
                   o.ticket_count AS ticket_count,
                   o.total_price AS total_price,
                   o.individual_ticket_price AS individual_ticket_price,
                   o.payment_reference AS payment_reference,
                   o.created_at AS created_at,
                   COALESCE(o.paid_at, '') AS paid_at,
                   COALESCE(o.status, '') AS status,
                   COALESCE(o.tier_name, t.name, 'Standard') AS tier_name,
                   e.id AS event_id,
                   e.name AS event_name,
                   e.year AS event_year,
                   participants,
                   latest_payment_request
            ORDER BY o.created_at DESC
        END_OF_QUERY
        
        respond(success: true, orders: orders)
    end

    # Admin: Update ticket order
    post "/api/update_ticket_order" do
        require_user_with_permission!("manage_orders")
        data = parse_request_data(
            required_keys: [:order_id, :ticket_count, :total_price, :payment_reference, :status],
            optional_keys: [:participants, :user_name, :user_email, :user_address, :user_phone],
            types: {
                ticket_count: Integer,
                participants: Array
            }
        )
        
        order_id = data[:order_id]
        ticket_count = data[:ticket_count]
        # Ensure total_price is handled as Float or nil
        total_price = data[:total_price].nil? ? nil : data[:total_price].to_f
        puts "Total price: #{order_id} - #{total_price}"
        payment_reference = data[:payment_reference]
        status = data[:status]
        paid_at = data[:paid_at]
        participants = data[:participants] || []
        
        # Update order basic information
        update_params = {
            order_id: order_id,
            ticket_count: ticket_count,
            total_price: total_price,
            payment_reference: payment_reference,
            status: status
        }

        neo4j_query(<<~END_OF_QUERY, update_params)
            MATCH (o:TicketOrder {id: $order_id})
            SET o.ticket_count = $ticket_count,
                o.total_price = $total_price,
                o.payment_reference = $payment_reference,
                o.status = $status
            RETURN o
        END_OF_QUERY

        # Update user information if provided
        if data[:user_name] || data[:user_email] || data[:user_address] || data[:user_phone]
            user_update_params = {
                order_id: order_id,
                user_name: data[:user_name],
                user_email: data[:user_email],
                user_address: data[:user_address],
                user_phone: data[:user_phone]
            }
            
            neo4j_query(<<~END_OF_QUERY, user_update_params)
                MATCH (u:User)-[:PLACED]->(o:TicketOrder {id: $order_id})
                SET u.name = COALESCE($user_name, u.name),
                    u.email = COALESCE($user_email, u.email),
                    u.address = COALESCE($user_address, u.address),
                    u.phone = COALESCE($user_phone, u.phone)
                RETURN u
            END_OF_QUERY
        end

        puts "Updated order: #{order_id}"


        # Update participants if provided
        if participants.any?
            # First, delete existing participants
            neo4j_query(<<~END_OF_QUERY, {order_id: order_id})
                MATCH (o:TicketOrder {id: $order_id})-[:INCLUDES]->(p:Participant)
                DETACH DELETE p
            END_OF_QUERY
            
            # Then add updated participants
            participants.each_with_index do |participant, index|
                next if participant['name'].nil? || participant['name'].empty?
                
                # Use nil for birthdate if not provided or empty
                birthdate_value = participant['birthdate']
                birthdate_value = nil if birthdate_value.nil? || birthdate_value.strip.empty?
                
                participant_params = {
                    order_id: order_id,
                    name: participant['name'],
                    phone: participant['phone'] || '',
                    email: participant['email'] || '',
                    birthdate: birthdate_value,
                    ticket_number: index + 1
                }
                neo4j_query(<<~END_OF_QUERY, participant_params)
                    MATCH (o:TicketOrder {id: $order_id})
                    CREATE (p:Participant {
                        name: $name,
                        phone: $phone,
                        email: $email,
                        birthdate: $birthdate,
                        ticket_number: $ticket_number
                    })
                    CREATE (o)-[:INCLUDES]->(p)
                END_OF_QUERY
            end
        end
        
        respond(success: true)
    end

    # Admin: Delete/cancel ticket order
    post "/api/delete_ticket_order" do
        require_user_with_permission!("manage_orders")
        data = parse_request_data(required_keys: [:order_id])
        
        order_id = data[:order_id]
        
        # First check if order exists
        order_check = neo4j_query(<<~END_OF_QUERY, {order_id: order_id})
            MATCH (o:TicketOrder {id: $order_id})
            RETURN o.id AS order_id, o.status AS status
        END_OF_QUERY
        
        if order_check.empty?
            respond(success: false, error: "Bestellung nicht gefunden")
            return
        end
        
        # Delete participants and order
        neo4j_query(<<~END_OF_QUERY, {order_id: order_id})
            MATCH (o:TicketOrder {id: $order_id})
            OPTIONAL MATCH (o)-[:INCLUDES]->(p:Participant)
            DETACH DELETE p, o
        END_OF_QUERY
        
        respond(success: true, message: "Bestellung wurde erfolgreich gelöscht")
    end

    # API endpoint for order statistics
    post "/api/get_order_statistics" do
        require_user_with_permission!("view_users")
        data = parse_request_data(optional_keys: [:event_id])
        
        event_id = data[:event_id]
        
        if event_id && !event_id.empty?
            # Event-specific statistics
            # Get paid tickets (sold and confirmed)
            tickets_paid_result = neo4j_query(<<~END_OF_QUERY, {event_id: event_id})
                MATCH (o:TicketOrder)-[:FOR]->(e:Event {id: $event_id})
                WHERE o.status = 'paid'
                RETURN SUM(o.ticket_count) AS total
            END_OF_QUERY
            tickets_paid = tickets_paid_result.first&.dig('total') || 0
            
            # Get reserved (pending) tickets
            tickets_reserved_result = neo4j_query(<<~END_OF_QUERY, {event_id: event_id})
                MATCH (o:TicketOrder)-[:FOR]->(e:Event {id: $event_id})
                WHERE o.status = 'pending'
                RETURN SUM(o.ticket_count) AS total
            END_OF_QUERY
            tickets_reserved = tickets_reserved_result.first&.dig('total') || 0
            
            # Total tickets sold includes both paid and reserved
            total_tickets_sold = tickets_paid + tickets_reserved
            
            # Get event max tickets
            event_data = neo4j_query(<<~END_OF_QUERY, {event_id: event_id})
                MATCH (e:Event {id: $event_id})
                RETURN e.max_tickets AS max_tickets
            END_OF_QUERY
            max_tickets = event_data.first&.dig('max_tickets') || 0
            # Available tickets excludes both paid and reserved tickets
            tickets_available = max_tickets - total_tickets_sold
            
            # Get order counts by status for this event
            order_counts_result = neo4j_query(<<~END_OF_QUERY, {event_id: event_id})
                MATCH (o:TicketOrder)-[:FOR]->(e:Event {id: $event_id})
                RETURN o.status AS status, COUNT(o) AS count
            END_OF_QUERY
            
            paid_orders = 0
            pending_orders = 0
            order_counts_result.each do |row|
                if row['status'] == 'paid'
                    paid_orders = row['count']
                elsif row['status'] == 'pending'
                    pending_orders = row['count']
                end
            end
            
            # Calculate total revenue for this event
            revenue_result = neo4j_query(<<~END_OF_QUERY, {event_id: event_id})
                MATCH (o:TicketOrder)-[:FOR]->(e:Event {id: $event_id})
                WHERE o.status = 'paid'
                RETURN SUM(o.total_price) AS total_revenue
            END_OF_QUERY
            revenue_total = revenue_result.first&.dig('total_revenue') || 0.0
            
            # Count total participants for this event (paid and reserved orders)
            participants_result = neo4j_query(<<~END_OF_QUERY, {event_id: event_id})
                MATCH (o:TicketOrder)-[:FOR]->(e:Event {id: $event_id})
                MATCH (o)-[:INCLUDES]->(p:Participant)
                WHERE (o.status = 'paid' OR o.status = 'pending') AND p.name IS NOT NULL AND p.name <> ''
                RETURN COUNT(p) AS total_participants
            END_OF_QUERY
            total_participants = participants_result.first&.dig('total_participants') || 0
        else
            # Global statistics (all events)
            # Get paid tickets
            tickets_paid_result = neo4j_query(<<~END_OF_QUERY)
                MATCH (o:TicketOrder)
                WHERE o.status = 'paid'
                RETURN SUM(o.ticket_count) AS total
            END_OF_QUERY
            tickets_paid = tickets_paid_result.first&.dig('total') || 0
            
            # Get reserved tickets
            tickets_reserved_result = neo4j_query(<<~END_OF_QUERY)
                MATCH (o:TicketOrder)
                WHERE o.status = 'pending'
                RETURN SUM(o.ticket_count) AS total
            END_OF_QUERY
            tickets_reserved = tickets_reserved_result.first&.dig('total') || 0
            
            # Total tickets includes both paid and reserved
            total_tickets_sold = tickets_paid + tickets_reserved
            
            # Calculate tickets available (excludes both paid and reserved)
            tickets_available = MAX_TICKETS_GLOBAL - total_tickets_sold
            
            # Get order counts by status
            order_counts_result = neo4j_query(<<~END_OF_QUERY)
                MATCH (o:TicketOrder)
                RETURN o.status AS status, COUNT(o) AS count
            END_OF_QUERY
            
            paid_orders = 0
            pending_orders = 0
            order_counts_result.each do |row|
                if row['status'] == 'paid'
                    paid_orders = row['count']
                elsif row['status'] == 'pending'
                    pending_orders = row['count']
                end
            end
            
            # Calculate total revenue
            revenue_result = neo4j_query(<<~END_OF_QUERY)
                MATCH (o:TicketOrder)
                WHERE o.status = 'paid'
                RETURN SUM(o.total_price) AS total_revenue
            END_OF_QUERY
            revenue_total = revenue_result.first&.dig('total_revenue') || 0.0
            
            # Count total participants (paid and reserved orders)
            participants_result = neo4j_query(<<~END_OF_QUERY)
                MATCH (o:TicketOrder)-[:INCLUDES]->(p:Participant)
                WHERE (o.status = 'paid' OR o.status = 'pending') AND p.name IS NOT NULL AND p.name <> ''
                RETURN COUNT(p) AS total_participants
            END_OF_QUERY
            total_participants = participants_result.first&.dig('total_participants') || 0
        end
        
        statistics = {
            total_tickets_sold: total_tickets_sold,
            tickets_paid: tickets_paid,
            tickets_reserved: tickets_reserved,
            tickets_available: tickets_available,
            paid_orders: paid_orders,
            pending_orders: pending_orders,
            revenue_total: revenue_total.round(2),
            total_participants: total_participants
        }
        
        respond(success: true, statistics: statistics)
    end

    # Generate order summary PDF
    get "/api/generate_order_summary_pdf" do
        require_user_with_permission!("view_users")
        
        # Get all orders with details
        orders = neo4j_query(<<~END_OF_QUERY)
            MATCH (u:User)-[:PLACED]->(o:TicketOrder)
            OPTIONAL MATCH (o)-[:INCLUDES]->(p:Participant)
            RETURN u.name AS user_name,
                   u.email AS user_email,
                   o.id AS order_id,
                   o.ticket_count AS ticket_count,
                   o.total_price AS total_price,
                   o.individual_ticket_price AS individual_ticket_price,
                   o.payment_reference AS payment_reference,
                   o.status AS status,
                   o.created_at AS created_at,
                   o.paid_at AS paid_at,
                   COLLECT({name: p.name, phone: p.phone, email: p.email, birthdate: p.birthdate, ticket_number: p.ticket_number}) AS participants
            ORDER BY o.created_at DESC
        END_OF_QUERY
        
        pdf_content = generate_pdf_content(orders)
        
        respond_raw_with_mimetype_and_filename(
            pdf_content,
            'application/pdf',
            "Bestelluebersicht_#{Date.today.strftime('%Y%m%d')}.pdf"
        )
    end

    # Generate single order PDF
    get "/api/generate_order_pdf/:order_id" do
        require_user!

        order_id = params[:order_id]
        unless order_id && !order_id.empty?
            respond(success: false, error: "Ungültige Bestell-ID")
            return
        end
        # Check if user can access this order (admin or order owner)
        order_user_email = neo4j_query_expect_one(<<~END_OF_QUERY, {order_id: order_id})['user_email']
            MATCH (u:User)-[:PLACED]->(o:TicketOrder {id: $order_id})
            RETURN u.email AS user_email
        END_OF_QUERY
        
        is_admin = user_has_permission?("view_users")
        is_order_owner = @session_user[:email] == order_user_email
        
        unless is_admin || is_order_owner
            respond(success: false, error: "Keine Berechtigung für diese Bestellung")
            return
        end
        
        # Check if user ticket downloads are allowed (admins can always download)
        unless is_admin || ALLOW_USER_TICKET_DOWNLOAD
            respond(success: false, error: "Ticket-Download ist derzeit nicht verfügbar")
            return
        end
        
        # Get order details
        order = neo4j_query_expect_one(<<~END_OF_QUERY, {order_id: order_id})
            MATCH (u:User)-[:PLACED]->(o:TicketOrder {id: $order_id})
            OPTIONAL MATCH (o)-[:INCLUDES]->(p:Participant)
            OPTIONAL MATCH (o)-[:USES_ACCOUNT]->(b:BankAccount)
            RETURN u.name AS user_name,
                   u.email AS user_email,
                   u.address AS user_address,
                   u.phone AS user_phone,
                   o.id AS order_id,
                   o.ticket_count AS ticket_count,
                   o.total_price AS total_price,
                   o.individual_ticket_price AS individual_ticket_price,
                   o.payment_reference AS payment_reference,
                   o.status AS status,
                   o.created_at AS created_at,
                   o.paid_at AS paid_at,
                   b.account_name AS bank_account_name,
                   b.bank_name AS bank_name,
                   b.iban AS bank_iban,
                   b.bic AS bank_bic,
                   COLLECT({name: p.name, phone: p.phone, email: p.email, birthdate: p.birthdate, ticket_number: p.ticket_number}) AS participants
        END_OF_QUERY
        
        pdf_content = generate_order_confirmation_pdf_content(order)
        
        respond_raw_with_mimetype_and_filename(
            pdf_content,
            'application/pdf',
            "Bestellbestaetigung_#{order['payment_reference']}.pdf"
        )
    end

    # Check if tickets can be generated for an order (admin only)
    post "/api/check_ticket_generation/:order_id" do
        require_user_with_permission!("manage_orders")
        
        order_id = params[:order_id]
        unless order_id && !order_id.empty?
            respond(success: false, error: "Ungültige Bestell-ID")
            return
        end
        
        # Get order details
        order = neo4j_query_expect_one(<<~END_OF_QUERY, {order_id: order_id})
            MATCH (u:User)-[:PLACED]->(o:TicketOrder {id: $order_id})
            RETURN o.status AS status, o.tickets_generated AS tickets_generated
        END_OF_QUERY
        
        can_generate = order['status'] == 'paid' && !order['tickets_generated']
        
        respond(success: true, can_generate_tickets: can_generate, order_status: order['status'], tickets_generated: !!order['tickets_generated'])
    end

    # Generate tickets for a paid order (admin only)
    post "/api/generate_tickets" do
        require_user_with_permission!("manage_orders")
        data = parse_request_data(required_keys: [:order_id])
        
        order_id = data[:order_id]
        
        # Get order details and verify it's paid
        order = neo4j_query_expect_one(<<~END_OF_QUERY, {order_id: order_id})
            MATCH (u:User)-[:PLACED]->(o:TicketOrder {id: $order_id})
            OPTIONAL MATCH (o)-[:INCLUDES]->(p:Participant)
            RETURN o.status AS status,
                   o.tickets_generated AS tickets_generated,
                   o.payment_reference AS payment_reference,
                   COLLECT({name: p.name, phone: p.phone, email: p.email, birthdate: p.birthdate, ticket_number: p.ticket_number}) AS participants
        END_OF_QUERY
        
        unless order['status'] == 'paid'
            respond(success: false, error: "Tickets können nur für bezahlte Bestellungen generiert werden")
            return
        end
        
        if order['tickets_generated']
            respond(success: false, error: "Tickets wurden bereits für diese Bestellung generiert")
            return
        end
        
        # Mark tickets as generated
        neo4j_query(<<~END_OF_QUERY, {order_id: order_id, generated_at: DateTime.now.to_s, generated_by: @session_user[:email]})
            MATCH (o:TicketOrder {id: $order_id})
            SET o.tickets_generated = true, o.tickets_generated_at = $generated_at, o.tickets_generated_by = $generated_by
        END_OF_QUERY
        
        respond(success: true, message: "Tickets wurden erfolgreich generiert und freigegeben")
        log("Tickets wurden für Bestellung #{order_id} generiert")
    end

    # Download individual ticket PDF (requires tickets to be generated)
    get "/api/download_ticket/:order_id/:ticket_number" do
        require_user!
        
        order_id = params[:order_id]
        ticket_number = params[:ticket_number].to_i
        
        unless order_id && !order_id.empty? && ticket_number > 0
            respond(success: false, error: "Ungültige Parameter")
            return
        end
        
        # Check if user can access this order (admin or order owner)
        order_user_email = neo4j_query_expect_one(<<~END_OF_QUERY, {order_id: order_id})['user_email']
            MATCH (u:User)-[:PLACED]->(o:TicketOrder {id: $order_id})
            RETURN u.email AS user_email
        END_OF_QUERY
        
        is_admin = user_has_permission?("manage_orders")
        is_order_owner = @session_user[:email] == order_user_email
        
        unless is_admin || is_order_owner
            respond(success: false, error: "Keine Berechtigung für diese Bestellung")
            return
        end
        
        # Check if user ticket downloads are allowed (admins can always download)
        unless is_admin || ALLOW_USER_TICKET_DOWNLOAD
            respond(success: false, error: "Ticket-Download ist derzeit nicht verfügbar")
            return
        end
        
        # Get order and participant details
        order_result = neo4j_query(<<~END_OF_QUERY, {order_id: order_id, ticket_number: ticket_number})
            MATCH (u:User)-[:PLACED]->(o:TicketOrder {id: $order_id})
            MATCH (o)-[:INCLUDES]->(p:Participant {ticket_number: $ticket_number})
            MATCH (o)-[:FOR]->(e:Event)
            RETURN u.name AS user_name,
                   u.email AS user_email,
                   o.id AS order_id,
                   o.payment_reference AS payment_reference,
                   o.status AS status,
                   o.tickets_generated AS tickets_generated,
                   p.name AS participant_name,
                   p.phone AS participant_phone,
                   p.email AS participant_email,
                   p.birthdate AS participant_birthdate,
                   p.ticket_number AS participant_ticket_number,
                   e.start_datetime AS event_start_datetime
        END_OF_QUERY
        
        if order_result.empty?
            respond(success: false, error: "Ticket nicht gefunden")
            return
        end
        
        order_data = order_result.first
        
        unless order_data['status'] == 'paid'
            respond(success: false, error: "Tickets sind nur für bezahlte Bestellungen verfügbar")
            return
        end
        
        unless order_data['tickets_generated']
            respond(success: false, error: "Tickets wurden noch nicht freigegeben")
            return
        end
        
        # Prepare participant data
        participant = {
            'name' => order_data['participant_name'],
            'phone' => order_data['participant_phone'],
            'email' => order_data['participant_email'],
            'birthdate' => order_data['participant_birthdate'],
            'ticket_number' => order_data['participant_ticket_number']
        }
        
        # Prepare order data with event info
        order_info = {
            'order_id' => order_data['order_id'],
            'payment_reference' => order_data['payment_reference'],
            'event_start_datetime' => order_data['event_start_datetime']
        }
        
        # Generate individual ticket PDF
        pdf_content = generate_ticket_pdf_content(order_info, participant)
        
        respond_raw_with_mimetype_and_filename(
            pdf_content,
            'application/pdf',
            "Ticket_#{order_data['payment_reference']}_#{ticket_number}.pdf"
        )
    end

    # Quick payment search by reference
    post "/api/search_payment_reference" do
        require_user_with_permission!("manage_orders")
        data = parse_request_data(required_keys: [:payment_reference])
        
        payment_ref = data[:payment_reference].strip.upcase
        
        # Search for order with matching payment reference
        orders = neo4j_query(<<~END_OF_QUERY, {payment_ref: payment_ref})
            MATCH (u:User)-[:PLACED]->(o:TicketOrder {payment_reference: $payment_ref})
            RETURN u.name AS user_name,
                   u.email AS user_email,
                   o.id AS order_id,
                   o.ticket_count AS ticket_count,
                   o.total_price AS total_price,
                   o.individual_ticket_price AS individual_ticket_price,
                   o.payment_reference AS payment_reference,
                   o.status AS status,
                   o.created_at AS created_at,
                   o.paid_at AS paid_at
        END_OF_QUERY
        
        if orders.empty?
            respond(success: false, error: "Keine Bestellung mit Verwendungszweck '#{payment_ref}' gefunden")
        else
            order = orders.first
            respond(success: true, order: order)
        end
    end

    # Quick payment mark as paid
    post "/api/quick_mark_paid" do
        require_user_with_permission!("manage_orders")
        data = parse_request_data(required_keys: [:payment_reference])
        
        payment_ref = data[:payment_reference].strip.upcase
        
        # Mark order as paid
        result = neo4j_query(<<~END_OF_QUERY, {payment_ref: payment_ref, date: Date.today.to_s})
            MATCH (o:TicketOrder {payment_reference: $payment_ref})
            SET o.status = 'paid', o.paid_at = $date
            RETURN o.id AS order_id
        END_OF_QUERY
        
        if result.empty?
            respond(success: false, error: "Bestellung nicht gefunden")
        else
            log("Bestellung #{result.first['order_id']} über Quick Payment als bezahlt markiert (Ref: #{payment_ref})")
            respond(success: true)
        end
    end

    # Mark payment as error
    post "/api/mark_payment_error" do
        require_user_with_permission!("manage_orders")
        data = parse_request_data(required_keys: [:payment_reference])
        
        payment_ref = data[:payment_reference].strip.upcase
        
        # Create error record - we'll create a new TicketOrder with error status
        error_params = {
            order_id: RandomTag::generate(8),
            payment_ref: payment_ref,
            status: 'error',
            created_at: DateTime.now.to_s,
            error_reason: 'Verwendungszweck nicht gefunden'
        }
        
        neo4j_query(<<~END_OF_QUERY, error_params)
            CREATE (o:TicketOrder {
                id: $order_id,
                ticket_count: 0,
                total_price: 0,
                individual_ticket_price: 0,
                payment_reference: $payment_ref,
                status: $status,
                created_at: $created_at,
                error_reason: $error_reason
            })
        END_OF_QUERY
        
        log("Fehlerhafter Zahlungseingang markiert (Ref: #{payment_ref})")
        respond(success: true)
    end

    private

    def generate_pdf_content(orders)
        Prawn::Document.new(page_size: 'A4', margin: [50, 50, 50, 50]) do |pdf|
            # Title
            pdf.text "#{EVENT_NAME} - Bestellübersicht", size: 20, style: :bold, align: :center
            pdf.text "Erstellt am: #{Date.today.strftime('%d.%m.%Y')}", size: 12, align: :center
            pdf.move_down 20
            
            # Statistics section
            pdf.text "Statistiken", size: 16, style: :bold
            pdf.move_down 10
            
            total_tickets_sold = orders.select { |o| o['status'] == 'paid' }.sum { |o| o['ticket_count'] || 0 }
            tickets_available = MAX_TICKETS_GLOBAL - total_tickets_sold
            total_revenue = orders.select { |o| o['status'] == 'paid' }.sum { |o| o['total_price']&.to_f || 0.0 }
            paid_orders = orders.count { |o| o['status'] == 'paid' }
            pending_orders = orders.count { |o| o['status'] == 'pending' }
            
            stats_data = [
                ['Verkaufte Tickets:', total_tickets_sold.to_s],
                ['Verfügbare Tickets:', tickets_available.to_s],
                ['Gesamtumsatz:', "#{total_revenue.round(2)}€"],
                ['Bezahlte Bestellungen:', paid_orders.to_s],
                ['Ausstehende Bestellungen:', pending_orders.to_s]
            ]
            
            pdf.table(stats_data, width: pdf.bounds.width / 2) do
                row(0..-1).border_width = 0
                column(0).font_style = :bold
                column(0).width = 150
            end
            
            pdf.move_down 30
            
            # Orders table
            pdf.text "Bestellungen", size: 16, style: :bold
            pdf.move_down 10
            
            if orders.any?
                table_data = [['Benutzer', 'Status', 'Tickets', 'Preis', 'Bestellt am', 'Bezahlt am']]
                
                orders.each do |order|
                    status_text = order['status'] == 'paid' ? 'Bezahlt' : 'Ausstehend'
                    created_date = order['created_at'] ? Date.parse(order['created_at']).strftime('%d.%m.%Y') : '-'
                    paid_date = order['paid_at'] ? Date.parse(order['paid_at']).strftime('%d.%m.%Y') : '-'
                    
                    table_data << [
                        order['user_name'] || '-',
                        status_text,
                        (order['ticket_count'] || 0).to_s,
                        "#{(order['total_price']&.to_f || 0.0).round(2)}€",
                        created_date,
                        paid_date
                    ]
                end
                
                pdf.table(table_data, header: true, width: pdf.bounds.width) do
                    row(0).font_style = :bold
                    self.row_colors = ['FFFFFF', 'F7F7F7']
                    self.header = true
                end
            else
                pdf.text "Keine Bestellungen vorhanden.", style: :italic
            end
            
            # Footer
            pdf.number_pages "<page> / <total>", at: [pdf.bounds.right - 50, 0], align: :right, size: 10
        end.render
    end

    # Generate order confirmation PDF (proof of order only, no QR codes or security features)
    def generate_order_confirmation_pdf_content(order)
        Prawn::Document.new(page_size: 'A4', margin: [50, 50, 50, 50]) do |pdf|
            # Title
            pdf.text "#{EVENT_NAME} - Bestellbestätigung", size: 20, style: :bold, align: :center
            pdf.text "Bestätigung für Ihre Ticket-Bestellung", size: 12, align: :center, style: :italic
            pdf.move_down 30
            
            # Order information
            pdf.text "Bestellinformationen", size: 16, style: :bold
            pdf.move_down 10
            
            order_data = [
                ['Bestellnummer:', order['payment_reference'] || '-'],
                ['Status:', order['status'] == 'paid' ? 'Bezahlt' : 'Ausstehend'],
                ['Anzahl Tickets:', (order['ticket_count'] || 0).to_s],
                ['Gesamtpreis:', "#{(order['total_price']&.to_f || 0.0).round(2)}€"],
                ['Bestellt am:', order['created_at'] ? Date.parse(order['created_at']).strftime('%d.%m.%Y') : '-'],
                ['Bezahlt am:', order['paid_at'] ? Date.parse(order['paid_at']).strftime('%d.%m.%Y') : '-']
            ]
            
            pdf.table(order_data, width: pdf.bounds.width) do
                row(0..-1).border_width = 0
                column(0).font_style = :bold
                column(0).width = 150
            end
            
            pdf.move_down 30
            
            # Customer information
            pdf.text "Kundendaten", size: 16, style: :bold
            pdf.move_down 10
            
            customer_data = [
                ['Name:', order['user_name'] || '-'],
                ['E-Mail:', order['user_email'] || '-'],
                ['Adresse:', order['user_address'] || '-'],
                ['Telefon:', order['user_phone'] || '-']
            ]
            
            pdf.table(customer_data, width: pdf.bounds.width) do
                row(0..-1).border_width = 0
                column(0).font_style = :bold
                column(0).width = 150
            end
            
            pdf.move_down 30
            
            # Participants
            if order['participants'] && order['participants'].any? { |p| p['name'] && !p['name'].empty? }
                pdf.text "Teilnehmer", size: 16, style: :bold
                pdf.move_down 10
                
                participant_data = [['Ticket #', 'Name', 'Telefon', 'E-Mail']]
                order['participants'].each do |participant|
                    next if participant['name'].nil? || participant['name'].empty?
                    participant_data << [
                        participant['ticket_number'].to_s,
                        participant['name'],
                        participant['phone'] || '-',
                        participant['email'] || '-'
                    ]
                end
                
                pdf.table(participant_data, header: true, width: pdf.bounds.width) do
                    row(0).font_style = :bold
                    self.row_colors = ['FFFFFF', 'F7F7F7']
                    self.header = true
                end
            end
            
            # Payment information if not paid
            if order['status'] != 'paid'
                pdf.move_down 30
                pdf.text "Zahlungsinformationen", size: 16, style: :bold
                pdf.move_down 10

                if order['bank_account_name'] && !order['bank_account_name'].empty?
                    pdf.text "Bitte überweisen Sie den Betrag von #{(order['total_price']&.to_f || 0.0).round(2)}€ auf folgendes Konto:"
                    pdf.move_down 5
                    
                    payment_data = [
                        ['Empfänger:', order['bank_account_name']],
                        ['Bank:', order['bank_name']],
                        ['IBAN:', order['bank_iban']],
                        ['BIC:', order['bank_bic']],
                        ['Verwendungszweck:', order['payment_reference'] || '-']
                    ]
                    
                    pdf.table(payment_data, width: pdf.bounds.width) do
                        row(0..-1).border_width = 0
                        column(0).font_style = :bold
                        column(0).width = 150
                    end
                else
                    pdf.text "Die Zahlungsdetails werden Ihnen separat mitgeteilt."
                    pdf.move_down 5
                    pdf.text "Bitte verwenden Sie die Bestellnummer #{order['payment_reference']} als Verwendungszweck."
                end
            end
            
            # Important notice for order confirmation
            pdf.move_down 30
            pdf.text "Wichtige Hinweise:", size: 12, style: :bold
            pdf.text "• Dies ist eine Bestellbestätigung und dient nur als Nachweis Ihrer Bestellung", size: 9
            pdf.text "• Die eigentlichen Tickets werden separat nach Genehmigung durch die Veranstaltungsleitung erstellt", size: 9
            pdf.text "• Bei Fragen wenden Sie sich an den Support", size: 9
            
            # Footer
            pdf.number_pages "<page> / <total>", at: [pdf.bounds.right - 50, 0], align: :right, size: 10
        end.render
    end

    # Generate individual ticket PDFs with QR codes and security features (only after approval)
    def generate_ticket_pdf_content(order, participant)
        # Generate unique security ID for this ticket PDF
        security_id = SecureRandom.hex(8).upcase
        
        Prawn::Document.new(page_size: 'A4', margin: [50, 50, 50, 50]) do |pdf|
            # Add watermark
            pdf.transparent(0.1) do
                pdf.rotate(45, origin: [pdf.bounds.width/2, pdf.bounds.height/2]) do
                    pdf.draw_text "#{EVENT_NAME} - ORIGINAL TICKET", 
                                  at: [pdf.bounds.width/2 - 120, pdf.bounds.height/2], 
                                  size: 36, style: :bold
                end
            end
            
            # Title with security ID and age badge
            pdf.text "#{EVENT_NAME} - Ticket", size: 24, style: :bold, align: :center
            
            # Calculate and display age badge if birthdate is available
            if participant['birthdate'] && !participant['birthdate'].empty?
                # Get reference date from event start or today
                reference_date = nil
                if order['event_start_datetime'] && !order['event_start_datetime'].empty?
                    begin
                        reference_date = DateTime.parse(order['event_start_datetime']).to_date
                    rescue ArgumentError
                        reference_date = Date.today
                    end
                else
                    reference_date = Date.today
                end
                
                age_category = get_age_category(participant['birthdate'], reference_date)
                if age_category
                    # Display age badge in header with high contrast
                    pdf.fill_color '000000'  # Black
                    pdf.stroke_color '000000'
                    pdf.line_width 2
                    
                    # Create a box for the age badge
                    badge_width = 50
                    badge_height = 20
                    badge_x = pdf.bounds.right - badge_width - 10
                    badge_y = pdf.cursor - 10
                    
                    pdf.stroke_rectangle [badge_x, badge_y], badge_width, badge_height
                    pdf.fill_rectangle [badge_x, badge_y], badge_width, badge_height
                    
                    # White text on black background for high contrast
                    pdf.fill_color 'FFFFFF'
                    pdf.text_box age_category,
                        at: [badge_x, badge_y],
                        width: badge_width,
                        height: badge_height,
                        align: :center,
                        valign: :center,
                        size: 12,
                        style: :bold
                    
                    # Reset colors
                    pdf.fill_color '000000'
                    pdf.stroke_color '000000'
                end
            end
            
            pdf.text "Ticket-ID: #{security_id}", size: 10, align: :center, style: :italic
            pdf.move_down 40
            
            # Generate unique QR data for this ticket
            qr_data = {
                order_id: order['order_id'],
                ticket_number: participant['ticket_number'],
                participant_name: participant['name'],
                event: EVENT_NAME,
                security_id: security_id,
                verification_hash: Digest::SHA256.hexdigest("#{order['order_id']}-#{participant['ticket_number']}-#{security_id}")
            }.to_json
            
            # Large QR code for ticket verification
            pdf.text "Ticket QR-Code", size: 18, style: :bold, align: :center
            pdf.move_down 20
            pdf.print_qr_code(qr_data, extent: 170 , align: :center)

            
            pdf.move_down 100
            
            # Ticket information
            pdf.text "Ticket-Informationen", size: 16, style: :bold, align: :center
            pdf.move_down 15
            
            ticket_data = [
                ['Ticket Nummer:', participant['ticket_number'].to_s],
                ['Name:', participant['name']],
                ['Telefon:', participant['phone'] || '-'],
                ['E-Mail:', participant['email'] || '-'],
                ['Event:', EVENT_NAME],
                ['Bestellnummer:', order['payment_reference'] || '-'],
                ['Status:', 'Gültig']
            ]
            
            pdf.table(ticket_data, width: pdf.bounds.width, position: :center) do
                row(0..-1).border_width = 1
                column(0).font_style = :bold
                column(0).width = 150
                self.row_colors = ['FFFFFF', 'F7F7F7']
            end
            
            pdf.move_down 30
            
            # Security footer for tickets
            pdf.text "Sicherheitshinweise:", size: 12, style: :bold
            pdf.text "• Dieses Ticket wurde nach Genehmigung durch die Veranstaltungsleitung erstellt", size: 9
            pdf.text "• Ticket-ID: #{security_id} - Bei Verdacht auf Fälschung kontaktieren Sie den Support", size: 9
            pdf.text "• Der QR-Code dient zur Verifizierung am Eingang und enthält verschlüsselte Daten", size: 9
            pdf.text "• Dieses Ticket ist nur in Verbindung mit einem gültigen Ausweis gültig", size: 9
            
            # Footer
            pdf.number_pages "Ticket <page> / <total>", at: [pdf.bounds.right - 50, 0], align: :right, size: 10
        end.render
    end

    # Send order confirmation email
    # Send order received confirmation email (without payment details)
    # This is sent immediately when an order is placed
    def send_order_received_email(user_email, order_id, payment_ref, event, participants, total_price)
        # Get user details
        user_result = neo4j_query(<<~END_OF_QUERY, {email: user_email})
            MATCH (u:User {email: $email})
            RETURN u.name AS name
        END_OF_QUERY
        
        user_name = user_result.first&.dig('name') || 'Liebe/r Nutzer/in'
        
        deliver_mail do
            to user_email
            from SMTP_FROM
            subject "Bestellung eingegangen - #{event[:name]}"
            
            content = StringIO.open do |io|
                io.puts "            <div class=\"success-badge\">"
                io.puts "                <strong>Bestellung erfolgreich eingegangen!</strong>"
                io.puts "            </div>"
                io.puts "            <p>Hallo #{user_name},</p>"
                io.puts "            <p>vielen Dank für deine Ticket-Bestellung für #{event[:name]}. Deine Tickets sind reserviert.</p>"
                io.puts "            <div class=\"order-details\">"
                io.puts "                <h3>Bestelldetails</h3>"
                io.puts "                <p><strong>Bestellnummer:</strong> #{payment_ref}</p>"
                io.puts "                <p><strong>Event:</strong> #{event[:name]}</p>"
                io.puts "                <p><strong>Anzahl Tickets:</strong> #{participants.length}</p>"
                io.puts "                <p><strong>Gesamtpreis:</strong> #{total_price.round(2)}€</p>"
                io.puts "                <p><strong>Status:</strong> Tickets reserviert</p>"
                io.puts "                <p><strong>Datum:</strong> #{DateTime.now.strftime('%d.%m.%Y %H:%M')}</p>"
                io.puts "            </div>"
                io.puts "            <div class=\"participants\">"
                io.puts "                <h4>Teilnehmer:</h4>"
                participants.each_with_index do |participant, index|
                    contact_info = [participant['phone'], participant['email']].compact.reject(&:empty?).join(', ')
                    io.puts "                <div class=\"participant\">#{index + 1}. #{participant['name']}#{contact_info.empty? ? '' : ' (' + contact_info + ')'}</div>"
                end
                io.puts "            </div>"
                io.puts "            <div class=\"info-badge\">"
                io.puts "                <strong>Nächste Schritte:</strong>"
                io.puts "                <p>Du erhältst in Kürze eine separate E-Mail mit den Zahlungsinformationen. Deine Tickets werden nach Eingang der Zahlung final bestätigt.</p>"
                io.puts "            </div>"
                io.puts "            <p><a href=\"#{WEB_ROOT}/tickets\" class=\"btn\">Meine Bestellungen ansehen</a></p>"
                io.puts "            <p>Bei Fragen wende dich gerne an unseren Support.</p>"
                io.string
            end
            
            format_email_with_template("Bestellung eingegangen", content)
        end
        log("Bestelleingang für Bestellung #{order_id} versendet")
    rescue => e
        log("Bestelleingang für Bestellung #{order_id} fehlgeschlagen: #{e.message}")
    end

    # Send payment request email with bank account details and QR code
    # This is sent when a payment request is explicitly sent for an order
    def send_order_confirmation_email(user_email, order_id, payment_ref, event, participants, total_price)
        puts event
        # Get user details
        user_result = neo4j_query(<<~END_OF_QUERY, {email: user_email})
            MATCH (u:User {email: $email})
            RETURN u.name AS name
        END_OF_QUERY
        
        user_name = user_result.first&.dig('name') || 'Liebe/r Nutzer/in'
        
        # Get bank account details from the order
        bank_account_result = neo4j_query(<<~END_OF_QUERY, {order_id: order_id})
            MATCH (o:TicketOrder {id: $order_id})-[:USES_ACCOUNT]->(b:BankAccount)
            RETURN b.account_name AS account_name, b.bank_name AS bank_name,
                   b.iban AS iban, b.bic AS bic
        END_OF_QUERY
        
        # Use bank account from order, or show a message if no account is configured
        if bank_account_result.empty?
            bank_info = nil
            qr_code_data_uri = nil
        else
            bank_account = bank_account_result.first
            bank_info = {
                account_name: bank_account['account_name'],
                bank_name: bank_account['bank_name'],
                iban: bank_account['iban'],
                bic: bank_account['bic']
            }
            
            # Generate QR code for payment
            begin
                require 'rqrcode'
                epc_data = generate_epc_qr_data(
                    bank_info[:account_name],
                    bank_info[:iban],
                    bank_info[:bic],
                    total_price,
                    payment_ref
                )
                qr = RQRCode::QRCode.new(epc_data)
                png = qr.as_png(
                    resize_gte_to: false,
                    resize_exactly_to: false,
                    fill: 'white',
                    color: 'black',
                    size: 300,
                    border_modules: 4
                )
                qr_code_data_uri = "data:image/png;base64,#{Base64.strict_encode64(png.to_s)}"
            rescue => e
                debug_error("Failed to generate QR code for email: #{e.message}")
                qr_code_data_uri = nil
            end
        end
        
        deliver_mail do
            to user_email
            from SMTP_FROM
            subject "Bestellbestätigung - #{event[:name]}"
            
            content = StringIO.open do |io|
                io.puts "            <div class=\"success-badge\">"
                io.puts "                <strong>Bestellung erfolgreich aufgegeben!</strong>"
                io.puts "            </div>"
                io.puts "            <p>Hallo #{user_name},</p>"
                io.puts "            <p>vielen Dank für deine Ticket-Bestellung für #{event[:name]}. Hier sind die Details deiner Bestellung:</p>"
                io.puts "            <div class=\"order-details\">"
                io.puts "                <h3>Bestelldetails</h3>"
                io.puts "                <p><strong>Bestellnummer:</strong> #{payment_ref}</p>"
                io.puts "                <p><strong>Event:</strong> #{event[:name]}</p>"
                io.puts "                <p><strong>Anzahl Tickets:</strong> #{participants.length}</p>"
                io.puts "                <p><strong>Gesamtpreis:</strong> #{total_price.round(2)}€</p>"
                io.puts "                <p><strong>Status:</strong> Ausstehend</p>"
                io.puts "                <p><strong>Datum:</strong> #{DateTime.now.strftime('%d.%m.%Y %H:%M')}</p>"
                io.puts "            </div>"
                io.puts "            <div class=\"participants\">"
                io.puts "                <h4>Teilnehmer:</h4>"
                participants.each_with_index do |participant, index|
                    contact_info = [participant['phone'], participant['email']].compact.reject(&:empty?).join(', ')
                    io.puts "                <div class=\"participant\">#{index + 1}. #{participant['name']}#{contact_info.empty? ? '' : ' (' + contact_info + ')'}</div>"
                end
                io.puts "            </div>"
                io.puts "            <h4>Nächste Schritte:</h4>"
                io.puts "            <ol>"
                if bank_info
                    io.puts "                <li>Überweise den Betrag von <strong>#{total_price.round(2)}€</strong> auf folgendes Konto:</li>"
                    io.puts "                <ul>"
                    io.puts "                    <li><strong>Empfänger:</strong> #{bank_info[:account_name]}</li>"
                    io.puts "                    <li><strong>Bank:</strong> #{bank_info[:bank_name]}</li>"
                    io.puts "                    <li><strong>IBAN:</strong> #{bank_info[:iban]}</li>"
                    io.puts "                    <li><strong>BIC:</strong> #{bank_info[:bic]}</li>"
                    io.puts "                    <li><strong>Verwendungszweck:</strong> #{payment_ref}</li>"
                    io.puts "                </ul>"
                    
                    # Add QR code if available
                    if qr_code_data_uri
                        io.puts "                <div style='margin: 20px 0; padding: 15px; background-color: #f8f9fa; border-radius: 5px;'>"
                        io.puts "                    <h4 style='margin-top: 0;'>Schnelle Zahlung mit QR-Code</h4>"
                        io.puts "                    <p>Scanne diesen QR-Code mit deiner Banking-App, um die Überweisung automatisch auszufüllen:</p>"
                        io.puts "                    <div style='text-align: center; margin: 15px 0;'>"
                        io.puts "                        <img src='#{qr_code_data_uri}' alt='Payment QR Code' style='max-width: 300px; width: 100%; height: auto;' />"
                        io.puts "                    </div>"
                        io.puts "                    <p style='font-size: 0.9em; color: #666;'>"
                        io.puts "                        <strong>Hinweis:</strong> Dieser QR-Code enthält alle Zahlungsinformationen (Empfänger, IBAN, BIC, Betrag und Verwendungszweck). "
                        io.puts "                        Die meisten modernen Banking-Apps können diesen Code scannen und das Überweisungsformular automatisch ausfüllen."
                        io.puts "                    </p>"
                        io.puts "                </div>"
                    end
                    
                    io.puts "                <li>Nach Zahlungseingang wird deine Bestellung vom Team als \"Bezahlt\" markiert</li>"
                else
                    io.puts "                <li>Die Zahlungsdetails werden dir separat mitgeteilt</li>"
                    io.puts "                <li>Bitte verwende die Bestellnummer <strong>#{payment_ref}</strong> als Verwendungszweck</li>"
                end
                io.puts "                <li>Du kannst den Status jederzeit in deinem Account überprüfen</li>"
                io.puts "            </ol>"
                io.puts "            <p><a href=\"#{WEB_ROOT}/tickets\" class=\"btn\">Meine Bestellungen ansehen</a></p>"
                io.puts "            <p>Bei Fragen wende dich gerne an unseren Support.</p>"
                io.string
            end
            
            format_email_with_template("Bestellbestätigung", content)
        end
        log("Bestellbestätigung für Bestellung #{order_id} versendet")
    rescue => e
        log("Bestellbestätigung für Bestellung #{order_id} fehlgeschlagen: #{e.message}")
    end
    
    get "/api/export_guest_list_csv/:event_id" do
        require_user_with_permission!("view_users")
        event_id = params[:event_id]
        
        # Get event details
        event = neo4j_query_expect_one(<<~END_OF_QUERY, {event_id: event_id})
            MATCH (e:Event {id: $event_id})
            RETURN e.name AS name, e.year AS year
        END_OF_QUERY
        
        # Get all paid participants for this event
        participants = neo4j_query(<<~END_OF_QUERY, {event_id: event_id})
            MATCH (e:Event {id: $event_id})<-[:FOR]-(o:TicketOrder)-[:INCLUDES]->(p:Participant)
            MATCH (u:User)-[:PLACED]->(o)
            WHERE o.status = 'paid'
            RETURN p.name AS participant_name,
                   p.phone AS participant_phone,
                   p.email AS participant_email,
                   p.ticket_number AS ticket_number,
                   u.email AS user_email,
                   u.name AS user_name,
                   o.payment_reference AS payment_reference,
                   o.created_at AS order_date,
                   o.total_price AS total_price
            ORDER BY p.name ASC
        END_OF_QUERY
        
        # Generate CSV content
        csv_content = "Name,Telefon,E-Mail,Ticket-Nr,Besteller E-Mail,Besteller Name,Zahlungsreferenz,Bestelldatum,Preis\n"
        participants.each do |participant|
            order_date = DateTime.parse(participant['order_date']).strftime('%d.%m.%Y')
            csv_content += "\"#{participant['participant_name']}\","
            csv_content += "\"#{participant['participant_phone'] || ''}\","
            csv_content += "\"#{participant['participant_email'] || ''}\","
            csv_content += "\"#{participant['ticket_number']}\","
            csv_content += "\"#{participant['user_email']}\","
            csv_content += "\"#{participant['user_name']}\","
            csv_content += "\"#{participant['payment_reference']}\","
            csv_content += "\"#{order_date}\","
            csv_content += "\"#{(participant['total_price']&.to_f || 0.0).round(2)}€\"\n"
        end
        
        filename = "Gaesteliste_#{event['name'].gsub(/[^a-zA-Z0-9]/, '_')}_#{Date.today.strftime('%Y%m%d')}.csv"
        respond_raw_with_mimetype_and_filename(csv_content, 'text/csv', filename)
    end
    
    # Export guest list as PDF
    get "/api/export_guest_list_pdf/:event_id" do
        require_user_with_permission!("view_users")
        event_id = params[:event_id]
        
        # Get event details
        event = neo4j_query_expect_one(<<~END_OF_QUERY, {event_id: event_id})
            MATCH (e:Event {id: $event_id})
            RETURN e.name AS name, e.year AS year, e.location AS location, e.start_datetime AS start_datetime
        END_OF_QUERY
        
        # Get all paid participants for this event
        participants = neo4j_query(<<~END_OF_QUERY, {event_id: event_id})
            MATCH (e:Event {id: $event_id})<-[:FOR]-(o:TicketOrder)-[:INCLUDES]->(p:Participant)
            MATCH (u:User)-[:PLACED]->(o)
            WHERE o.status = 'paid'
            RETURN p.name AS participant_name,
                   p.phone AS participant_phone,
                   p.email AS participant_email,
                   p.ticket_number AS ticket_number,
                   u.email AS user_email,
                   u.name AS user_name,
                   o.payment_reference AS payment_reference
            ORDER BY p.name ASC
        END_OF_QUERY
        
        pdf_content = generate_guest_list_pdf(event, participants)
        filename = "Gaesteliste_#{event['name'].gsub(/[^a-zA-Z0-9]/, '_')}_#{Date.today.strftime('%Y%m%d')}.pdf"
        respond_raw_with_mimetype_and_filename(pdf_content, 'application/pdf', filename)
    end
    
    # Generate guest list PDF
    def generate_guest_list_pdf(event, participants)
        Prawn::Document.new(page_size: 'A4', margin: [50, 50, 50, 50]) do |pdf|
            # Title section
            pdf.text "#{event['name']} - Gästeliste", size: 20, style: :bold, align: :center
            pdf.move_down 10
            
            # Event details
            if event['location']
                pdf.text "Veranstaltungsort: #{event['location']}", size: 12, align: :center
            end
            if event['start_datetime']
                event_date = DateTime.parse(event['start_datetime']).strftime('%d.%m.%Y %H:%M')
                pdf.text "Datum: #{event_date}", size: 12, align: :center
            end
            pdf.text "Erstellt am: #{Date.today.strftime('%d.%m.%Y')}", size: 10, align: :center, style: :italic
            pdf.move_down 30
            
            # Statistics
            pdf.text "Statistiken", size: 16, style: :bold
            pdf.move_down 10
            pdf.text "Anzahl Teilnehmer: #{participants.length}", size: 12
            pdf.move_down 20
            
            # Participants table
            pdf.text "Teilnehmerliste", size: 16, style: :bold
            pdf.move_down 10
            
            if participants.any?
                table_data = [['Nr.', 'Name', 'Telefon', 'E-Mail', 'Besteller']]
                participants.each_with_index do |participant, index|
                    table_data << [
                        (index + 1).to_s,
                        participant['participant_name'] || '',
                        participant['participant_phone'] || '',
                        participant['participant_email'] || '',
                        participant['user_name'] || participant['user_email']
                    ]
                end
                
                pdf.table table_data, {
                    header: true,
                    width: pdf.bounds.width,
                    cell_style: { size: 9, padding: [4, 4, 4, 4] },
                    column_widths: [30, 130, 90, 130, 130]
                } do
                    row(0).font_style = :bold
                    row(0).background_color = 'f0f0f0'
                    cells.borders = [:top, :bottom, :left, :right]
                    cells.border_width = 0.5
                end
            else
                pdf.text "Keine Teilnehmer gefunden.", size: 12, style: :italic
            end
            
            # Footer
            pdf.move_down 30
            pdf.text "Diese Liste wurde automatisch generiert und enthält nur bestätigte, bezahlte Teilnehmer.", 
                     size: 10, style: :italic, align: :center
            
            # Page numbers
            pdf.number_pages "Seite <page> von <total>", at: [pdf.bounds.right - 50, 0], align: :right, size: 10
        end.render
    end

    # Check if ticket downloads are allowed for users
    post "/api/ticket_download_settings" do
        require_user!
        
        is_admin = user_has_permission?("view_users") || user_has_permission?("manage_orders")
        download_allowed = is_admin || ALLOW_USER_TICKET_DOWNLOAD
        
        # Order confirmation PDFs are always available to order owners
        order_confirmation_allowed = true
        
        respond(success: true, 
                download_allowed: download_allowed, 
                order_confirmation_allowed: order_confirmation_allowed,
                is_admin: is_admin)
    end

    # Check ticket generation status for a specific order
    get "/api/order_ticket_status/:order_id" do
        require_user!
        
        order_id = params[:order_id]
        unless order_id && !order_id.empty?
            respond(success: false, error: "Ungültige Bestell-ID")
            return
        end
        
        # Check if user can access this order (admin or order owner)
        order_result = neo4j_query(<<~END_OF_QUERY, {order_id: order_id})
            MATCH (u:User)-[:PLACED]->(o:TicketOrder {id: $order_id})
            RETURN u.email AS user_email, 
                   o.status AS status, 
                   o.tickets_generated AS tickets_generated,
                   o.tickets_generated_at AS tickets_generated_at
        END_OF_QUERY
        
        if order_result.empty?
            respond(success: false, error: "Bestellung nicht gefunden")
            return
        end
        
        order_data = order_result.first
        is_admin = user_has_permission?("manage_orders")
        is_order_owner = @session_user[:email] == order_data['user_email']
        
        unless is_admin || is_order_owner
            respond(success: false, error: "Keine Berechtigung für diese Bestellung")
            return
        end
        
        respond(success: true, 
                order_status: order_data['status'],
                tickets_generated: !!order_data['tickets_generated'],
                tickets_generated_at: order_data['tickets_generated_at'],
                can_download_tickets: order_data['status'] == 'paid' && !!order_data['tickets_generated'])
    end

    # Toggle ticket download setting (admin only)
    post "/api/toggle_ticket_download_setting" do
        require_user_with_permission!("admin")
        data = parse_request_data(required_keys: [:allow_download])
        
        # Note: This endpoint exists to inform the admin about the current setting
        # The actual setting needs to be changed in the credentials.rb file
        # This is just for informational purposes and future database-based configuration
        
        respond(success: true, 
               message: "Ticket-Download-Einstellung muss in der Konfigurationsdatei (credentials.rb) geändert werden",
               current_setting: ALLOW_USER_TICKET_DOWNLOAD)
    end

    # Get user's tickets for download
    post "/api/get_user_tickets" do
        require_user!
        
        user_email = @session_user[:email]
        
        # Get all orders by the user with generated tickets
        tickets = neo4j_query(<<~END_OF_QUERY, {user_email: user_email})
            MATCH (u:User {email: $user_email})-[:PLACED]->(o:TicketOrder)-[:FOR]->(e:Event)
            WHERE o.status = 'paid' AND o.tickets_generated = true
            MATCH (o)-[:INCLUDES]->(p:Participant)
            RETURN e.id AS event_id,
                   e.name AS event_name,
                   e.location AS event_location,
                   e.start_datetime AS event_start_datetime,
                   o.id AS order_id,
                   o.payment_reference AS payment_reference,
                   o.created_at AS order_date,
                   COLLECT({
                       name: p.name,
                       phone: p.phone,
                       email: p.email,
                       birthdate: p.birthdate,
                       ticket_number: p.ticket_number
                   }) AS participants
            ORDER BY e.start_datetime DESC, o.created_at DESC
        END_OF_QUERY
        
        respond(success: true, tickets: tickets)
    end

    # Bulk generate tickets for all orders of an event (admin only)
    post "/api/bulk_generate_tickets_for_event" do
        require_user_with_permission!("manage_orders")
        data = parse_request_data(required_keys: [:event_id])
        
        event_id = data[:event_id]
        
        # Get all paid orders for this event that don't have tickets generated yet
        orders = neo4j_query(<<~END_OF_QUERY, {event_id: event_id})
            MATCH (o:TicketOrder)-[:FOR]->(e:Event {id: $event_id})
            WHERE o.status = 'paid' AND (o.tickets_generated IS NULL OR o.tickets_generated = false)
            RETURN o.id AS order_id
        END_OF_QUERY
        
        generated_count = 0
        orders.each do |order|
            # Generate tickets for each order
            order_id = order['order_id']
            generated_at = DateTime.now.to_s
            generated_by = @session_user[:email]
            
            neo4j_query(<<~END_OF_QUERY, {order_id: order_id, generated_at: generated_at, generated_by: generated_by})
                MATCH (o:TicketOrder {id: $order_id})
                SET o.tickets_generated = true, o.tickets_generated_at = $generated_at, o.tickets_generated_by = $generated_by
            END_OF_QUERY
            
            generated_count += 1
        end
        
        respond(success: true, message: "Tickets für #{generated_count} Bestellungen wurden generiert und freigegeben")
        log("Ticket Generierung für Event #{event_id}: #{generated_count} Bestellungen bearbeitet")
    end

    # Scan and validate a ticket
    post "/api/scan_ticket" do
        require_user_with_permission!("manage_orders")
        data = parse_request_data(
            required_keys: [:qr_data],
            optional_keys: [:auto_redeem],
            max_body_length: 2048
        )
        
        qr_data_str = data[:qr_data]
        auto_redeem = data[:auto_redeem] || false
        
        begin
            # Parse QR code data
            qr_data = JSON.parse(qr_data_str)
            
            order_id = qr_data['order_id']
            ticket_number = qr_data['ticket_number']
            participant_name = qr_data['participant_name']
            security_id = qr_data['security_id']
            verification_hash = qr_data['verification_hash']
            
            # Validate required fields
            unless order_id && ticket_number && security_id && verification_hash
                respond(success: false, error: "Ungültiger QR-Code: Fehlende Daten", status: 'invalid')
                return
            end
            
            # Verify hash
            expected_hash = Digest::SHA256.hexdigest("#{order_id}-#{ticket_number}-#{security_id}")
            unless verification_hash == expected_hash
                respond(success: false, error: "Ungültiger QR-Code: Verifizierung fehlgeschlagen", status: 'invalid')
                return
            end
            
            # Get ticket information from database
            ticket_result = neo4j_query(<<~END_OF_QUERY, {order_id: order_id, ticket_number: ticket_number})
                MATCH (o:TicketOrder {id: $order_id})-[:INCLUDES]->(p:Participant {ticket_number: $ticket_number})
                MATCH (u:User)-[:PLACED]->(o)
                MATCH (o)-[:FOR]->(e:Event)
                RETURN p.name AS name, 
                       p.phone AS phone,
                       p.email AS email,
                       p.birthdate AS birthdate,
                       p.ticket_number AS ticket_number,
                       p.redeemed AS redeemed,
                       p.redeemed_at AS redeemed_at,
                       p.redeemed_by AS redeemed_by,
                       o.status AS order_status,
                       o.payment_reference AS payment_reference,
                       u.name AS user_name,
                       u.email AS user_email,
                       e.start_datetime AS event_start_datetime
            END_OF_QUERY
            
            if ticket_result.empty?
                respond(success: false, error: "Ticket nicht gefunden", status: 'invalid')
                return
            end
            
            ticket = ticket_result.first
            
            # Calculate age status if birthdate is available
            age_status = nil
            if ticket['birthdate'] && !ticket['birthdate'].empty?
                reference_date = nil
                if ticket['event_start_datetime'] && !ticket['event_start_datetime'].empty?
                    begin
                        reference_date = DateTime.parse(ticket['event_start_datetime']).to_date
                    rescue ArgumentError
                        reference_date = Date.today
                    end
                else
                    reference_date = Date.today
                end
                
                age_status = get_age_status(ticket['birthdate'], reference_date)
            end
            
            # Add age status to ticket data
            ticket['age_status'] = age_status
            
            # Check if order is paid
            unless ticket['order_status'] == 'paid'
                respond(success: false, error: "Bestellung ist nicht bezahlt", status: 'invalid', ticket: ticket)
                return
            end
            
            # Check if already redeemed
            if ticket['redeemed']
                respond(
                    success: true, 
                    status: 'already_redeemed',
                    message: "Ticket wurde bereits eingelöst",
                    ticket: ticket,
                    redeemed_at: ticket['redeemed_at'],
                    redeemed_by: ticket['redeemed_by']
                )
                return
            end
            
            # Auto-redeem if requested
            if auto_redeem
                neo4j_query(<<~END_OF_QUERY, {order_id: order_id, ticket_number: ticket_number, redeemed_at: DateTime.now.to_s, redeemed_by: @session_user[:email]})
                    MATCH (o:TicketOrder {id: $order_id})-[:INCLUDES]->(p:Participant {ticket_number: $ticket_number})
                    SET p.redeemed = true,
                        p.redeemed_at = $redeemed_at,
                        p.redeemed_by = $redeemed_by
                END_OF_QUERY

                log("Ticket automatisch eingelöst: Bestellung #{order_id}, Ticket ##{ticket_number}")

                respond(
                    success: true,
                    status: 'redeemed',
                    message: "Ticket erfolgreich eingelöst",
                    ticket: ticket
                )
            else
                # Info-only mode
                respond(
                    success: true,
                    status: 'valid',
                    message: "Ticket ist gültig",
                    ticket: ticket
                )
            end
            
        rescue JSON::ParserError
            respond(success: false, error: "Ungültiger QR-Code: Keine gültigen JSON-Daten", status: 'invalid')
        rescue => e
            debug_error("Error scanning ticket: #{e.message}")
            respond(success: false, error: "Fehler beim Scannen des Tickets", status: 'error')
        end
    end

    # Manually redeem a ticket (for info-only mode)
    post "/api/redeem_ticket" do
        require_user_with_permission!("manage_orders")
        data = parse_request_data(required_keys: [:order_id, :ticket_number])
        
        order_id = data[:order_id]
        ticket_number = data[:ticket_number]
        
        # Check if ticket exists and is not already redeemed
        ticket_result = neo4j_query(<<~END_OF_QUERY, {order_id: order_id, ticket_number: ticket_number})
            MATCH (o:TicketOrder {id: $order_id})-[:INCLUDES]->(p:Participant {ticket_number: $ticket_number})
            RETURN p.redeemed AS redeemed, o.status AS order_status
        END_OF_QUERY
        
        if ticket_result.empty?
            respond(success: false, error: "Ticket nicht gefunden")
            return
        end
        
        ticket = ticket_result.first
        
        unless ticket['order_status'] == 'paid'
            respond(success: false, error: "Bestellung ist nicht bezahlt")
            return
        end
        
        if ticket['redeemed']
            respond(success: false, error: "Ticket wurde bereits eingelöst")
            return
        end
        
        # Redeem the ticket
        neo4j_query(<<~END_OF_QUERY, {order_id: order_id, ticket_number: ticket_number, redeemed_at: DateTime.now.to_s, redeemed_by: @session_user[:email]})
            MATCH (o:TicketOrder {id: $order_id})-[:INCLUDES]->(p:Participant {ticket_number: $ticket_number})
            SET p.redeemed = true,
                p.redeemed_at = $redeemed_at,
                p.redeemed_by = $redeemed_by
        END_OF_QUERY

        log("Ticket manuell eingelöst: Bestellung #{order_id}, Ticket ##{ticket_number}")

        respond(success: true, message: "Ticket erfolgreich eingelöst")
    end

    # Undo last redemption
    post "/api/undo_last_redemption" do
        require_user_with_permission!("manage_orders")
        
        # Find the last redeemed ticket by this user
        last_redeemed = neo4j_query(<<~END_OF_QUERY, {redeemed_by: @session_user[:email]})
            MATCH (o:TicketOrder)-[:INCLUDES]->(p:Participant)
            WHERE p.redeemed = true AND p.redeemed_by = $redeemed_by
            RETURN o.id AS order_id, 
                   p.ticket_number AS ticket_number,
                   p.name AS name,
                   p.redeemed_at AS redeemed_at
            ORDER BY p.redeemed_at DESC
            LIMIT 1
        END_OF_QUERY
        
        if last_redeemed.empty?
            respond(success: false, error: "Keine eingelösten Tickets gefunden")
            return
        end
        
        ticket = last_redeemed.first
        order_id = ticket['order_id']
        ticket_number = ticket['ticket_number']
        
        # Undo redemption
        neo4j_query(<<~END_OF_QUERY, {order_id: order_id, ticket_number: ticket_number})
            MATCH (o:TicketOrder {id: $order_id})-[:INCLUDES]->(p:Participant {ticket_number: $ticket_number})
            SET p.redeemed = false
            REMOVE p.redeemed_at, p.redeemed_by
        END_OF_QUERY

        log("Ticket Einlösung rückgängig gemacht: Order #{order_id}, Ticket ##{ticket_number}")

        respond(
            success: true, 
            message: "Einlösung rückgängig gemacht",
            ticket: {
                order_id: order_id,
                ticket_number: ticket_number,
                name: ticket['name']
            }
        )
    end

    # Correct birthdate for a participant (with audit logging)
    post "/api/correct_birthdate" do
        require_user_with_permission!("manage_orders")
        data = parse_request_data(
            required_keys: [:order_id, :ticket_number, :new_birthdate, :reason],
            max_body_length: 1024
        )
        
        order_id = data[:order_id]
        ticket_number = data[:ticket_number]
        new_birthdate = data[:new_birthdate]
        reason = data[:reason]
        
        # Validate reason is not empty
        if reason.nil? || reason.strip.empty?
            respond(success: false, error: "Begründung ist erforderlich")
            return
        end
        
        # Get event start datetime for validation
        event_result = neo4j_query(<<~END_OF_QUERY, {order_id: order_id})
            MATCH (o:TicketOrder {id: $order_id})-[:FOR]->(e:Event)
            RETURN e.start_datetime AS event_start_datetime
        END_OF_QUERY
        
        if event_result.empty?
            respond(success: false, error: "Event nicht gefunden")
            return
        end
        
        event_start_datetime = event_result.first['event_start_datetime']
        reference_date = nil
        if event_start_datetime && !event_start_datetime.empty?
            begin
                reference_date = DateTime.parse(event_start_datetime).to_date
            rescue ArgumentError
                reference_date = Date.today
            end
        else
            reference_date = Date.today
        end
        
        # Validate new birthdate
        valid, error_msg = validate_birthdate(new_birthdate, reference_date)
        unless valid
            respond(success: false, error: "Ungültiges Geburtsdatum: #{error_msg}")
            return
        end
        
        # Get current participant data
        participant_result = neo4j_query(<<~END_OF_QUERY, {order_id: order_id, ticket_number: ticket_number})
            MATCH (o:TicketOrder {id: $order_id})-[:INCLUDES]->(p:Participant {ticket_number: $ticket_number})
            RETURN p.name AS name, p.birthdate AS old_birthdate
        END_OF_QUERY
        
        if participant_result.empty?
            respond(success: false, error: "Ticket nicht gefunden")
            return
        end
        
        participant = participant_result.first
        old_birthdate = participant['old_birthdate']
        participant_name = participant['name']
        
        # Update birthdate
        neo4j_query(<<~END_OF_QUERY, {order_id: order_id, ticket_number: ticket_number, new_birthdate: new_birthdate})
            MATCH (o:TicketOrder {id: $order_id})-[:INCLUDES]->(p:Participant {ticket_number: $ticket_number})
            SET p.birthdate = $new_birthdate
        END_OF_QUERY
        
        # Create audit log entry
        audit_id = RandomTag::generate(16)
        timestamp = DateTime.now.to_s
        operator_id = @session_user[:email]
        
        neo4j_query(<<~END_OF_QUERY, { audit_id: audit_id, order_id: order_id, ticket_number: ticket_number, participant_name: participant_name, old_value: old_birthdate, new_value: new_birthdate, reason: reason, timestamp: timestamp, operator_id: operator_id })
            CREATE (a:BirthdateAuditLog {
                id: $audit_id,
                order_id: $order_id,
                ticket_number: $ticket_number,
                participant_name: $participant_name,
                old_value: $old_value,
                new_value: $new_value,
                reason: $reason,
                timestamp: $timestamp,
                operator_id: $operator_id
            })
        END_OF_QUERY
        
        log("Geburtsdatum korrigiert für Bestellung #{order_id}, Ticket ##{ticket_number}: #{old_birthdate} → #{new_birthdate} (Grund: #{reason})")
        
        # Calculate new age status
        age_status = get_age_status(new_birthdate, reference_date)
        
        respond(
            success: true,
            message: "Geburtsdatum erfolgreich korrigiert",
            old_birthdate: old_birthdate,
            new_birthdate: new_birthdate,
            age_status: age_status
        )
    end

    # Live statistics endpoint for real-time dashboard
    post "/api/live_stats" do
        require_user_with_permission!("manage_orders")
        data = parse_request_data(required_keys: [:event_id])
        event_id = data[:event_id]
        
        # Build where clause for event filtering
        event_filter = event_id ? "AND e.id = $event_id" : ""
        query_params = event_id ? {event_id: event_id} : {}
        
        # Get total tickets, checked-in, and not checked-in counts
        stats = neo4j_query(<<~END_OF_QUERY, query_params).first
            MATCH (o:TicketOrder)-[:INCLUDES]->(p:Participant)
            MATCH (o)-[:FOR]->(e:Event)
            WHERE o.status = 'paid' #{event_filter}
            WITH 
                COUNT(p) AS total_tickets,
                SUM(CASE WHEN p.redeemed = true THEN 1 ELSE 0 END) AS checked_in,
                SUM(CASE WHEN p.redeemed = true OR p.redeemed IS NULL THEN 0 ELSE 1 END) AS not_checked_in
            RETURN 
                total_tickets,
                checked_in,
                (total_tickets - checked_in) AS not_checked_in
        END_OF_QUERY
        
        total_tickets = stats ? stats['total_tickets'].to_i : 0
        checked_in = stats ? stats['checked_in'].to_i : 0
        not_checked_in = total_tickets - checked_in
        
        # Get scans in the last minute
        one_minute_ago = (DateTime.now - Rational(1, 1440)).to_s  # 1/1440 day = 1 minute
        recent_scans = neo4j_query(<<~END_OF_QUERY, query_params.merge({one_minute_ago: one_minute_ago}))
            MATCH (o:TicketOrder)-[:INCLUDES]->(p:Participant)
            MATCH (o)-[:FOR]->(e:Event)
            WHERE o.status = 'paid' 
              AND p.redeemed = true 
              AND p.redeemed_at > $one_minute_ago
              #{event_filter}
            RETURN COUNT(p) AS count
        END_OF_QUERY
        
        scans_last_minute = recent_scans.first ? recent_scans.first['count'].to_i : 0
        
        # Get arrival distribution over time (hourly buckets for the last 12 hours)
        twelve_hours_ago = (DateTime.now - Rational(12, 24)).to_s
        arrival_distribution = neo4j_query(<<~END_OF_QUERY, query_params.merge({twelve_hours_ago: twelve_hours_ago}))
            MATCH (o:TicketOrder)-[:INCLUDES]->(p:Participant)
            MATCH (o)-[:FOR]->(e:Event)
            WHERE o.status = 'paid' 
              AND p.redeemed = true 
              AND p.redeemed_at > $twelve_hours_ago
              #{event_filter}
            WITH p, 
                 datetime(p.redeemed_at) AS redeemed_datetime
            WITH 
                redeemed_datetime.year AS year,
                redeemed_datetime.month AS month,
                redeemed_datetime.day AS day,
                redeemed_datetime.hour AS hour,
                COUNT(p) AS count
            RETURN 
                year, month, day, hour, count
            ORDER BY year, month, day, hour
        END_OF_QUERY
        
        # Format arrival distribution
        distribution = arrival_distribution.map do |row|
            {
                hour: sprintf("%04d-%02d-%02d %02d:00", row['year'], row['month'], row['day'], row['hour']),
                count: row['count'].to_i
            }
        end
        
        respond(
            success: true,
            stats: {
                total_tickets: total_tickets,
                checked_in: checked_in,
                not_checked_in: not_checked_in,
                scans_last_minute: scans_last_minute,
                arrival_distribution: distribution,
                last_updated: DateTime.now.to_s
            }
        )
    end

    # Live list endpoint for real-time dashboard (present and missing attendees)
    post "/api/live_list" do
        require_user_with_permission!("manage_orders")
        data = parse_request_data(required_keys: [:event_id])
        event_id = data[:event_id]
        
        # Build where clause for event filtering
        event_filter = event_id ? "AND e.id = $event_id" : ""
        query_params = event_id ? {event_id: event_id} : {}
        
        # Get present attendees (checked-in)
        present = neo4j_query(<<~END_OF_QUERY, query_params)
            MATCH (o:TicketOrder)-[:INCLUDES]->(p:Participant)
            MATCH (o)-[:FOR]->(e:Event)
            WHERE o.status = 'paid' 
              AND p.redeemed = true 
              #{event_filter}
            RETURN 
                p.name AS name,
                p.ticket_number AS ticket_number,
                p.redeemed_at AS checked_in_at,
                o.payment_reference AS reference
            ORDER BY p.redeemed_at DESC
        END_OF_QUERY
        
        # Get missing attendees (not checked-in)
        missing = neo4j_query(<<~END_OF_QUERY, query_params)
            MATCH (o:TicketOrder)-[:INCLUDES]->(p:Participant)
            MATCH (o)-[:FOR]->(e:Event)
            WHERE o.status = 'paid' 
              AND (p.redeemed IS NULL OR p.redeemed = false)
              #{event_filter}
            RETURN 
                p.name AS name,
                p.ticket_number AS ticket_number,
                o.payment_reference AS reference
            ORDER BY p.name
        END_OF_QUERY
        
        respond(
            success: true,
            present: present.map { |p| {
                name: p['name'],
                ticket_number: p['ticket_number'],
                checked_in_at: p['checked_in_at'],
                reference: p['reference']
            }},
            missing: missing.map { |m| {
                name: m['name'],
                ticket_number: m['ticket_number'],
                reference: m['reference']
            }},
            last_updated: DateTime.now.to_s
        )
    end
end