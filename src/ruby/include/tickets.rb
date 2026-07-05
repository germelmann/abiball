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
            'overpaid' => 'Überzahlung',
            'partially_paid' => 'Teilweise bezahlt',
            'pending' => 'Ausstehend',
            'pending_payment' => 'Zahlung ausstehend',
            'offline_payment' => 'Barzahlung vor Ort',
            'cancelled' => 'Storniert',
            'cancelled_by_user' => 'Storniert durch Käufer',
            'in_review' => 'Manuelle Prüfung',
            'on_hold' => 'Pausiert',
            'issue' => 'Problem/Fehler',
            'contact_required' => 'Kontakt erforderlich'
        }
    end

    # Statuses that are derived from payments and cannot be set manually
    # 'auto' is the user-selectable value that triggers recalculation
    PAYMENT_DERIVED_STATUSES = %w[auto paid overpaid partially_paid pending].freeze

    # Statuses excluded from dunning (reminders/cancellation)
    DUNNING_EXCLUDED_STATUSES = %w[cancelled cancelled_by_user paid overpaid offline_payment].freeze
    
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

    # ===========================================
    # Payment Tracking Helpers
    # ===========================================

    # Calculate the sum of all payments for an order
    def get_payments_sum(order_id)
        result = neo4j_query(<<~END_OF_QUERY, {order_id: order_id})
            MATCH (o:TicketOrder {id: $order_id})-[:HAS_PAYMENT]->(pay:Payment)
            RETURN COALESCE(SUM(pay.amount), 0) AS total_paid
        END_OF_QUERY
        result.first&.dig('total_paid').to_f || 0.0
    end

    # Calculate payment status dynamically from payments
    # Returns: 'pending', 'partially_paid', 'paid'
    # Also returns overpayment amount if applicable
    def calculate_payment_status(order_id)
        result = neo4j_query(<<~END_OF_QUERY, {order_id: order_id})
            MATCH (o:TicketOrder {id: $order_id})
            OPTIONAL MATCH (o)-[:HAS_PAYMENT]->(pay:Payment)
            RETURN o.total_price AS total_price,
                   COALESCE(SUM(pay.amount), 0) AS total_paid
        END_OF_QUERY

        return { status: 'pending', total_paid: 0.0, total_price: 0.0, remaining: 0.0, overpayment: 0.0 } if result.empty?

        row = result.first
        total_price = (row['total_price'] || 0).to_f
        total_paid = (row['total_paid'] || 0).to_f
        remaining = [total_price - total_paid, 0].max
        overpayment = [total_paid - total_price, 0].max

        status = if total_paid <= 0
            'pending'
        elsif total_paid < total_price
            'partially_paid'
        elsif total_paid > total_price
            'overpaid'
        else
            'paid'
        end

        { status: status, total_paid: total_paid, total_price: total_price, remaining: remaining, overpayment: overpayment }
    end

    # Record a payment for an order, update order status accordingly, and log it
    def record_payment_for_order(order_id, amount, recorded_by, note: nil)
        payment_id = RandomTag::generate(12)
        timestamp = Time.now.iso8601
        if note == "" || !note
            note = order_id
        end

        neo4j_query(<<~END_OF_QUERY, {order_id: order_id, payment_id: payment_id, amount: amount.to_f, recorded_by: recorded_by, note: note, timestamp: timestamp})
            MATCH (o:TicketOrder {id: $order_id})
            CREATE (pay:Payment {
                id: $payment_id,
                amount: $amount,
                recorded_by: $recorded_by,
                note: $note,
                timestamp: $timestamp
            })
            CREATE (o)-[:HAS_PAYMENT]->(pay)
        END_OF_QUERY

        # Recalculate and update order status
        payment_info = calculate_payment_status(order_id)
        new_status = payment_info[:status]

        if new_status == 'paid' || new_status == 'overpaid'
            neo4j_query(<<~END_OF_QUERY, {order_id: order_id, date: Date.today.to_s, status: new_status})
                MATCH (o:TicketOrder {id: $order_id})
                SET o.status = $status, o.paid_at = $date
            END_OF_QUERY
        else
            neo4j_query(<<~END_OF_QUERY, {order_id: order_id, status: new_status})
                MATCH (o:TicketOrder {id: $order_id})
                SET o.status = $status
            END_OF_QUERY
        end

        log("Zahlung #{payment_id} über #{sprintf('%.2f', amount)}€ für Bestellung #{order_id} verbucht. Neuer Status: #{new_status}")

        { payment_id: payment_id, payment_info: payment_info }
    end

    # Revert (delete) a specific payment and recalculate order status
    def revert_payment_for_order(payment_id, reverted_by)
        # Get the order associated with this payment
        result = neo4j_query(<<~END_OF_QUERY, {payment_id: payment_id})
            MATCH (o:TicketOrder)-[:HAS_PAYMENT]->(pay:Payment {id: $payment_id})
            RETURN o.id AS order_id, pay.amount AS amount
        END_OF_QUERY

        return nil if result.empty?

        order_id = result.first['order_id']
        amount = result.first['amount']

        # Delete the payment
        neo4j_query(<<~END_OF_QUERY, {payment_id: payment_id})
            MATCH (o:TicketOrder)-[:HAS_PAYMENT]->(pay:Payment {id: $payment_id})
            DETACH DELETE pay
        END_OF_QUERY

        # Recalculate and update order status
        payment_info = calculate_payment_status(order_id)
        new_status = payment_info[:status]

        if new_status == 'pending'
            neo4j_query(<<~END_OF_QUERY, {order_id: order_id, status: new_status})
                MATCH (o:TicketOrder {id: $order_id})
                SET o.status = $status
                REMOVE o.paid_at
            END_OF_QUERY
        else
            neo4j_query(<<~END_OF_QUERY, {order_id: order_id, status: new_status})
                MATCH (o:TicketOrder {id: $order_id})
                SET o.status = $status
            END_OF_QUERY
        end

        log("Zahlung #{payment_id} über #{sprintf('%.2f', amount)}€ für Bestellung #{order_id} storniert von #{reverted_by}. Neuer Status: #{new_status}")

        { order_id: order_id, amount: amount, payment_info: payment_info }
    end

    # Get or create ticket order for user
    post "/api/create_ticket_order" do
        require_user_with_permission!("buy_tickets")
        data = parse_request_data(required_keys: [:ticket_count, :participants, :event_id],
                                  optional_keys: [:tier_id],
                                  types: {ticket_count: Integer, participants: Array},
                                  max_body_length: 2048,
                                  max_string_length: 2048)
        
        user_email = @session_user[:email]
        ticket_count = data[:ticket_count]
        participants = data[:participants]
        event_id = data[:event_id]
        tier_id = data[:tier_id]

        puts "Creating ticket order: user_email=#{user_email}, ticket_count=#{ticket_count}, event_id=#{event_id}, tier_id=#{tier_id}"
        puts "Participants: #{participants.inspect}"
        
        # Verify event exists and is accessible
        event = neo4j_query(<<~END_OF_QUERY, {event_id: event_id}).map { |e| e['e'] }
            MATCH (e:Event {id: $event_id})
            WHERE e.active = true
            RETURN e
        END_OF_QUERY

        event = event.first
        
        if event.empty?
            respond(success: false, error: "Event nicht gefunden.")
            return
        end
        
        # Check if ticket generation is enabled for this event
        unless event[:ticket_generation_enabled]
            respond(success: false, error: "Ticket-Verkauf für dieses Event ist derzeit deaktiviert.")
            return
        end
        
        # Check if user has bypass_restrictions enabled for this event
        bypass_result = neo4j_query(<<~END_OF_QUERY, {email: user_email, event_id: event_id})
            MATCH (u:User {email: $email})
            MATCH (e:Event {id: $event_id})
            OPTIONAL MATCH (u)-[r:HAS_EVENT_LIMIT]->(e)
            RETURN COALESCE(r.bypass_restrictions, false) AS bypass_restrictions
        END_OF_QUERY
        user_bypass_restrictions = bypass_result.first&.dig('bypass_restrictions') || false
        
        # Check if ticket sales are within the allowed time window
        current_time = Time.now
        if event[:ticket_sale_start_datetime] && !event[:ticket_sale_start_datetime].empty?
            sale_start_time = Time.parse(event[:ticket_sale_start_datetime])
            if current_time < sale_start_time
                respond(success: false, error: "Ticket-Verkauf hat noch nicht begonnen. Verkaufsstart: #{sale_start_time.strftime('%d.%m.%Y um %H:%M Uhr')}")
                return
            end
        end

        if event[:ticket_sale_end_datetime] && !event[:ticket_sale_end_datetime].empty? && !user_bypass_restrictions
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
            WHERE o.status = 'paid' OR o.status = 'pending' OR o.status = 'offline_payment'
            RETURN SUM(o.ticket_count) AS total
        END_OF_QUERY
        event_sold = event_sold_result.first&.dig('total') || 0

        if event_sold + ticket_count > event[:max_tickets] && !user_bypass_restrictions
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

        current_tickets = existing_orders.select { |o| o['status'] == 'paid' || o['status'] == 'overpaid' || o['status'] == 'pending' }
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
                    WHERE o.status = 'paid' OR o.status = 'pending' OR o.status = 'offline_payment'
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
        
        # Get next order count for this user (across ALL events, to avoid duplicate payment references)
        all_user_orders_result = neo4j_query(<<~END_OF_QUERY, {email: user_email})
            MATCH (u:User {email: $email})-[:PLACED]->(o:TicketOrder)
            RETURN COUNT(o) AS order_count
        END_OF_QUERY
        order_count = (all_user_orders_result.first&.dig('order_count') || 0) + 1
        
        # Generate order ID and payment reference
        order_id = RandomTag::generate(8)
        payment_ref = generate_payment_reference(@session_user[:username] || user_email.split('@').first, order_count)
        
        # Check for payment reference uniqueness (protect against race conditions)
        # If the reference already exists, increment counter until we find a unique one
        max_attempts = 100
        attempts = 0
        loop do
            existing_ref = neo4j_query(<<~END_OF_QUERY, {payment_ref: payment_ref})
                MATCH (o:TicketOrder {payment_reference: $payment_ref})
                RETURN o.id AS id LIMIT 1
            END_OF_QUERY
            break if existing_ref.empty?
            attempts += 1
            if attempts >= max_attempts
                respond(success: false, error: "Fehler bei der Bestellungserstellung. Bitte versuche es erneut.")
                return
            end
            order_count += 1
            payment_ref = generate_payment_reference(@session_user[:username] || user_email.split('@').first, order_count)
        end
        
        # NOTE: Bank account is NOT assigned at order creation time.
        # Payment requests are now a separate step and can be sent manually or in bulk.
        # 
        # Order Status Flow:
        # - 'pending': Order created, tickets reserved, awaiting review/payment
        # - 'offline_payment': Order confirmed for offline payment (e.g., cash at venue)
        # - 'paid': Payment received and confirmed (online payment)
        # - 'cancelled': Order cancelled by admin
        # - 'cancelled_by_user': Order cancelled by customer
        
        # Determine if payment is required for this event (for email messaging)
        payment_required = event[:payment_required] != false
        
        # All orders start as 'pending' for review - admin can then mark as paid or offline_payment
        order_status = 'pending'
        
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
            status: order_status,
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
        
        # NOTE: Payment request is NOT automatically sent for online payment events.
        # The order is created in 'pending' or 'offline_payment' status with tickets reserved.
        # A payment request will be sent separately, either manually per order or in bulk via event settings.
        # Send order received confirmation email (without payment details - those come with payment request)
        send_order_received_email(user_email, order_id, payment_ref, event, participants, ticket_price * ticket_count, payment_required)
        
        log("Neue Bestellung #{order_id} erstellt für #{user_email} - #{ticket_count} Tickets, #{ticket_price * ticket_count}€")
        
        respond(success: true, order_id: order_id, payment_reference: payment_ref, total_price: ticket_price * ticket_count, ticket_count: ticket_count, payment_request_sent: false, payment_required: payment_required)
    end
    
    # Get payment QR code for an order
    # Admin: Mark order as paid - records a payment for the remaining amount
    post "/api/mark_order_paid" do
        require_user_with_permission!("manage_orders")
        data = parse_request_data(required_keys: [:order_id])

        order_id = data[:order_id]

        # Check if the event requires payment
        event_result = neo4j_query(<<~END_OF_QUERY, {order_id: order_id})
            MATCH (o:TicketOrder {id: $order_id})-[:FOR]->(e:Event)
            RETURN e.payment_required AS payment_required
        END_OF_QUERY
        
        if event_result.empty?
            respond(success: false, error: "Order not found or not linked to an event")
            return
        end
        
        payment_required = event_result.first&.dig('payment_required') != false

        # For non-payment events, set offline_payment status directly
        unless payment_required
            neo4j_query(<<~END_OF_QUERY, {order_id: order_id, date: Date.today.to_s})
                MATCH (o:TicketOrder {id: $order_id})
                SET o.status = 'offline_payment', o.paid_at = $date
            END_OF_QUERY
            respond(success: true, new_status: 'offline_payment')
            return
        end

        # Calculate remaining amount and record payment
        payment_info = calculate_payment_status(order_id)
        remaining = payment_info[:remaining]
        
        if remaining <= 0
            respond(success: false, error: "Bestellung ist bereits vollständig bezahlt")
            return
        end

        result = record_payment_for_order(order_id, remaining, @session_user[:username])
        respond(success: true, new_status: result[:payment_info][:status], payment_info: result[:payment_info])
    end

    # Admin: Recalculate order payment status from actual payments
    # Payments are the single source of truth and are NEVER deleted by status changes
    post "/api/mark_order_unpaid" do
        require_user_with_permission!("manage_orders")
        data = parse_request_data(required_keys: [:order_id])
        
        order_id = data[:order_id]

        # Recalculate payment status from actual payment records
        payment_info = calculate_payment_status(order_id)
        new_status = payment_info[:status]

        neo4j_query(<<~END_OF_QUERY, {order_id: order_id, status: new_status})
            MATCH (o:TicketOrder {id: $order_id})
            SET o.status = $status
        END_OF_QUERY

        log("Bestellung #{order_id} Zahlungsstatus neu berechnet: #{new_status}")
        
        respond(success: true, new_status: new_status, payment_info: payment_info)
    end

    # ===========================================
    # Payment Recording & Tracking Endpoints
    # ===========================================

    # Record a payment for an order
    post "/api/record_payment" do
        require_user_with_permission!("manage_orders")
        data = parse_request_data(required_keys: [:order_id, :amount], optional_keys: [:note, :send_email])

        order_id = data[:order_id]
        amount = data[:amount].to_f
        note = data[:note]
        send_email = data[:send_email] != false  # default true

        if amount == 0
            respond(success: false, error: "Betrag darf nicht 0 sein")
            return
        end

        # Verify order exists
        order_check = neo4j_query(<<~END_OF_QUERY, {order_id: order_id})
            MATCH (u:User)-[:PLACED]->(o:TicketOrder {id: $order_id})
            RETURN o.id AS order_id, o.total_price AS total_price, u.email AS user_email, u.name AS user_name, u.username AS user_username, o.payment_reference AS payment_reference
        END_OF_QUERY

        if order_check.empty?
            respond(success: false, error: "Bestellung nicht gefunden")
            return
        end

        result = record_payment_for_order(order_id, amount, @session_user[:username], note: note)

        # Send email based on payment status
        if send_email
            order = order_check.first
            payment_status = result[:payment_info][:status]
            
            begin
                if amount < 0
                    # Negative amount (correction/refund) - send negative_payment_recorded email
                    rendered = render_manual_mail_template('negative_payment_recorded', {
                        'NAME' => order['user_name'] || 'Nutzer',
                        'ORDER_ID' => order['order_id'],
                        'PAYMENT_AMOUNT' => sprintf("%.2f", amount.to_f),
                        'TOTAL_PRICE' => sprintf("%.2f", order['total_price'] || 0),
                        'TOTAL_PAID' => sprintf("%.2f", result[:payment_info][:total_paid]),
                        'REMAINING' => sprintf("%.2f", result[:payment_info][:remaining]),
                        'REFERENCE' => order['payment_reference'] || 'N/A'
                    })
                    if rendered
                        send_manual_mail(
                            to_email: order['user_email'],
                            subject: rendered[:subject],
                            body: rendered[:body],
                            template_key: 'negative_payment_recorded',
                            sender_username: @session_user[:username],
                            recipient_username: order['user_username'],
                            order_id: order_id
                        )
                    end
                elsif payment_status == 'overpaid'
                    # Overpayment - send overpayment_received email
                    rendered = render_manual_mail_template('overpayment_received', {
                        'NAME' => order['user_name'] || 'Nutzer',
                        'ORDER_ID' => order['order_id'],
                        'PAYMENT_AMOUNT' => sprintf("%.2f", amount.to_f),
                        'TOTAL_PRICE' => sprintf("%.2f", order['total_price'] || 0),
                        'TOTAL_PAID' => sprintf("%.2f", result[:payment_info][:total_paid]),
                        'REFUND' => sprintf("%.2f", result[:payment_info][:overpayment]),
                        'REFERENCE' => order['payment_reference'] || 'N/A'
                    })
                    if rendered
                        send_manual_mail(
                            to_email: order['user_email'],
                            subject: rendered[:subject],
                            body: rendered[:body],
                            template_key: 'overpayment_received',
                            sender_username: @session_user[:username],
                            recipient_username: order['user_username'],
                            order_id: order_id
                        )
                    end
                elsif payment_status == 'paid'
                    # Fully paid - send payment_received email
                    rendered = render_manual_mail_template('payment_received', {
                        'NAME' => order['user_name'] || 'Nutzer',
                        'ORDER_ID' => order['order_id'],
                        'TOTAL_PRICE' => sprintf("%.2f", order['total_price'] || 0),
                        'REFERENCE' => order['payment_reference'] || 'N/A',
                        'TICKET_LINK' => "#{WEB_ROOT}/ticket_download"
                    })
                    if rendered
                        send_manual_mail(
                            to_email: order['user_email'],
                            subject: rendered[:subject],
                            body: rendered[:body],
                            template_key: 'payment_received',
                            sender_username: @session_user[:username],
                            recipient_username: order['user_username'],
                            order_id: order_id
                        )
                    end
                elsif payment_status == 'partially_paid'
                    # Partially paid - send partial_payment_received email
                    rendered = render_manual_mail_template('partial_payment_received', {
                        'NAME' => order['user_name'] || 'Nutzer',
                        'ORDER_ID' => order['order_id'],
                        'PAYMENT_AMOUNT' => sprintf("%.2f", amount.to_f),
                        'TOTAL_PRICE' => sprintf("%.2f", order['total_price'] || 0),
                        'TOTAL_PAID' => sprintf("%.2f", result[:payment_info][:total_paid]),
                        'REMAINING' => sprintf("%.2f", result[:payment_info][:remaining]),
                        'REFERENCE' => order['payment_reference'] || 'N/A'
                    })
                    if rendered
                        send_manual_mail(
                            to_email: order['user_email'],
                            subject: rendered[:subject],
                            body: rendered[:body],
                            template_key: 'partial_payment_received',
                            sender_username: @session_user[:username],
                            recipient_username: order['user_username'],
                            order_id: order_id
                        )
                    end
                end
            rescue => e
                STDERR.puts "Error sending payment email: #{e.message}"
            end
        end

        respond(success: true, payment_id: result[:payment_id], payment_info: result[:payment_info])
    end

    # Revert a specific payment
    post "/api/revert_payment" do
        require_user_with_permission!("manage_orders")
        data = parse_request_data(required_keys: [:payment_id])

        payment_id = data[:payment_id]
        result = revert_payment_for_order(payment_id, @session_user[:username])

        if result.nil?
            respond(success: false, error: "Zahlung nicht gefunden")
            return
        end

        respond(success: true, order_id: result[:order_id], reverted_amount: result[:amount], payment_info: result[:payment_info])
    end

    # Get all payments for an order
    post "/api/get_payments" do
        require_user_with_permission!("manage_orders")
        data = parse_request_data(required_keys: [:order_id])

        order_id = data[:order_id]

        payments = neo4j_query(<<~END_OF_QUERY, {order_id: order_id})
            MATCH (o:TicketOrder {id: $order_id})-[:HAS_PAYMENT]->(pay:Payment)
            RETURN pay.id AS id,
                   pay.amount AS amount,
                   pay.recorded_by AS recorded_by,
                   pay.note AS note,
                   pay.timestamp AS timestamp
            ORDER BY pay.timestamp DESC
        END_OF_QUERY

        payment_info = calculate_payment_status(order_id)

        respond(success: true, payments: payments, payment_info: payment_info)
    end

    # Get all payments across all orders (for payments.html dashboard)
    post "/api/all_payments" do
        require_user_with_permission!("manage_orders")
        data = parse_request_data(optional_keys: [:event_id])

        event_id = data[:event_id]
        event_filter = (event_id && !event_id.to_s.empty?) ? "WHERE e.id = $event_id" : ""
        query_params = (event_id && !event_id.to_s.empty?) ? {event_id: event_id} : {}

        payments = neo4j_query(<<~END_OF_QUERY, query_params)
            MATCH (o:TicketOrder)-[:HAS_PAYMENT]->(pay:Payment)
            MATCH (o)-[:FOR]->(e:Event)
            #{event_filter}
            OPTIONAL MATCH (u:User)-[:PLACED]->(o)
            RETURN pay.id AS id,
                   pay.amount AS amount,
                   pay.recorded_by AS recorded_by,
                   pay.note AS note,
                   pay.timestamp AS timestamp,
                   o.id AS order_id,
                   o.payment_reference AS payment_reference,
                   o.total_price AS total_price,
                   o.status AS order_status,
                   COALESCE(u.name, '') AS user_name,
                   COALESCE(u.email, '') AS user_email,
                   COALESCE(e.name, '') AS event_name,
                   COALESCE(e.year, '') AS event_year,
                   COALESCE(pay.verified, false) AS verified,
                   pay.verified_amount AS verified_amount,
                   pay.verified_by AS verified_by,
                   pay.verified_at AS verified_at,
                   pay.verified_account_id AS verified_account_id,
                   pay.verification_matches AS verification_matches,
                   pay.verification_note AS verification_note,
                   'payment' AS entry_type
            ORDER BY pay.timestamp DESC
        END_OF_QUERY

        # Also fetch error records (unassignable payments) - only when not filtering by event
        error_records = []
        unless event_id && !event_id.to_s.empty?
            error_records = neo4j_query(<<~END_OF_QUERY)
                MATCH (o:TicketOrder {status: 'error'})
                WHERE NOT EXISTS((o)<-[:PLACED]-(:User))
                RETURN null AS id,
                       0 AS amount,
                       '' AS recorded_by,
                       COALESCE(o.error_reason, '') AS note,
                       o.created_at AS timestamp,
                       o.id AS order_id,
                       o.payment_reference AS payment_reference,
                       0 AS total_price,
                       'error' AS order_status,
                       '' AS user_name,
                       '' AS user_email,
                       '' AS event_name,
                       '' AS event_year,
                       'error' AS entry_type
                ORDER BY o.created_at DESC
            END_OF_QUERY
        end

        all_entries = payments + error_records

        # Calculate summary statistics (only from actual payments)
        total_amount = payments.sum { |p| (p['amount'] || 0).to_f }

        respond(success: true, payments: all_entries, total_amount: total_amount, error_count: error_records.length)
    end

    # ===========================================
    # Kassenprüfung (Audit) Endpoints
    # ===========================================

    # List bank accounts available for audit (optionally filtered by event)
    post "/api/audit_list_bank_accounts" do
        require_user_with_permission!("manage_orders")
        data = parse_request_data(optional_keys: [:event_id])

        if data[:event_id] && !data[:event_id].to_s.empty?
            accounts = neo4j_query(<<~END_OF_QUERY, {event_id: data[:event_id]})
                MATCH (e:Event {id: $event_id})-[:HAS_BANK_ACCOUNT]->(b:BankAccount)
                RETURN b.id AS id,
                       b.account_name AS account_name,
                       b.bank_name AS bank_name,
                       b.iban AS iban
                ORDER BY b.account_name
            END_OF_QUERY
        else
            accounts = neo4j_query(<<~END_OF_QUERY)
                MATCH (b:BankAccount)
                OPTIONAL MATCH (e:Event)-[:HAS_BANK_ACCOUNT]->(b)
                WITH b, COLLECT(DISTINCT (CASE WHEN e IS NULL THEN NULL ELSE e.name + ' ' + toString(e.year) END)) AS event_names
                RETURN b.id AS id,
                       b.account_name AS account_name,
                       b.bank_name AS bank_name,
                       b.iban AS iban,
                       [n IN event_names WHERE n IS NOT NULL] AS event_names
                ORDER BY b.account_name
            END_OF_QUERY
        end

        respond(success: true, accounts: accounts)
    end

    # Get all unverified payments for a given bank account (and optional event)
    post "/api/audit_get_pending_payments" do
        require_user_with_permission!("manage_orders")
        data = parse_request_data(required_keys: [:bank_account_id], optional_keys: [:event_id])

        bank_account_id = data[:bank_account_id]
        event_id = data[:event_id]

        params = {bank_account_id: bank_account_id}
        event_filter = ""
        if event_id && !event_id.to_s.empty?
            event_filter = "AND e.id = $event_id"
            params[:event_id] = event_id
        end

        payments = neo4j_query(<<~END_OF_QUERY, params)
            MATCH (o:TicketOrder)-[:HAS_PAYMENT]->(pay:Payment)
            MATCH (o)-[:FOR]->(e:Event)
            MATCH (u:User)-[:PLACED]->(o)
            WHERE (pay.verified IS NULL OR pay.verified = false)
              #{event_filter}
            OPTIONAL MATCH (o)-[:HAS_PAYMENT_REQUEST]->(pr:PaymentRequest)-[:USES_ACCOUNT]->(b:BankAccount)
            WITH o, e, u, pay, b, pr
            ORDER BY pr.created_at DESC
            WITH o, e, u, pay, HEAD(COLLECT(b)) AS bank
            WHERE bank IS NULL OR bank.id = $bank_account_id
            RETURN pay.id AS id,
                   pay.amount AS amount,
                   pay.timestamp AS timestamp,
                   pay.recorded_by AS recorded_by,
                   pay.note AS note,
                   o.id AS order_id,
                   o.payment_reference AS payment_reference,
                   o.total_price AS total_price,
                   COALESCE(u.name, '') AS user_name,
                   COALESCE(u.email, '') AS user_email,
                   COALESCE(e.name, '') AS event_name,
                   COALESCE(e.year, '') AS event_year,
                   CASE WHEN bank IS NULL THEN true ELSE false END AS account_unknown
            ORDER BY pay.timestamp ASC
        END_OF_QUERY

        respond(success: true, payments: payments)
    end

    # Mark a payment as verified (Kassenprüfung) or correct an existing verification.
    # bank_account_id is optional: when re-checking an already verified payment (e.g. to
    # correct a wrongly recorded deviation) the account it was originally verified against
    # is reused, so a payment never stays a deviation by accident – and vice versa.
    post "/api/audit_verify_payment" do
        require_user_with_permission!("manage_orders")
        data = parse_request_data(required_keys: [:payment_id, :verified_amount],
                                  optional_keys: [:bank_account_id, :note])

        payment_id = data[:payment_id]
        verified_amount = data[:verified_amount].to_f
        note = data[:note].to_s
        timestamp = Time.now.iso8601

        existing = neo4j_query(<<~END_OF_QUERY, {payment_id: payment_id})
            MATCH (pay:Payment {id: $payment_id})
            RETURN pay.amount AS amount, pay.verified AS verified,
                   pay.verified_account_id AS verified_account_id
        END_OF_QUERY

        if existing.empty?
            respond(success: false, error: "Zahlung nicht gefunden")
            return
        end

        # Fall back to the account the payment was previously verified against so a
        # correction does not require selecting the bank account again.
        bank_account_id = data[:bank_account_id]
        if bank_account_id.nil? || bank_account_id.to_s.empty?
            bank_account_id = existing.first['verified_account_id']
        end

        original_amount = existing.first['amount'].to_f
        matches = (original_amount - verified_amount).abs < 0.005

        verify_params = {
            payment_id: payment_id,
            verified_amount: verified_amount,
            verified_by: @session_user[:username],
            verified_at: timestamp,
            verified_account_id: bank_account_id,
            verification_matches: matches,
            verification_note: note
        }
        neo4j_query(<<~END_OF_QUERY, verify_params)
            MATCH (pay:Payment {id: $payment_id})
            SET pay.verified = true,
                pay.verified_amount = $verified_amount,
                pay.verified_by = $verified_by,
                pay.verified_at = $verified_at,
                pay.verified_account_id = $verified_account_id,
                pay.verification_matches = $verification_matches,
                pay.verification_note = $verification_note
        END_OF_QUERY

        log("Zahlung #{payment_id} bei Kassenprüfung verifiziert (gebucht: #{sprintf('%.2f', original_amount)}€, Kontoauszug: #{sprintf('%.2f', verified_amount)}€, Übereinstimmung: #{matches})")

        respond(success: true, matches: matches, original_amount: original_amount, verified_amount: verified_amount)
    end

    # Remove verification flag (undo audit)
    post "/api/audit_unverify_payment" do
        require_user_with_permission!("manage_orders")
        data = parse_request_data(required_keys: [:payment_id])

        payment_id = data[:payment_id]

        existing = neo4j_query(<<~END_OF_QUERY, {payment_id: payment_id})
            MATCH (pay:Payment {id: $payment_id})
            RETURN pay.id AS id
        END_OF_QUERY

        if existing.empty?
            respond(success: false, error: "Zahlung nicht gefunden")
            return
        end

        neo4j_query(<<~END_OF_QUERY, {payment_id: payment_id})
            MATCH (pay:Payment {id: $payment_id})
            REMOVE pay.verified,
                   pay.verified_amount,
                   pay.verified_by,
                   pay.verified_at,
                   pay.verified_account_id,
                   pay.verification_matches,
                   pay.verification_note
        END_OF_QUERY

        log("Verifizierungs-Markierung für Zahlung #{payment_id} entfernt von #{@session_user[:username]}")

        respond(success: true)
    end

    # Return expected and verified balance for a single bank account
    post "/api/audit_account_balance" do
        require_user_with_permission!("manage_orders")
        data = parse_request_data(required_keys: [:bank_account_id], optional_keys: [:event_id])

        bank_account_id = data[:bank_account_id]
        event_id        = data[:event_id]

        event_filter = ""
        params = { bank_account_id: bank_account_id }
        if event_id && !event_id.to_s.empty?
            event_filter = "AND e.id = $event_id"
            params[:event_id] = event_id
        end

        # Verified payments: explicitly confirmed to belong to this account
        verified = neo4j_query(<<~END_OF_QUERY, params)
            MATCH (pay:Payment {verified: true, verified_account_id: $bank_account_id})
            MATCH (o:TicketOrder)-[:HAS_PAYMENT]->(pay)
            MATCH (o)-[:FOR]->(e:Event)
            WHERE true #{event_filter}
            RETURN
                COUNT(pay)               AS verified_count,
                SUM(pay.verified_amount) AS verified_total
        END_OF_QUERY

        # Expected payments: all payments from orders whose *most recently assigned*
        # bank account is this one. When an order had several payment requests (e.g. the
        # bank account was changed), only the latest assignment counts.
        expected = neo4j_query(<<~END_OF_QUERY, params)
            MATCH (o:TicketOrder)-[:HAS_PAYMENT_REQUEST]->(pr:PaymentRequest)-[:USES_ACCOUNT]->(b:BankAccount)
            MATCH (o)-[:FOR]->(e:Event)
            WHERE true #{event_filter}
            WITH o, b, pr
            ORDER BY pr.created_at DESC
            WITH o, HEAD(COLLECT(b.id)) AS current_account_id
            WHERE current_account_id = $bank_account_id
            MATCH (o)-[:HAS_PAYMENT]->(pay:Payment)
            WITH DISTINCT pay
            RETURN
                COUNT(pay)      AS expected_count,
                SUM(pay.amount) AS expected_total
        END_OF_QUERY

        # Unverified: payments whose order's latest assigned account is this one and that
        # have not been verified yet.
        unverified = neo4j_query(<<~END_OF_QUERY, params)
            MATCH (o:TicketOrder)-[:HAS_PAYMENT_REQUEST]->(pr:PaymentRequest)-[:USES_ACCOUNT]->(b:BankAccount)
            MATCH (o)-[:FOR]->(e:Event)
            WHERE true #{event_filter}
            WITH o, b, pr
            ORDER BY pr.created_at DESC
            WITH o, HEAD(COLLECT(b.id)) AS current_account_id
            WHERE current_account_id = $bank_account_id
            MATCH (o)-[:HAS_PAYMENT]->(pay:Payment)
            WHERE (pay.verified IS NULL OR pay.verified = false)
            WITH DISTINCT pay
            RETURN
                COUNT(pay)      AS unverified_count,
                SUM(pay.amount) AS unverified_total
        END_OF_QUERY

        # Account meta (IBAN etc.)
        account_info = neo4j_query(<<~END_OF_QUERY, { bank_account_id: bank_account_id })
            MATCH (b:BankAccount {id: $bank_account_id})
            RETURN b.account_name AS account_name,
                   b.bank_name    AS bank_name,
                   b.iban         AS iban
        END_OF_QUERY

        respond(
            success:          true,
            account:          account_info.first || {},
            verified_count:   (verified.first&.dig('verified_count') || 0).to_i,
            verified_total:   (verified.first&.dig('verified_total') || 0.0).to_f.round(2),
            expected_count:   (expected.first&.dig('expected_count') || 0).to_i,
            expected_total:   (expected.first&.dig('expected_total') || 0.0).to_f.round(2),
            unverified_count: (unverified.first&.dig('unverified_count') || 0).to_i,
            unverified_total: (unverified.first&.dig('unverified_total') || 0.0).to_f.round(2)
        )
    end

    # Return the expected account balance for *all* orders of an event, across every bank
    # account. Gives an overview of what should be on the accounts versus what has actually
    # been received and verified.
    post "/api/audit_event_balance" do
        require_user_with_permission!("manage_orders")
        data = parse_request_data(required_keys: [:event_id])

        event_id = data[:event_id]

        # How much is owed in total (sum of all order prices, excluding error records)
        due = neo4j_query(<<~END_OF_QUERY, {event_id: event_id})
            MATCH (o:TicketOrder)-[:FOR]->(e:Event {id: $event_id})
            WHERE COALESCE(o.status, '') <> 'error'
            RETURN COUNT(DISTINCT o) AS order_count,
                   SUM(o.total_price) AS total_due
        END_OF_QUERY

        # How much has actually been received / verified
        received = neo4j_query(<<~END_OF_QUERY, {event_id: event_id})
            MATCH (o:TicketOrder)-[:FOR]->(e:Event {id: $event_id})
            MATCH (o)-[:HAS_PAYMENT]->(pay:Payment)
            RETURN
                COUNT(pay) AS received_count,
                SUM(pay.amount) AS received_total,
                SUM(CASE WHEN pay.verified = true THEN pay.verified_amount ELSE 0 END) AS verified_total,
                SUM(CASE WHEN pay.verified = true THEN 1 ELSE 0 END) AS verified_count,
                SUM(CASE WHEN (pay.verified IS NULL OR pay.verified = false) THEN pay.amount ELSE 0 END) AS unverified_total,
                SUM(CASE WHEN (pay.verified IS NULL OR pay.verified = false) THEN 1 ELSE 0 END) AS unverified_count,
                SUM(CASE WHEN pay.verified = true AND pay.verification_matches = false THEN 1 ELSE 0 END) AS deviation_count
        END_OF_QUERY

        # Per-account breakdown using the most recently assigned account of each order
        per_account = neo4j_query(<<~END_OF_QUERY, {event_id: event_id})
            MATCH (o:TicketOrder)-[:FOR]->(e:Event {id: $event_id})
            MATCH (o)-[:HAS_PAYMENT_REQUEST]->(pr:PaymentRequest)-[:USES_ACCOUNT]->(b:BankAccount)
            WITH o, b, pr
            ORDER BY pr.created_at DESC
            WITH o, HEAD(COLLECT(b)) AS bank
            MATCH (o)-[:HAS_PAYMENT]->(pay:Payment)
            RETURN bank.id AS account_id,
                   bank.account_name AS account_name,
                   bank.iban AS iban,
                   COUNT(pay) AS payment_count,
                   SUM(pay.amount) AS payment_total,
                   SUM(CASE WHEN pay.verified = true THEN pay.verified_amount ELSE 0 END) AS verified_total
            ORDER BY account_name
        END_OF_QUERY

        r = received.first || {}
        respond(
            success:          true,
            order_count:      (due.first&.dig('order_count') || 0).to_i,
            total_due:        (due.first&.dig('total_due') || 0.0).to_f.round(2),
            received_count:   (r['received_count'] || 0).to_i,
            received_total:   (r['received_total'] || 0.0).to_f.round(2),
            verified_count:   (r['verified_count'] || 0).to_i,
            verified_total:   (r['verified_total'] || 0.0).to_f.round(2),
            unverified_count: (r['unverified_count'] || 0).to_i,
            unverified_total: (r['unverified_total'] || 0.0).to_f.round(2),
            deviation_count:  (r['deviation_count'] || 0).to_i,
            accounts:         per_account.map { |a|
                {
                    account_id:     a['account_id'],
                    account_name:   a['account_name'],
                    iban:           a['iban'],
                    payment_count:  (a['payment_count'] || 0).to_i,
                    payment_total:  (a['payment_total'] || 0.0).to_f.round(2),
                    verified_total: (a['verified_total'] || 0.0).to_f.round(2)
                }
            }
        )
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
        if order['status'] == 'paid' || order['status'] == 'overpaid'
            respond(success: false, error: "Bestellung ist bereits bezahlt")
            return
        end
        
        # Verify bank account exists
        bank_result = neo4j_query(<<~END_OF_QUERY, {bank_account_id: bank_account_id})
            MATCH (b:BankAccount {id: $bank_account_id})
            RETURN b.id AS id, b.account_name AS account_name, b.bank_name AS bank_name,
                   b.iban AS iban, b.bic AS bic, b.escrow_document_url AS escrow_document_url
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
                   b.iban AS iban, b.bic AS bic, b.percentage AS percentage,
                   b.escrow_document_url AS escrow_document_url
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
    def send_payment_request_email(user_email, order_id, payment_ref, event, participants, total_price, bank_account, bank_account_changed: false, change_reason: nil)
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
        
        subject_line = bank_account_changed ? "Wichtige Information: Bankkontoänderung – #{event[:name]}" : "Zahlungsaufforderung - #{event[:name]}"
        
        deliver_mail do
            to user_email
            from SMTP_FROM
            subject subject_line
            
            content = StringIO.open do |io|
                io.puts "            <p>Hallo #{user_name},</p>"
                
                if bank_account_changed
                    io.puts "            <div style='background-color: #fff3cd; border: 1px solid #ffc107; border-radius: 5px; padding: 15px; margin-bottom: 15px;'>"
                    io.puts "                <strong>Wichtiger Hinweis: Bankkontoänderung</strong><br>"
                    io.puts "                <p>Wir mussten das Bankkonto für Deine Bestellung aktualisieren.</p>"
                    if change_reason && !change_reason.strip.empty?
                        io.puts "                <p>#{CGI.escapeHTML(change_reason.strip)}</p>"
                    end
                    io.puts "                <p>Falls Du bereits eine Überweisung an das alte Konto getätigt hast, ist das kein Problem. Bitte überweise andernfalls auf das unten angegebene <strong>neue Konto</strong>.</p>"
                    io.puts "                <p>Wende Dich bei Fragen an <a href='mailto:#{SUPPORT_EMAIL}'>#{SUPPORT_EMAIL}</a>. Vielen Dank für Dein Verständnis!</p>"
                    io.puts "            </div>"
                end
                
                io.puts "            <p>hier sind die Zahlungsinformationen für deine Ticket-Bestellung ##{order_id} (#{payment_ref})</p>"
                io.puts "            <p><strong>Anzahl Tickets:</strong> #{participants.length}</p>"
                io.puts "            <p><strong>Gesamtpreis:</strong> #{total_price.round(2)}€</p>"
                io.puts "            <h4>Bitte überweise auf folgendes Konto:</h4>"
                io.puts "            <ul>"
                io.puts "                <li><strong>Empfänger:</strong> #{bank_account['account_name']}</li>"
                io.puts "                <li><strong>Bank:</strong> #{bank_account['bank_name']}</li>"
                io.puts "                <li><strong>IBAN:</strong> #{bank_account['iban']}</li>"
                io.puts "                <li><strong>BIC:</strong> #{bank_account['bic']}</li>"
                io.puts "                <li><strong>Betrag:</strong> #{total_price.round(2)}€</li>"
                io.puts "                <li><strong>Verwendungszweck:</strong> #{payment_ref}</li>"
                if bank_account['escrow_document_url'] && !bank_account['escrow_document_url'].empty?
                    escaped_url = CGI.escapeHTML(bank_account['escrow_document_url'])
                    io.puts "                <li><strong>Treuhandvertrag:</strong> <a href='#{escaped_url}'>Vertrag ansehen</a></li>"
                end
                io.puts "            </ul>"
                
                if qr_code_data_uri
                    io.puts "            <div style='margin: 20px 0; padding: 15px; background-color: #f8f9fa; border-radius: 5px;'>"
                    io.puts "                <h4 style='margin-top: 0;'>Einfache Zahlung mit QR-Code</h4>"
                    io.puts "                <p>Scanne diesen QR-Code mit deiner Banking-App, um die Überweisung automatisch auszufüllen:</p>"
                    io.puts "                <img src='#{qr_code_data_uri}' alt='Payment QR Code' width='200' style='display: block; margin: 0 auto; max-width: 200px; width: 100%; height: auto; border: 0;' />"
                    io.puts "            </div>"
                end
                
                io.puts "            <p><strong>Wichtig:</strong> Bitte verwende unbedingt die Bestellnummer <code>#{payment_ref}</code> als Verwendungszweck!</p>"
                io.puts "            <p>Nach Zahlungseingang werden deine Tickets freigeschaltet.</p>"
                io.puts "            <p><a href=\"#{WEB_ROOT}/tickets\" class=\"btn\">Meine Bestellungen ansehen</a></p>"
                io.puts "            <p>Bei Fragen stehen wir dir gerne zur Verfügung: <a href='mailto:#{SUPPORT_EMAIL}'>#{SUPPORT_EMAIL}</a>.</p>"
                io.string
            end
            
            format_email_with_template("Zahlungsaufforderung", content)
        end
        log("Zahlungsaufforderung für Bestellung #{order_id} versendet")
    rescue => e
        log("Zahlungsaufforderung für Bestellung #{order_id} fehlgeschlagen: #{e.message}")
        raise e
    end

    # Change bank account for a single order and send updated payment request email
    post "/api/change_order_bank_account" do
        require_user_with_permission!("manage_orders")
        data = parse_request_data(required_keys: [:order_id, :new_bank_account_id], optional_keys: [:reason])
        
        order_id = data[:order_id]
        new_bank_account_id = data[:new_bank_account_id]
        reason = data[:reason] || ''
        
        # Fetch order details
        order_result = neo4j_query(<<~END_OF_QUERY, {order_id: order_id})
            MATCH (u:User)-[:PLACED]->(o:TicketOrder {id: $order_id})-[:FOR]->(e:Event)
            OPTIONAL MATCH (o)-[:INCLUDES]->(p:Participant)
            RETURN o.id AS order_id,
                   o.status AS status,
                   o.payment_reference AS payment_reference,
                   o.total_price AS total_price,
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
        
        # Skip already-paid orders
        if order['status'] == 'paid' || order['status'] == 'overpaid'
            respond(success: false, error: "Bezahlte Bestellungen können nicht geändert werden")
            return
        end
        
        # Verify new bank account exists
        bank_result = neo4j_query(<<~END_OF_QUERY, {bank_account_id: new_bank_account_id})
            MATCH (b:BankAccount {id: $bank_account_id})
            RETURN b.id AS id, b.account_name AS account_name, b.bank_name AS bank_name,
                   b.iban AS iban, b.bic AS bic, b.escrow_document_url AS escrow_document_url
        END_OF_QUERY
        
        if bank_result.empty?
            respond(success: false, error: "Bankkonto nicht gefunden")
            return
        end
        
        bank_account = bank_result.first
        
        # Create new payment request pointing to the new bank account
        payment_request_id = RandomTag::generate(12)
        created_at = DateTime.now.to_s
        
        pr_params = {
            order_id: order_id,
            payment_request_id: payment_request_id,
            bank_account_id: new_bank_account_id,
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
        
        # Send updated payment request email with bank change notification
        send_payment_request_email(
            order['user_email'],
            order_id,
            order['payment_reference'],
            event,
            order['participants'],
            order['total_price'].to_f,
            bank_account,
            bank_account_changed: true,
            change_reason: reason
        )
        
        log("Bankkonto für Bestellung #{order_id} geändert auf #{bank_account['account_name']}, neue Zahlungsaufforderung gesendet")
        respond(success: true, payment_request_id: payment_request_id)
    end

    post "/api/all_ticket_orders" do
        require_user_with_permission!("view_users")
        data = parse_request_data(required_keys: [], optional_keys: [:event_id])
        
        event_id = data[:event_id]
        
        # Build query with optional event filter using WHERE clause
        event_filter = (event_id && !event_id.to_s.empty?) ? "WHERE e.id = $event_id" : ""
        query_params = (event_id && !event_id.to_s.empty?) ? {event_id: event_id} : {}
        
        orders = neo4j_query(<<~END_OF_QUERY, query_params)
            MATCH (u:User)-[:PLACED]->(o:TicketOrder)-[:FOR]->(e:Event)
            #{event_filter}
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
            OPTIONAL MATCH (o)-[:HAS_PAYMENT]->(pay:Payment)
            WITH u, o, e, participants, latest_payment_request,
                 COALESCE(o.total_price, 0) AS total_price_val,
                 COALESCE(SUM(pay.amount), 0) AS total_paid_val
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
                   COALESCE(e.payment_required, true) AS event_payment_required,
                   participants,
                   latest_payment_request,
                   CASE WHEN total_paid_val <= 0 THEN 'pending'
                        WHEN total_paid_val < total_price_val THEN 'partially_paid'
                        ELSE 'paid' END AS payment_status,
                   total_paid_val AS total_paid,
                   CASE WHEN total_price_val - total_paid_val > 0 THEN total_price_val - total_paid_val ELSE 0 END AS remaining_balance,
                   CASE WHEN total_paid_val - total_price_val > 0 THEN total_paid_val - total_price_val ELSE 0 END AS overpayment
            ORDER BY o.created_at DESC
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
                 COLLECT(DISTINCT {name: p.name, phone: p.phone, email: p.email, birthdate: p.birthdate, ticket_number: p.ticket_number, redeemed: COALESCE(p.redeemed, false), redeemed_at: p.redeemed_at, redeemed_by: p.redeemed_by}) AS participants,
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
                   COALESCE(o.notes, '') AS notes,
                   COALESCE(o.admin_notes, '') AS admin_notes,
                   COALESCE(o.tickets_generated, false) AS tickets_generated,
                   o.reminder_1_override_days AS reminder_1_override_days,
                   o.reminder_2_override_days AS reminder_2_override_days,
                   o.cancellation_override_days AS cancellation_override_days,
                   e.id AS event_id,
                   COALESCE(e.name, '') AS event_name,
                   COALESCE(e.year, '') AS event_year,
                   COALESCE(e.payment_required, true) AS event_payment_required,
                   e.reminder_1_days AS event_reminder_1_days,
                   e.reminder_2_days AS event_reminder_2_days,
                   e.cancellation_days AS event_cancellation_days,
                   participants,
                   [x IN payment_requests WHERE x IS NOT NULL] AS payment_requests
        END_OF_QUERY
        
        if order_result.empty?
            respond(success: false, error: "Bestellung nicht gefunden")
            return
        end
        
        # Since we're getting a single order, extract the first result
        order = order_result.first
        
        # Add dynamically calculated payment info
        payment_info = calculate_payment_status(order_id)
        order['payment_status'] = payment_info[:status]
        order['total_paid'] = payment_info[:total_paid]
        order['remaining_balance'] = payment_info[:remaining]
        order['overpayment'] = payment_info[:overpayment]

        # Get individual payments
        payments = neo4j_query(<<~END_OF_QUERY, {order_id: order_id})
            MATCH (o:TicketOrder {id: $order_id})-[:HAS_PAYMENT]->(pay:Payment)
            RETURN pay.id AS id,
                   pay.amount AS amount,
                   pay.recorded_by AS recorded_by,
                   pay.note AS note,
                   pay.timestamp AS timestamp
            ORDER BY pay.timestamp DESC
        END_OF_QUERY
        order['payments'] = payments

        # Get dunning/reminder mail history for this order
        dunning_logs = neo4j_query(<<~END_OF_QUERY, {order_id: order_id})
            MATCH (m:ManualMailLog)-[:FOR_ORDER]->(o:TicketOrder {id: $order_id})
            WHERE m.template_key IN ['order_reminder_1', 'order_reminder_2', 'order_cancelled', 'order_cancelled_no_payment']
            RETURN m.template_key AS template_key,
                   m.timestamp AS sent_at,
                   m.sender_username AS sent_by
            ORDER BY m.timestamp ASC
        END_OF_QUERY
        order['dunning_history'] = dunning_logs
        
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
            RETURN e.max_tickets AS max_tickets, e.ticket_price AS ticket_price, e.visibility AS visibility, e.payment_required AS payment_required
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
                   COALESCE(r.ticket_price, e.ticket_price) AS price,
                   COALESCE(r.bypass_restrictions, false) AS bypass_restrictions
        END_OF_QUERY
        user_limit = user_limit_result.first&.dig('limit') || TICKETS_PER_USER
        ticket_price = user_limit_result.first&.dig('price')&.to_f || event['ticket_price'].to_f
        bypass_restrictions = user_limit_result.first&.dig('bypass_restrictions') || false
        
        # Check if user is blocked (limit = 0)
        if user_limit == 0
            respond(success: false, error: "Du bist temporär vom Ticketkauf für dieses Event ausgeschlossen.")
            return
        end
        
        # Get event tickets sold (include reserved/pending tickets)
        event_sold_result = neo4j_query(<<~END_OF_QUERY, {event_id: event_id})
            MATCH (e:Event {id: $event_id})<-[:FOR]-(o:TicketOrder)
            WHERE o.status = 'paid' OR o.status = 'pending' OR o.status = 'offline_payment'
            RETURN SUM(o.ticket_count) AS total
        END_OF_QUERY
        event_sold = event_sold_result.first&.dig('total') || 0
        
        # Get user's current tickets for this event
        user_orders = neo4j_query(<<~END_OF_QUERY, {email: user_email, event_id: event_id})
            MATCH (u:User {email: $email})-[:PLACED]->(o:TicketOrder)-[:FOR]->(e:Event {id: $event_id})
            WHERE o.status = 'paid' OR o.status = 'pending' OR o.status = 'offline_payment'
            RETURN o.ticket_count AS ticket_count
        END_OF_QUERY
        current_tickets = user_orders.sum { |o| o['ticket_count'] }
        
        available_event = event['max_tickets'] - event_sold
        # If user has bypass_restrictions, don't limit by event availability
        effective_available_event = bypass_restrictions ? Float::INFINITY : available_event
        available_user = user_limit - current_tickets
        max_order = [effective_available_event, available_user].min.to_i
        
        respond(success: true, 
                user_limit: user_limit, 
                ticket_price: ticket_price,
                current_tickets: current_tickets,
                available_user: available_user,
                available_event: available_event,
                max_tickets_event: event['max_tickets'],
                event_sold: event_sold,
                max_order: max_order > 0 ? max_order : 0,
                payment_required: event['payment_required'] != false,
                bypass_restrictions: bypass_restrictions)
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
                 COLLECT(DISTINCT {name: p.name, phone: p.phone, email: p.email, birthdate: p.birthdate, ticket_number: p.ticket_number, redeemed: COALESCE(p.redeemed, false), redeemed_at: p.redeemed_at}) AS participants,
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
                    bic: b.bic,
                    escrow_document_url: b.escrow_document_url
                 } ELSE null END)[0] AS latest_payment_request
            RETURN o.id AS order_id,
                   o.ticket_count AS ticket_count,
                   o.total_price AS total_price,
                   o.individual_ticket_price AS individual_ticket_price,
                   o.payment_reference AS payment_reference,
                   o.created_at AS created_at,
                   COALESCE(o.paid_at, '') AS paid_at,
                   COALESCE(o.status, '') AS status,
                   COALESCE(o.notes, '') AS notes,
                   COALESCE(o.tier_name, t.name, 'Standard') AS tier_name,
                   e.id AS event_id,
                   e.name AS event_name,
                   e.year AS event_year,
                   COALESCE(e.ticket_generation_enabled, false) AS event_ticket_generation_enabled,
                   COALESCE(o.tickets_generated, false) AS tickets_generated,
                   participants,
                   latest_payment_request
            ORDER BY o.created_at DESC
        END_OF_QUERY

        # Add calculated payment info for each order
        orders.each do |order|
            payment_info = calculate_payment_status(order['order_id'])
            order['payment_status'] = payment_info[:status]
            order['total_paid'] = payment_info[:total_paid]
            order['remaining_balance'] = payment_info[:remaining]
        end
        
        respond(success: true, orders: orders)
    end

    # Admin: Update ticket order
    post "/api/update_ticket_order" do
        require_user_with_permission!("manage_orders")
        data = parse_request_data(
            required_keys: [:order_id, :ticket_count, :total_price, :payment_reference, :status],
            optional_keys: [:participants, :user_name, :user_email, :user_address, :user_phone, :notes, :admin_notes],
            types: {
                ticket_count: Integer,
                participants: Array
            },
            max_body_length: 10 * 1024 * 1024,
            max_string_length: 5 * 1024 * 1024,
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
        notes = data[:notes] || ''
        admin_notes = data[:admin_notes] || ''

        # Payment-derived statuses (paid, partially_paid, pending) are always
        # calculated from actual payment records and cannot be set manually.
        # Payments are the single source of truth and are NEVER deleted here.
        payment_info = calculate_payment_status(order_id)
        if PAYMENT_DERIVED_STATUSES.include?(status)
            status = payment_info[:status]
        end
        
        # Update order basic information
        update_params = {
            order_id: order_id,
            ticket_count: ticket_count,
            total_price: total_price,
            payment_reference: payment_reference,
            status: status,
            notes: notes,
            admin_notes: admin_notes
        }

        neo4j_query(<<~END_OF_QUERY, update_params)
            MATCH (o:TicketOrder {id: $order_id})
            SET o.ticket_count = $ticket_count,
                o.total_price = $total_price,
                o.payment_reference = $payment_reference,
                o.status = $status,
                o.notes = $notes,
                o.admin_notes = $admin_notes
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
        
        # Delete participants, payments, payment requests, and order
        neo4j_query(<<~END_OF_QUERY, {order_id: order_id})
            MATCH (o:TicketOrder {id: $order_id})
            OPTIONAL MATCH (o)-[:INCLUDES]->(p:Participant)
            OPTIONAL MATCH (o)-[:HAS_PAYMENT]->(pay:Payment)
            OPTIONAL MATCH (o)-[:HAS_PAYMENT_REQUEST]->(pr:PaymentRequest)
            DETACH DELETE p, pay, pr, o
        END_OF_QUERY
        
        respond(success: true, message: "Bestellung wurde erfolgreich gelöscht")
    end

    # API endpoint for order statistics
    post "/api/get_order_statistics" do
        require_user_with_permission!("view_users")
        data = parse_request_data(optional_keys: [:event_id])
        
        event_id = data[:event_id]
        
        # Initialize variables for forecast-related data
        target_tickets = nil
        expected_users = nil
        
        if event_id && !event_id.empty?
            # Event-specific statistics
            # Get paid tickets (sold and confirmed - includes paid and offline_payment)
            tickets_paid_result = neo4j_query(<<~END_OF_QUERY, {event_id: event_id})
                MATCH (o:TicketOrder)-[:FOR]->(e:Event {id: $event_id})
                WHERE o.status = 'paid' OR o.status = 'offline_payment'
                RETURN SUM(o.ticket_count) AS total
            END_OF_QUERY
            tickets_paid = tickets_paid_result.first&.dig('total') || 0
            
            # Get reserved (pending only) tickets
            tickets_reserved_result = neo4j_query(<<~END_OF_QUERY, {event_id: event_id})
                MATCH (o:TicketOrder)-[:FOR]->(e:Event {id: $event_id})
                WHERE o.status = 'pending'
                RETURN SUM(o.ticket_count) AS total
            END_OF_QUERY
            tickets_reserved = tickets_reserved_result.first&.dig('total') || 0
            
            # Total tickets sold includes both paid/offline_payment and reserved
            total_tickets_sold = tickets_paid + tickets_reserved
            
            # Get event data including target_tickets and expected_users
            event_data = neo4j_query(<<~END_OF_QUERY, {event_id: event_id})
                MATCH (e:Event {id: $event_id})
                RETURN e.max_tickets AS max_tickets, e.target_tickets AS target_tickets, e.expected_users AS expected_users
            END_OF_QUERY
            max_tickets = event_data.first&.dig('max_tickets') || 0
            target_tickets = event_data.first&.dig('target_tickets')
            expected_users = event_data.first&.dig('expected_users')
            # Available tickets excludes both paid/offline_payment and reserved tickets
            tickets_available = max_tickets - total_tickets_sold
            
            # Get order counts by status for this event
            order_counts_result = neo4j_query(<<~END_OF_QUERY, {event_id: event_id})
                MATCH (o:TicketOrder)-[:FOR]->(e:Event {id: $event_id})
                RETURN o.status AS status, COUNT(o) AS count
            END_OF_QUERY
            
            paid_orders = 0
            pending_orders = 0
            order_counts_result.each do |row|
                if row['status'] == 'paid' || row['status'] == 'overpaid' || row['status'] == 'offline_payment'
                    paid_orders += row['count']
                elsif row['status'] == 'pending'
                    pending_orders = row['count']
                end
            end

            # Calculate paid revenue for this event (includes paid and offline_payment)
            revenue_paid_result = neo4j_query(<<~END_OF_QUERY, {event_id: event_id})
                MATCH (o:TicketOrder)-[:FOR]->(e:Event {id: $event_id})
                WHERE o.status = 'paid' OR o.status = 'overpaid' OR o.status = 'offline_payment'
                RETURN SUM(o.total_price) AS total_revenue
            END_OF_QUERY
            revenue_paid_total = revenue_paid_result.first&.dig('total_revenue') || 0.0
            
            # Calculate total revenue for this event (all orders)
            revenue_result = neo4j_query(<<~END_OF_QUERY, {event_id: event_id})
                MATCH (o:TicketOrder)-[:FOR]->(e:Event {id: $event_id})
                RETURN SUM(o.total_price) AS total_revenue
            END_OF_QUERY
            revenue_total = revenue_result.first&.dig('total_revenue') || 0.0
            
            # Count total participants for this event (paid and reserved orders)
            participants_result = neo4j_query(<<~END_OF_QUERY, {event_id: event_id})
                MATCH (o:TicketOrder)-[:FOR]->(e:Event {id: $event_id})
                MATCH (o)-[:INCLUDES]->(p:Participant)
                WHERE (o.status = 'paid' OR o.status = 'pending' OR o.status = 'offline_payment') AND p.name IS NOT NULL AND p.name <> ''
                RETURN COUNT(p) AS total_participants
            END_OF_QUERY
            total_participants = participants_result.first&.dig('total_participants') || 0
            
            # Count unique users who placed orders for this event (paid, pending and offline_payment)
            unique_users_result = neo4j_query(<<~END_OF_QUERY, {event_id: event_id})
                MATCH (u:User)-[:PLACED]->(o:TicketOrder)-[:FOR]->(e:Event {id: $event_id})
                WHERE o.status = 'paid' OR o.status = 'pending' OR o.status = 'offline_payment'
                RETURN COUNT(DISTINCT u) AS unique_users
            END_OF_QUERY
            unique_users = unique_users_result.first&.dig('unique_users') || 0
        else
            # Global statistics (all events)
            # Get paid tickets (includes paid and offline_payment)
            tickets_paid_result = neo4j_query(<<~END_OF_QUERY)
                MATCH (o:TicketOrder)
                WHERE o.status = 'paid' OR o.status = 'offline_payment'
                RETURN SUM(o.ticket_count) AS total
            END_OF_QUERY
            tickets_paid = tickets_paid_result.first&.dig('total') || 0
            
            # Get reserved tickets (pending only)
            tickets_reserved_result = neo4j_query(<<~END_OF_QUERY)
                MATCH (o:TicketOrder)
                WHERE o.status = 'pending'
                RETURN SUM(o.ticket_count) AS total
            END_OF_QUERY
            tickets_reserved = tickets_reserved_result.first&.dig('total') || 0
            
            # Total tickets includes both paid/offline_payment and reserved
            total_tickets_sold = tickets_paid + tickets_reserved
            
            # Calculate tickets available (excludes both paid/offline_payment and reserved)
            tickets_available = MAX_TICKETS_GLOBAL - total_tickets_sold
            
            # Get order counts by status
            order_counts_result = neo4j_query(<<~END_OF_QUERY)
                MATCH (o:TicketOrder)
                RETURN o.status AS status, COUNT(o) AS count
            END_OF_QUERY
            
            paid_orders = 0
            pending_orders = 0
            order_counts_result.each do |row|
                if row['status'] == 'paid' || row['status'] == 'overpaid' || row['status'] == 'offline_payment'
                    paid_orders += row['count']
                elsif row['status'] == 'pending'
                    pending_orders = row['count']
                end
            end

            # Calculate total paid revenue (includes paid and offline_payment)
            revenue_paid_result = neo4j_query(<<~END_OF_QUERY)
                MATCH (o:TicketOrder)
                WHERE o.status = 'paid' OR o.status = 'overpaid' OR o.status = 'offline_payment'
                RETURN SUM(o.total_price) AS total_revenue
            END_OF_QUERY
            revenue_paid_total = revenue_paid_result.first&.dig('total_revenue') || 0.0
            
            # Calculate total revenue (all orders)
            revenue_result = neo4j_query(<<~END_OF_QUERY)
                MATCH (o:TicketOrder)
                RETURN SUM(o.total_price) AS total_revenue
            END_OF_QUERY
            revenue_total = revenue_result.first&.dig('total_revenue') || 0.0
            
            # Count total participants (paid, pending and offline_payment orders)
            participants_result = neo4j_query(<<~END_OF_QUERY)
                MATCH (o:TicketOrder)-[:INCLUDES]->(p:Participant)
                WHERE (o.status = 'paid' OR o.status = 'pending' OR o.status = 'offline_payment') AND p.name IS NOT NULL AND p.name <> ''
                RETURN COUNT(p) AS total_participants
            END_OF_QUERY
            total_participants = participants_result.first&.dig('total_participants') || 0
            
            # Count unique users who placed orders (paid, pending and offline_payment)
            unique_users_result = neo4j_query(<<~END_OF_QUERY)
                MATCH (u:User)-[:PLACED]->(o:TicketOrder)
                WHERE o.status = 'paid' OR o.status = 'pending' OR o.status = 'offline_payment'
                RETURN COUNT(DISTINCT u) AS unique_users
            END_OF_QUERY
            unique_users = unique_users_result.first&.dig('unique_users') || 0
        end
        
        # Calculate average tickets per participant (user who placed order)
        # This is total_tickets_sold / unique_users
        avg_tickets_per_participant = unique_users > 0 ? (total_tickets_sold.to_f / unique_users).round(2) : 0.0
        
        # Calculate forecast based on expected users (if available)
        forecast_tickets = nil
        forecast_difference = nil
        if expected_users && expected_users > 0 && avg_tickets_per_participant > 0
            forecast_tickets = (expected_users * avg_tickets_per_participant).to_i
            if target_tickets && target_tickets > 0
                forecast_difference = forecast_tickets - target_tickets
            end
        end
        
        # Calculate progress toward target (if target is set)
        target_progress_percent = nil
        if target_tickets && target_tickets > 0
            target_progress_percent = ((total_tickets_sold.to_f / target_tickets) * 100).round(1)
        end
        
        statistics = {
            total_tickets_sold: total_tickets_sold,
            tickets_paid: tickets_paid,
            tickets_reserved: tickets_reserved,
            tickets_available: tickets_available,
            paid_orders: paid_orders,
            pending_orders: pending_orders,
            revenue_paid_total: revenue_paid_total.round(2),
            revenue_total: revenue_total.round(2),
            total_participants: total_participants,
            # New statistics
            unique_users: unique_users,
            avg_tickets_per_participant: avg_tickets_per_participant,
            target_tickets: target_tickets,
            expected_users: expected_users,
            forecast_tickets: forecast_tickets,
            forecast_difference: forecast_difference,
            target_progress_percent: target_progress_percent
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
        
        can_generate = (order['status'] == 'paid' || order['status'] == 'overpaid' || order['status'] == 'offline_payment') && !order['tickets_generated']
        
        respond(success: true, can_generate_tickets: can_generate, order_status: order['status'], tickets_generated: !!order['tickets_generated'])
    end

    # Generate tickets for a paid or offline_payment order (admin only)
    post "/api/generate_tickets" do
        require_user_with_permission!("manage_orders")
        data = parse_request_data(required_keys: [:order_id])
        
        order_id = data[:order_id]
        
        # Get order details and verify it's paid or offline_payment
        order = neo4j_query_expect_one(<<~END_OF_QUERY, {order_id: order_id})
            MATCH (u:User)-[:PLACED]->(o:TicketOrder {id: $order_id})
            OPTIONAL MATCH (o)-[:INCLUDES]->(p:Participant)
            RETURN o.status AS status,
                   o.tickets_generated AS tickets_generated,
                   o.payment_reference AS payment_reference,
                   COLLECT({name: p.name, phone: p.phone, email: p.email, birthdate: p.birthdate, ticket_number: p.ticket_number}) AS participants
        END_OF_QUERY
        
        unless order['status'] == 'paid' || order['status'] == 'overpaid' || order['status'] == 'offline_payment'
            respond(success: false, error: "Tickets können nur für bestätigte Bestellungen generiert werden")
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
        
        unless order_data['status'] == 'paid' || order_data['status'] == 'overpaid'
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
        
        # Generate PDF (single ticket wrapped in 3-per-page layout)
        pdf_content = generate_ticket_pdf_content(order_info, participant)

        respond_raw_with_mimetype_and_filename(
            pdf_content,
            'application/pdf',
            "Ticket_#{order_data['payment_reference']}_#{ticket_number}.pdf"
        )
    end

    # Download all tickets for an order as one PDF (3 tickets per A4 page)
    get "/api/download_order_tickets/:order_id" do
        require_user!

        order_id = params[:order_id]
        unless order_id && !order_id.empty?
            respond(success: false, error: "Ungültige Parameter")
            return
        end

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

        unless is_admin || ALLOW_USER_TICKET_DOWNLOAD
            respond(success: false, error: "Ticket-Download ist derzeit nicht verfügbar")
            return
        end

        order_result = neo4j_query(<<~END_OF_QUERY, {order_id: order_id})
            MATCH (u:User)-[:PLACED]->(o:TicketOrder {id: $order_id})
            MATCH (o)-[:INCLUDES]->(p:Participant)
            MATCH (o)-[:FOR]->(e:Event)
            RETURN o.id AS order_id,
                   o.payment_reference AS payment_reference,
                   o.status AS status,
                   o.tickets_generated AS tickets_generated,
                   e.start_datetime AS event_start_datetime,
                   p.name AS participant_name,
                   p.phone AS participant_phone,
                   p.email AS participant_email,
                   p.birthdate AS participant_birthdate,
                   p.ticket_number AS participant_ticket_number
            ORDER BY p.ticket_number ASC
        END_OF_QUERY

        if order_result.empty?
            respond(success: false, error: "Bestellung nicht gefunden")
            return
        end

        first = order_result.first
        unless first['status'] == 'paid' || first['status'] == 'overpaid'
            respond(success: false, error: "Tickets sind nur für bezahlte Bestellungen verfügbar")
            return
        end

        unless first['tickets_generated']
            respond(success: false, error: "Tickets wurden noch nicht freigegeben")
            return
        end

        order_info = {
            'order_id'             => first['order_id'],
            'payment_reference'    => first['payment_reference'],
            'event_start_datetime' => first['event_start_datetime']
        }

        participants = order_result.map do |row|
            {
                'name'          => row['participant_name'],
                'phone'         => row['participant_phone'],
                'email'         => row['participant_email'],
                'birthdate'     => row['participant_birthdate'],
                'ticket_number' => row['participant_ticket_number']
            }
        end

        pdf_content = generate_order_tickets_pdf(order_info, participants)
        filename = "Tickets_#{first['payment_reference']}.pdf"
        respond_raw_with_mimetype_and_filename(pdf_content, 'application/pdf', filename)
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
            # Add calculated payment info
            payment_info = calculate_payment_status(order['order_id'])
            order['payment_status'] = payment_info[:status]
            order['total_paid'] = payment_info[:total_paid]
            order['remaining_balance'] = payment_info[:remaining]
            respond(success: true, order: order)
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
            
            total_tickets_sold = orders.select { |o| o['status'] == 'paid' || o['status'] == 'overpaid' }.sum { |o| o['ticket_count'] || 0 }
            tickets_available = MAX_TICKETS_GLOBAL - total_tickets_sold
            total_paid_revenue = orders.select { |o| o['status'] == 'paid' || o['status'] == 'overpaid' }.sum { |o| o['total_price']&.to_f || 0.0 }
            total_revenue = orders.sum { |o| o['total_price']&.to_f || 0.0 }
            paid_orders = orders.count { |o| o['status'] == 'paid' || o['status'] == 'overpaid' }
            pending_orders = orders.count { |o| o['status'] == 'pending' }
            
            stats_data = [
                ['Verkaufte Tickets:', total_tickets_sold.to_s],
                ['Verfügbare Tickets:', tickets_available.to_s],
                ['Gesamtumsatz:', "#{total_revenue.round(2)}€"],
                ['Bestätigter Umsatz:', "#{total_paid_revenue.round(2)}€"],
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
                    status_text = self.class.get_order_status_text(order['status'])
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
                ['Status:', self.class.get_order_status_text(order['status'])],
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

    # Locate optional ticket artwork. If a single-ticket image exists it is used as the
    # full-bleed background and only the dynamic fields (name, QR, age) are overlaid.
    def ticket_background_image_path
        base = File.expand_path(File.join(File.dirname(__FILE__), '..', '..', 'static', 'images'))
        %w[ticket_background.png ticket_background.jpg abiball_ticket.png abiball_ticket.jpg].each do |name|
            path = File.join(base, name)
            return path if File.exist?(path)
        end
        nil
    end

    # Draw one "Abiball-Ticket" (burgundy & gold design) into the region whose top-left is
    # [0, y_top] within the current page bounds. Three of these fit on an A4 page.
    def draw_single_ticket(pdf, y_top, ticket_height, order, participant, security_id, reference_date)
        w = pdf.bounds.width
        h = ticket_height

        # Palette (vintage burgundy / gold)
        burgundy      = '5C0F18'
        burgundy_dark = '2E060B'
        gold          = 'C6A24C'
        gold_light    = 'E6D6A8'
        cream         = 'F1E8CF'

        qr_data = {
            order_id: order['order_id'],
            ticket_number: participant['ticket_number'],
            participant_name: participant['name'],
            event: EVENT_NAME,
            security_id: security_id,
            verification_hash: Digest::SHA256.hexdigest("#{order['order_id']}-#{participant['ticket_number']}-#{security_id}")
        }.to_json

        age_category = if participant['birthdate'] && !participant['birthdate'].to_s.empty?
            get_age_category(participant['birthdate'], reference_date)
        end
        age_label = age_category || '18+'
        name      = participant['name'].to_s
        org_label = defined?(TICKET_VERTICAL_LABEL) ? TICKET_VERTICAL_LABEL : EVENT_NAME
        bg_image  = ticket_background_image_path

        pdf.bounding_box([0, y_top], width: w, height: h) do
            stub_w = w * 0.115
            main_w = w - stub_w

            if bg_image
                begin
                    pdf.image bg_image, at: [0, h], width: w, height: h
                rescue StandardError
                    bg_image = nil
                end
            end

            unless bg_image
                # ---------- Vector recreation of the ticket artwork ----------
                # Body + dark vignette edge
                pdf.fill_color burgundy
                pdf.fill_rounded_rectangle [0, h], w, h, 10
                pdf.stroke_color burgundy_dark
                pdf.line_width 5
                pdf.stroke_rounded_rectangle [3, h - 3], w - 6, h - 6, 9

                # Perforation separating main area from the stub
                pdf.stroke_color gold
                pdf.line_width 0.8
                pdf.dash(2, space: 2)
                pdf.stroke_vertical_line 8, h - 8, at: main_w
                pdf.undash

                # Gold double-line cartouche
                cart_x   = main_w * 0.045
                cart_w   = main_w * 0.91
                cart_top = h - h * 0.08
                cart_h   = h * 0.84
                pdf.line_width 2
                pdf.stroke_color gold
                pdf.stroke_rounded_rectangle [cart_x, cart_top], cart_w, cart_h, 12
                pdf.line_width 0.8
                pdf.stroke_color gold_light
                pdf.stroke_rounded_rectangle [cart_x + 5, cart_top - 5], cart_w - 10, cart_h - 10, 9

                # Title
                pdf.fill_color gold_light
                pdf.font('Times-Roman', style: :bold_italic) do
                    pdf.text_box 'Abiball-Ticket',
                        at: [cart_x, cart_top - h * 0.05],
                        width: cart_w, height: h * 0.22,
                        size: h * 0.155, align: :center, valign: :top
                end
                # Event name (small, under the title)
                pdf.fill_color gold
                pdf.font('Times-Roman', style: :italic) do
                    pdf.text_box EVENT_NAME.to_s,
                        at: [cart_x, cart_top - h * 0.24],
                        width: cart_w, height: h * 0.07,
                        size: h * 0.06, align: :center, valign: :top
                end

                # "Für:" label (aligned with the name line)
                pdf.fill_color gold_light
                pdf.font('Times-Roman', style: :italic) do
                    pdf.text_box 'Für:',
                        at: [cart_x + cart_w * 0.14, cart_top - h * 0.32],
                        width: cart_w * 0.16, height: h * 0.10,
                        size: h * 0.085, valign: :center
                end

                # Vertical stub with the organiser / school name
                pdf.line_width 1.2
                pdf.stroke_color gold
                pdf.stroke_rounded_rectangle [main_w + stub_w * 0.18, h - h * 0.08],
                    stub_w * 0.64, h * 0.84, 6
                pdf.fill_color gold_light
                pdf.font('Times-Roman', style: :bold_italic) do
                    pdf.rotate(90, origin: [main_w + stub_w * 0.5, h * 0.5]) do
                        pdf.text_box org_label.to_s,
                            at: [main_w + stub_w * 0.5 - h * 0.42, h * 0.5 + stub_w * 0.22],
                            width: h * 0.84, height: stub_w * 0.5,
                            size: [stub_w * 0.34, 13].min,
                            align: :center, valign: :center, overflow: :shrink_to_fit
                    end
                end
            end

            # ---------- Dynamic fields (drawn in both modes) ----------
            cart_x   = main_w * 0.045
            cart_w   = main_w * 0.91
            cart_top = h - h * 0.08
            cart_bottom = cart_top - h * 0.84
            # The ticket writing area is dark burgundy in both modes, so use light gold text.
            name_color = gold_light

            # Participant name on the "Für" line + underline
            nx1 = cart_x + cart_w * 0.30
            nx2 = cart_x + cart_w * 0.74
            name_top = cart_top - h * 0.32
            pdf.fill_color name_color
            pdf.font('Times-Roman', style: :bold_italic) do
                pdf.text_box name,
                    at: [nx1, name_top],
                    width: nx2 - nx1, height: h * 0.10,
                    size: h * 0.085, align: :center, valign: :center,
                    overflow: :shrink_to_fit
            end
            unless bg_image
                pdf.stroke_color gold
                pdf.line_width 1
                pdf.stroke_horizontal_line nx1, nx2, at: name_top - h * 0.10
            end

            # Inner cartouche boundary references (inner line is 5pt inset from outer)
            inner_left   = cart_x + 5
            inner_right  = cart_x + cart_w - 5
            inner_top    = cart_top - 5
            inner_bottom = cart_bottom + 5
            # Shared margin so age badge, QR code and info text keep the same distance
            # from the inner cartouche border lines.
            corner_margin = 5

            # QR code: bottom-right corner, same margin as age badge
            qr_side   = h * 0.34
            qr_x    = inner_right - corner_margin - 5 - qr_side
            qr_top  = inner_bottom + corner_margin + qr_side + 5
            pdf.fill_color cream
            pdf.fill_rounded_rectangle [qr_x - 5, qr_top + 5], qr_side + 10, qr_side + 10, 4
            pdf.fill_color '000000'
            pdf.bounding_box([qr_x, qr_top], width: qr_side, height: qr_side) do
                pdf.print_qr_code(qr_data, extent: qr_side)
            end

            # Age badge: top-left corner with equal margin to inner borders
            badge_w = [w * 0.085, 48].min
            badge_h = h * 0.11
            badge_x = inner_left + corner_margin
            badge_y = inner_top - corner_margin
            pdf.fill_color gold
            pdf.fill_rounded_rectangle [badge_x, badge_y], badge_w, badge_h, 3
            pdf.fill_color burgundy_dark
            pdf.font('Helvetica', style: :bold) do
                pdf.text_box age_label,
                    at: [badge_x, badge_y], width: badge_w, height: badge_h,
                    size: h * 0.06, align: :center, valign: :center
            end

            # Info / security micro-text: bottom-left corner, same margin as badge/QR
            info_color  = bg_image ? 'F1E8CF' : gold
            info_lines  = [
                "Ticket-Nr.: #{participant['ticket_number']}",
                "Bestellnr.: #{order['payment_reference'] || '-'}",
                "Ticket-ID: #{security_id}"
            ].join("\n")
            info_size   = h * 0.038
            info_h      = h * 0.18
            info_bottom = inner_bottom + corner_margin
            pdf.fill_color info_color
            pdf.font('Helvetica') do
                pdf.text_box info_lines,
                    at: [inner_left + corner_margin, info_bottom + info_h],
                    width: qr_x - inner_left - corner_margin - 8,
                    height: info_h,
                    size: info_size, leading: h * 0.010,
                    valign: :bottom, overflow: :shrink_to_fit
            end

            # Design credit, centred just below the cartouche
            pdf.fill_color info_color
            pdf.font('Times-Roman', style: :italic) do
                pdf.text_box 'Ticket-Design: Yuhan',
                    at: [cart_x, cart_bottom - 1],
                    width: cart_w, height: h * 0.055,
                    size: h * 0.035, align: :center, valign: :center,
                    overflow: :shrink_to_fit
            end

            pdf.fill_color '000000'
            pdf.stroke_color '000000'
        end
    end

    # Generate a single PDF with all tickets for an order – 3 tickets per A4 page
    def generate_order_tickets_pdf(order, participants)
        reference_date = if order['event_start_datetime'] && !order['event_start_datetime'].empty?
            begin
                DateTime.parse(order['event_start_datetime']).to_date
            rescue ArgumentError
                Date.today
            end
        else
            Date.today
        end

        tickets_per_page = 3
        ticket_gap = 6

        Prawn::Document.new(page_size: 'A4', margin: [12, 18, 12, 18]) do |pdf|
            ticket_height = (pdf.bounds.height - (tickets_per_page - 1) * ticket_gap) / tickets_per_page.to_f

            participants.each_with_index do |participant, idx|
                slot = idx % tickets_per_page
                pdf.start_new_page if slot == 0 && idx > 0

                security_id = SecureRandom.hex(8).upcase
                y_top = pdf.bounds.top - slot * (ticket_height + ticket_gap)
                draw_single_ticket(pdf, y_top, ticket_height, order, participant, security_id, reference_date)
            end

            # Page numbers
            pdf.number_pages "Seite <page> / <total>",
                at: [pdf.bounds.right - 60, 0],
                align: :right,
                size: 8
        end.render
    end

    # Legacy single-ticket PDF (kept for backwards compatibility)
    def generate_ticket_pdf_content(order, participant)
        generate_order_tickets_pdf(order, [participant])
    end

    # Send order confirmation email
    # Send order received confirmation email (without payment details)
    # This is sent immediately when an order is placed
    def send_order_received_email(user_email, order_id, payment_ref, event, participants, total_price, payment_required = true)
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
                if payment_required
                    io.puts "            <div class=\"info-badge\">"
                    io.puts "                <strong>Nächste Schritte:</strong>"
                    io.puts "                <p>Du erhältst in Kürze eine separate E-Mail mit den Zahlungsinformationen. Deine Tickets werden nach Eingang der Zahlung final bestätigt.</p>"
                    io.puts "            </div>"
                else
                    io.puts "            <div class=\"info-badge\">"
                    io.puts "                <strong>Zahlung vor Ort:</strong>"
                    io.puts "                <p>Für dieses Event ist keine Online-Zahlung erforderlich. Die Bezahlung erfolgt vor Ort (z.B. in bar). Du erhältst weitere Informationen in einer separaten Nachricht.</p>"
                    io.puts "            </div>"
                end
                io.puts "            <p><a href=\"#{WEB_ROOT}/tickets\" class=\"btn\">Meine Bestellungen ansehen</a></p>"
                io.puts "            <p>Bei Fragen stehen wir dir gerne zur Verfügung: <a href='mailto:#{SUPPORT_EMAIL}'>#{SUPPORT_EMAIL}</a>.</p>"
                io.string
            end
            
            format_email_with_template("Bestellung eingegangen", content)
        end
        log("Bestelleingang für Bestellung #{order_id} versendet")
    # rescue => e
    #     log("Bestelleingang für Bestellung #{order_id} fehlgeschlagen: #{e.message}")
    #     debug e
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

    # Advanced guest list PDF with configurable columns and status filters
    def generate_guest_list_pdf_advanced(event, participants, opts = {})
        show_phone        = opts.fetch(:show_phone, true)
        show_email        = opts.fetch(:show_email, true)
        show_birthdate    = opts.fetch(:show_birthdate, false)
        show_age_category = opts.fetch(:show_age_category, true)

        event_date_str = if event['start_datetime'] && !event['start_datetime'].to_s.empty?
            begin
                DateTime.parse(event['start_datetime']).strftime('%d.%m.%Y %H:%M')
            rescue ArgumentError
                '-'
            end
        end

        Prawn::Document.new(page_size: 'A4', margin: [40, 30, 40, 30]) do |pdf|
            # Title
            pdf.text "#{event['name']} – Gästeliste", size: 18, style: :bold, align: :center
            pdf.move_down 6
            pdf.text "Veranstaltungsort: #{event['location']}", size: 11, align: :center if event['location'] && !event['location'].to_s.empty?
            pdf.text "Datum: #{event_date_str}", size: 11, align: :center if event_date_str
            pdf.text "Erstellt am: #{Date.today.strftime('%d.%m.%Y')}", size: 9, align: :center, style: :italic
            pdf.move_down 16

            # Statistics
            total = participants.length
            paid_count    = participants.count { |p| ['paid', 'overpaid'].include?(p['order_status']) }
            pending_count = participants.count { |p| !['paid', 'overpaid'].include?(p['order_status']) }

            pdf.text "Teilnehmer gesamt: #{total}  |  bezahlt: #{paid_count}  |  ausstehend: #{pending_count}",
                size: 10, align: :center
            pdf.move_down 14

            # Build dynamic columns
            headers = ['Nr.', 'Bestellnr.', 'Name']
            headers << 'Geburtsdatum'   if show_birthdate
            headers << 'Alterskategorie' if show_age_category
            headers << 'Telefon'        if show_phone
            headers << 'E-Mail'         if show_email
            headers << 'Status'
            headers << 'Besteller'

            # Calculate reference date for age category
            reference_date = if event['start_datetime'] && !event['start_datetime'].to_s.empty?
                begin
                    DateTime.parse(event['start_datetime']).to_date
                rescue ArgumentError
                    Date.today
                end
            else
                Date.today
            end

            if participants.any?
                table_data = [headers]

                participants.each_with_index do |p, idx|
                    row_data = [
                        (idx + 1).to_s,
                        p['payment_reference'] || p['order_id'] || '-',
                        p['participant_name'] || '-'
                    ]
                    if show_birthdate
                        bd = p['participant_birthdate']
                        row_data << (bd && !bd.empty? ? begin Date.parse(bd).strftime('%d.%m.%Y') rescue bd end : '-')
                    end
                    if show_age_category
                        bd = p['participant_birthdate']
                        cat = if bd && !bd.empty?
                            cat_raw = get_age_category(bd, reference_date)
                            cat_raw ? cat_raw : '18+'
                        else
                            'unbekannt'
                        end
                        row_data << cat
                    end
                    row_data << (p['participant_phone'] || '-') if show_phone
                    row_data << (p['participant_email'] || '-') if show_email
                    status_map = {
                        'paid' => 'bezahlt', 'overpaid' => 'überbezahlt',
                        'pending' => 'ausstehend', 'in_review' => 'in Prüfung',
                        'partially_paid' => 'teilw. bezahlt', 'contact_required' => 'Kontakt nötig',
                        'offline_payment' => 'Barzahlung'
                    }
                    row_data << (status_map[p['order_status']] || p['order_status'] || '-')
                    row_data << (p['user_name'] || p['user_email'] || '-')
                    table_data << row_data
                end

                # Dynamic column widths
                available_width = pdf.bounds.width
                fixed_cols = { 0 => 24, 1 => 62 }  # Nr., Bestellnr.
                remaining = available_width - fixed_cols.values.sum
                variable_count = headers.length - fixed_cols.length
                default_w = remaining / variable_count.to_f

                col_widths = headers.each_index.map do |i|
                    fixed_cols[i] || default_w
                end

                # Compensate for floating point rounding so the column widths
                # sum exactly to available_width. Otherwise Prawn may raise
                # CannotFit when the total is marginally larger than the table.
                width_diff = available_width - col_widths.sum
                last_variable_index = headers.each_index.to_a.reverse.find { |i| !fixed_cols.key?(i) }
                col_widths[last_variable_index] += width_diff if last_variable_index

                num_rows = table_data.length
                pdf.table table_data, {
                    header: true,
                    width: available_width,
                    cell_style: { size: 8, padding: [3, 4, 3, 4] },
                    column_widths: col_widths
                } do
                    row(0).font_style = :bold
                    row(0).background_color = 'e8e8e8'
                    cells.borders = [:top, :bottom, :left, :right]
                    cells.border_width = 0.5
                    row(0).border_width = 1
                    (1..num_rows - 1).each do |r|
                        rows(r).background_color = r.odd? ? 'FFFFFF' : 'F7F7F7'
                    end
                end
            else
                pdf.text "Keine Teilnehmer gefunden.", size: 11, style: :italic
            end

            pdf.move_down 20
            pdf.text "Automatisch generiert am #{DateTime.now.strftime('%d.%m.%Y %H:%M')} Uhr.",
                size: 8, style: :italic, align: :center
            pdf.number_pages "Seite <page> von <total>",
                at: [pdf.bounds.right - 60, 0], align: :right, size: 9
        end.render
    end

    # Advanced guest list export (POST, supports filters and column selection)
    post "/api/export_guest_list_pdf_advanced" do
        require_user_with_permission!("view_users")
        data = parse_request_data(
            required_keys: [:event_id],
            optional_keys: [:include_paid, :include_pending, :show_phone, :show_email,
                            :show_birthdate, :show_age_category]
        )

        event_id       = data[:event_id]
        include_paid    = data[:include_paid]    != false && data[:include_paid]    != 'false'
        include_pending = data[:include_pending] == true  || data[:include_pending] == 'true'
        show_phone        = data[:show_phone]        != false && data[:show_phone]        != 'false'
        show_email        = data[:show_email]        != false && data[:show_email]        != 'false'
        show_birthdate    = data[:show_birthdate]    == true  || data[:show_birthdate]    == 'true'
        show_age_category = data[:show_age_category] != false && data[:show_age_category] != 'false'

        statuses = []
        statuses += ['paid', 'overpaid', 'offline_payment'] if include_paid
        statuses += ['pending', 'in_review', 'contact_required', 'partially_paid'] if include_pending

        if statuses.empty?
            respond(success: false, error: "Mindestens einen Status (bezahlt oder ausstehend) auswählen")
            return
        end

        event = neo4j_query_expect_one(<<~END_OF_QUERY, {event_id: event_id})
            MATCH (e:Event {id: $event_id})
            RETURN e.name AS name, e.location AS location, e.start_datetime AS start_datetime
        END_OF_QUERY

        participants = neo4j_query(<<~END_OF_QUERY, {event_id: event_id, statuses: statuses})
            MATCH (e:Event {id: $event_id})<-[:FOR]-(o:TicketOrder)-[:INCLUDES]->(p:Participant)
            MATCH (u:User)-[:PLACED]->(o)
            WHERE o.status IN $statuses
            RETURN p.name AS participant_name,
                   p.phone AS participant_phone,
                   p.email AS participant_email,
                   p.birthdate AS participant_birthdate,
                   p.ticket_number AS ticket_number,
                   u.email AS user_email,
                   u.name AS user_name,
                   o.payment_reference AS payment_reference,
                   o.id AS order_id,
                   o.status AS order_status
            ORDER BY p.name ASC
        END_OF_QUERY

        pdf_content = generate_guest_list_pdf_advanced(event, participants, {
            show_phone:        show_phone,
            show_email:        show_email,
            show_birthdate:    show_birthdate,
            show_age_category: show_age_category
        })

        filename = "Gaesteliste_#{event['name'].gsub(/[^a-zA-Z0-9]/, '_')}_#{Date.today.strftime('%Y%m%d')}.pdf"
        respond_raw_with_mimetype_and_filename(pdf_content, 'application/pdf', filename)
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

    # Get user's tickets for download
    post "/api/get_user_tickets" do
        require_user!
        
        user_email = @session_user[:email]
        
        # Get all orders by the user with generated tickets
        tickets = neo4j_query(<<~END_OF_QUERY, {user_email: user_email})
            MATCH (u:User {email: $user_email})-[:PLACED]->(o:TicketOrder)-[:FOR]->(e:Event)
            WHERE (o.status = 'paid' OR o.status = 'offline_payment') AND o.tickets_generated = true
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
        
        # Get all paid and offline_payment orders for this event that don't have tickets generated yet
        orders = neo4j_query(<<~END_OF_QUERY, {event_id: event_id})
            MATCH (o:TicketOrder)-[:FOR]->(e:Event {id: $event_id})
            WHERE (o.status = 'paid' OR o.status = 'offline_payment') AND (o.tickets_generated IS NULL OR o.tickets_generated = false)
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
            unless ticket['order_status'] == 'paid' || ticket['order_status'] == 'overpaid'
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
        
        unless ticket['order_status'] == 'paid' || ticket['order_status'] == 'overpaid'
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

    # Undo redemption of a specific ticket (by order_id + ticket_number)
    post "/api/undo_ticket_redemption" do
        require_user_with_permission!("manage_orders")
        data = parse_request_data(required_keys: [:order_id, :ticket_number])

        order_id = data[:order_id]
        ticket_number = data[:ticket_number].to_i

        result = neo4j_query(<<~END_OF_QUERY, {order_id: order_id, ticket_number: ticket_number})
            MATCH (o:TicketOrder {id: $order_id})-[:INCLUDES]->(p:Participant {ticket_number: $ticket_number})
            RETURN p.redeemed AS redeemed, p.name AS name
        END_OF_QUERY

        if result.empty?
            respond(success: false, error: "Ticket nicht gefunden")
            return
        end

        unless result.first['redeemed']
            respond(success: false, error: "Ticket ist nicht eingelöst")
            return
        end

        neo4j_query(<<~END_OF_QUERY, {order_id: order_id, ticket_number: ticket_number})
            MATCH (o:TicketOrder {id: $order_id})-[:INCLUDES]->(p:Participant {ticket_number: $ticket_number})
            SET p.redeemed = false
            REMOVE p.redeemed_at, p.redeemed_by
        END_OF_QUERY

        log("Ticket Einlösung rückgängig gemacht (Order Management): Order #{order_id}, Ticket ##{ticket_number} durch #{@session_user[:email]}")

        respond(
            success: true,
            message: "Einlösung rückgängig gemacht",
            ticket: {
                order_id: order_id,
                ticket_number: ticket_number,
                name: result.first['name']
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
            WHERE (o.status = 'paid' OR o.status = 'offline_payment') #{event_filter}
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
            WHERE (o.status = 'paid' OR o.status = 'offline_payment')
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
            WHERE (o.status = 'paid' OR o.status = 'offline_payment')
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
            WHERE (o.status = 'paid' OR o.status = 'offline_payment')
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
            WHERE (o.status = 'paid' OR o.status = 'offline_payment')
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

    # All participants endpoint for participants management page
    post "/api/all_participants" do
        require_user_with_permission!("view_users")
        data = parse_request_data(optional_keys: [:event_id])

        event_id = data[:event_id]

        # Build optional event filter
        event_filter = (event_id && !event_id.to_s.empty?) ? "WHERE e.id = $event_id" : ""
        query_params = (event_id && !event_id.to_s.empty?) ? { event_id: event_id } : {}

        # Fetch all participants with related order and event info (no N+1)
        rows = neo4j_query(<<~END_OF_QUERY, query_params)
            MATCH (u:User)-[:PLACED]->(o:TicketOrder)-[:FOR]->(e:Event)
            #{event_filter}
            MATCH (o)-[:INCLUDES]->(p:Participant)
            WHERE p.name IS NOT NULL AND p.name <> ''
            RETURN
                p.name          AS name,
                p.birthdate     AS birthdate,
                p.ticket_number AS ticket_number,
                COALESCE(p.redeemed, false) AS redeemed,
                p.redeemed_at   AS redeemed_at,
                p.redeemed_by   AS redeemed_by,
                o.id            AS order_id,
                o.payment_reference AS payment_reference,
                COALESCE(o.status, '') AS order_status,
                COALESCE(o.tier_name, '') AS tier_name,
                e.id            AS event_id,
                COALESCE(e.name, '') AS event_name,
                e.start_datetime AS event_start_datetime
            ORDER BY p.name
        END_OF_QUERY

        participants = rows.map do |row|
            birthdate = row['birthdate']
            # Use event start date as reference (like ticket generation), fall back to today
            reference_date = begin
                event_start = row['event_start_datetime']
                (event_start && !event_start.empty?) ? DateTime.parse(event_start).to_date : Date.today
            rescue ArgumentError
                Date.today
            end
            age = begin
                birthdate ? calculate_age(birthdate, reference_date) : nil
            rescue ArgumentError
                nil
            end
            age_status = get_age_status(birthdate, reference_date)
            {
                name:             row['name'],
                birthdate:        birthdate,
                age:              age,
                age_category:     age_status ? age_status[:category] : nil,
                age_color:        age_status ? age_status[:color]    : nil,
                ticket_number:    row['ticket_number'],
                tier_name:        row['tier_name'],
                order_id:         row['order_id'],
                payment_reference: row['payment_reference'],
                order_status:     row['order_status'],
                event_id:         row['event_id'],
                event_name:       row['event_name'],
                redeemed:         row['redeemed'] ? true : false,
                redeemed_at:      row['redeemed_at'],
                redeemed_by:      row['redeemed_by']
            }
        end

        # Compute statistics
        ages_with_value = participants.map { |p| p[:age] }.compact
        total_participants = participants.size
        avg_age = ages_with_value.empty? ? nil : (ages_with_value.sum.to_f / ages_with_value.size).round(1)

        age_group_counts = {
            "<14" => 0,
            "<16" => 0,
            "<18" => 0,
            "18+"  => 0,
            "unbekannt" => 0
        }
        participants.each do |p|
            key = p[:age_category] || "unbekannt"
            age_group_counts[key] = (age_group_counts[key] || 0) + 1
        end

        statistics = {
            total_participants: total_participants,
            avg_age: avg_age,
            age_group_counts: age_group_counts
        }

        respond(success: true, participants: participants, statistics: statistics)
    end

    # ===========================================
    # Guest list check-in (tablet-friendly manual check-in)
    #
    # These endpoints back the /guest_list page. They are gated by the dedicated
    # "guest_list" permission so a device can be set up to *only* do check-in
    # without the broader "view_users" / "manage_orders" rights. Scanner devices
    # that also carry the permission can jump to the guest list and back.
    # ===========================================

    # Active events for the guest list event picker. Unlike /api/get_events this
    # is not restricted to public events, since a check-in device must be able to
    # select whichever event is currently taking place.
    post "/api/guest_list_events" do
        require_user_with_permission!("guest_list")

        events = neo4j_query(<<~END_OF_QUERY)
            MATCH (e:Event)
            WHERE e.active = true
            RETURN e.id AS id,
                   COALESCE(e.name, e.id) AS name,
                   e.start_datetime AS start_datetime,
                   e.year AS year
            ORDER BY COALESCE(e.start_datetime, '') DESC, COALESCE(e.name, '')
        END_OF_QUERY

        respond(success: true, events: events.map { |e| {
            id: e['id'],
            name: e['name'],
            start_datetime: e['start_datetime'],
            year: e['year']
        }})
    end

    # Participants for the guest list, alphabetically by name. Includes the
    # order/payment status so the frontend can tell which entries may be checked
    # in and which are (still) unpaid.
    post "/api/guest_list_participants" do
        require_user_with_permission!("guest_list")
        data = parse_request_data(optional_keys: [:event_id])

        event_id = data[:event_id]
        event_filter = (event_id && !event_id.to_s.empty?) ? "WHERE e.id = $event_id" : ""
        query_params = (event_id && !event_id.to_s.empty?) ? { event_id: event_id } : {}

        rows = neo4j_query(<<~END_OF_QUERY, query_params)
            MATCH (u:User)-[:PLACED]->(o:TicketOrder)-[:FOR]->(e:Event)
            #{event_filter}
            MATCH (o)-[:INCLUDES]->(p:Participant)
            WHERE p.name IS NOT NULL AND p.name <> ''
            RETURN
                p.name          AS name,
                p.birthdate     AS birthdate,
                p.ticket_number AS ticket_number,
                COALESCE(p.redeemed, false) AS redeemed,
                p.redeemed_at   AS redeemed_at,
                p.redeemed_by   AS redeemed_by,
                o.id            AS order_id,
                o.payment_reference AS payment_reference,
                COALESCE(o.status, '') AS order_status,
                COALESCE(o.tier_name, '') AS tier_name,
                e.id            AS event_id,
                COALESCE(e.name, '') AS event_name,
                e.start_datetime AS event_start_datetime
            ORDER BY toLower(p.name)
        END_OF_QUERY

        participants = rows.map do |row|
            birthdate = row['birthdate']
            reference_date = begin
                event_start = row['event_start_datetime']
                (event_start && !event_start.empty?) ? DateTime.parse(event_start).to_date : Date.today
            rescue ArgumentError
                Date.today
            end
            age_status = get_age_status(birthdate, reference_date)
            order_status = row['order_status']
            {
                name:              row['name'],
                ticket_number:     row['ticket_number'],
                order_id:          row['order_id'],
                payment_reference: row['payment_reference'],
                tier_name:         row['tier_name'],
                order_status:      order_status,
                paid:              (order_status == 'paid' || order_status == 'overpaid'),
                age_category:      age_status ? age_status[:category] : nil,
                age_color:         age_status ? age_status[:color]    : nil,
                redeemed:          row['redeemed'] ? true : false,
                redeemed_at:       row['redeemed_at'],
                redeemed_by:       row['redeemed_by']
            }
        end

        checked_in = participants.count { |p| p[:redeemed] }

        respond(
            success: true,
            participants: participants,
            statistics: {
                total: participants.size,
                checked_in: checked_in,
                not_checked_in: participants.size - checked_in
            }
        )
    end

    # Check a participant in from the guest list (equivalent to redeeming their
    # ticket manually). Only paid orders may be checked in.
    post "/api/guest_list_check_in" do
        require_user_with_permission!("guest_list")
        data = parse_request_data(required_keys: [:order_id, :ticket_number])

        order_id = data[:order_id]
        ticket_number = data[:ticket_number]

        ticket_result = neo4j_query(<<~END_OF_QUERY, {order_id: order_id, ticket_number: ticket_number})
            MATCH (o:TicketOrder {id: $order_id})-[:INCLUDES]->(p:Participant {ticket_number: $ticket_number})
            RETURN COALESCE(p.redeemed, false) AS redeemed, o.status AS order_status, p.name AS name
        END_OF_QUERY

        if ticket_result.empty?
            respond(success: false, error: "Teilnehmer nicht gefunden")
            return
        end

        ticket = ticket_result.first

        unless ticket['order_status'] == 'paid' || ticket['order_status'] == 'overpaid'
            respond(success: false, error: "Bestellung ist nicht bezahlt")
            return
        end

        if ticket['redeemed']
            respond(success: false, error: "Teilnehmer ist bereits eingecheckt")
            return
        end

        redeemed_at = DateTime.now.to_s
        neo4j_query(<<~END_OF_QUERY, {order_id: order_id, ticket_number: ticket_number, redeemed_at: redeemed_at, redeemed_by: @session_user[:email]})
            MATCH (o:TicketOrder {id: $order_id})-[:INCLUDES]->(p:Participant {ticket_number: $ticket_number})
            SET p.redeemed = true,
                p.redeemed_at = $redeemed_at,
                p.redeemed_by = $redeemed_by
        END_OF_QUERY

        log("Gästeliste Check-in: #{ticket['name']} (Bestellung #{order_id}, Ticket ##{ticket_number})")

        respond(
            success: true,
            message: "Eingecheckt",
            redeemed_at: redeemed_at,
            redeemed_by: @session_user[:email]
        )
    end

    # Undo a guest list check-in.
    post "/api/guest_list_check_out" do
        require_user_with_permission!("guest_list")
        data = parse_request_data(required_keys: [:order_id, :ticket_number])

        order_id = data[:order_id]
        ticket_number = data[:ticket_number]

        result = neo4j_query(<<~END_OF_QUERY, {order_id: order_id, ticket_number: ticket_number})
            MATCH (o:TicketOrder {id: $order_id})-[:INCLUDES]->(p:Participant {ticket_number: $ticket_number})
            RETURN COALESCE(p.redeemed, false) AS redeemed, p.name AS name
        END_OF_QUERY

        if result.empty?
            respond(success: false, error: "Teilnehmer nicht gefunden")
            return
        end

        unless result.first['redeemed']
            respond(success: false, error: "Teilnehmer ist nicht eingecheckt")
            return
        end

        neo4j_query(<<~END_OF_QUERY, {order_id: order_id, ticket_number: ticket_number})
            MATCH (o:TicketOrder {id: $order_id})-[:INCLUDES]->(p:Participant {ticket_number: $ticket_number})
            SET p.redeemed = false
            REMOVE p.redeemed_at, p.redeemed_by
        END_OF_QUERY

        log("Gästeliste Check-in rückgängig gemacht: #{result.first['name']} (Bestellung #{order_id}, Ticket ##{ticket_number}) durch #{@session_user[:email]}")

        respond(success: true, message: "Check-in rückgängig gemacht")
    end

    # ===========================================
    # Seat Planning - Users and their participants (flat per row, grouped by user in Ruby)
    # ===========================================
    post "/api/get_seat_planning_data" do
        require_user_with_permission!("seat_planning")
        data = parse_request_data(optional_keys: [:event_id])

        event_id = data[:event_id]
        event_filter = (event_id && !event_id.to_s.empty?) ? "AND e.id = $event_id" : ""
        query_params = (event_id && !event_id.to_s.empty?) ? { event_id: event_id } : {}

        # Mirror the all_participants query: use a plain MATCH on Participant so the
        # join is correct, then group by ordering user in Ruby.
        rows = neo4j_query(<<~END_OF_QUERY, query_params)
            MATCH (u:User)-[:PLACED]->(o:TicketOrder)-[:FOR]->(e:Event)
            MATCH (o)-[:INCLUDES]->(p:Participant)
            WHERE p.name IS NOT NULL AND p.name <> ''
            #{event_filter}
            RETURN
                u.username AS username,
                u.name     AS user_name,
                u.email    AS user_email,
                u.phone    AS user_phone,
                p.name     AS participant_name,
                p.birthdate AS participant_birthdate,
                e.id       AS event_id,
                COALESCE(e.name, '') AS event_name,
                e.start_datetime AS event_start_datetime
            ORDER BY u.name, p.name
        END_OF_QUERY

        users_by_username = {}
        rows.each do |row|
            uname = row['username']
            users_by_username[uname] ||= {
                username:     uname,
                name:         row['user_name'],
                email:        row['user_email'],
                phone:        row['user_phone'],
                participants: []
            }

            birthdate = row['participant_birthdate']
            reference_date = begin
                event_start = row['event_start_datetime']
                (event_start && !event_start.empty?) ? DateTime.parse(event_start).to_date : Date.today
            rescue ArgumentError
                Date.today
            end
            age = begin
                birthdate ? calculate_age(birthdate, reference_date) : nil
            rescue ArgumentError
                nil
            end
            age_status = get_age_status(birthdate, reference_date)

            users_by_username[uname][:participants] << {
                name:         row['participant_name'],
                birthdate:    birthdate,
                age:          age,
                age_category: age_status ? age_status[:category] : nil,
                age_color:    age_status ? age_status[:color]    : nil,
                event_id:     row['event_id'],
                event_name:   row['event_name']
            }
        end

        users = users_by_username.values
            .each { |u| u[:participant_count] = u[:participants].size }
            .sort_by { |u| (u[:name] || '').downcase }

        respond(success: true, users: users)
    end

    # ===========================================
    # Dunning System (Mahnwesen) - Duration-based
    # ===========================================

    # Get dunning status for an event - shows which orders are due for reminders/cancellation
    post "/api/get_dunning_status" do
        require_user_with_permission!("manage_orders")
        data = parse_request_data(required_keys: [:event_id])

        event_id = data[:event_id]

        # Get event dunning configuration
        event = neo4j_query_expect_one(<<~END_OF_QUERY, {event_id: event_id})
            MATCH (e:Event {id: $event_id})
            WHERE e.active = true
            RETURN e.reminder_1_days AS reminder_1_days,
                   e.reminder_2_days AS reminder_2_days,
                   e.cancellation_days AS cancellation_days,
                   e.auto_cancel_enabled AS auto_cancel_enabled,
                   e.name AS name
        END_OF_QUERY

        # Get all unpaid orders with payment request info
        orders = neo4j_query(<<~END_OF_QUERY, {event_id: event_id, excluded_statuses: DUNNING_EXCLUDED_STATUSES})
            MATCH (u:User)-[:PLACED]->(o:TicketOrder)-[:FOR]->(e:Event {id: $event_id})
            WHERE NOT o.status IN $excluded_statuses
            OPTIONAL MATCH (o)-[:HAS_PAYMENT]->(pay:Payment)
            OPTIONAL MATCH (o)-[:HAS_PAYMENT_REQUEST]->(pr:PaymentRequest)
            WITH o, u,
                 COALESCE(SUM(DISTINCT pay.amount), 0) AS total_paid,
                 COUNT(DISTINCT pr) AS payment_request_count,
                 MAX(pr.sent_at) AS last_payment_request_sent
            WHERE total_paid < o.total_price AND payment_request_count > 0
            RETURN o.id AS order_id,
                   o.total_price AS total_price,
                   o.payment_reference AS payment_reference,
                   o.created_at AS created_at,
                   o.status AS status,
                   o.reminder_1_override_days AS reminder_1_override_days,
                   o.reminder_2_override_days AS reminder_2_override_days,
                   o.cancellation_override_days AS cancellation_override_days,
                   u.email AS user_email,
                   u.name AS user_name,
                   u.username AS username,
                   total_paid,
                   last_payment_request_sent
            ORDER BY o.created_at ASC
        END_OF_QUERY

        # Get reminder mail counts for each order
        order_ids = orders.map { |o| o['order_id'] }

        reminder_counts = {}
        unless order_ids.empty?
            counts = neo4j_query(<<~END_OF_QUERY, {order_ids: order_ids})
                MATCH (m:ManualMailLog)-[:FOR_ORDER]->(o:TicketOrder)
                WHERE o.id IN $order_ids
                  AND m.template_key IN ['order_reminder_1', 'order_reminder_2']
                RETURN o.id AS order_id, m.template_key AS template_key, COUNT(m) AS count
            END_OF_QUERY

            counts.each do |c|
                reminder_counts[c['order_id']] ||= {}
                reminder_counts[c['order_id']][c['template_key']] = c['count']
            end
        end

        now = Time.now

        # Enrich orders with computed dunning info
        orders.each do |order|
            oid = order['order_id']
            order['reminder_1_sent'] = (reminder_counts.dig(oid, 'order_reminder_1') || 0) > 0
            order['reminder_2_sent'] = (reminder_counts.dig(oid, 'order_reminder_2') || 0) > 0
            order['remaining'] = [(order['total_price'].to_f - order['total_paid'].to_f), 0].max.round(2)

            # Calculate days since payment request was sent
            sent_at = order['last_payment_request_sent']
            if sent_at
                begin
                    sent_time = Time.parse(sent_at.to_s)
                    order['days_since_payment_request'] = ((now - sent_time) / 86400).floor
                rescue
                    order['days_since_payment_request'] = nil
                end
            else
                order['days_since_payment_request'] = nil
            end

            # Calculate effective deadlines (per-order override > event default)
            r1_days = order['reminder_1_override_days'] || event['reminder_1_days']
            r2_days = order['reminder_2_override_days'] || event['reminder_2_days']
            c_days = order['cancellation_override_days'] || event['cancellation_days']
            order['effective_reminder_1_days'] = r1_days
            order['effective_reminder_2_days'] = r2_days
            order['effective_cancellation_days'] = c_days

            # Determine if each action is due
            days = order['days_since_payment_request']
            order['reminder_1_due'] = days && r1_days && days >= r1_days && !order['reminder_1_sent']
            order['reminder_2_due'] = days && r2_days && days >= r2_days && !order['reminder_2_sent']
            order['cancellation_due'] = days && c_days && days >= c_days
        end

        respond(success: true, event: event, orders: orders)
    end

    # Send bulk reminders (reminder_1 or reminder_2) to due orders for an event
    post "/api/send_bulk_reminders" do
        require_user_with_permission!("manage_orders")
        data = parse_request_data(
            required_keys: [:event_id, :reminder_type],
            max_body_length: 1024,
            max_string_length: 512
        )

        event_id = data[:event_id]
        reminder_type = data[:reminder_type]

        unless ['order_reminder_1', 'order_reminder_2'].include?(reminder_type)
            respond(success: false, error: 'Ungültiger Mahnungstyp')
            return
        end

        # Get event dunning config
        event = neo4j_query_expect_one(<<~END_OF_QUERY, {event_id: event_id})
            MATCH (e:Event {id: $event_id})
            WHERE e.active = true
            RETURN e.reminder_1_days AS reminder_1_days,
                   e.reminder_2_days AS reminder_2_days
        END_OF_QUERY

        # Get all unpaid orders with payment request
        orders = neo4j_query(<<~END_OF_QUERY, {event_id: event_id, excluded_statuses: DUNNING_EXCLUDED_STATUSES})
            MATCH (u:User)-[:PLACED]->(o:TicketOrder)-[:FOR]->(e:Event {id: $event_id})
            WHERE NOT o.status IN $excluded_statuses
            OPTIONAL MATCH (o)-[:HAS_PAYMENT]->(pay:Payment)
            OPTIONAL MATCH (o)-[:HAS_PAYMENT_REQUEST]->(pr:PaymentRequest)
            WITH o, u,
                 COALESCE(SUM(DISTINCT pay.amount), 0) AS total_paid,
                 COUNT(DISTINCT pr) AS payment_request_count,
                 MAX(pr.sent_at) AS last_payment_request_sent
            WHERE total_paid < o.total_price AND payment_request_count > 0
            RETURN o.id AS order_id,
                   o.total_price AS total_price,
                   o.payment_reference AS payment_reference,
                   o.reminder_1_override_days AS reminder_1_override_days,
                   o.reminder_2_override_days AS reminder_2_override_days,
                   u.email AS user_email,
                   u.name AS user_name,
                   u.username AS username,
                   total_paid,
                   last_payment_request_sent
        END_OF_QUERY

        # Check which orders already received this reminder
        order_ids = orders.map { |o| o['order_id'] }
        already_sent = {}
        unless order_ids.empty?
            counts = neo4j_query(<<~END_OF_QUERY, {order_ids: order_ids, template_key: reminder_type})
                MATCH (m:ManualMailLog {template_key: $template_key})-[:FOR_ORDER]->(o:TicketOrder)
                WHERE o.id IN $order_ids
                RETURN o.id AS order_id, COUNT(m) AS count
            END_OF_QUERY
            counts.each { |c| already_sent[c['order_id']] = c['count'] > 0 }
        end

        now = Time.now
        sent_count = 0
        skipped_count = 0
        errors = []

        orders.each do |order|
            # Skip if already sent
            if already_sent[order['order_id']]
                skipped_count += 1
                next
            end

            # Check if this order is due based on duration
            sent_at = order['last_payment_request_sent']
            next unless sent_at

            begin
                days_elapsed = ((now - Time.parse(sent_at.to_s)) / 86400).floor
            rescue
                next
            end

            # Determine effective days for this reminder type
            if reminder_type == 'order_reminder_1'
                effective_days = order['reminder_1_override_days'] || event['reminder_1_days']
            else
                effective_days = order['reminder_2_override_days'] || event['reminder_2_days']
            end

            # Skip if no deadline configured or not yet due
            unless effective_days && days_elapsed >= effective_days
                skipped_count += 1
                next
            end

            remaining = (order['total_price'].to_f - order['total_paid'].to_f).round(2)

            begin
                template = get_manual_mail_template(reminder_type)
                next unless template

                replacements = {
                    'NAME' => order['user_name'] || order['user_email'],
                    'ORDER_ID' => order['order_id'],
                    'REFERENCE' => order['payment_reference'],
                    'TOTAL_PRICE' => sprintf('%.2f', remaining)
                }

                rendered = render_manual_mail_template(reminder_type, replacements)

                send_manual_mail(
                    to_email: order['user_email'],
                    subject: rendered[:subject],
                    body: rendered[:body],
                    template_key: reminder_type,
                    sender_username: @session_user[:username],
                    recipient_username: order['username'],
                    order_id: order['order_id']
                )

                sent_count += 1
            rescue => e
                errors << {order_id: order['order_id'], error: e.message}
            end
        end

        log("Bulk-Mahnung (#{reminder_type}) für Event #{event_id}: #{sent_count} gesendet, #{skipped_count} übersprungen")

        respond(success: true, sent_count: sent_count, skipped_count: skipped_count, total_orders: orders.length, errors: errors)
    end

    # Bulk cancel unpaid orders for an event (only fully unpaid)
    post "/api/bulk_cancel_unpaid" do
        require_user_with_permission!("manage_orders")
        data = parse_request_data(required_keys: [:event_id])

        event_id = data[:event_id]

        # Get event dunning config
        event = neo4j_query_expect_one(<<~END_OF_QUERY, {event_id: event_id})
            MATCH (e:Event {id: $event_id})
            WHERE e.active = true
            RETURN e.cancellation_days AS cancellation_days
        END_OF_QUERY

        # Get all unpaid orders that have received payment request
        orders = neo4j_query(<<~END_OF_QUERY, {event_id: event_id, excluded_statuses: DUNNING_EXCLUDED_STATUSES})
            MATCH (u:User)-[:PLACED]->(o:TicketOrder)-[:FOR]->(e:Event {id: $event_id})
            WHERE NOT o.status IN $excluded_statuses
            OPTIONAL MATCH (o)-[:HAS_PAYMENT]->(pay:Payment)
            OPTIONAL MATCH (o)-[:HAS_PAYMENT_REQUEST]->(pr:PaymentRequest)
            WITH o, u,
                 COALESCE(SUM(DISTINCT pay.amount), 0) AS total_paid,
                 COUNT(DISTINCT pr) AS payment_request_count,
                 MAX(pr.sent_at) AS last_payment_request_sent
            WHERE total_paid < o.total_price AND payment_request_count > 0
            RETURN o.id AS order_id,
                   o.total_price AS total_price,
                   o.payment_reference AS payment_reference,
                   o.cancellation_override_days AS cancellation_override_days,
                   u.email AS user_email,
                   u.name AS user_name,
                   u.username AS username,
                   total_paid,
                   last_payment_request_sent
        END_OF_QUERY

        now = Time.now
        cancelled_count = 0
        skipped_count = 0
        errors = []

        orders.each do |order|
            total_paid = order['total_paid'].to_f

            # Skip partially paid orders
            if total_paid > 0
                skipped_count += 1
                next
            end

            # Check if cancellation is due based on duration
            sent_at = order['last_payment_request_sent']
            next unless sent_at

            begin
                days_elapsed = ((now - Time.parse(sent_at.to_s)) / 86400).floor
            rescue
                next
            end

            effective_days = order['cancellation_override_days'] || event['cancellation_days']

            unless effective_days && days_elapsed >= effective_days
                skipped_count += 1
                next
            end

            begin
                neo4j_query(<<~END_OF_QUERY, {order_id: order['order_id']})
                    MATCH (o:TicketOrder {id: $order_id})
                    SET o.status = 'cancelled'
                END_OF_QUERY

                # Send cancellation email
                template = get_manual_mail_template('order_cancelled')
                if template
                    replacements = {
                        'NAME' => order['user_name'] || order['user_email'],
                        'ORDER_ID' => order['order_id'],
                        'REFERENCE' => order['payment_reference']
                    }

                    rendered = render_manual_mail_template('order_cancelled', replacements)

                    send_manual_mail(
                        to_email: order['user_email'],
                        subject: rendered[:subject],
                        body: rendered[:body],
                        template_key: 'order_cancelled',
                        sender_username: @session_user[:username],
                        recipient_username: order['username'],
                        order_id: order['order_id']
                    )
                end

                cancelled_count += 1
            rescue => e
                errors << {order_id: order['order_id'], error: e.message}
            end
        end

        log("Bulk-Stornierung für Event #{event_id}: #{cancelled_count} storniert, #{skipped_count} übersprungen")

        respond(success: true, cancelled_count: cancelled_count, skipped_count: skipped_count, total_orders: orders.length, errors: errors)
    end

    # Update dunning overrides for a specific order
    post "/api/update_order_dunning_overrides" do
        require_user_with_permission!("manage_orders")
        data = parse_request_data(
            required_keys: [:order_id],
            optional_keys: [:reminder_1_override_days, :reminder_2_override_days, :cancellation_override_days],
            types: {reminder_1_override_days: Integer, reminder_2_override_days: Integer, cancellation_override_days: Integer}
        )

        order_id = data[:order_id]

        updates = []
        params = {order_id: order_id}

        [:reminder_1_override_days, :reminder_2_override_days, :cancellation_override_days].each do |field|
            if data.key?(field)
                updates << "o.#{field} = $#{field}"
                params[field] = data[field]
            end
        end

        if updates.any?
            neo4j_query(<<~END_OF_QUERY, params)
                MATCH (o:TicketOrder {id: $order_id})
                SET #{updates.join(', ')}
            END_OF_QUERY
        end

        log("Dunning-Overrides für Bestellung #{order_id} aktualisiert: #{params.reject { |k, _| k == :order_id }.inspect}")

        respond(success: true)
    end

    # Send a dunning reminder or cancellation for a single order
    post "/api/send_order_dunning" do
        require_user_with_permission!("manage_orders")
        data = parse_request_data(
            required_keys: [:order_id, :dunning_type],
            max_body_length: 1024,
            max_string_length: 512
        )

        order_id = data[:order_id]
        dunning_type = data[:dunning_type]

        unless ['order_reminder_1', 'order_reminder_2', 'order_cancelled', 'order_cancelled_no_payment'].include?(dunning_type)
            respond(success: false, error: 'Ungültiger Mahnungstyp')
            return
        end

        # Get order details with user info
        order = neo4j_query(<<~END_OF_QUERY, {order_id: order_id})
            MATCH (u:User)-[:PLACED]->(o:TicketOrder {id: $order_id})
            OPTIONAL MATCH (o)-[:HAS_PAYMENT]->(pay:Payment)
            WITH o, u, COALESCE(SUM(pay.amount), 0) AS total_paid
            RETURN o.id AS order_id,
                   o.total_price AS total_price,
                   o.payment_reference AS payment_reference,
                   o.status AS status,
                   u.email AS user_email,
                   u.name AS user_name,
                   u.username AS username,
                   total_paid
        END_OF_QUERY

        order = order.first
        unless order
            respond(success: false, error: 'Bestellung nicht gefunden')
            return
        end

        remaining = (order['total_price'].to_f - order['total_paid'].to_f).round(2)

        # For cancellation types, also set order status to cancelled
        if ['order_cancelled', 'order_cancelled_no_payment'].include?(dunning_type)
            neo4j_query(<<~END_OF_QUERY, {order_id: order_id})
                MATCH (o:TicketOrder {id: $order_id})
                SET o.status = 'cancelled'
            END_OF_QUERY
        end

        template = get_manual_mail_template(dunning_type)
        unless template
            respond(success: false, error: 'Template nicht gefunden')
            return
        end

        replacements = {
            'NAME' => order['user_name'] || order['user_email'],
            'ORDER_ID' => order['order_id'],
            'REFERENCE' => order['payment_reference'] || 'N/A',
            'TOTAL_PRICE' => sprintf('%.2f', remaining)
        }

        rendered = render_manual_mail_template(dunning_type, replacements)

        begin
            send_manual_mail(
                to_email: order['user_email'],
                subject: rendered[:subject],
                body: rendered[:body],
                template_key: dunning_type,
                sender_username: @session_user[:username],
                recipient_username: order['username'],
                order_id: order['order_id']
            )

            type_labels = {
                'order_reminder_1' => '1. Mahnung',
                'order_reminder_2' => '2. Mahnung',
                'order_cancelled' => 'Stornierung',
                'order_cancelled_no_payment' => 'Stornierung (keine Zahlung)'
            }
            log("#{type_labels[dunning_type]} für Bestellung #{order_id} gesendet an #{order['user_email']}")

            respond(success: true, message: "#{type_labels[dunning_type]} erfolgreich gesendet")
        rescue => e
            STDERR.puts "Error sending dunning mail: #{e.message}"
            respond(success: false, error: "Fehler beim Senden: #{e.message}")
        end
    end
end